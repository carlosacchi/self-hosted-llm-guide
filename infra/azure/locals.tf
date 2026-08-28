locals {
  lab_tags = merge({
    Environment = "llm-lab"
    Project     = "self-hosted-llm-lab"
    ManagedBy   = "terraform"
    Component   = "gpu-vm"
  }, var.additional_tags)

  ingress_ipv4_cidr = "${var.ipv4_allowed}/32"

  # VM sizes that can actually host MiniMax-H3.
  #
  #   Standard_NC80adis_H100_v5           2x H100 NVL 94 GB (sm_90)   640 GiB RAM
  #   Standard_NC288ds_xl_RTXPRO6000BSE   2x RTX PRO 6000 96 GB (sm_120) 1032 GiB
  #   Standard_NC288lds_xl_RTXPRO6000BSE  2x RTX PRO 6000 96 GB (sm_120)  516 GiB
  #
  # H100 NVL is the default rather than the RTX PRO 6000 that the AWS side uses,
  # for two reasons. The SGLang cookbook publishes a verified H100 TP2 recipe and
  # no RTX PRO 6000 profile at all, so the H100 path starts from measured
  # numbers instead of rediscovering them on the meter. And on Azure the second
  # RTX PRO 6000 is only sold attached to 288 vCPUs, which this workload does not
  # use: NC144ds_xl stops at one GPU.
  #
  # Single-GPU sizes are excluded even at 94-96 GB: H3 needs the TP2 shard to
  # keep the DiT resident, and one card would put it back on layerwise offload.
  #
  # A100 and A10 sizes are absent on purpose. A100 (sm_80) has no published H3
  # recipe, and 24 GB A10 cards are far too small per device.
  h3_capable_vm_sizes = [
    "Standard_NC80adis_H100_v5",
    "Standard_NC288ds_xl_RTXPRO6000BSE_v6",
    "Standard_NC288lds_xl_RTXPRO6000BSE_v6",
  ]

  # Ports reachable from ipv4_allowed. Kept as data so the NSG is one rule per
  # entry instead of five near-identical blocks.
  ingress_ports = {
    22    = "SSH access"
    80    = "Landing page portal (nginx)"
    7865  = "MiniMax-H3 video generation UI (Gradio)"
    19999 = "Netdata monitoring dashboard"
    30010 = "MiniMax-H3 SGLang REST API (/v1/videos)"
  }
}
