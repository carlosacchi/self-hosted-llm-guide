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
  name   = "llm-gpu-autostop"
  role   = aws_iam_role.scheduler_autostop.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "ec2:DescribeInstances"]
        Resource = aws_instance.llm_gpu.arn
      }
    ]
  })
}

resource "aws_scheduler_schedule" "scheduler_autostop" {
  name                         = "llm-gpu-autostop"
  description                  = "Automatically stop the GPU VM nightly at 1 AM Europe/Amsterdam"
  schedule_expression          = "cron(0 1 * * ? *)"
  schedule_expression_timezone = "Europe/Amsterdam"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler_autostop.arn
    input = jsonencode({
      InstanceIds = [aws_instance.llm_gpu.id]
    })
  }
}
