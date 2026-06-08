#!/usr/bin/env bash
set -euo pipefail

########################################
# Bootstrap orchestrator
#
# Runs the full provisioning chain in order:
#   1. provision_monitoring_stack.sh (Netdata system + GPU dashboard)
#   2. provision_llm_stack.sh        (Docker + NVIDIA + Ollama + Open WebUI)
#   3. provision_tts_stack.sh        (Kokoro/XTTS/Piper + Gradio TTS UI)
#   4. provision_vibevoice_stack.sh  (VibeVoice Realtime TTS web UI)
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

log "=== Step 1/4: Monitoring stack (Netdata dashboard) ==="
bash "${HERE}/provision_monitoring_stack.sh"

log "=== Step 2/4: LLM stack (Ollama + Open WebUI) ==="
bash "${HERE}/provision_llm_stack.sh"

log "=== Step 3/4: TTS stack (Gradio UI) ==="
bash "${HERE}/provision_tts_stack.sh"

log "=== Step 4/4: VibeVoice Realtime TTS stack ==="
bash "${HERE}/provision_vibevoice_stack.sh"

log "=== All provisioning complete ==="
log "  Monitoring    : http://<EIP>:19999"
log "  Open WebUI    : http://<EIP>:3000"
log "  TTS UI        : http://<EIP>:7860"
log "  VibeVoice UI  : http://<EIP>:7861"
