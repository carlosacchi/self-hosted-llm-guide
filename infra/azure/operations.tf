# Nightly backstop.
#
# The AWS equivalent is an EventBridge Scheduler calling SetDesiredCapacity(0),
# which TERMINATES the instance and destroys its root volume -- not a preference
# but the only option, because under an Auto Scaling group there is no instance
# id to hand to StopInstances at plan time.
#
# Azure has no such constraint. There is a plain VM with a known id, and the
# platform ships a native auto-shutdown that DEALLOCATES it: the meter stops,
# the OS disk and the ~144 GB model cache survive, and the next morning starts
# in minutes instead of re-downloading the checkpoint.
#
# So this layer is strictly better than its AWS counterpart, and it is also the
# only one of the three that does not depend on the guest being healthy: the
# in-VM TTL and idle timers cannot fire if the VM has wedged, and this can.
resource "azurerm_dev_test_global_vm_shutdown_schedule" "nightly" {
  count = var.vm_enabled ? 1 : 0

  virtual_machine_id = azurerm_linux_virtual_machine.llm_gpu[0].id
  location           = azurerm_resource_group.llm.location
  enabled            = true

  daily_recurrence_time = var.nightly_shutdown_time
  timezone              = var.nightly_shutdown_timezone

  # A notification would need a webhook or an email address to send to, and a
  # 15-minute "are you sure" window is the wrong default for a cost guardrail.
  notification_settings {
    enabled = false
  }

  tags = local.lab_tags
}
