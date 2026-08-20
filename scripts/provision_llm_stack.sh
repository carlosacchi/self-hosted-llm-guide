#!/usr/bin/env bash
set -euo pipefail

########################################
# Base configuration
########################################

# Default models to download (comma-separated, override via first argument).
#   llama3.2:3b        : small, fast general-purpose model (~2 GB)
#   qwen3.5:27b        : 27B MoE multimodal, ~17 GB Q4, 256K context, strong
#                        all-rounder incl. long-context/agentic coding
#   qwen2.5-coder:32b  : dedicated code specialist, ~20 GB Q4, 32K context,
#                        GPT-4o-class on code benchmarks
#
# All three live on disk (~39 GB total). VRAM is used lazily: Ollama loads a
# model only on request and unloads it after keep_alive (~5 min). The two big
# models (17 + 20 GB) can't both be resident on a 24 GB GPU, so Ollama swaps
# them in/out on demand (a few-second reload when switching).
DEFAULT_MODELS="${1:-llama3.2:3b,qwen3.5:27b,qwen2.5-coder:32b}"

# Published ports
OPENWEBUI_PORT="${OPENWEBUI_PORT:-3000}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

# Directory where the stack will live
STACK_DIR="${STACK_DIR:-/opt/llm-stack}"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"

# Owner of the files (typically ubuntu on AWS)
LLM_USER="${LLM_USER:-ubuntu}"
LLM_GROUP="${LLM_GROUP:-ubuntu}"

########################################
# Utility functions
########################################

log() {
  echo -e "[provision_llm_stack] $*"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log "This script must run as root (use: sudo $0)"
    exit 1
  fi
}

########################################
# Step 0: base packages / monitoring
########################################

install_base_tools() {
  log "Installing base packages and monitoring tools..."
  apt-get update -y
  apt-get install -y \
    curl ca-certificates git \
    htop nvtop ncdu iptraf nload \
    jq

  log "Base packages installed (curl, git, htop, nvtop, jq...)."
}

########################################
# Steps 1 & 2: Docker + NVIDIA Container Toolkit
#
# install_docker_if_needed() and configure_nvidia_toolkit_if_needed() live in
# lib_docker_gpu.sh so the MiniMax-H3 stack (mutually exclusive with this one,
# so it can never rely on this script having run) shares the same setup.
########################################

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_docker_gpu.sh
source "${HERE}/lib_docker_gpu.sh"

########################################
# Step 3: docker-compose.yml (GPU-ready)
########################################

create_compose_file() {
  log "Creating stack directory in ${STACK_DIR}..."
  mkdir -p "${STACK_DIR}"
  chown "${LLM_USER}:${LLM_GROUP}" "${STACK_DIR}"

  log "Writing docker-compose.yml..."
  cat > "${COMPOSE_FILE}" <<EOF
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    # Use Docker Compose's explicit GPU flag; the deploy/devices form is not
    # applied consistently outside Swarm.
    gpus: all
    ports:
      - "${OLLAMA_PORT}:11434"
    volumes:
      - ollama:/root/.ollama
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
      # Keep the loaded model resident in VRAM indefinitely instead of
      # unloading it after the default 5 min idle. This avoids paying the
      # multi-minute cold reload (load_duration) on every request after a
      # pause. Set to e.g. 30m if you prefer it to free VRAM when idle.
      - OLLAMA_KEEP_ALIVE=-1
      # Only one model resident at a time. The two big models (qwen3.5:27b
      # ~17 GB, qwen2.5-coder:32b ~20 GB) can't both fit a 24 GB GPU, so this
      # stops Ollama from trying to co-load them (which would spill layers to
      # CPU and crawl). Switching models still reloads, but never offloads.
      - OLLAMA_MAX_LOADED_MODELS=1

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    depends_on:
      - ollama
    environment:
      # IMPORTANT: internal Ollama port (11434), not the published one
      - OLLAMA_BASE_URL=http://ollama:11434
    ports:
      - "${OPENWEBUI_PORT}:8080"
    volumes:
      - openwebui:/app/backend/data

volumes:
  ollama:
  openwebui:
EOF

  chown "${LLM_USER}:${LLM_GROUP}" "${COMPOSE_FILE}"
}

########################################
# Step 4: start stack
########################################

start_stack() {
  log "Starting Docker stack (Ollama + Open WebUI)..."
  cd "${STACK_DIR}"

  # Tear down any previous stack (optional but handy)
  docker compose down || true

  docker compose pull
  docker compose up -d

  log "Stack started."
}

########################################
# Step 5: download default models
########################################

wait_for_ollama_ready() {
  local max_retries=10
  local delay=5

  for i in $(seq 1 "${max_retries}"); do
    if docker exec ollama ollama list >/dev/null 2>&1; then
      return 0
    fi

    log "Ollama not ready yet, retry ${i}/${max_retries} in ${delay}s..."
    sleep "${delay}"
  done

  log "Unable to reach Ollama to download the models (timeout)."
  return 1
}

pull_default_models() {
  local models_csv="$1"

  if [[ -z "${models_csv}" ]]; then
    log "No default models to download (empty string)."
    return 0
  fi

  IFS=',' read -ra models <<< "${models_csv}"
  if [[ "${#models[@]}" -eq 0 ]]; then
    log "Parsed default model list is empty."
    return 0
  fi

  if ! wait_for_ollama_ready; then
    return 1
  fi

  for raw_model in "${models[@]}"; do
    local model="${raw_model//[[:space:]]/}"
    if [[ -z "${model}" ]]; then
      continue
    fi

    log "Downloading default model: ${model}"
    if docker exec ollama ollama pull "${model}"; then
      log "Model ${model} downloaded successfully."
    else
      log "Failed to download ${model}, but continuing anyway."
    fi
  done
}

########################################
# MAIN
########################################

require_root
log "Starting LLM stack provisioning..."
log "User: ${LLM_USER}, stack dir: ${STACK_DIR}"
log "Ports -> Open WebUI: ${OPENWEBUI_PORT}, Ollama API: ${OLLAMA_PORT}"
log "Default models: ${DEFAULT_MODELS}"

install_base_tools
install_docker_if_needed
configure_nvidia_toolkit_if_needed
create_compose_file
start_stack
pull_default_models "${DEFAULT_MODELS}"

if ! PUBLIC_IP=$(curl -fsS --max-time 5 ifconfig.me); then
  PUBLIC_IP="<unknown>"
fi

log "Provisioning completed!"
log "UI available at:  http://${PUBLIC_IP}:${OPENWEBUI_PORT}"
log "Ollama API at:   http://${PUBLIC_IP}:${OLLAMA_PORT}"
log "Monitoring tools installed: htop, nvtop (GPU), nvidia-smi"
