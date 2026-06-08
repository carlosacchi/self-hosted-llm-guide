#!/usr/bin/env bash
set -euo pipefail

########################################
# VibeVoice Realtime (TTS) stack provisioner
#
# Installs Microsoft VibeVoice-Realtime-0.5B and serves its official
# web UI (FastAPI + WebSocket streaming) on its own port, separate from
# the multi-engine Gradio TTS app (provision_tts_stack.sh, port 7860).
#
# VibeVoice generates expressive, long-form, multi-speaker conversational
# speech (e.g. podcasts). It is a Qwen2-based LLM + diffusion head model and
# requires an NVIDIA GPU. The DLAMI already ships CUDA + PyTorch, which the
# venv reuses via --system-site-packages.
#
# Assumes Docker/NVIDIA + system tools were set up by provision_llm_stack.sh.
#
# Usage:
#   sudo bash provision_vibevoice_stack.sh [app-dir]
#
# Default app dir: /opt/vibevoice
########################################

VV_DIR="${1:-/opt/vibevoice}"
VV_USER="${VV_USER:-ubuntu}"
VV_GROUP="${VV_GROUP:-ubuntu}"
VV_PORT="${VV_PORT:-7861}"
VV_MODEL="${VV_MODEL:-microsoft/VibeVoice-Realtime-0.5B}"
VV_REPO="${VV_REPO:-https://github.com/microsoft/VibeVoice.git}"

# Shared HF cache so the model downloaded as root during provisioning is
# readable by the service user at runtime.
HF_CACHE="${VV_DIR}/hf-cache"

log() {
  echo -e "[provision_vibevoice_stack] $*"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log "This script must run as root (use: sudo $0)"
    exit 1
  fi
}

########################################
# Step 1: system deps (git for clone, ffmpeg for audio IO)
########################################

install_system_deps() {
  log "Installing system-level deps (git, ffmpeg)..."
  apt-get update -y
  apt-get install -y git ffmpeg python3-venv python3-pip
  log "System deps installed."
}

########################################
# Step 2: clone the VibeVoice repository
########################################

clone_repo() {
  if [[ -d "${VV_DIR}/.git" ]]; then
    log "Repo already present in ${VV_DIR}, pulling latest..."
    git -C "${VV_DIR}" pull --ff-only || log "Pull failed (non-fatal), keeping existing checkout."
  else
    log "Cloning ${VV_REPO} into ${VV_DIR}..."
    mkdir -p "$(dirname "${VV_DIR}")"
    git clone --depth 1 "${VV_REPO}" "${VV_DIR}"
  fi
}

########################################
# Step 3: Python virtual environment + package install
########################################

create_venv() {
  log "Creating Python venv in ${VV_DIR}/.venv ..."
  if [[ ! -d "${VV_DIR}/.venv" ]]; then
    # --system-site-packages reuses the GPU PyTorch shipped with the DLAMI
    # instead of pulling a CPU-only torch via pip.
    python3 -m venv --system-site-packages "${VV_DIR}/.venv"
    log "Venv created (with system site-packages for GPU torch)."
  else
    log "Venv already exists, skipping creation."
  fi
}

install_python_packages() {
  log "Installing VibeVoice (streamingtts extra) into the venv..."
  "${VV_DIR}/.venv/bin/pip" install --upgrade pip

  # Editable install of the cloned repo with the streaming-TTS extra. This
  # pulls the streaming model, processor, FastAPI demo deps, etc. The model
  # loader auto-falls back from flash_attention_2 to SDPA if flash-attn is
  # not available, so we do not force a flash-attn build here.
  "${VV_DIR}/.venv/bin/pip" install -e "${VV_DIR}[streamingtts]"

  log "VibeVoice packages installed."
}

########################################
# Step 4: pre-download the model into the shared cache
########################################

download_model() {
  log "Pre-downloading model ${VV_MODEL} into ${HF_CACHE} ..."
  mkdir -p "${HF_CACHE}"
  HF_HOME="${HF_CACHE}" "${VV_DIR}/.venv/bin/python" - <<PY || log "Model pre-download failed (non-fatal); the service will download on first start."
from huggingface_hub import snapshot_download
snapshot_download("${VV_MODEL}")
print("Model downloaded.")
PY
}

########################################
# Step 5: systemd service (official realtime web UI)
########################################

install_systemd_service() {
  log "Installing systemd service (vibevoice.service)..."

  # The demo entrypoint runs uvicorn serving web.app:app; it must run from the
  # demo/ directory so the 'web' package is importable.
  cat > /etc/systemd/system/vibevoice.service <<EOF
[Unit]
Description=VibeVoice Realtime TTS web UI
After=network.target

[Service]
User=${VV_USER}
WorkingDirectory=${VV_DIR}/demo
Environment=HF_HOME=${HF_CACHE}
Environment=PYTHONPATH=${VV_DIR}/demo
ExecStart=${VV_DIR}/.venv/bin/python ${VV_DIR}/demo/vibevoice_realtime_demo.py --port ${VV_PORT} --model_path ${VV_MODEL} --device cuda
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable vibevoice
  systemctl restart vibevoice
  log "Service vibevoice installed and started on port ${VV_PORT}."
}

########################################
# Main
########################################

main() {
  require_root
  install_system_deps
  clone_repo
  create_venv
  install_python_packages
  download_model

  # Hand the whole tree to the service user so it can write caches at runtime.
  chown -R "${VV_USER}:${VV_GROUP}" "${VV_DIR}"

  install_systemd_service

  log ""
  log "=== VibeVoice Realtime stack ready ==="
  log "  App dir : ${VV_DIR}"
  log "  Model   : ${VV_MODEL}"
  log "  Port    : ${VV_PORT}"
  log "  Access  : http://<EIP>:${VV_PORT}"
  log "            or ssh -L ${VV_PORT}:localhost:${VV_PORT} ubuntu@<EIP>"
  log ""
  log "  Status  : sudo systemctl status vibevoice"
  log "  Logs    : sudo journalctl -fu vibevoice"
}

main "$@"
