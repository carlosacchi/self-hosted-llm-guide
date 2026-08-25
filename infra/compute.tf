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
    description = "Landing page portal (nginx)"
    from_port   = 80
    to_port     = 80
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
    description = "VibeVoice multi-speaker TTS UI (1.5B)"
    from_port   = 7862
    to_port     = 7862
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "VibeVoice multi-speaker TTS UI (7B)"
    from_port   = 7863
    to_port     = 7863
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "ASR speech-to-text UI"
    from_port   = 7864
    to_port     = 7864
    protocol    = "tcp"
    cidr_blocks = [local.ingress_ipv4_cidr]
  }

  ingress {
    description = "MiniMax-H3 video generation UI (Gradio)"
    from_port   = 7865
    to_port     = 7865
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
    description = "MiniMax-H3 SGLang REST API (/v1/videos)"
    from_port   = 30010
    to_port     = 30010
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

# The instance is launched by an Auto Scaling group, not created directly.
#
# This is NOT autoscaling. min=0 / max=1 / desired=1 turns the group into a
# capacity broker: instead of "give me exactly a g6e.12xlarge in eu-central-1a"
# (one shot, one pool, InsufficientInstanceCapacity, done), it says "give me any
# of these compatible shapes in any of these zones, and keep trying". G6e and
# G7e .12xlarge pools are thin per-AZ and there is no AWS API to check capacity
# before launching, so blind retries against a single pool are the actual
# failure mode this replaces.
resource "aws_launch_template" "llm_gpu" {
  name_prefix   = "llm-gpu-"
  image_id      = data.aws_ami.dlami.id
  instance_type = local.primary_instance_type
  key_name      = var.key_pair_name != "" ? var.key_pair_name : null

  update_default_version = true

  # Pinned explicitly, NOT left to the AWS default. The autostop guardrails work
  # by calling poweroff from inside the VM; with "terminate" that would destroy
  # the instance and its root volume (and the 144 GB model cache with it) every
  # time the box went idle. "stop" makes an OS shutdown a plain EC2 stop -- see
  # the suspended_processes note on the ASG for why that survives here.
  instance_initiated_shutdown_behavior = "stop"

  dynamic "iam_instance_profile" {
    for_each = var.run_bootstrap ? [1] : []
    content {
      name = aws_iam_instance_profile.llm_gpu[0].name
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.llm_gpu.id]
  }

  block_device_mappings {
    device_name = data.aws_ami.dlami.root_device_name

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      throughput            = var.root_volume_throughput
      iops                  = local.root_volume_iops
      delete_on_termination = "true"
      encrypted             = "true"
    }
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"

    # Exposes the ASG name to the instance as aws:autoscaling/groupName without
    # an IAM call. Nothing reads it today, but it is the only way for in-VM
    # tooling to learn its own group without a launch-template -> ASG ->
    # launch-template dependency cycle.
    instance_metadata_tags = "enabled"
  }

  # Provisioning runs via cloud-init on first boot (no SSH / key pair needed).
  # The instance downloads the provisioning scripts from a private S3 bucket
  # using its IAM role, then runs them as root. This keeps user-data under the
  # 16 KB EC2 limit. Logs land in /var/log/llm-lab-bootstrap.log on the VM.
  user_data = var.run_bootstrap ? base64encode(templatefile("${path.module}/../scripts/user-data.sh", {
    scripts_bucket = aws_s3_bucket.scripts[0].bucket
    aws_region     = var.aws_region

    # The ASG picks the AZ, so the public address cannot be attached by
    # Terraform any more; the instance claims it on boot instead.
    eip_allocation_id = aws_eip.llm_gpu.id

    # Tool selection flags (rendered as "true"/"false" strings in the script).
    enable_monitoring         = var.enable_monitoring
    enable_llm                = var.enable_llm
    enable_tts                = var.enable_tts
    enable_vibevoice_15b      = var.enable_vibevoice_15b
    enable_vibevoice_realtime = var.enable_vibevoice_realtime
    enable_vibevoice_7b       = var.enable_vibevoice_7b
    enable_asr                = var.enable_asr
    asr_model                 = var.asr_model
    enable_h3                 = var.enable_h3
    h3_sglang_image           = var.h3_sglang_image

    # Cost guardrails, applied to every workload (not just H3).
    auto_stop_hours   = var.auto_stop_hours
    idle_stop_minutes = var.idle_stop_minutes
  })) : null

  tag_specifications {
    resource_type = "instance"
    tags = merge({
      Name = "llm-gpu"
    }, local.lab_tags)
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge({
      Name = "llm-gpu-root"
    }, local.lab_tags)
  }

  tags = merge({
    Name = "llm-gpu-lt"
  }, local.lab_tags)

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = length(local.candidate_azs) > 0
      error_message = "None of the requested instance types (${join(", ", local.requested_instance_types)}) are offered in any availability zone of ${var.aws_region}. g6e.12xlarge, for example, exists in eu-central-1, eu-north-1 and eu-south-2 but not in eu-west-1."
    }

    precondition {
      condition     = length(local.deploy_azs) > 0
      error_message = "availability_zone = \"${var.availability_zone}\" does not offer any of ${join(", ", local.requested_instance_types)}. Capable zones in ${var.aws_region}: ${join(", ", local.candidate_azs)}. Leave availability_zone empty to let the Auto Scaling group search all of them."
    }

    # EC2 enforces this at RunInstances, which under an ASG means a failed
    # scaling activity minutes after a successful apply. Catch it in plan.
    precondition {
      condition     = local.root_volume_iops * 0.25 >= var.root_volume_throughput
      error_message = "gp3 allows at most 0.25 MiB/s of throughput per provisioned IOPS. root_volume_throughput = ${var.root_volume_throughput} needs at least ${ceil(var.root_volume_throughput * 4)} IOPS, but root_volume_iops resolves to ${local.root_volume_iops}. Raise root_volume_iops or leave it at 0 to derive it."
    }
  }
}

resource "aws_autoscaling_group" "llm_gpu" {
  name_prefix         = "llm-gpu-"
  vpc_zone_identifier = [for s in aws_subnet.public : s.id]

  min_size         = 0
  max_size         = 1
  desired_capacity = var.desired_capacity

  # Do not block `apply` waiting for capacity. A thin GPU pool can free up
  # minutes later and the group will keep retrying on its own; failing the
  # Terraform run would only tear down the thing that is doing the retrying.
  # Watch progress with the `capacity_hunt_command` output.
  wait_for_capacity_timeout = "0"

  health_check_type         = "EC2"
  health_check_grace_period = var.health_check_grace_period

  # This is the load-bearing line of the whole file.
  #
  # The in-VM autostop guardrails call `systemctl poweroff`, which with
  # instance_initiated_shutdown_behavior = "stop" leaves a STOPPED instance. An
  # ordinary ASG fails that instance's EC2 health check, terminates it, and
  # launches a replacement -- turning a cost guardrail into a billing loop at
  # ~$13/h. Suspending the health-check and replacement processes makes a
  # stopped member simply stay stopped, so the root volume and the 144 GB model
  # cache survive exactly as they did with a bare aws_instance.
  #
  # AZRebalance is suspended for a related reason: with subnets in several
  # zones the group would otherwise be free to terminate a perfectly healthy
  # instance just to even out the distribution of a one-instance group.
  suspended_processes = ["HealthCheck", "ReplaceUnhealthy", "AZRebalance"]

  # Nothing about this instance is replaceable mid-flight: first boot downloads
  # up to 144 GB.
  capacity_rebalance    = false
  protect_from_scale_in = false

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 1
      on_demand_percentage_above_base_capacity = 100

      # Walk the overrides in the order they are declared and move to the next
      # one when a pool cannot satisfy the launch, rather than optimising for
      # price across an unordered set.
      on_demand_allocation_strategy = "prioritized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.llm_gpu.id
        version            = aws_launch_template.llm_gpu.latest_version
      }

      dynamic "override" {
        for_each = local.instance_type_waterfall
        content {
          instance_type = override.value
        }
      }
    }
  }

  dynamic "tag" {
    for_each = merge({ Name = "llm-gpu" }, local.lab_tags)
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # Fail in `plan`, not 20 minutes into a $13/h boot. Terraform's required_version
  # here is >= 1.6.0 and cross-variable `validation` blocks need >= 1.9, so these
  # cross-cutting rules live as resource preconditions instead.
  #
  # Deliberately NOT create_before_destroy: replacing this group that way would
  # stand up a second one, and therefore a second GPU instance, before tearing
  # the first down. name_prefix already keeps a destroy-then-create replacement
  # from colliding on the name.
  lifecycle {
    precondition {
      condition = !var.enable_h3 || length([
        for t in local.requested_instance_types : t
        if !contains(local.h3_capable_instance_types, t)
      ]) == 0
      error_message = "enable_h3 restricts every instance type in the waterfall to ${join(" or ", local.h3_capable_instance_types)}. Got: ${join(", ", local.requested_instance_types)}. This stack serves the Ref2VA partition, which denoises to snow/noise on compute-capability 8.9 cards (the 4x L40S g6e.12xlarge shape) -- see https://github.com/sgl-project/sglang/issues/34110 -- and H3 cannot run at all on the 24 GB A10G sizes (g5.12xlarge/g5.24xlarge)."
    }

    precondition {
      condition     = !var.enable_h3 || length(local.instance_type_waterfall) > 0
      error_message = "enable_h3 found none of ${join(", ", local.requested_instance_types)} offered in ${var.aws_region}. Pick a region that offers at least one H3-capable type."
    }

    precondition {
      condition     = !var.enable_h3 || var.root_volume_size >= 300
      error_message = "enable_h3 requires root_volume_size >= 300 GiB. The Ref2VA checkpoint partition is ~144 GB on disk (the HF repo also ships the FL2VA partition and a parallel diffusers layout, ~498 GB in total, which this stack deliberately does NOT download), plus the pinned SGLang image, CUDA/torch layers and generated MP4s."
    }

    precondition {
      condition     = !var.enable_h3 || contains(["eu-central-1", "eu-north-1", "eu-south-2"], var.aws_region)
      error_message = "enable_h3 requires aws_region to be eu-central-1, eu-north-1 or eu-south-2. Those are the three EU regions offering G7e .12xlarge; while it exists in us-east-2 the account's 'Running On-Demand G and VT instances' quota there is 0."
    }

    precondition {
      condition = !var.enable_h3 || !(
        var.enable_llm || var.enable_tts || var.enable_vibevoice_15b ||
        var.enable_vibevoice_realtime || var.enable_vibevoice_7b || var.enable_asr
      )
      error_message = "enable_h3 is mutually exclusive with every other GPU stack (enable_llm/enable_tts/enable_vibevoice_*/enable_asr). H3 needs every GPU plus most of the host RAM for layerwise offload; sharing the box guarantees an OOM. Netdata monitoring may stay on."
    }
  }

  depends_on = [
    aws_s3_object.scripts,
    time_sleep.instance_profile_propagation,
  ]
}

# Allocated by Terraform, attached by the instance.
#
# The ASG decides which AZ (and therefore which instance) wins, so there is no
# instance ID to bind to at plan time. user-data.sh calls AssociateAddress on
# first boot instead. A VPC Elastic IP stays associated across stop/start, so
# the address is stable for the life of the instance -- only a terminate/relaunch
# cycle re-claims it, and the address itself never changes.
resource "aws_eip" "llm_gpu" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.llm]

  tags = merge({
    Name = "llm-gpu-eip"
  }, local.lab_tags)
}
