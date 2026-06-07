locals {
  lab_tags = merge({
    Environment = "llm-lab"
    Project     = "self-hosted-llm-lab"
    ManagedBy   = "terraform"
  }, var.additional_tags)

  ingress_ipv4_cidr = "${var.ipv4_allowed}/32"

  # Resolve the SSH private key: explicit override, or ~/.ssh/<key_pair_name>.pem
  ssh_private_key_path = var.ssh_private_key_path != "" ? pathexpand(var.ssh_private_key_path) : pathexpand("~/.ssh/${var.key_pair_name}.pem")
}
