locals {
  lab_tags = merge({
    Environment = "llm-lab"
    Project     = "self-hosted-llm-lab"
    ManagedBy   = "terraform"
    Component   = "gpu-vm"
  }, var.additional_tags)

  ingress_ipv4_cidr = "${var.ipv4_allowed}/32"
}
