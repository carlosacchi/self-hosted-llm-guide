#!/bin/bash
#
# Cloud-init user-data wrapper.
#
# AWS runs this script as root on first boot via cloud-init, so no SSH access
# and no EC2 key pair are required to provision the instance. It downloads the
# provisioning scripts from a private S3 bucket (using the instance's IAM role)
# and runs the bootstrap orchestrator, which installs the LLM and TTS stacks.
#
# Pulling from S3 instead of embedding the scripts keeps user-data well under
# the 16 KB EC2 limit and supports arbitrarily large scripts.
#
# The ${...} placeholders are filled in by Terraform's templatefile()
# (see infra/compute.tf).
#
set -euo pipefail

LOG_FILE="/var/log/llm-lab-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo "LLM Lab cloud-init bootstrap"
echo "Date: $(date)"
echo "========================================"

PROVISION_DIR="/opt/llm-lab/provisioning"
mkdir -p "$PROVISION_DIR"

echo "-> Downloading provisioning scripts from s3://${scripts_bucket}/provisioning/"
aws s3 cp "s3://${scripts_bucket}/provisioning/" "$PROVISION_DIR/" \
  --recursive --region "${aws_region}"

chmod +x "$PROVISION_DIR"/*.sh

echo "-> Running bootstrap orchestrator..."
bash "$PROVISION_DIR/bootstrap_all.sh"

echo "========================================"
echo "LLM Lab bootstrap complete: $(date)"
echo "  Logs: $LOG_FILE"
echo "========================================"
