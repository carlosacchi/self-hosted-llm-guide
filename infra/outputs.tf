output "instance_id" {
  description = "ID of the GPU instance"
  value       = aws_instance.llm_gpu.id
}

output "public_ip" {
  description = "Elastic IP attached to the GPU VM"
  value       = aws_eip.llm_gpu.public_ip
}

output "ssh_command" {
  description = "Helper command for SSH (only when a key pair was provided)"
  value       = var.key_pair_name != "" ? "ssh -i ~/.ssh/${var.key_pair_name}.pem ubuntu@${aws_eip.llm_gpu.public_ip}" : "No key pair configured. Provisioning runs automatically via cloud-init; use EC2 Instance Connect or SSM Session Manager from the AWS console if you need shell access."
}

output "portal_url" {
  description = "Landing page portal linking every service (start here)"
  value       = "http://${aws_eip.llm_gpu.public_ip}/"
}

output "web_ui_url" {
  description = "Open WebUI (LLM chat) URL"
  value       = "http://${aws_eip.llm_gpu.public_ip}:3000"
}

output "tts_ui_url" {
  description = "Gradio TTS UI URL"
  value       = "http://${aws_eip.llm_gpu.public_ip}:7860"
}

output "vibevoice_ui_url" {
  description = "VibeVoice 1.5B multi-speaker (podcast) TTS UI URL"
  value       = "http://${aws_eip.llm_gpu.public_ip}:7861"
}

output "monitoring_url" {
  description = "Netdata monitoring dashboard URL (GPU, CPU, RAM, disk)"
  value       = "http://${aws_eip.llm_gpu.public_ip}:19999"
}

output "ollama_api_url" {
  description = "Ollama REST API base URL (restricted to ipv4_allowed)"
  value       = "http://${aws_eip.llm_gpu.public_ip}:11434"
}

output "vpc_id" {
  description = "ID of the provisioned VPC"
  value       = aws_vpc.llm.id
}

output "subnet_id" {
  description = "ID of the public subnet hosting the GPU VM"
  value       = aws_subnet.public.id
}
