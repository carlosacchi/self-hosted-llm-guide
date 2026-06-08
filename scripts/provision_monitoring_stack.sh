#!/usr/bin/env bash
set -euo pipefail

########################################
# Monitoring stack provisioner (Netdata)
#
# Installs the Netdata agent, which exposes a real-time web dashboard for
# system health WITHOUT needing SSH:
#   - GPU utilization + GPU memory (NVIDIA, via nvidia-smi collector)
#   - CPU per-core utilization, load average
#   - RAM / swap usage
#   - Disk space + disk I/O
#   - Network throughput, running services, systemd unit states
#
# The dashboard is served on port 19999. Access is restricted to your IP by
# the security group (see infra/compute.tf).
#
# The DLAMI already ships nvidia-smi, which Netdata's nvidia_smi collector
# uses to scrape GPU metrics automatically — no extra config needed.
#
# Usage:
#   sudo bash provision_monitoring_stack.sh
########################################

NETDATA_PORT="${NETDATA_PORT:-19999}"

log() {
  echo -e "[provision_monitoring_stack] $*"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log "This script must run as root (use: sudo $0)"
    exit 1
  fi
}

########################################
# Step 1: install Netdata via the official kickstart script
########################################

install_netdata() {
  if command -v netdata >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^netdata.service'; then
    log "Netdata already installed, skipping kickstart."
    return
  fi

  log "Installing Netdata (stable channel, no telemetry, no auto-update)..."
  # --stable-channel : use stable releases
  # --disable-telemetry : do not phone home
  # --no-updates : we manage updates ourselves (immutable lab box)
  # --non-interactive : never prompt
  curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh
  sh /tmp/netdata-kickstart.sh --stable-channel --disable-telemetry --no-updates --non-interactive
  rm -f /tmp/netdata-kickstart.sh
  log "Netdata installed."
}

########################################
# Step 2: bind the dashboard to all interfaces on the chosen port
########################################

configure_netdata() {
  log "Configuring Netdata to listen on 0.0.0.0:${NETDATA_PORT}..."

  local cfg="/etc/netdata/netdata.conf"
  mkdir -p /etc/netdata

  # Minimal override: bind address + port. The security group is what actually
  # restricts who can reach the dashboard (your IP only).
  cat > "${cfg}" <<EOF
[global]
    run as user = netdata

[web]
    bind to = 0.0.0.0:${NETDATA_PORT}
EOF

  log "Netdata config written to ${cfg}."
}

########################################
# Step 3: ensure the NVIDIA GPU collector is enabled
########################################

enable_gpu_collector() {
  log "Verifying nvidia-smi is available for GPU metrics..."
  if command -v nvidia-smi >/dev/null 2>&1; then
    log "nvidia-smi found; Netdata will auto-collect GPU utilization + memory."
  else
    log "WARNING: nvidia-smi not found. GPU panels will be empty until drivers are present."
  fi
}

########################################
# Step 4: (re)start the service
########################################

start_service() {
  log "Enabling and restarting netdata.service..."
  systemctl daemon-reload
  systemctl enable netdata
  systemctl restart netdata
  log "Netdata running on port ${NETDATA_PORT}."
}

########################################
# Main
########################################

main() {
  require_root
  install_netdata
  configure_netdata
  enable_gpu_collector
  start_service

  log ""
  log "=== Monitoring stack ready ==="
  log "  Dashboard : http://<EIP>:${NETDATA_PORT}"
  log "  Metrics   : GPU util/mem, CPU, RAM, disk, network, services"
  log "  Status    : sudo systemctl status netdata"
  log "  Logs      : sudo journalctl -fu netdata"
}

main "$@"
