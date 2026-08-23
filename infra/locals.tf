locals {
  lab_tags = merge({
    Environment = "llm-lab"
    Project     = "self-hosted-llm-lab"
    ManagedBy   = "terraform"
    Component   = "gpu-vm"
  }, var.additional_tags)

  ingress_ipv4_cidr = "${var.ipv4_allowed}/32"

  # Instance types that can actually host MiniMax-H3. Both carry 192 GB of total
  # VRAM, which is still not enough to hold the model resident -- layerwise
  # offload to host RAM is mandatory on either -- but they are the only two
  # shapes here where that is even arguable:
  #
  #   g6e.12xlarge  4x L40S 48 GB          384 GiB RAM
  #   g7e.12xlarge  2x RTX PRO 6000 96 GB  512 GiB RAM
  #
  # g5 is deliberately absent: 24 GB A10G cards are far too small per device and
  # the offload recipe would have to be rediscovered from scratch.
  h3_capable_instance_types = ["g6e.12xlarge", "g7e.12xlarge"]

  # H3 is the only workload with a genuinely interchangeable second option, and
  # capacity for *either* of them is the entire reason this deployment uses an
  # Auto Scaling group instead of a single aws_instance.
  default_instance_type_fallbacks = var.enable_h3 ? [
    for t in local.h3_capable_instance_types : t if t != var.instance_type
  ] : []

  # Ordered waterfall, primary first. The ASG tries these in this order.
  requested_instance_types = distinct(concat(
    [var.instance_type],
    length(var.instance_type_fallbacks) > 0 ? var.instance_type_fallbacks : local.default_instance_type_fallbacks,
  ))
}
