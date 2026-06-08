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

variable "additional_tags" {
  description = "Optional tags merged on top of the lab defaults (Environment/Project/ManagedBy)"
  type        = map(string)
  default     = {}
}
