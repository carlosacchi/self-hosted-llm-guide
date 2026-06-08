#!/usr/bin/env bash
set -euo pipefail

########################################
# Bootstrap orchestrator
#
# Runs the full provisioning chain in order:
#   1. provision_monitoring_stack.sh (Netdata system + GPU dashboard)
#   2. provision_llm_stack.sh        (Docker + NVIDIA + Ollama + Open WebUI)
#   3. provision_tts_stack.sh             (Kokoro/XTTS/Piper + Gradio TTS UI)
#   4. provision_vibevoice_stack.sh       (VibeVoice Realtime single-speaker UI)
#   5. provision_vibevoice_tts_stack.sh   (VibeVoice 1.5B multi-speaker podcast UI)
#   6. provision_vibevoice_tts_stack.sh   (VibeVoice 7B  multi-speaker podcast UI)
#
# NOTE: steps 5 and 6 run the 1.5B and 7B multi-speaker stacks concurrently on
# ports 7862 and 7863. The 7B model needs ~16 GB VRAM; running both at once on
# a single 24 GB GPU (g5.xlarge) is tight and may OOM during long generations.
# Use a larger GPU or comment out one step if you hit memory pressure.
#
# Intended to be invoked by Terraform's remote-exec after the two
# scripts have been copied onto the VM, but can also be run by hand:
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

log "=== Step 1/6: Monitoring stack (Netdata dashboard) ==="
bash "${HERE}/provision_monitoring_stack.sh"

log "=== Step 2/6: LLM stack (Ollama + Open WebUI) ==="
bash "${HERE}/provision_llm_stack.sh"

log "=== Step 3/6: TTS stack (Gradio UI) ==="
bash "${HERE}/provision_tts_stack.sh"

log "=== Step 4/6: VibeVoice Realtime TTS stack (single speaker) ==="
bash "${HERE}/provision_vibevoice_stack.sh"

log "=== Step 5/6: VibeVoice multi-speaker TTS stack (1.5B podcast) ==="
bash "${HERE}/provision_vibevoice_tts_stack.sh"

log "=== Step 6/6: VibeVoice multi-speaker TTS stack (7B podcast) ==="
VVT_NAME=vibevoice-tts-7b VVT_PORT=7863 VVT_MODEL=vibevoice/VibeVoice-7B \
  bash "${HERE}/provision_vibevoice_tts_stack.sh"

log "=== All provisioning complete ==="
log "  Monitoring          : http://<EIP>:19999"
log "  Open WebUI          : http://<EIP>:3000"
log "  TTS UI              : http://<EIP>:7860"
log "  VibeVoice (1 spk)   : http://<EIP>:7861"
log "  VibeVoice (multi 1.5B): http://<EIP>:7862"
log "  VibeVoice (multi 7B)  : http://<EIP>:7863"
