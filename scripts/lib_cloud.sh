#!/usr/bin/env bash
#
# Cloud abstraction for the two places where AWS and Azure genuinely differ.
#
# Sourced by provision_autostop.sh and provision_h3_stack.sh. It only defines
# functions and has no side effects, so it is safe to source from anywhere:
#
#   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${HERE}/lib_cloud.sh"
#
# Everything else in scripts/ is already portable: Ubuntu, Docker, the NVIDIA
# container toolkit and systemd behave identically on both clouds. These two
# do not, and both of them cost money when they are got wrong.
#
# Callers are expected to provide their own log() function; a default is used
# when they don't.

if ! declare -f log >/dev/null 2>&1; then
  log() {
    echo -e "[lib_cloud] $*"
  }
fi

########################################
# Which cloud are we on?
#
# Both providers answer on 169.254.169.254 but with incompatible protocols, so
# the probe is the identification. Cached in a file because the idle probe runs
# every five minutes forever and there is no reason to ask twice.
########################################

LLM_LAB_CLOUD_CACHE="${LLM_LAB_CLOUD_CACHE:-/etc/llm-lab/cloud}"

detect_cloud() {
  if [[ -s "${LLM_LAB_CLOUD_CACHE}" ]]; then
    cat "${LLM_LAB_CLOUD_CACHE}"
    return 0
  fi

  local answer="unknown"

  # Azure: flat HTTP, requires the Metadata header, refuses without it.
  if curl -sS -m 3 -H 'Metadata: true' \
    'http://169.254.169.254/metadata/instance?api-version=2021-02-01' \
    >/dev/null 2>&1; then
    answer="azure"
  # AWS IMDSv2: PUT for a token first.
  elif curl -sS -m 3 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    'http://169.254.169.254/latest/api/token' >/dev/null 2>&1; then
    answer="aws"
  fi

  install -d -m 0755 "$(dirname "${LLM_LAB_CLOUD_CACHE}")" 2>/dev/null || true
  echo "${answer}" > "${LLM_LAB_CLOUD_CACHE}" 2>/dev/null || true
  echo "${answer}"
}

########################################
# Stop billing for this VM, from inside it.
#
# THIS IS THE ONE THAT BITES.
#
# On AWS an OS poweroff is enough: the launch template pins
# instance_initiated_shutdown_behavior = "stop", so the instance stops, the root
# volume survives, and billing for compute ends.
#
# On Azure the same poweroff leaves the VM in state "Stopped" -- still
# ALLOCATED, and still billed at the full hourly rate. Only "Stopped
# (deallocated)" stops the meter, and that state can only be reached through the
# ARM control plane. So the Azure path calls the deallocate API with the VM's
# own system-assigned managed identity (which needs Virtual Machine Contributor
# on itself) and lets the platform shut the guest down.
#
# Porting the AWS guardrail unchanged would produce a cost guardrail that costs
# exactly as much as having no guardrail at all.
########################################

stop_self() {
  local reason="${1:-requested}"
  local cloud
  cloud="$(detect_cloud)"

  case "${cloud}" in
    azure)
      log "Deallocating this VM via ARM (${reason})."

      local token resource_id
      token="$(curl -sS -m 10 -H 'Metadata: true' \
        'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F' \
        2>/dev/null | jq -r '.access_token // empty')"

      resource_id="$(curl -sS -m 10 -H 'Metadata: true' \
        'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' \
        2>/dev/null | jq -r '.resourceId // empty')"

      if [[ -z "${token}" || -z "${resource_id}" ]]; then
        log "FATAL: no managed-identity token or resource id. NOT falling back to"
        log "       poweroff: on Azure that would stop the guest while Azure keeps"
        log "       billing the allocation. Leaving the VM up so the failure is"
        log "       visible instead of silently expensive."
        return 1
      fi

      sync
      curl -sS -m 30 -X POST \
        -H "Authorization: Bearer ${token}" \
        -H 'Content-Length: 0' \
        "https://management.azure.com${resource_id}/deallocate?api-version=2024-07-01" \
        >/dev/null
      log "Deallocate accepted; the platform will shut the guest down shortly."
      ;;

    aws)
      log "Powering off (${reason}); EC2 turns this into a stop, not a terminate."
      sync
      systemctl poweroff
      ;;

    *)
      log "WARNING: cloud not identified. Falling back to a plain poweroff."
      sync
      systemctl poweroff
      ;;
  esac
}

########################################
# Find the ephemeral local storage.
#
# Both clouds ship some, and both wipe it on every stop/deallocate, which is why
# the H3 stack rebuilds its scratch and swap on every boot. Identification
# differs:
#
#   AWS    model "Amazon EC2 NVMe Instance Storage". The root EBS volume reports
#          "Amazon Elastic Block Store" and must never be touched.
#   Azure  model "Microsoft NVMe Direct Disk" on the newer local-NVMe sizes, and
#          the classic temp resource disk elsewhere. The resource disk cannot be
#          matched on its model string -- it reports the same "Virtual Disk" as
#          every persistent data disk -- so it is found through the udev alias
#          the Azure guest agent maintains for exactly this purpose.
#
# Prints one device path per line; prints nothing when there is no local disk.
########################################

find_ephemeral_nvme() {
  local found
  found="$(
    lsblk -dno NAME,MODEL 2>/dev/null \
      | grep -iE 'Instance Storage|NVMe Direct Disk' \
      | awk '{print "/dev/"$1}'
  )"

  if [[ -n "${found}" ]]; then
    echo "${found}"
    return 0
  fi

  if [[ -e /dev/disk/cloud/azure_resource ]]; then
    readlink -f /dev/disk/cloud/azure_resource
  fi
}
