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
    description = "Ollama API"
    from_port   = 11434
    to_port     = 11434
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

  # Provisioning runs via cloud-init on first boot (no SSH / key pair needed).
  # The instance downloads the provisioning scripts from a private S3 bucket
  # using its IAM role, then runs them as root. This keeps user-data under the
  # 16 KB EC2 limit. Logs land in /var/log/llm-lab-bootstrap.log on the VM.
  user_data = var.run_bootstrap ? templatefile("${path.module}/../scripts/user-data.sh", {
    scripts_bucket = aws_s3_bucket.scripts[0].bucket
    aws_region     = var.aws_region
  }) : null

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_tokens = "required"
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
