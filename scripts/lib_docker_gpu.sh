#!/usr/bin/env bash
#
# Shared Docker + NVIDIA Container Toolkit setup.
#
# Sourced by the provisioners that run containers on the GPU
# (provision_llm_stack.sh, provision_h3_stack.sh). It only defines functions and
# has no side effects, so it is safe to source from anywhere:
#
#   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${HERE}/lib_docker_gpu.sh"
#
# Extracted so the H3 stack (which never runs the LLM stack, being mutually
# exclusive with it) gets the exact same, already-debugged GPU container setup
# instead of a second copy that drifts.
#
# Callers are expected to provide their own log() function; a default is used
# when they don't.

if ! declare -f log >/dev/null 2>&1; then
  log() {
    echo -e "[lib_docker_gpu] $*"
  }
fi

########################################
# Docker + compose (with containerd cleanup)
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
# NVIDIA Container Toolkit (GPU inside containers)
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
