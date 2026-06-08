#!/usr/bin/env bash
set -euo pipefail

########################################
# VibeVoice multi-speaker TTS stack provisioner
#
# Installs the COMMUNITY fork of VibeVoice and serves its Gradio "podcast"
# demo, which supports up to 4 distinct speakers (Speaker 0 / Speaker 1 / ...)
# with voice cloning from .wav samples. This is the full long-form TTS model
# (VibeVoice-1.5B), NOT the single-speaker streaming 0.5B model served by
# provision_vibevoice_stack.sh on port 7861.
#
# Why the community fork:
#   Microsoft removed the official VibeVoice TTS inference/demo code from its
#   repository (responsible-AI reasons). The model weights remain on Hugging
#   Face under the `vibevoice` org, and the MIT-licensed code is preserved by
#   the community fork at github.com/vibevoice-community/VibeVoice.
#
# Runs as its own Gradio app on port 7862 in an isolated venv, so its copy of
# the `vibevoice` Python package does not collide with the 0.5B streaming
# stack's copy.
#
# Requires an NVIDIA GPU. The DLAMI ships CUDA + PyTorch, reused via
# --system-site-packages. The demo auto-falls back from flash_attention_2 to
# SDPA, so no flash-attn build is needed.
#
# Multiple instances:
#   The app dir and the systemd unit are both derived from VVT_NAME, so this
#   script can stand up several isolated instances side by side. For example,
#   a 1.5B stack on 7862 (default) and a 7B stack on 7863:
#
#     sudo bash provision_vibevoice_tts_stack.sh                      # 1.5B / 7862
#     sudo VVT_NAME=vibevoice-tts-7b VVT_PORT=7863 \
#          VVT_MODEL=vibevoice/VibeVoice-7B \
#          bash provision_vibevoice_tts_stack.sh                      # 7B   / 7863
#
#   NOTE: the 7B model needs ~16 GB VRAM. Running the 1.5B and 7B services
#   concurrently on a single 24 GB GPU (e.g. g5.xlarge) is tight and may OOM
#   during long generations; prefer a larger GPU or stop one service.
#
# Usage:
#   sudo bash provision_vibevoice_tts_stack.sh [app-dir]
#
# Default app dir: /opt/vibevoice-tts
########################################

# Instance name — drives both the app dir and the systemd unit so multiple
# instances can coexist without colliding. Override via env for a 2nd instance.
VVT_NAME="${VVT_NAME:-vibevoice-tts}"
VVT_DIR="${1:-${VVT_DIR:-/opt/${VVT_NAME}}}"
VVT_USER="${VVT_USER:-ubuntu}"
VVT_GROUP="${VVT_GROUP:-ubuntu}"
VVT_PORT="${VVT_PORT:-7862}"
VVT_MODEL="${VVT_MODEL:-vibevoice/VibeVoice-1.5B}"
VVT_REPO="${VVT_REPO:-https://github.com/vibevoice-community/VibeVoice.git}"

# Shared HF cache so the model downloaded as root during provisioning is
# readable by the service user at runtime.
HF_CACHE="${VVT_DIR}/hf-cache"

log() {
  echo -e "[provision_vibevoice_tts_stack] $*"
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
# Step 2: clone the community VibeVoice repository
########################################

clone_repo() {
  if [[ -d "${VVT_DIR}/.git" ]]; then
    log "Repo already present in ${VVT_DIR}, pulling latest..."
    git -C "${VVT_DIR}" pull --ff-only || log "Pull failed (non-fatal), keeping existing checkout."
  else
    log "Cloning ${VVT_REPO} into ${VVT_DIR}..."
    mkdir -p "$(dirname "${VVT_DIR}")"
    git clone --depth 1 "${VVT_REPO}" "${VVT_DIR}"
  fi
}

########################################
# Step 2b: patch the Gradio demo so it is reachable externally
########################################

patch_demo() {
  local demo_py="${VVT_DIR}/demo/gradio_demo.py"

  if [[ ! -f "${demo_py}" ]]; then
    log "WARNING: ${demo_py} not found, skipping patch."
    return
  fi

  # The upstream launch() call (a) comments out server_port so --port is
  # ignored and it falls back to Gradio's default 7860 (colliding with the
  # TTS Gradio app), and (b) binds to 127.0.0.1 unless --share is passed,
  # which would also open a public Gradio tunnel we do not want. Patch it to
  # honor --port and bind to all interfaces (the security group restricts
  # access to the allowed IP). Both edits are idempotent.
  if grep -q "# server_port=args.port," "${demo_py}"; then
    log "Patching ${demo_py}: enable server_port=args.port ..."
    sed -i 's/# server_port=args.port,/server_port=args.port,/' "${demo_py}"
  fi

  if grep -q 'server_name="0.0.0.0" if args.share else "127.0.0.1"' "${demo_py}"; then
    log "Patching ${demo_py}: bind server_name to 0.0.0.0 ..."
    sed -i 's/server_name="0.0.0.0" if args.share else "127.0.0.1"/server_name="0.0.0.0"/' "${demo_py}"
  fi

  # Upstream builds the UI with a bare `gr.Blocks()`, so the browser tab shows
  # the generic "Gradio" title. Set an explicit title so the page is
  # recognizable, matching the convention used by the other stacks
  # (e.g. "AI Hub — TTS"). Idempotent.
  if grep -q 'with gr.Blocks() as interface:' "${demo_py}"; then
    log "Patching ${demo_py}: set browser tab title to 'AI Hub — VibeVoice' ..."
    sed -i 's/with gr.Blocks() as interface:/with gr.Blocks(title="AI Hub — VibeVoice") as interface:/' "${demo_py}"
  fi
}

########################################
# Step 3: Python virtual environment + package install
########################################

create_venv() {
  log "Creating Python venv in ${VVT_DIR}/.venv ..."
  if [[ ! -d "${VVT_DIR}/.venv" ]]; then
    # --system-site-packages reuses the GPU PyTorch shipped with the DLAMI
    # instead of pulling a CPU-only torch via pip.
    python3 -m venv --system-site-packages "${VVT_DIR}/.venv"
    log "Venv created (with system site-packages for GPU torch)."
  else
    log "Venv already exists, skipping creation."
  fi
}

install_python_packages() {
  log "Installing community VibeVoice into the venv (editable)..."
  "${VVT_DIR}/.venv/bin/pip" install --upgrade pip

  # Editable install of the community fork. Its pyproject pins a compatible
  # gradio (gradio 6 breaks the demo) and pulls librosa/soundfile/etc. flash
  # attention is intentionally not installed; the demo auto-falls back to SDPA.
  "${VVT_DIR}/.venv/bin/pip" install -e "${VVT_DIR}"

  log "Community VibeVoice packages installed."
}

########################################
# Step 4: pre-download the model into the shared cache
########################################

download_model() {
  log "Pre-downloading model ${VVT_MODEL} into ${HF_CACHE} ..."
  mkdir -p "${HF_CACHE}"
  HF_HOME="${HF_CACHE}" "${VVT_DIR}/.venv/bin/python" - <<PY || log "Model pre-download failed (non-fatal); the service will download on first start."
from huggingface_hub import snapshot_download
snapshot_download("${VVT_MODEL}")
print("Model downloaded.")
PY
}

########################################
# Step 5: systemd service (multi-speaker Gradio podcast UI)
########################################

install_systemd_service() {
  log "Installing systemd service (${VVT_NAME}.service)..."

  cat > "/etc/systemd/system/${VVT_NAME}.service" <<EOF
[Unit]
Description=VibeVoice multi-speaker TTS (${VVT_MODEL}, Gradio podcast UI)
After=network.target

[Service]
User=${VVT_USER}
WorkingDirectory=${VVT_DIR}/demo
Environment=HF_HOME=${HF_CACHE}
Environment=PYTHONPATH=${VVT_DIR}
ExecStart=${VVT_DIR}/.venv/bin/python ${VVT_DIR}/demo/gradio_demo.py --model_path ${VVT_MODEL} --port ${VVT_PORT} --device cuda
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${VVT_NAME}"
  systemctl restart "${VVT_NAME}"
  log "Service ${VVT_NAME} installed and started on port ${VVT_PORT}."
}

########################################
# Main
########################################

main() {
  require_root
  install_system_deps
  clone_repo
  patch_demo
  create_venv
  install_python_packages
  download_model

  # Hand the whole tree to the service user so it can write caches at runtime.
  chown -R "${VVT_USER}:${VVT_GROUP}" "${VVT_DIR}"

  install_systemd_service

  log ""
  log "=== VibeVoice multi-speaker TTS stack ready ==="
  log "  App dir : ${VVT_DIR}"
  log "  Model   : ${VVT_MODEL} (up to 4 speakers)"
  log "  Port    : ${VVT_PORT}"
  log "  Access  : http://<EIP>:${VVT_PORT}"
  log "            or ssh -L ${VVT_PORT}:localhost:${VVT_PORT} ubuntu@<EIP>"
  log ""
  log "  Status  : sudo systemctl status ${VVT_NAME}"
  log "  Logs    : sudo journalctl -fu ${VVT_NAME}"
}

main "$@"
