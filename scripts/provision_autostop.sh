#!/usr/bin/env bash
set -euo pipefail

########################################
# Autostop guardrails
#
# Installed for EVERY workload, not just the expensive ones -- the runs where
# you forget to think about cost are exactly the runs that need this.
#
# Three independent layers stop the VM:
#
#   1. Hard TTL      systemd timer, N hours after boot, unconditionally.
#   2. Idle stop     systemd timer, every 5 min: stop after N minutes with an
#                    idle GPU and no user traffic on the service ports.
#   3. Nightly       EventBridge Scheduler, 01:00 Europe/Amsterdam
#                    (infra/operations.tf). Sets the Auto Scaling group's
#                    desired capacity to 0, which TERMINATES the instance.
#
# Layers 1 and 2 live inside the VM and call `systemctl poweroff`. On an
# EBS-backed instance an OS shutdown STOPS the instance rather than terminating
# it (Terraform pins instance_initiated_shutdown_behavior = "stop" in the launch
# template), so the root volume and the model cache survive untouched and no
# extra IAM permissions are needed.
#
# That still holds now that the instance is owned by an Auto Scaling group, but
# only because of one deliberate choice: the group runs with HealthCheck,
# ReplaceUnhealthy and AZRebalance suspended. A default ASG would fail the
# stopped instance's health check, terminate it, and launch a replacement --
# turning this guardrail into a billing loop at ~$13/hour. If you ever un-suspend
# those processes, these two layers must be rewritten to call
# `aws autoscaling set-desired-capacity --desired-capacity 0` instead.
#
# Why this matters: a g6e.12xlarge bills at roughly $13/hour in eu-central-1.
# Booting at 09:00 and relying only on the 01:00 nightly costs about $210 for a
# day nobody was using the box.
#
# Usage:
#   sudo bash provision_autostop.sh
#   sudo AUTO_STOP_HOURS=8 IDLE_STOP_MINUTES=45 bash provision_autostop.sh
#   sudo AUTO_STOP_HOURS=0 IDLE_STOP_MINUTES=0 bash provision_autostop.sh   # disable both
########################################

AUTO_STOP_HOURS="${AUTO_STOP_HOURS:-4}"
IDLE_STOP_MINUTES="${IDLE_STOP_MINUTES:-30}"

# How often the idle probe runs. IDLE_STOP_MINUTES is converted to a number of
# consecutive idle probes, so the VM must look idle for the whole window.
IDLE_CHECK_INTERVAL_MIN="${IDLE_CHECK_INTERVAL_MIN:-5}"

# GPU utilisation (percent) at or below which the GPU counts as idle.
IDLE_GPU_THRESHOLD="${IDLE_GPU_THRESHOLD:-5}"

# Ports whose established connections count as "someone is using this box".
#
# Deliberately EXCLUDES 19999 (Netdata) and 80 (static portal): a dashboard left
# open in a background tab is not work, and counting it would keep a $13/h
# instance alive all night for nothing.
ACTIVITY_PORTS="${ACTIVITY_PORTS:-3000 7860 7861 7862 7863 7864 7865 11434 30010}"

CONF_DIR=/etc/llm-lab
BIN_DIR=/opt/llm-lab/bin
STATE_FILE=/run/llm-lab-idle-count

log() {
  echo -e "[provision_autostop] $*"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log "This script must run as root (use: sudo $0)"
    exit 1
  fi
}

########################################
# Step 1: config file (tunable without re-provisioning)
########################################

write_config() {
  log "Writing ${CONF_DIR}/autostop.env ..."
  install -d -m 0755 "${CONF_DIR}" "${BIN_DIR}"

  cat > "${CONF_DIR}/autostop.env" <<EOF
# Autostop tuning. Edit, then:
#   sudo systemctl restart llm-lab-ttl.timer llm-lab-idle.timer
#
# AUTO_STOP_HOURS    hard time-to-live from boot, in hours. 0 disables.
# IDLE_STOP_MINUTES  stop after this long with an idle GPU and no traffic.
#                    0 disables.
AUTO_STOP_HOURS=${AUTO_STOP_HOURS}
IDLE_STOP_MINUTES=${IDLE_STOP_MINUTES}
IDLE_CHECK_INTERVAL_MIN=${IDLE_CHECK_INTERVAL_MIN}
IDLE_GPU_THRESHOLD=${IDLE_GPU_THRESHOLD}
ACTIVITY_PORTS="${ACTIVITY_PORTS}"
EOF
}

########################################
# Step 2: the idle probe
#
# The hard part is not detecting idleness, it is avoiding a false positive:
# stopping the box during a 20-minute weight load, or halfway through the
# initial 144 GB download, would be worse than never stopping at all. So the
# probe treats "still setting up" and "service starting" as busy.
########################################

write_idle_check() {
  log "Writing ${BIN_DIR}/idle-check.sh ..."

  cat > "${BIN_DIR}/idle-check.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

# Decide whether the VM has been idle long enough to stop itself.
# Exit status is irrelevant; the side effect (poweroff) is the point.

# shellcheck disable=SC1091
source /etc/llm-lab/autostop.env

STATE_FILE=/run/llm-lab-idle-count
LOG_TAG="llm-lab-idle"

say() { logger -t "${LOG_TAG}" -- "$*"; echo "[${LOG_TAG}] $*"; }

if [[ "${IDLE_STOP_MINUTES:-0}" -le 0 ]]; then
  exit 0
fi

busy_reason=""

# --- 1. Manual escape hatch -------------------------------------------------
# `sudo touch /run/llm-lab-busy` pins the box up for long unattended jobs.
if [[ -e /run/llm-lab-busy ]]; then
  busy_reason="/run/llm-lab-busy marker present"
fi

# --- 2. Provisioning still in flight ----------------------------------------
# First boot downloads ~144 GB and installs multi-GB container images with the
# GPU completely idle. Stopping here would strand a half-built machine.
if [[ -z "${busy_reason}" ]] && command -v cloud-init >/dev/null 2>&1; then
  ci_status="$(cloud-init status 2>/dev/null | awk -F': ' '/status:/ {print $2}')"
  if [[ -n "${ci_status}" && "${ci_status}" != "done" && "${ci_status}" != "disabled" ]]; then
    busy_reason="cloud-init still ${ci_status}"
  fi
fi

# --- 3. A service is starting up --------------------------------------------
# SGLang spends many minutes loading H3's weights through layerwise offload with
# near-zero GPU utilisation. systemd reports that as "activating".
if [[ -z "${busy_reason}" ]]; then
  for unit in sglang-h3 h3-ui asr tts vibevoice-tts vibevoice-tts-7b vibevoice; do
    state="$(systemctl show -p ActiveState --value "${unit}.service" 2>/dev/null || true)"
    if [[ "${state}" == "activating" ]]; then
      busy_reason="${unit}.service is still starting"
      break
    fi
  done
fi

# --- 4. GPU actually working ------------------------------------------------
if [[ -z "${busy_reason}" ]] && command -v nvidia-smi >/dev/null 2>&1; then
  max_util=0
  while read -r util; do
    util="${util//[!0-9]/}"
    [[ -z "${util}" ]] && continue
    (( util > max_util )) && max_util="${util}"
  done < <(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null)

  if (( max_util > IDLE_GPU_THRESHOLD )); then
    busy_reason="GPU utilisation ${max_util}% > ${IDLE_GPU_THRESHOLD}%"
  fi
fi

# --- 5. Someone connected to a service --------------------------------------
if [[ -z "${busy_reason}" ]] && command -v ss >/dev/null 2>&1; then
  for port in ${ACTIVITY_PORTS}; do
    conns="$(ss -Htn state established "sport = :${port}" 2>/dev/null | wc -l)"
    if (( conns > 0 )); then
      busy_reason="${conns} established connection(s) on port ${port}"
      break
    fi
  done
fi

# --- Decide -----------------------------------------------------------------
if [[ -n "${busy_reason}" ]]; then
  [[ -f "${STATE_FILE}" ]] && rm -f "${STATE_FILE}"
  say "busy: ${busy_reason} (idle counter reset)"
  exit 0
fi

count=0
[[ -f "${STATE_FILE}" ]] && count="$(cat "${STATE_FILE}" 2>/dev/null || echo 0)"
count=$(( count + 1 ))
echo "${count}" > "${STATE_FILE}"

interval="${IDLE_CHECK_INTERVAL_MIN:-5}"
needed=$(( (IDLE_STOP_MINUTES + interval - 1) / interval ))
(( needed < 1 )) && needed=1

idle_min=$(( count * interval ))
say "idle ${idle_min}/${IDLE_STOP_MINUTES} min (check ${count}/${needed})"

if (( count >= needed )); then
  say "STOPPING: idle for ${idle_min} minutes. An OS poweroff stops (does not terminate) this instance; the root volume and model cache are kept."
  rm -f "${STATE_FILE}"
  sync
  systemctl poweroff
fi
EOF
  chmod +x "${BIN_DIR}/idle-check.sh"
}

########################################
# Step 3: the hard TTL
########################################

write_ttl_check() {
  log "Writing ${BIN_DIR}/ttl-stop.sh ..."

  cat > "${BIN_DIR}/ttl-stop.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

# shellcheck disable=SC1091
source /etc/llm-lab/autostop.env

if [[ "${AUTO_STOP_HOURS:-0}" -le 0 ]]; then
  exit 0
fi

logger -t llm-lab-ttl -- "STOPPING: hard TTL of ${AUTO_STOP_HOURS}h since boot reached."
echo "[llm-lab-ttl] Hard TTL reached (${AUTO_STOP_HOURS}h since boot). Stopping the instance."
sync
systemctl poweroff
EOF
  chmod +x "${BIN_DIR}/ttl-stop.sh"
}

########################################
# Step 4: systemd units
########################################

install_units() {
  log "Installing systemd timers..."

  cat > /etc/systemd/system/llm-lab-ttl.service <<EOF
[Unit]
Description=Hard time-to-live stop for the GPU lab VM

[Service]
Type=oneshot
ExecStart=${BIN_DIR}/ttl-stop.sh
EOF

  # OnBootSec, not a wall-clock schedule: the budget is "hours of billed
  # runtime", and it restarts correctly after every stop/start cycle.
  cat > /etc/systemd/system/llm-lab-ttl.timer <<EOF
[Unit]
Description=Stop the GPU lab VM ${AUTO_STOP_HOURS}h after boot

[Timer]
OnBootSec=${AUTO_STOP_HOURS}h
AccuracySec=1min
Unit=llm-lab-ttl.service

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/llm-lab-idle.service <<EOF
[Unit]
Description=Stop the GPU lab VM when it has been idle

[Service]
Type=oneshot
ExecStart=${BIN_DIR}/idle-check.sh
EOF

  # First probe deliberately delayed: never fire while first-boot provisioning
  # is still downloading models.
  cat > /etc/systemd/system/llm-lab-idle.timer <<EOF
[Unit]
Description=Periodic idle probe for the GPU lab VM

[Timer]
OnBootSec=15min
OnUnitActiveSec=${IDLE_CHECK_INTERVAL_MIN}min
AccuracySec=30s
Unit=llm-lab-idle.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload

  if [[ "${AUTO_STOP_HOURS}" -gt 0 ]]; then
    systemctl enable --now llm-lab-ttl.timer
    log "  Hard TTL enabled: stop ${AUTO_STOP_HOURS}h after boot."
  else
    systemctl disable --now llm-lab-ttl.timer 2>/dev/null || true
    log "  Hard TTL DISABLED (AUTO_STOP_HOURS=0)."
  fi

  if [[ "${IDLE_STOP_MINUTES}" -gt 0 ]]; then
    systemctl enable --now llm-lab-idle.timer
    log "  Idle stop enabled: ${IDLE_STOP_MINUTES} min idle, probed every ${IDLE_CHECK_INTERVAL_MIN} min."
  else
    systemctl disable --now llm-lab-idle.timer 2>/dev/null || true
    log "  Idle stop DISABLED (IDLE_STOP_MINUTES=0)."
  fi
}

########################################
# Main
########################################

main() {
  require_root
  write_config
  write_idle_check
  write_ttl_check
  install_units

  log ""
  log "=== Autostop guardrails installed ==="
  log "  Hard TTL   : ${AUTO_STOP_HOURS}h after boot (0 = off)"
  log "  Idle stop  : ${IDLE_STOP_MINUTES} min idle (0 = off)"
  log "  Nightly    : 01:00 Europe/Amsterdam, ASG desired=0 (see infra/operations.tf)"
  log ""
  log "  Inspect    : systemctl list-timers 'llm-lab-*'"
  log "  Idle log   : journalctl -t llm-lab-idle"
  log "  Tune       : sudo nano ${CONF_DIR}/autostop.env"
  log "  Pin awake  : sudo touch /run/llm-lab-busy   (removes on reboot)"
  log ""
  log "  A poweroff STOPS this instance, it does not terminate it: the root"
  log "  volume and any cached models survive. The Auto Scaling group will not"
  log "  replace it, because HealthCheck/ReplaceUnhealthy are suspended."
  log "  Restart it from the AWS console or with:"
  log "    aws ec2 start-instances --instance-ids <id>"
  log ""
  log "  The NIGHTLY layer is different: it terminates. Anything not on a"
  log "  snapshot has to be downloaded again the next morning."
}

main "$@"
