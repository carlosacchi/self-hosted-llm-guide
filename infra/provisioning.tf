# Provisioning artifacts and access.
#
# The provisioning scripts are uploaded to a private S3 bucket and pulled by the
# GPU instance at first boot via cloud-init (see scripts/user-data.sh). This
# removes any need for an SSH key pair to provision the VM and avoids the 16 KB
# EC2 user-data limit. Everything here is gated on var.run_bootstrap and is torn
# down cleanly by `terraform destroy` (force_destroy empties the bucket first).

locals {
  provisioning_scripts = {
    "bootstrap_all.sh"                 = "${path.module}/../scripts/bootstrap_all.sh"
    "lib_docker_gpu.sh"                = "${path.module}/../scripts/lib_docker_gpu.sh"
    "provision_monitoring_stack.sh"    = "${path.module}/../scripts/provision_monitoring_stack.sh"
    "provision_llm_stack.sh"           = "${path.module}/../scripts/provision_llm_stack.sh"
    "provision_tts_stack.sh"           = "${path.module}/../scripts/provision_tts_stack.sh"
    "provision_vibevoice_stack.sh"     = "${path.module}/../scripts/provision_vibevoice_stack.sh"
    "provision_vibevoice_tts_stack.sh" = "${path.module}/../scripts/provision_vibevoice_tts_stack.sh"
    "provision_asr_stack.sh"           = "${path.module}/../scripts/provision_asr_stack.sh"
    "provision_h3_stack.sh"            = "${path.module}/../scripts/provision_h3_stack.sh"
    "provision_h3_ui_stack.sh"         = "${path.module}/../scripts/provision_h3_ui_stack.sh"
    "provision_autostop.sh"            = "${path.module}/../scripts/provision_autostop.sh"
    "provision_landing_stack.sh"       = "${path.module}/../scripts/provision_landing_stack.sh"
  }
}

resource "aws_s3_bucket" "scripts" {
  count = var.run_bootstrap ? 1 : 0

  bucket_prefix = "llm-lab-scripts-"
  force_destroy = true

  tags = merge({
    Name = "llm-lab-scripts"
  }, local.lab_tags)
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  count = var.run_bootstrap ? 1 : 0

  bucket                  = aws_s3_bucket.scripts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "scripts" {
  count = var.run_bootstrap ? 1 : 0

  bucket = aws_s3_bucket.scripts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Upload each script. The etag (filemd5) makes Terraform re-upload whenever a
# script changes, so re-applying refreshes the artifacts in S3.
resource "aws_s3_object" "scripts" {
  for_each = var.run_bootstrap ? local.provisioning_scripts : {}

  bucket = aws_s3_bucket.scripts[0].id
  key    = "provisioning/${each.key}"
  source = each.value
  etag   = filemd5(each.value)

  tags = merge({
    Name = "llm-lab-script-${each.key}"
  }, local.lab_tags)
}

# IAM role/instance profile granting the VM read-only access to the scripts.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "llm_gpu" {
  count = var.run_bootstrap ? 1 : 0

  name_prefix        = "llm-gpu-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = merge({
    Name = "llm-gpu-bootstrap"
  }, local.lab_tags)
}

data "aws_iam_policy_document" "scripts_read" {
  count = var.run_bootstrap ? 1 : 0

  statement {
    sid       = "ReadScripts"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.scripts[0].arn}/*"]
  }

  statement {
    sid       = "ListScriptsBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.scripts[0].arn]
  }
}

resource "aws_iam_role_policy" "scripts_read" {
  count = var.run_bootstrap ? 1 : 0

  name_prefix = "scripts-read-"
  role        = aws_iam_role.llm_gpu[0].id
  policy      = data.aws_iam_policy_document.scripts_read[0].json
}

# The Auto Scaling group chooses the AZ and therefore the instance, so Terraform
# cannot attach the Elastic IP itself any more. The instance claims it on first
# boot (see scripts/user-data.sh). AssociateAddress authorises against all three
# resources involved, so the address alone is not a sufficient scope.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "claim_eip" {
  count = var.run_bootstrap ? 1 : 0

  statement {
    sid     = "ClaimElasticIp"
    actions = ["ec2:AssociateAddress"]
    resources = [
      aws_eip.llm_gpu.arn,
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
    ]
  }

  statement {
    sid       = "DescribeElasticIps"
    actions   = ["ec2:DescribeAddresses"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "claim_eip" {
  count = var.run_bootstrap ? 1 : 0

  name_prefix = "claim-eip-"
  role        = aws_iam_role.llm_gpu[0].id
  policy      = data.aws_iam_policy_document.claim_eip[0].json
}

resource "aws_iam_instance_profile" "llm_gpu" {
  count = var.run_bootstrap ? 1 : 0

  name_prefix = "llm-gpu-"
  role        = aws_iam_role.llm_gpu[0].name

  tags = merge({
    Name = "llm-gpu-instance-profile"
  }, local.lab_tags)
}
