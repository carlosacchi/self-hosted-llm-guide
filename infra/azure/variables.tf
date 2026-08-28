variable "location" {
  description = "Azure region hosting the GPU workload. GPU SKUs are region-scoped AND quota-gated per family, so a region that lists the SKU can still refuse to allocate it. The workflow runs `az vm list-skus` / `az vm list-usage` before apply."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group to create for the lab. Everything the stack owns lives here, so `terraform destroy` and a manual group delete are equivalent."
  type        = string
  default     = "llm-gpu-lab"
}

variable "vm_size" {
  description = "Azure VM size. Unlike the AWS side there is no capacity waterfall: a single VM has no equivalent of the ASG's mixed_instances_policy, so the retry across sizes lives in the workflow instead."
  type        = string
  default     = "Standard_NC80adis_H100_v5"

  validation {
    condition = contains([
      "Standard_NC40ads_H100_v5",
      "Standard_NC80adis_H100_v5",
      "Standard_NC144ds_xl_RTXPRO6000BSE_v6",
      "Standard_NC288ds_xl_RTXPRO6000BSE_v6",
      "Standard_NC288lds_xl_RTXPRO6000BSE_v6",
      "Standard_NC24ads_A100_v4",
      "Standard_NC48ads_A100_v4",
      "Standard_NC96ads_A100_v4",
      "Standard_NV36ads_A10_v5",
      "Standard_NV72ads_A10_v5",
    ], var.vm_size)
    error_message = "Supported sizes: NC40ads/NC80adis_H100_v5 (1-2x H100 NVL 94 GB) | NC144ds_xl/NC288ds_xl/NC288lds_xl_RTXPRO6000BSE_v6 (1-2x RTX PRO 6000 96 GB) | NC24/48/96ads_A100_v4 (1-4x A100 80 GB) | NV36ads/NV72ads_A10_v5 (1-2x A10 24 GB)."
  }
}

variable "admin_username" {
  description = "Local admin user on the VM. Azure has no concept of an EC2 key pair as a separate resource, so the public key is supplied inline via ssh_public_key."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "OpenSSH public key granted access to admin_username. Leave empty to deploy with no SSH access at all (provisioning still runs via cloud-init). Azure refuses password auth on Linux by default, so an empty key means the VM is genuinely unreachable by SSH."
  type        = string
  default     = ""
}

variable "ipv4_allowed" {
  description = "Single IPv4 address allowed to reach SSH/Web/API"
  type        = string
  default     = "0.0.0.0"

  validation {
    condition     = can(cidrnetmask("${var.ipv4_allowed}/32"))
    error_message = "Provide a valid IPv4 address (x.x.x.x)"
  }
}

variable "vnet_cidr" {
  description = "CIDR range for the dedicated virtual network."
  type        = string
  default     = "10.42.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR range for the single public subnet holding the VM."
  type        = string
  default     = "10.42.0.0/24"
}

variable "run_bootstrap" {
  description = "When true, provisioning runs automatically on first boot via cloud-init custom_data."
  type        = bool
  default     = true
}

variable "vm_enabled" {
  description = "Whether the GPU VM exists at all. false is the Azure equivalent of desired_capacity = 0: it destroys the VM while keeping the VNet/NSG/storage/identity scaffolding, so the next apply is fast."
  type        = bool
  default     = true
}

# --- Tool selection -----------------------------------------------------------
# Only the H3 stack is wired up on Azure for now; the other stacks stay off so
# the box is never asked to share VRAM with them. Netdata is cheap and stays on.

variable "enable_monitoring" {
  description = "Provision the Netdata system + GPU monitoring dashboard (port 19999)."
  type        = bool
  default     = true
}

variable "enable_h3" {
  description = "Provision the MiniMax-H3 stack: SGLang-Diffusion image-reference video+audio generation (REST 30010, Gradio UI 7865). Serves the Ref2VA checkpoint partition."
  type        = bool
  default     = true
}

variable "h3_sglang_image" {
  description = "Pinned SGLang container image serving H3. Deliberately NOT ':latest': H3 landed in SGLang-Diffusion recently and CLI flags/behavior still move between releases."
  type        = string
  default     = "lmsysorg/sglang:v0.5.17-cu129"
}

variable "os_disk_size" {
  description = "OS disk size in GiB. H3 needs >= 300 for the ~144 GB Ref2VA partition plus the pinned SGLang image and generated MP4s -- but the default is 1024 because on Premium_LRS the performance tier is derived from the capacity, and throughput is the real bottleneck: at the P20 (512 GiB) tier's 150 MB/s, writing the checkpoint costs ~16 minutes of paid-for VM time and every later boot re-reads it. P30 (1024 GiB) doubles that to 200 MB/s. The extra space is bought for the speed, not the room."
  type        = number
  default     = 1024

  validation {
    condition     = var.os_disk_size >= 300
    error_message = "os_disk_size must be at least 300 GiB to hold the Ref2VA checkpoint, the SGLang image and the CUDA/torch layers."
  }
}

variable "os_disk_type" {
  description = "Managed disk SKU for the OS disk. Premium SSD v2 is deliberately absent: it is the true gp3 analogue (IOPS and throughput provisioned independently of capacity) but Azure does not allow it to back an OS disk, and attaching it as a zonal data disk would pin the VM to one availability zone -- a bad trade when the GPU SKU is already capacity-constrained."
  type        = string
  default     = "Premium_LRS"

  validation {
    condition     = contains(["Premium_LRS", "StandardSSD_LRS"], var.os_disk_type)
    error_message = "Supported OS disk types: Premium_LRS, StandardSSD_LRS."
  }
}

# --- Cost guardrails ----------------------------------------------------------
# Same three layers as AWS, with one load-bearing difference: on Azure a guest
# poweroff leaves the VM ALLOCATED and fully billed. Every layer here has to
# reach the ARM control plane to actually stop the meter.

variable "auto_stop_hours" {
  description = "Hard time-to-live: deallocate the VM this many hours after boot, no matter what. 0 disables it."
  type        = number
  default     = 4

  validation {
    condition     = var.auto_stop_hours >= 0 && var.auto_stop_hours <= 24
    error_message = "auto_stop_hours must be between 0 (disabled) and 24."
  }
}

variable "idle_stop_minutes" {
  description = "Deallocate the VM after this many minutes with an idle GPU and no inbound service activity. 0 disables it."
  type        = number
  default     = 30

  validation {
    condition     = var.idle_stop_minutes == 0 || var.idle_stop_minutes >= 10
    error_message = "idle_stop_minutes must be 0 (disabled) or at least 10, to avoid stopping the VM while a model is still loading."
  }
}

variable "nightly_shutdown_time" {
  description = "Nightly backstop, as HHmm in nightly_shutdown_timezone. Azure's native auto-shutdown DEALLOCATES rather than deleting, so unlike the AWS nightly layer the model cache survives until morning."
  type        = string
  default     = "0100"
}

variable "nightly_shutdown_timezone" {
  description = "Windows timezone id for the nightly shutdown (Azure uses Windows names even for Linux VMs)."
  type        = string
  default     = "W. Europe Standard Time"
}

variable "additional_tags" {
  description = "Optional tags merged on top of the lab defaults (Environment/Project/ManagedBy)"
  type        = map(string)
  default     = {}
}
