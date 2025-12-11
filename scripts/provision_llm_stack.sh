#!/usr/bin/env bash
set -euo pipefail

########################################
# Base configuration
########################################

# Default models to download (comma-separated, override via first argument)
DEFAULT_MODELS="${1:-llama3.2:3b,qwen2.5-coder:32b}"

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
# Step 1: Docker + compose (with containerd cleanup)
########################################

install_docker_if_needed() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker not found, removing conflicting packages and installing it..."

    # Stop services if present
    systemctl stop docker 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true

    # Remove legacy Docker/containerd packages (Ubuntu + Docker repo)
    apt-get remove -y \
      docker.io docker-ce docker-ce-cli \
      containerd containerd.io \
      docker-compose docker-compose-plugin \
      docker-buildx-plugin || true

    apt-get autoremove -y || true
    apt-get update -y

    # Install the clean build from Ubuntu repos
    apt-get install -y docker.io docker-compose-plugin

    systemctl enable --now docker
    log "Docker installed and running."
  else
    log "Docker already present, skipping installation."
  fi
}

########################################
# Step 2: NVIDIA Container Toolkit (GPU)
########################################

configure_nvidia_toolkit_if_needed() {
  # If nvidia-smi is missing, assume no GPU/drivers are present and stay CPU-only.
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    log "nvidia-smi not found: no NVIDIA GPU/driver detected, staying CPU-only."
    return 0
  fi

  # If nvidia-ctk is missing, install nvidia-container-toolkit
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    log "Configuring NVIDIA Container Toolkit for Docker (GPU inside containers)..."

    local distribution
    distribution=$(. /etc/os-release; echo "${ID}${VERSION_ID}")

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -fsSL "https://nvidia.github.io/libnvidia-container/stable/${distribution}/libnvidia-container.list" \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update -y
    apt-get install -y nvidia-container-toolkit

    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    log "NVIDIA Container Toolkit configured."
  else
    log "NVIDIA Container Toolkit already configured."
  fi
}

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
    ports:
      - "${OLLAMA_PORT}:11434"
    volumes:
      - ollama:/root/.ollama
    # If an NVIDIA GPU exists, Docker will use the runtime configured by nvidia-container-toolkit.
    # These env vars expose the correct capabilities.
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: ["gpu"]

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
