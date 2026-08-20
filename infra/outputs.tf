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

output "asr_ui_url" {
  description = "ASR speech-to-text (audio/video/YouTube -> text) Gradio UI URL"
  value       = "http://${aws_eip.llm_gpu.public_ip}:7864"
}

output "h3_ui_url" {
  description = "MiniMax-H3 video+audio generation Gradio UI URL (empty unless enable_h3)"
  value       = var.enable_h3 ? "http://${aws_eip.llm_gpu.public_ip}:7865" : ""
}

output "h3_api_url" {
  description = "MiniMax-H3 SGLang REST base URL (empty unless enable_h3). The API is asynchronous: POST /v1/videos -> GET /v1/videos/{id} until status is completed -> GET /v1/videos/{id}/content for the MP4."
  value       = var.enable_h3 ? "http://${aws_eip.llm_gpu.public_ip}:30010" : ""
}

output "h3_curl_example" {
  description = "Ready-to-paste smoke test for the H3 REST API"
  value = var.enable_h3 ? join("\n", [
    "curl -sS http://${aws_eip.llm_gpu.public_ip}:30010/v1/videos \\",
    "  -H 'Content-Type: application/json' \\",
    "  -d '{\"model\":\"MiniMaxAI/MiniMax-H3\",\"task\":\"t2va\",\"prompt\":\"A futuristic data center at night, slow dolly shot\",\"seconds\":5,\"conditions\":[],\"target\":{\"short_edge\":768,\"aspect_ratio\":\"16:9\",\"duration_seconds\":5},\"num_inference_steps\":50,\"seed\":1101}'",
    "# then poll: curl http://${aws_eip.llm_gpu.public_ip}:30010/v1/videos/<id>",
    "# then fetch: curl -o out.mp4 http://${aws_eip.llm_gpu.public_ip}:30010/v1/videos/<id>/content",
  ]) : ""
}

output "auto_stop_summary" {
  description = "Active cost guardrails. Three independent layers stop the VM; the nightly cron is only the last one."
  value = join(" | ", [
    var.auto_stop_hours > 0 ? "hard TTL: stops ${var.auto_stop_hours}h after boot" : "hard TTL: DISABLED",
    var.idle_stop_minutes > 0 ? "idle stop: after ${var.idle_stop_minutes}min idle" : "idle stop: DISABLED",
    "nightly cron: 01:00 Europe/Amsterdam",
  ])
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
