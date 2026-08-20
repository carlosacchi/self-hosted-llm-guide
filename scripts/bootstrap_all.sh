#!/usr/bin/env bash
set -euo pipefail

########################################
# Bootstrap orchestrator
#
# Each stack is gated by an ENABLE_* env var so the deploy can pick exactly
# which tools to install (the GitHub Actions workflow exposes these as
# checkboxes; Terraform passes them through cloud-init / user-data.sh):
#
#   ENABLE_MONITORING          provision_monitoring_stack.sh      (Netdata, 19999)
#   ENABLE_LLM                 provision_llm_stack.sh             (Ollama + Open WebUI, 3000/11434)
#   ENABLE_TTS                 provision_tts_stack.sh             (Kokoro/XTTS/Piper Gradio UI, 7860)
#   ENABLE_VIBEVOICE_15B       provision_vibevoice_tts_stack.sh   (VibeVoice 1.5B multi-speaker, 7861)
#   ENABLE_VIBEVOICE_REALTIME  provision_vibevoice_stack.sh       (VibeVoice Realtime 0.5B, 7862)
#   ENABLE_VIBEVOICE_7B        provision_vibevoice_tts_stack.sh   (VibeVoice 7B multi-speaker, 7863, ~16 GB VRAM)
#   ENABLE_ASR + ASR_MODEL     provision_asr_stack.sh             (Speech-to-text: audio/video/YouTube -> text, 7864)
#   ENABLE_H3 + H3_VARIANT     provision_h3_stack.sh              (MiniMax-H3 video+audio, 30010 + UI 7865)
#
# The autostop guardrails (provision_autostop.sh) and the landing portal
# (nginx, port 80) always run last. Defaults (when an env var is unset) match
# the previous behavior: monitoring/llm/tts/vibevoice-1.5B ON, realtime + 7B OFF.
#
# Mind the GPU budget: on a single 24 GB GPU (g5.xlarge) you cannot run every
# model at once (e.g. a 27B LLM + VibeVoice 7B will OOM). Pick a combo that
# fits, or use a larger GPU.
#
# ENABLE_H3 is different in kind: MiniMax-H3 is a 33B flow-matching DiT that
# needs all 4 L40S of a g6e.12xlarge plus most of the 384 GiB of host RAM for
# layerwise offload. It is EXCLUSIVE - enabling it alongside any other GPU stack
# is a hard error, not a warning, because on a ~$13/h box a bootstrap that OOMs
# halfway through is money burned for nothing.
#
# Intended to be invoked by cloud-init on first boot (see scripts/user-data.sh),
# but can also be run by hand, optionally overriding flags:
#
#   sudo ENABLE_VIBEVOICE_7B=true bash bootstrap_all.sh
#
# It must run as root (the sub-scripts require it).
########################################

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  echo -e "[bootstrap_all] $*"
}

# Tool selection flags. Default to the previous always-on behavior when unset
# so running this script by hand still provisions the standard lab.
ENABLE_MONITORING="${ENABLE_MONITORING:-true}"
ENABLE_LLM="${ENABLE_LLM:-true}"
ENABLE_TTS="${ENABLE_TTS:-true}"
ENABLE_VIBEVOICE_15B="${ENABLE_VIBEVOICE_15B:-true}"
ENABLE_VIBEVOICE_REALTIME="${ENABLE_VIBEVOICE_REALTIME:-false}"
ENABLE_VIBEVOICE_7B="${ENABLE_VIBEVOICE_7B:-false}"
ENABLE_ASR="${ENABLE_ASR:-false}"
ASR_MODEL="${ASR_MODEL:-whisper-large-v3}"
ENABLE_H3="${ENABLE_H3:-false}"
H3_VARIANT="${H3_VARIANT:-fl2va}"
H3_SGLANG_IMAGE="${H3_SGLANG_IMAGE:-lmsysorg/sglang:v0.5.17-cu129}"

# Cost guardrails (see provision_autostop.sh). Installed for every workload.
AUTO_STOP_HOURS="${AUTO_STOP_HOURS:-4}"
IDLE_STOP_MINUTES="${IDLE_STOP_MINUTES:-30}"

# True only for the literal string "true" (case-insensitive); anything else off.
is_enabled() {
  [[ "${1,,}" == "true" ]]
}

if [[ "$EUID" -ne 0 ]]; then
  log "This script must run as root (use: sudo $0)"
  exit 1
fi

# On first boot, cloud-init's unattended-upgrades grabs the dpkg/apt lock while
# our provisioners try to apt-get install. Without this, the first apt-get fails
# ("Could not get lock /var/lib/dpkg/lock-frontend"), and set -e aborts the whole
# bootstrap mid-way (e.g. before the portal is installed). Make every apt-get in
# every sub-script WAIT for the lock (up to 10 min) instead of failing outright.
log "Configuring apt to wait for the dpkg lock (avoids unattended-upgrades race)..."
echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/99llm-lab-lock-timeout

# A 10-min lock wait is not always enough: on the very first boot an
# unattended-upgrades run can hold the dpkg lock for far longer (large security
# upgrade set + slow first-boot I/O), so apt-get times out and the bootstrap
# stalls/aborts (we have seen it hang on "Waiting for cache lock ... held by
# process N (unattended-upgr)"). Rather than only waiting, proactively stop and
# disable the automatic apt timers/services for the duration of provisioning so
# nothing competes for the lock. This is the root-cause fix for the hang.
disable_unattended_upgrades() {
  log "Disabling automatic apt/unattended-upgrades to avoid dpkg lock contention..."

  # Stop and disable the timers + services that trigger background apt activity.
  # '|| true' everywhere: any of these may be absent depending on the AMI.
  local units=(
    unattended-upgrades.service
    apt-daily.service apt-daily.timer
    apt-daily-upgrade.service apt-daily-upgrade.timer
  )
  systemctl stop "${units[@]}" 2>/dev/null || true
  systemctl disable "${units[@]}" 2>/dev/null || true
  systemctl mask unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

  # If an unattended-upgrades run is already in flight and holding the lock,
  # wait briefly for it to exit cleanly, then force-kill any stragglers so the
  # lock is released before our provisioners start apt-get. dpkg-reconfigure
  # repairs any interrupted package state left behind by the kill.
  local waited=0
  while pgrep -x unattended-upgr >/dev/null 2>&1 && (( waited < 120 )); do
    log "  waiting for in-flight unattended-upgrades to finish (${waited}s)..."
    sleep 5
    waited=$((waited + 5))
  done
  if pgrep -x unattended-upgr >/dev/null 2>&1; then
    log "  unattended-upgrades still running after ${waited}s; terminating it to free the dpkg lock."
    pkill -x unattended-upgr 2>/dev/null || true
    sleep 3
    pkill -9 -x unattended-upgr 2>/dev/null || true
    sleep 2
    # Repair any package state interrupted by the kill so later apt-get works.
    dpkg --configure -a 2>/dev/null || true
  fi

  log "Automatic apt updates disabled for the provisioning run."
}

disable_unattended_upgrades

log "Selected stacks: monitoring=${ENABLE_MONITORING} llm=${ENABLE_LLM} tts=${ENABLE_TTS} vibevoice_1.5b=${ENABLE_VIBEVOICE_15B} vibevoice_realtime=${ENABLE_VIBEVOICE_REALTIME} vibevoice_7b=${ENABLE_VIBEVOICE_7B} asr=${ENABLE_ASR}(${ASR_MODEL}) h3=${ENABLE_H3}(${H3_VARIANT})"
log "Cost guardrails: hard TTL=${AUTO_STOP_HOURS}h idle stop=${IDLE_STOP_MINUTES}min (0 = disabled)"

# Hard guard, not a warning. Terraform already blocks this combination in
# `plan` (preconditions in infra/compute.tf), but bootstrap_all.sh is also run
# by hand, and on a g6e.12xlarge every wasted minute is real money.
if is_enabled "${ENABLE_H3}"; then
  conflicting=()
  is_enabled "${ENABLE_LLM}"                && conflicting+=("llm")
  is_enabled "${ENABLE_TTS}"                && conflicting+=("tts")
  is_enabled "${ENABLE_VIBEVOICE_15B}"      && conflicting+=("vibevoice_1.5b")
  is_enabled "${ENABLE_VIBEVOICE_REALTIME}" && conflicting+=("vibevoice_realtime")
  is_enabled "${ENABLE_VIBEVOICE_7B}"       && conflicting+=("vibevoice_7b")
  is_enabled "${ENABLE_ASR}"                && conflicting+=("asr")

  if (( ${#conflicting[@]} > 0 )); then
    log "FATAL: ENABLE_H3=true cannot be combined with: ${conflicting[*]}"
    log "       MiniMax-H3 needs all 4 GPUs and most of the host RAM for layerwise"
    log "       offload. Sharing the box guarantees an OOM partway through a costly"
    log "       boot. Disable the other stacks (monitoring may stay on) and re-run."
    exit 1
  fi

  if [[ "${H3_VARIANT,,}" != "fl2va" ]]; then
    log "FATAL: H3_VARIANT='${H3_VARIANT}' is not supported; only 'fl2va' is."
    log "       The ref2va partition produces snow/noise on every run on L40S-class"
    log "       GPUs (compute capability 8.9): https://github.com/sgl-project/sglang/issues/34110"
    log "       fl2va already serves both t2va and first/last-frame conditioning."
    exit 1
  fi
fi

# Advisory only (non-fatal): the VibeVoice stacks reuse the GPU/NVIDIA setup
# performed by the LLM stack. If you enable a VibeVoice stack without the LLM
# stack, make sure the NVIDIA Container Toolkit / drivers are otherwise present.
if ! is_enabled "${ENABLE_LLM}" && { is_enabled "${ENABLE_VIBEVOICE_15B}" || is_enabled "${ENABLE_VIBEVOICE_REALTIME}" || is_enabled "${ENABLE_VIBEVOICE_7B}"; }; then
  log "WARNING: a VibeVoice stack is enabled but the LLM stack is not. GPU setup normally"
  log "         done by provision_llm_stack.sh may be missing; VibeVoice could fail to start."
fi

if is_enabled "${ENABLE_MONITORING}"; then
  log "=== Monitoring stack (Netdata dashboard, port 19999) ==="
  bash "${HERE}/provision_monitoring_stack.sh"
else
  log "--- Skipping monitoring stack (ENABLE_MONITORING=${ENABLE_MONITORING}) ---"
fi

if is_enabled "${ENABLE_LLM}"; then
  log "=== LLM stack (Ollama + Open WebUI, ports 3000/11434) ==="
  bash "${HERE}/provision_llm_stack.sh"
else
  log "--- Skipping LLM stack (ENABLE_LLM=${ENABLE_LLM}) ---"
fi

if is_enabled "${ENABLE_TTS}"; then
  log "=== TTS stack (Gradio UI, port 7860) ==="
  bash "${HERE}/provision_tts_stack.sh"
else
  log "--- Skipping TTS stack (ENABLE_TTS=${ENABLE_TTS}) ---"
fi

if is_enabled "${ENABLE_VIBEVOICE_15B}"; then
  log "=== VibeVoice multi-speaker TTS stack (1.5B podcast, port 7861) ==="
  VVT_PORT=7861 bash "${HERE}/provision_vibevoice_tts_stack.sh"
else
  log "--- Skipping VibeVoice 1.5B stack (ENABLE_VIBEVOICE_15B=${ENABLE_VIBEVOICE_15B}) ---"
fi

if is_enabled "${ENABLE_VIBEVOICE_REALTIME}"; then
  log "=== VibeVoice Realtime single-speaker TTS stack (0.5B, port 7862) ==="
  VV_PORT=7862 bash "${HERE}/provision_vibevoice_stack.sh"
else
  log "--- Skipping VibeVoice Realtime 0.5B stack (ENABLE_VIBEVOICE_REALTIME=${ENABLE_VIBEVOICE_REALTIME}) ---"
fi

if is_enabled "${ENABLE_VIBEVOICE_7B}"; then
  log "=== VibeVoice multi-speaker TTS stack (7B, port 7863, ~16 GB VRAM) ==="
  VVT_NAME=vibevoice-tts-7b VVT_PORT=7863 VVT_MODEL=vibevoice/VibeVoice-7B \
    bash "${HERE}/provision_vibevoice_tts_stack.sh"
else
  log "--- Skipping VibeVoice 7B stack (ENABLE_VIBEVOICE_7B=${ENABLE_VIBEVOICE_7B}) ---"
fi

if is_enabled "${ENABLE_ASR}"; then
  log "=== ASR speech-to-text stack (model=${ASR_MODEL}, port 7864) ==="
  ASR_MODEL="${ASR_MODEL}" ASR_PORT=7864 bash "${HERE}/provision_asr_stack.sh"
else
  log "--- Skipping ASR stack (ENABLE_ASR=${ENABLE_ASR}) ---"
fi

if is_enabled "${ENABLE_H3}"; then
  log "=== MiniMax-H3 video+audio stack (SGLang REST 30010, variant=${H3_VARIANT}) ==="
  H3_VARIANT="${H3_VARIANT}" H3_SGLANG_IMAGE="${H3_SGLANG_IMAGE}" \
    bash "${HERE}/provision_h3_stack.sh"

  log "=== MiniMax-H3 Gradio UI (port 7865) ==="
  H3_UI_PORT=7865 bash "${HERE}/provision_h3_ui_stack.sh"
else
  log "--- Skipping MiniMax-H3 stack (ENABLE_H3=${ENABLE_H3}) ---"
fi

# Always installed: the guardrails matter most on exactly the runs where you
# forgot to think about them.
log "=== Autostop guardrails (TTL + idle stop) ==="
AUTO_STOP_HOURS="${AUTO_STOP_HOURS}" IDLE_STOP_MINUTES="${IDLE_STOP_MINUTES}" \
  bash "${HERE}/provision_autostop.sh"

log "=== Landing page (nginx portal, port 80) ==="
# Pass the selection through so the portal lists only what was installed.
ENABLE_MONITORING="${ENABLE_MONITORING}" \
ENABLE_LLM="${ENABLE_LLM}" \
ENABLE_TTS="${ENABLE_TTS}" \
ENABLE_VIBEVOICE_15B="${ENABLE_VIBEVOICE_15B}" \
ENABLE_VIBEVOICE_REALTIME="${ENABLE_VIBEVOICE_REALTIME}" \
ENABLE_VIBEVOICE_7B="${ENABLE_VIBEVOICE_7B}" \
ENABLE_ASR="${ENABLE_ASR}" \
ENABLE_H3="${ENABLE_H3}" \
  bash "${HERE}/provision_landing_stack.sh"

log "=== All provisioning complete ==="
log "  Portal (start here)         : http://<EIP>/"
is_enabled "${ENABLE_MONITORING}"         && log "  Monitoring                  : http://<EIP>:19999"
is_enabled "${ENABLE_LLM}"                && log "  Open WebUI                  : http://<EIP>:3000"
is_enabled "${ENABLE_TTS}"               && log "  TTS UI                      : http://<EIP>:7860"
is_enabled "${ENABLE_VIBEVOICE_15B}"     && log "  VibeVoice (multi 1.5B)      : http://<EIP>:7861"
is_enabled "${ENABLE_VIBEVOICE_REALTIME}" && log "  VibeVoice (realtime 0.5B)   : http://<EIP>:7862"
is_enabled "${ENABLE_VIBEVOICE_7B}"      && log "  VibeVoice (multi 7B)        : http://<EIP>:7863"
is_enabled "${ENABLE_ASR}"               && log "  Speech-to-Text (${ASR_MODEL}) : http://<EIP>:7864"
is_enabled "${ENABLE_H3}"                && log "  MiniMax-H3 video UI         : http://<EIP>:7865"
is_enabled "${ENABLE_H3}"                && log "  MiniMax-H3 REST API         : http://<EIP>:30010/v1/videos"
log ""
log "  Autostop: hard TTL=${AUTO_STOP_HOURS}h, idle stop=${IDLE_STOP_MINUTES}min, nightly cron 01:00."
log "  Check it with: systemctl list-timers 'llm-lab-*'"
