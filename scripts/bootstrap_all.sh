#!/usr/bin/env bash
set -euo pipefail

########################################
# Bootstrap orchestrator
#
# Runs the provisioning chain in order:
#   1. provision_monitoring_stack.sh      (Netdata system + GPU dashboard)
#   2. provision_llm_stack.sh             (Docker + NVIDIA + Ollama + Open WebUI)
#   3. provision_tts_stack.sh             (Kokoro/XTTS/Piper + Gradio TTS UI, 7860)
#   4. provision_vibevoice_tts_stack.sh   (VibeVoice 1.5B multi-speaker UI, 7861)
#
# Disabled by default (kept below, commented out, for easy re-enable):
#   - VibeVoice Realtime single-speaker 0.5B  -> port 7862
#   - VibeVoice multi-speaker 7B              -> port 7863 (~16 GB VRAM)
#
# Only one VibeVoice stack runs by default (1.5B). Running the 7B and/or the
# 0.5B realtime stack at the same time on a single 24 GB GPU (g5.xlarge) is
# tight and may OOM, so they are left off until explicitly enabled.
#
# Intended to be invoked by cloud-init on first boot (see scripts/user-data.sh),
# but can also be run by hand:
#
#   sudo bash bootstrap_all.sh
#
# It must run as root (the sub-scripts require it).
########################################

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  echo -e "[bootstrap_all] $*"
}

if [[ "$EUID" -ne 0 ]]; then
  log "This script must run as root (use: sudo $0)"
  exit 1
fi

log "=== Step 1/4: Monitoring stack (Netdata dashboard) ==="
bash "${HERE}/provision_monitoring_stack.sh"

log "=== Step 2/4: LLM stack (Ollama + Open WebUI) ==="
bash "${HERE}/provision_llm_stack.sh"

log "=== Step 3/4: TTS stack (Gradio UI, port 7860) ==="
bash "${HERE}/provision_tts_stack.sh"

log "=== Step 4/4: VibeVoice multi-speaker TTS stack (1.5B podcast, port 7861) ==="
VVT_PORT=7861 bash "${HERE}/provision_vibevoice_tts_stack.sh"

# --- Disabled stacks ---------------------------------------------------------
# Uncomment a block to install it. Mind the GPU budget on a single 24 GB card:
# running these alongside the 1.5B stack above may OOM during long generations.
#
# VibeVoice Realtime single-speaker 0.5B -> port 7862
#   VV_PORT=7862 bash "${HERE}/provision_vibevoice_stack.sh"
#
# VibeVoice multi-speaker 7B -> port 7863 (~16 GB VRAM)
#   VVT_NAME=vibevoice-tts-7b VVT_PORT=7863 VVT_MODEL=vibevoice/VibeVoice-7B \
#     bash "${HERE}/provision_vibevoice_tts_stack.sh"

log "=== All provisioning complete ==="
log "  Monitoring            : http://<EIP>:19999"
log "  Open WebUI            : http://<EIP>:3000"
log "  TTS UI                : http://<EIP>:7860"
log "  VibeVoice (multi 1.5B): http://<EIP>:7861"
