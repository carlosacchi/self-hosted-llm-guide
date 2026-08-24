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
# The template variables (scripts_bucket, aws_region, eip_allocation_id) are
# filled in by Terraform's templatefile() (see infra/compute.tf).
#
set -euo pipefail

LOG_FILE="/var/log/llm-lab-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo "LLM Lab cloud-init bootstrap"
echo "Date: $(date)"
echo "========================================"

# --- Claim the Elastic IP ----------------------------------------------------
# The Auto Scaling group picks the instance and the AZ, so Terraform cannot bind
# the address at plan time. Done FIRST, before anything else touches the
# network: associating an EIP swaps the instance's public address and resets any
# connection already open through the old one.
imds() {
  local token
  token="$(curl -sS -m 5 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  curl -sS -m 5 -H "X-aws-ec2-metadata-token: $token" \
    "http://169.254.169.254/latest/meta-data/$1"
}

INSTANCE_ID="$(imds instance-id)"
echo "-> Associating Elastic IP ${eip_allocation_id} with $INSTANCE_ID"
aws ec2 associate-address \
  --region "${aws_region}" \
  --allocation-id "${eip_allocation_id}" \
  --instance-id "$INSTANCE_ID" \
  --allow-reassociation
# Let the new address settle before the first outbound transfer.
sleep 10

PROVISION_DIR="/opt/llm-lab/provisioning"
mkdir -p "$PROVISION_DIR"

echo "-> Downloading provisioning scripts from s3://${scripts_bucket}/provisioning/"
aws s3 cp "s3://${scripts_bucket}/provisioning/" "$PROVISION_DIR/" \
  --recursive --region "${aws_region}"

chmod +x "$PROVISION_DIR"/*.sh

echo "-> Running bootstrap orchestrator..."
# Tool selection flags, rendered by Terraform's templatefile() as true/false.
# bootstrap_all.sh reads these env vars to decide which stacks to install.
export ENABLE_MONITORING="${enable_monitoring}"
export ENABLE_LLM="${enable_llm}"
export ENABLE_TTS="${enable_tts}"
export ENABLE_VIBEVOICE_15B="${enable_vibevoice_15b}"
export ENABLE_VIBEVOICE_REALTIME="${enable_vibevoice_realtime}"
export ENABLE_VIBEVOICE_7B="${enable_vibevoice_7b}"
export ENABLE_ASR="${enable_asr}"
export ASR_MODEL="${asr_model}"
export ENABLE_H3="${enable_h3}"
export H3_VARIANT="${h3_variant}"
export H3_MODEL_VARIANT="${h3_model_variant}"
export H3_SGLANG_IMAGE="${h3_sglang_image}"
# Cost guardrails installed for every workload (see provision_autostop.sh).
export AUTO_STOP_HOURS="${auto_stop_hours}"
export IDLE_STOP_MINUTES="${idle_stop_minutes}"
bash "$PROVISION_DIR/bootstrap_all.sh"
echo "========================================"
echo "LLM Lab bootstrap complete: $(date)"
echo "  Logs: $LOG_FILE"
echo "========================================"
