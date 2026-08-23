resource "aws_iam_role" "scheduler_autostop" {
  name_prefix = "llm-gpu-autostop-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge({
    Name = "llm-gpu-autostop-role"
  }, local.lab_tags)
}

resource "aws_iam_role_policy" "scheduler_autostop" {
  name = "llm-gpu-autostop"
  role = aws_iam_role.scheduler_autostop.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["autoscaling:SetDesiredCapacity"]
        Resource = aws_autoscaling_group.llm_gpu.arn
      },
      {
        Effect   = "Allow"
        Action   = ["autoscaling:DescribeAutoScalingGroups"]
        Resource = "*"
      },
    ]
  })
}

# Nightly backstop.
#
# The other two guardrails (hard TTL and idle probe, both systemd timers inside
# the VM) call poweroff, which STOPS the instance and keeps the root volume and
# its model cache. This one is deliberately harsher: it scales the group to
# zero, which TERMINATES the instance and destroys the root volume with it.
#
# That is not a preference, it is the only option available. EventBridge can
# only call StopInstances with an explicit instance ID, and under an Auto
# Scaling group there is no instance ID at plan time. SetDesiredCapacity works
# on the group name, which Terraform does know.
#
# The trade: an overnight forget costs a model re-download tomorrow (~30-45 min
# of instance time for H3) instead of ~$210 of runtime. A snapshot-backed
# /opt/models volume would remove the trade; until then this is the layer that
# guarantees the bill actually stops.
resource "aws_scheduler_schedule" "scheduler_autostop" {
  name                         = "llm-gpu-autostop"
  description                  = "Scale the GPU Auto Scaling group to zero nightly at 1 AM Europe/Amsterdam"
  schedule_expression          = "cron(0 1 * * ? *)"
  schedule_expression_timezone = "Europe/Amsterdam"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:autoscaling:setDesiredCapacity"
    role_arn = aws_iam_role.scheduler_autostop.arn
    input = jsonencode({
      AutoScalingGroupName = aws_autoscaling_group.llm_gpu.name
      DesiredCapacity      = 0
    })
  }
}
