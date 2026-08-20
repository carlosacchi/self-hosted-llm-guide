data "aws_ami" "dlami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning OSS Nvidia Driver*Ubuntu 22.04*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "llm_gpu" {
  name_prefix = "llm-gpu-"
  description = "Access for self-hosted LLM lab"
  vpc_id      = aws_vpc.llm.id

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "Landing page portal (nginx)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "WEB UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "FastAPI access"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "Gradio TTS UI"
    from_port   = 7860
    to_port     = 7860
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "VibeVoice Realtime TTS UI"
    from_port   = 7861
    to_port     = 7861
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "VibeVoice multi-speaker TTS UI (1.5B)"
    from_port   = 7862
    to_port     = 7862
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "VibeVoice multi-speaker TTS UI (7B)"
    from_port   = 7863
    to_port     = 7863
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "ASR speech-to-text UI"
    from_port   = 7864
    to_port     = 7864
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "MiniMax-H3 video generation UI (Gradio)"
    from_port   = 7865
    to_port     = 7865
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "Ollama API"
    from_port   = 11434
    to_port     = 11434
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "MiniMax-H3 SGLang REST API (/v1/videos)"
    from_port   = 30010
    to_port     = 30010
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "Netdata monitoring dashboard"
    from_port   = 19999
    to_port     = 19999
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge({
    Name = "llm-gpu-access"
  }, local.lab_tags)
}

resource "aws_instance" "llm_gpu" {
  ami                         = data.aws_ami.dlami.id
  instance_type               = var.instance_type
  key_name                    = var.key_pair_name != "" ? var.key_pair_name : null
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.llm_gpu.id]
  associate_public_ip_address = true
  iam_instance_profile        = var.run_bootstrap ? aws_iam_instance_profile.llm_gpu[0].name : null

  # Pinned explicitly, NOT left to the AWS default. The autostop guardrails work
  # by calling poweroff from inside the VM; with "terminate" that would destroy
  # the instance and its root volume (and the 144 GB model cache with it) every
  # time the box went idle. "stop" makes an OS shutdown a plain EC2 stop.
  instance_initiated_shutdown_behavior = "stop"

  # Provisioning runs via cloud-init on first boot (no SSH / key pair needed).
  # The instance downloads the provisioning scripts from a private S3 bucket
  # using its IAM role, then runs them as root. This keeps user-data under the
  # 16 KB EC2 limit. Logs land in /var/log/llm-lab-bootstrap.log on the VM.
  user_data = var.run_bootstrap ? templatefile("${path.module}/../scripts/user-data.sh", {
    scripts_bucket = aws_s3_bucket.scripts[0].bucket
    aws_region     = var.aws_region

    # Tool selection flags (rendered as "true"/"false" strings in the script).
    enable_monitoring         = var.enable_monitoring
    enable_llm                = var.enable_llm
    enable_tts                = var.enable_tts
    enable_vibevoice_15b      = var.enable_vibevoice_15b
    enable_vibevoice_realtime = var.enable_vibevoice_realtime
    enable_vibevoice_7b       = var.enable_vibevoice_7b
    enable_asr                = var.enable_asr
    asr_model                 = var.asr_model
    enable_h3                 = var.enable_h3
    h3_variant                = var.h3_variant
    h3_sglang_image           = var.h3_sglang_image

    # Cost guardrails, applied to every workload (not just H3).
    auto_stop_hours   = var.auto_stop_hours
    idle_stop_minutes = var.idle_stop_minutes
  }) : null

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    throughput            = var.root_volume_throughput
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_tokens = "required"
  }

  # Fail in `plan`, not 20 minutes into a $13/h boot. Terraform's required_version
  # here is >= 1.6.0 and cross-variable `validation` blocks need >= 1.9, so these
  # cross-cutting rules live as resource preconditions instead.
  lifecycle {
    precondition {
      condition     = !var.enable_h3 || var.instance_type == "g6e.12xlarge"
      error_message = "enable_h3 requires instance_type = \"g6e.12xlarge\" (4x L40S 48 GB). H3 cannot run on a single GPU, and the other multi-GPU sizes in this repo (g5.12xlarge/g5.24xlarge) are A10G 24 GB, far too small even with layerwise offload."
    }

    precondition {
      condition     = !var.enable_h3 || var.root_volume_size >= 300
      error_message = "enable_h3 requires root_volume_size >= 300 GiB. The FL2VA partition alone is ~144 GB on disk (the HF repo also ships a Ref2VA partition and a parallel diffusers layout, ~498 GB in total, which this stack deliberately does NOT download), plus the pinned SGLang image, CUDA/torch layers and generated MP4s. 200 GiB fills up mid-provisioning."
    }

    precondition {
      condition     = !var.enable_h3 || contains(["eu-central-1", "eu-north-1"], var.aws_region)
      error_message = "enable_h3 requires aws_region to be eu-central-1 or eu-north-1. g6e.12xlarge is not offered in eu-west-1 at all, and while it exists in us-east-2 the account's 'Running On-Demand G and VT instances' quota there is 0."
    }

    precondition {
      condition = !var.enable_h3 || !(
        var.enable_llm || var.enable_tts || var.enable_vibevoice_15b ||
        var.enable_vibevoice_realtime || var.enable_vibevoice_7b || var.enable_asr
      )
      error_message = "enable_h3 is mutually exclusive with every other GPU stack (enable_llm/enable_tts/enable_vibevoice_*/enable_asr). H3 needs all 4 GPUs plus most of the host RAM for layerwise offload; sharing the box guarantees an OOM. Netdata monitoring may stay on."
    }
  }

  tags = merge({
    Name = "llm-gpu-${var.instance_type}"
  }, local.lab_tags)

  depends_on = [aws_s3_object.scripts]
}

resource "aws_eip" "llm_gpu" {
  domain   = "vpc"
  instance = aws_instance.llm_gpu.id

  depends_on = [aws_internet_gateway.llm]

  tags = merge({
    Name = "llm-gpu-eip"
  }, local.lab_tags)
}
