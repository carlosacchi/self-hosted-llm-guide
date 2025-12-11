output "instance_id" {
  description = "ID of the GPU instance"
  value       = aws_instance.llm_gpu.id
}

output "public_ip" {
  description = "Elastic IP attached to the GPU VM"
  value       = aws_eip.llm_gpu.public_ip
}

output "ssh_command" {
  description = "Helper command for SSH"
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem ubuntu@${aws_eip.llm_gpu.public_ip}"
}

output "vpc_id" {
  description = "ID of the provisioned VPC"
  value       = aws_vpc.llm.id
}

output "subnet_id" {
  description = "ID of the public subnet hosting the GPU VM"
  value       = aws_subnet.public.id
}
