# The GPU VM.
#
# Deliberately a plain VM, not a scale set. On AWS the Auto Scaling group earns
# its complexity by hunting capacity across instance types and zones; Azure has
# no equivalent for a single instance, so a VMSS here would buy nothing and cost
# two real things: the public IP could no longer be bound at plan time, and an
# idle-deallocated instance would be a candidate for reimaging. The size
# waterfall lives in the workflow instead.

resource "azurerm_linux_virtual_machine" "llm_gpu" {
  count = var.vm_enabled ? 1 : 0

  name                = "llm-gpu"
  resource_group_name = azurerm_resource_group.llm.name
  location            = azurerm_resource_group.llm.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.llm_gpu.id]

  # Azure has no separate key-pair resource: the public key is supplied inline.
  # With none supplied the VM has no usable SSH login at all, because password
  # authentication stays disabled -- provisioning still runs via cloud-init.
  disable_password_authentication = true

  dynamic "admin_ssh_key" {
    for_each = var.ssh_public_key != "" ? [1] : []
    content {
      username   = var.admin_username
      public_key = var.ssh_public_key
    }
  }

  # Needed twice over: to read the provisioning blobs, and to deallocate itself
  # when the autostop guardrails fire. See provisioning.tf for both grants.
  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size
  }

  # Plain Ubuntu, not a Marketplace AI image. The NVIDIA GPU-optimized VMI would
  # arrive with drivers preinstalled like the AWS DLAMI does, but it carries a
  # Marketplace plan that has to be accepted per-subscription before any deploy
  # succeeds -- a manual step that breaks an otherwise self-contained workflow.
  # The driver comes from the extension below instead.
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = var.run_bootstrap ? base64encode(templatefile("${path.module}/../../scripts/user-data-azure.sh", {
    storage_account = azurerm_storage_account.scripts.name
    container       = azurerm_storage_container.scripts.name
    script_names    = join(" ", sort(keys(local.provisioning_scripts)))

    enable_monitoring = var.enable_monitoring
    enable_h3         = var.enable_h3
    h3_sglang_image   = var.h3_sglang_image

    auto_stop_hours   = var.auto_stop_hours
    idle_stop_minutes = var.idle_stop_minutes
  })) : null

  tags = merge({ Name = "llm-gpu" }, local.lab_tags)

  lifecycle {
    # Fail in `plan`, not 30 minutes into an expensive boot.
    precondition {
      condition     = !var.enable_h3 || contains(local.h3_capable_vm_sizes, var.vm_size)
      error_message = "enable_h3 requires one of ${join(", ", local.h3_capable_vm_sizes)}. Got: ${var.vm_size}. H3 needs two large cards: the TP2 shard is what keeps the DiT resident, and a single-GPU size puts it back on layerwise offload."
    }

    precondition {
      condition     = !var.enable_h3 || var.os_disk_size >= 300
      error_message = "enable_h3 requires os_disk_size >= 300 GiB. The Ref2VA checkpoint partition is ~144 GB on disk (the HF repo also ships the FL2VA partition and a parallel diffusers layout, ~498 GB in total, which this stack deliberately does NOT download), plus the pinned SGLang image, CUDA/torch layers and generated MP4s."
    }
  }
}

# The AWS Deep Learning AMI ships the NVIDIA driver; plain Ubuntu does not, and
# nothing in scripts/ installs it -- configure_nvidia_toolkit_if_needed() checks
# for nvidia-smi and silently falls back to CPU-only when it is missing.
#
# This extension and cloud-init run CONCURRENTLY, so the bootstrap would race the
# driver install and lose. user-data-azure.sh waits for nvidia-smi before doing
# anything; that wait is the other half of this resource.
resource "azurerm_virtual_machine_extension" "nvidia_driver" {
  count = var.vm_enabled ? 1 : 0

  name                       = "NvidiaGpuDriverLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.llm_gpu[0].id
  publisher                  = "Microsoft.HpcCompute"
  type                       = "NvidiaGpuDriverLinux"
  type_handler_version       = "1.9"
  auto_upgrade_minor_version = true

  tags = local.lab_tags
}
