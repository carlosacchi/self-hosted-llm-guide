output "public_ip" {
  description = "Static public address of the GPU VM. Unlike the AWS Elastic IP this is bound at plan time and survives every deallocate/start cycle."
  value       = azurerm_public_ip.llm_gpu.ip_address
}

output "resource_group" {
  description = "Resource group holding every resource this stack owns."
  value       = azurerm_resource_group.llm.name
}

output "vm_name" {
  description = "Name of the GPU VM, for az vm start / az vm deallocate."
  value       = var.vm_enabled ? azurerm_linux_virtual_machine.llm_gpu[0].name : null
}

output "ssh_command" {
  description = "SSH command, or a note when the VM was deployed without a key."
  value = var.vm_enabled ? (
    var.ssh_public_key != ""
    ? "ssh ${var.admin_username}@${azurerm_public_ip.llm_gpu.ip_address}"
    : "No SSH key was supplied; the VM has no interactive login. Provisioning logs: az vm run-command invoke -g ${azurerm_resource_group.llm.name} -n llm-gpu --command-id RunShellScript --scripts 'tail -100 /var/log/llm-lab-bootstrap.log'"
  ) : null
}

output "start_command" {
  description = "Bring the VM back after an autostop deallocate."
  value       = var.vm_enabled ? "az vm start -g ${azurerm_resource_group.llm.name} -n ${azurerm_linux_virtual_machine.llm_gpu[0].name}" : null
}

output "h3_endpoints" {
  description = "MiniMax-H3 entry points once provisioning finishes (first boot downloads ~144 GB, so allow 30-45 minutes)."
  value = var.enable_h3 && var.vm_enabled ? {
    rest_api = "http://${azurerm_public_ip.llm_gpu.ip_address}:30010/v1/videos"
    gradio   = "http://${azurerm_public_ip.llm_gpu.ip_address}:7865"
    netdata  = var.enable_monitoring ? "http://${azurerm_public_ip.llm_gpu.ip_address}:19999" : null
  } : null
}

output "bootstrap_log_command" {
  description = "Follow first-boot provisioning without SSH."
  value       = var.vm_enabled ? "az vm run-command invoke -g ${azurerm_resource_group.llm.name} -n ${azurerm_linux_virtual_machine.llm_gpu[0].name} --command-id RunShellScript --scripts 'tail -200 /var/log/llm-lab-bootstrap.log'" : null
}
