variable "aws_region" {
  description = "AWS Region hosting the GPU workload"
  type        = string
  default     = "eu-central-1"

  validation {
    condition     = contains(["eu-central-1", "eu-west-1", "eu-north-1", "us-east-2"], var.aws_region)
    error_message = "Supported regions: eu-central-1 (Frankfurt), eu-west-1 (Ireland), eu-north-1 (Stockholm), us-east-2 (Ohio)."
  }
}

variable "instance_type" {
  description = "GPU instance size to provision"
  type        = string
  default     = "g5.xlarge"

  validation {
    condition     = contains(["g5.xlarge", "g5.2xlarge", "g5.4xlarge", "g5.8xlarge", "g5.12xlarge", "g5.24xlarge"], var.instance_type)
    error_message = "Supported instance types: g5.xlarge, g5.2xlarge, g5.4xlarge, g5.8xlarge (single GPU) | g5.12xlarge, g5.24xlarge (multi-GPU)."
  }
}

variable "key_pair_name" {
  description = "Optional name of an existing EC2 key pair for SSH access. Leave empty to deploy without a key pair (provisioning runs via cloud-init, no SSH needed)."
  type        = string
  default     = ""
}

variable "run_bootstrap" {
  description = "When true, embed the provisioning scripts in cloud-init user-data and run them automatically on first boot."
  type        = bool
  default     = true
}

# --- Tool selection -----------------------------------------------------------
# Each flag gates one provisioning stack in scripts/bootstrap_all.sh. Mind the
# GPU VRAM budget: on a single 24 GB GPU (g5.xlarge) you cannot run every model
# at once (e.g. a 27B LLM + VibeVoice 7B will OOM). Defaults match the previous
# always-on behavior; the two heavy VibeVoice stacks stay off by default.

variable "enable_monitoring" {
  description = "Provision the Netdata system + GPU monitoring dashboard (port 19999)."
  type        = bool
  default     = true
}

variable "enable_llm" {
  description = "Provision the LLM stack: Docker + NVIDIA + Ollama + Open WebUI (ports 3000/11434)."
  type        = bool
  default     = true
}

variable "enable_tts" {
  description = "Provision the multi-engine TTS stack: Kokoro/XTTS-v2/Piper + Gradio UI (port 7860)."
  type        = bool
  default     = true
}

variable "enable_vibevoice_15b" {
  description = "Provision the VibeVoice multi-speaker 1.5B podcast TTS UI (port 7861)."
  type        = bool
  default     = true
}

variable "enable_vibevoice_realtime" {
  description = "Provision the VibeVoice Realtime single-speaker 0.5B streaming UI (port 7862). Off by default (GPU budget)."
  type        = bool
  default     = false
}

variable "enable_vibevoice_7b" {
  description = "Provision the VibeVoice multi-speaker 7B TTS UI (port 7863, ~16 GB VRAM). Off by default (GPU budget)."
  type        = bool
  default     = false
}

variable "enable_asr" {
  description = "Provision the ASR speech-to-text stack: audio/video/YouTube -> text Gradio UI (port 7864)."
  type        = bool
  default     = false
}

variable "asr_model" {
  description = "ASR backend model. 'whisper-large-v3' is multilingual (incl. Italian, ~3-5 GB VRAM); 'granite-8b' is EN/FR/DE/ES/PT only (~16-18 GB VRAM)."
  type        = string
  default     = "whisper-large-v3"

  validation {
    condition     = contains(["whisper-large-v3", "granite-8b"], var.asr_model)
    error_message = "Supported asr_model values: whisper-large-v3, granite-8b."
  }
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB"
  type        = number
  default     = 200
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

variable "vpc_cidr" {
  description = "CIDR range for the dedicated VPC"
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR range for the public subnet"
  type        = string
  default     = "10.42.0.0/24"
}

variable "availability_zone" {
  description = "Availability zone for the public subnet. Leave empty to auto-select the first AZ in the active region."
  type        = string
  default     = ""
}

variable "aws_max_retries" {
  description = "Max AWS API retry attempts. Kept low so an InsufficientInstanceCapacity error fails in ~1-2 min instead of retrying ~25 times over ~50 min."
  type        = number
  default     = 3
}

variable "additional_tags" {
  description = "Optional tags merged on top of the lab defaults (Environment/Project/ManagedBy)"
  type        = map(string)
  default     = {}
}
