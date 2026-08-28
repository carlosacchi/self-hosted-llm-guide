# Provisioning artifacts and access.
#
# The AWS analogue of this file is infra/aws/provisioning.tf: scripts to a
# private bucket, an instance role that can read it, and cloud-init pulling them
# on first boot. The shape is identical here; only the primitives change.
#
#   S3 bucket + IAM instance profile  ->  Storage Account container + a
#                                         system-assigned managed identity
#   s3:GetObject policy               ->  "Storage Blob Data Reader" role
#   16 KB user-data limit             ->  64 KB custom_data limit
#
# The 64 KB ceiling is four times EC2's, but scripts/ is ~200 KB, so the
# indirection through blob storage is still required rather than merely tidy.

locals {
  provisioning_scripts = {
    "bootstrap_all.sh"              = "${path.module}/../../scripts/bootstrap_all.sh"
    "lib_docker_gpu.sh"             = "${path.module}/../../scripts/lib_docker_gpu.sh"
    "lib_cloud.sh"                  = "${path.module}/../../scripts/lib_cloud.sh"
    "provision_monitoring_stack.sh" = "${path.module}/../../scripts/provision_monitoring_stack.sh"
    "provision_h3_stack.sh"         = "${path.module}/../../scripts/provision_h3_stack.sh"
    "provision_h3_ui_stack.sh"      = "${path.module}/../../scripts/provision_h3_ui_stack.sh"
    "provision_autostop.sh"         = "${path.module}/../../scripts/provision_autostop.sh"
    "provision_landing_stack.sh"    = "${path.module}/../../scripts/provision_landing_stack.sh"
  }
}

# Storage account names are globally unique across all of Azure, 3-24 chars,
# lowercase alphanumeric only -- no hyphens, so the AWS bucket_prefix idiom does
# not translate directly.
resource "random_string" "storage_suffix" {
  length  = 10
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "scripts" {
  name                = "llmlabscripts${random_string.storage_suffix.result}"
  resource_group_name = azurerm_resource_group.llm.name
  location            = azurerm_resource_group.llm.location

  account_tier             = "Standard"
  account_replication_type = "LRS"

  # The VM authenticates with its managed identity, so the shared keys are dead
  # weight; disabling them removes the most common way this kind of bucket leaks.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  min_tls_version                 = "TLS1_2"

  tags = merge({ Name = "llm-lab-scripts" }, local.lab_tags)
}

resource "azurerm_storage_container" "scripts" {
  name                  = "provisioning"
  storage_account_id    = azurerm_storage_account.scripts.id
  container_access_type = "private"
}

# content_md5 makes Terraform re-upload whenever a script changes, so
# re-applying refreshes the artifacts the same way the S3 etag does.
resource "azurerm_storage_blob" "scripts" {
  for_each = local.provisioning_scripts

  name                   = each.key
  storage_account_name   = azurerm_storage_account.scripts.name
  storage_container_name = azurerm_storage_container.scripts.name
  type                   = "Block"
  source                 = each.value
  content_md5            = filemd5(each.value)
}

# --- What the VM is allowed to do --------------------------------------------
#
# Two grants, both scoped as narrowly as the operation allows.

# 1. Read the provisioning scripts. Container-scoped, not account-scoped.
resource "azurerm_role_assignment" "scripts_read" {
  count = var.vm_enabled ? 1 : 0

  scope                = azurerm_storage_container.scripts.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_linux_virtual_machine.llm_gpu[0].identity[0].principal_id
}

# 2. Deallocate itself.
#
# This is what makes the autostop guardrails actually stop the bill on Azure. A
# guest poweroff leaves the VM allocated and fully billed; only an ARM
# deallocate ends the meter, and the call has to be authorised. The scope is the
# VM's own resource id, so the identity can stop this one machine and nothing
# else -- it cannot create, resize or reach any other resource in the group.
#
# Assigning a role requires the deploying principal to hold "User Access
# Administrator" or "Owner" on the subscription. Contributor alone is not
# enough, and the failure surfaces here rather than at login.
resource "azurerm_role_assignment" "deallocate_self" {
  count = var.vm_enabled ? 1 : 0

  scope                = azurerm_linux_virtual_machine.llm_gpu[0].id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_linux_virtual_machine.llm_gpu[0].identity[0].principal_id
}
