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
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.llm_gpu.id]
  associate_public_ip_address = true

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
}

resource "aws_eip" "llm_gpu" {
  domain   = "vpc"
  instance = aws_instance.llm_gpu.id

  depends_on = [aws_internet_gateway.llm]

  tags = merge({
    Name = "llm-gpu-eip"
  }, local.lab_tags)
}

# Copies the provisioning scripts onto the VM and runs them in order.
# Re-runs automatically whenever any of the scripts change (filemd5 triggers),
# so editing a script and re-applying re-provisions without recreating the VM.
resource "null_resource" "bootstrap" {
  count = var.run_bootstrap ? 1 : 0

  triggers = {
    instance_id  = aws_instance.llm_gpu.id
    bootstrap_sh = filemd5("${path.module}/../scripts/bootstrap_all.sh")
    llm_script   = filemd5("${path.module}/../scripts/provision_llm_stack.sh")
    tts_script   = filemd5("${path.module}/../scripts/provision_tts_stack.sh")
  }

  connection {
    type        = "ssh"
    host        = aws_eip.llm_gpu.public_ip
    user        = "ubuntu"
    private_key = file(local.ssh_private_key_path)
    timeout     = "10m"
  }

  # Ensure the destination directory exists before uploading.
  provisioner "remote-exec" {
    inline = ["mkdir -p /home/ubuntu/provisioning"]
  }

  # Upload the contents of scripts/ into /home/ubuntu/provisioning.
  provisioner "file" {
    source      = "${path.module}/../scripts/"
    destination = "/home/ubuntu/provisioning"
  }

  # Make them executable and run the orchestrator.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /home/ubuntu/provisioning/*.sh",
      "sudo bash /home/ubuntu/provisioning/bootstrap_all.sh",
    ]
  }
}
