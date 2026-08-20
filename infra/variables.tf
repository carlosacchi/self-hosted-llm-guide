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
    condition     = contains(["g5.xlarge", "g5.2xlarge", "g5.4xlarge", "g5.8xlarge", "g5.12xlarge", "g5.24xlarge", "g6e.12xlarge"], var.instance_type)
    error_message = "Supported instance types: g5.xlarge, g5.2xlarge, g5.4xlarge, g5.8xlarge (single A10G) | g5.12xlarge, g5.24xlarge (multi A10G) | g6e.12xlarge (4x L40S 48 GB, required by the MiniMax-H3 stack)."
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

# --- MiniMax-H3 (video + audio generation, SGLang-Diffusion) -----------------
# H3 is an entire workload on its own: a 33B flow-matching DiT that denoises
# joint video+audio latents. It needs the whole box, so enable_h3 is mutually
# exclusive with every other GPU stack (enforced by preconditions in compute.tf).

variable "enable_h3" {
  description = "Provision the MiniMax-H3 stack: SGLang-Diffusion video+audio generation (REST 30010, Gradio UI 7865). Requires g6e.12xlarge and excludes every other GPU stack."
  type        = bool
  default     = false
}

variable "h3_variant" {
  description = "MiniMax-H3 checkpoint partition. Only 'fl2va' is supported here (it serves both t2va and fl2va tasks)."
  type        = string
  default     = "fl2va"

  validation {
    condition     = contains(["fl2va"], var.h3_variant)
    error_message = "Only 'fl2va' is supported. The 'ref2va' partition is deliberately excluded: on 4x L40S (compute capability 8.9) it produces snow/noise output on every run, while fl2va is healthy on the same hardware. See https://github.com/sgl-project/sglang/issues/34110. fl2va covers text-to-video-and-audio (t2va) and first/last-frame conditioning."
  }
}

variable "h3_sglang_image" {
  description = "Pinned SGLang container image serving H3. Deliberately NOT ':latest': H3 landed in SGLang-Diffusion recently and CLI flags/behavior still move between releases."
  type        = string
  default     = "lmsysorg/sglang:v0.5.17-cu129"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. The H3 stack needs >= 300: the FL2VA partition alone is ~144 GB on disk (66 GB transformer + 66 GB text encoder + 10 GB video VAE), plus the pinned SGLang image and generated videos."
  type        = number
  default     = 200
}

variable "root_volume_throughput" {
  description = "Root gp3 throughput in MiB/s (125-1000). This is the real bottleneck for H3: writing the 144 GB FL2VA checkpoint at the 125 MiB/s default takes ~19 minutes of paid-for instance time, and every later boot re-reads it. At 1000 MiB/s that drops to ~2.5 minutes."
  type        = number
  default     = 125

  validation {
    condition     = var.root_volume_throughput >= 125 && var.root_volume_throughput <= 1000
    error_message = "gp3 throughput must be between 125 and 1000 MiB/s."
  }
}

# --- Cost guardrails ----------------------------------------------------------
# The nightly EventBridge stop (operations.tf) is the last line of defense, not
# the first. On a g6e.12xlarge (~$13/h in eu-central-1) forgetting the VM running
# from 09:00 until the 01:00 cron costs ~$210. These two knobs shut the box down
# from the inside; on an EBS-backed instance an OS poweroff *stops* it (default
# instanceInitiatedShutdownBehavior), so the volume and model cache survive.

variable "auto_stop_hours" {
  description = "Hard time-to-live: stop the VM this many hours after boot, no matter what. 0 disables it."
  type        = number
  default     = 4

  validation {
    condition     = var.auto_stop_hours >= 0 && var.auto_stop_hours <= 24
    error_message = "auto_stop_hours must be between 0 (disabled) and 24."
  }
}

variable "idle_stop_minutes" {
  description = "Stop the VM after this many minutes with an idle GPU and no inbound service activity. 0 disables it."
  type        = number
  default     = 30

  validation {
    condition     = var.idle_stop_minutes == 0 || var.idle_stop_minutes >= 10
    error_message = "idle_stop_minutes must be 0 (disabled) or at least 10, to avoid stopping the VM while a model is still loading."
  }
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
