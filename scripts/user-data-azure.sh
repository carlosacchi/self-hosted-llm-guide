#!/bin/bash
#
# Cloud-init custom_data wrapper (Azure).
#
# The AWS counterpart is scripts/user-data.sh. Three things differ, and all
# three are load-bearing:
#
#   1. No Elastic IP claim. Azure binds the static public IP to the NIC at
#      deploy time, so the AssociateAddress dance on first boot is gone.
#   2. Scripts come from Blob Storage over the REST API, authenticated with the
#      VM's managed identity. No az CLI is installed for this: Terraform already
#      knows the file names, so there is nothing to enumerate and a bearer token
#      plus curl is the whole client.
#   3. It WAITS FOR THE GPU DRIVER. Plain Ubuntu ships without one, and the
#      NvidiaGpuDriverLinux extension installs it concurrently with cloud-init.
#      Racing it does not fail loudly: configure_nvidia_toolkit_if_needed() just
#      logs "no NVIDIA GPU/driver detected, staying CPU-only" and carries on,
#      and the first sign of trouble is H3 failing half an hour later.
#
# The template variables are filled in by Terraform's templatefile().
#
set -euo pipefail

LOG_FILE="/var/log/llm-lab-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo "LLM Lab cloud-init bootstrap (Azure)"
echo "Date: $(date)"
echo "========================================"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl jq

# --- Wait for the NVIDIA driver ---------------------------------------------
# 20 minutes is generous on purpose: the extension pulls and builds a driver
# package, and an under-tight timeout here would hand the rest of the script a
# CPU-only machine that looks provisioned but cannot serve.
echo "-> Waiting for the NVIDIA driver extension to finish..."
for _ in $(seq 1 120); do
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo "-> GPU driver ready:"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
    break
  fi
  sleep 10
done

if ! nvidia-smi >/dev/null 2>&1; then
  echo "FATAL: no working NVIDIA driver after 20 minutes." >&2
  echo "       Refusing to provision: every GPU stack would silently install" >&2
  echo "       itself CPU-only and fail on the first request instead of here." >&2
  echo "       Check: az vm extension list -g <rg> --vm-name llm-gpu -o table" >&2
  exit 1
fi

# --- Fetch the provisioning scripts ------------------------------------------
PROVISION_DIR="/opt/llm-lab/provisioning"
mkdir -p "$PROVISION_DIR"

echo "-> Requesting a managed-identity token for Blob Storage..."
TOKEN="$(curl -sS -m 30 -H 'Metadata: true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F' \
  | jq -r '.access_token')"

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "FATAL: no managed-identity token. Is the Storage Blob Data Reader role" >&2
  echo "       assignment still propagating? It is eventually consistent." >&2
  exit 1
fi

BASE="https://${storage_account}.blob.core.windows.net/${container}"
for name in ${script_names}; do
  echo "-> Downloading $name"
  curl -fsSL -m 120 \
    -H "Authorization: Bearer $TOKEN" \
    -H "x-ms-version: 2021-08-06" \
    "$BASE/$name" -o "$PROVISION_DIR/$name"
done

chmod +x "$PROVISION_DIR"/*.sh

echo "-> Running bootstrap orchestrator..."
# Tool selection flags, rendered by Terraform's templatefile() as true/false.
# bootstrap_all.sh reads these env vars to decide which stacks to install.
# Only the H3 path is wired up on Azure; the rest stay off so nothing competes
# for VRAM with a workload that needs all of it.
export ENABLE_MONITORING="${enable_monitoring}"
export ENABLE_LLM="false"
export ENABLE_TTS="false"
export ENABLE_VIBEVOICE_15B="false"
export ENABLE_VIBEVOICE_REALTIME="false"
export ENABLE_VIBEVOICE_7B="false"
export ENABLE_ASR="false"
export ASR_MODEL="whisper-large-v3"
export ENABLE_H3="${enable_h3}"
export H3_SGLANG_IMAGE="${h3_sglang_image}"
# Cost guardrails. On Azure these deallocate through ARM rather than powering
# off the guest -- see stop_self() in lib_cloud.sh for why that distinction is
# the difference between a guardrail and a placebo.
export AUTO_STOP_HOURS="${auto_stop_hours}"
export IDLE_STOP_MINUTES="${idle_stop_minutes}"
bash "$PROVISION_DIR/bootstrap_all.sh"

echo "========================================"
echo "LLM Lab bootstrap complete: $(date)"
echo "  Logs: $LOG_FILE"
echo "========================================"
