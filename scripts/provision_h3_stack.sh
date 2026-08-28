#!/usr/bin/env bash
set -euo pipefail

########################################
# MiniMax-H3 stack provisioner (SGLang-Diffusion, Ref2VA)
#
# Serves MiniMax-H3 -- a 33B flow-matching diffusion transformer that denoises
# joint video + audio latents -- behind SGLang's OpenAI-style video API on port
# 30010. One request returns an H.264 MP4 (24 fps) with a synchronized stereo
# AAC track. Clip length 4-15 seconds.
#
# This stack serves the Ref2VA checkpoint partition ONLY: `task: "ref2va"` with
# image, video and audio references in `conditions`. The FL2VA partition (t2va
# text-only + first/last-frame conditioning) is deliberately not downloaded --
# it is another 144 GB for a mode this lab does not use.
#
# The API is ASYNCHRONOUS, three calls:
#   POST /v1/videos                 -> {"id": ...}
#   GET  /v1/videos/{id}            -> poll until status is completed/failed
#   GET  /v1/videos/{id}/content    -> the MP4 bytes
# provision_h3_ui_stack.sh wraps that loop in a Gradio UI on port 7865.
#
# Reference assets are passed as server-local file:// URIs, so they must be
# visible INSIDE the container: H3_MEDIA_DIR on the host is bind-mounted
# read-only at /data/minimax-h3, which is where the UI writes its uploads.
#
# TARGET HARDWARE: g7e.12xlarge -- 2x NVIDIA RTX PRO 6000 96 GB (sm_120),
# 512 GiB RAM. Two consequences drive everything below:
#
#   1. 192 GB of total VRAM is NOT enough to hold H3 resident -- the published
#      datacenter recipes peak at 50-94 GB per GPU. Layerwise offload to host
#      RAM is mandatory (--performance-mode memory).
#   2. That makes HOST RAM the binding constraint, not VRAM. The reference
#      offload recipe (2x RTX 5090) needs ~377 GiB of host RAM. We add a large
#      NVMe-backed swapfile as the cushion, because swapping is slow but an OOM
#      kill costs a whole run.
#
# g6e.12xlarge (4x L40S, sm_89) is NOT supported and this script refuses to run
# on it: Ref2VA denoises to snow/noise on every run on compute capability 8.9 --
# https://github.com/sgl-project/sglang/issues/34110 -- and failing before the
# 144 GB download is far cheaper than discovering it after one generation.
#
# Usage:
#   sudo bash provision_h3_stack.sh
########################################

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

H3_NAME="${H3_NAME:-sglang-h3}"
H3_DIR="${H3_DIR:-/opt/h3}"
H3_PORT="${H3_PORT:-30010}"
H3_SGLANG_IMAGE="${H3_SGLANG_IMAGE:-lmsysorg/sglang:v0.5.17-cu129}"
H3_REPO_ID="${H3_REPO_ID:-MiniMaxAI/MiniMax-H3}"

# SGLang resolves --model-variant ref2va to this capitalised partition directory.
H3_PARTITION_DIR="Ref2VA"

# Model cache lives on the ROOT EBS VOLUME, never on the instance store: the
# autostop guardrails stop this VM several times a day and instance storage is
# wiped on every stop. Re-downloading 144 GB each morning would cost more than
# the extra EBS.
H3_MODEL_ROOT="${H3_MODEL_ROOT:-/opt/models}"
H3_MODEL_DIR="${H3_MODEL_DIR:-${H3_MODEL_ROOT}/MiniMax-H3}"

# Reference images/audio/video uploaded by the UI. Bind-mounted read-only into
# the container at /data/minimax-h3; on EBS so uploads survive an autostop.
H3_MEDIA_DIR="${H3_MEDIA_DIR:-${H3_DIR}/media}"
H3_MEDIA_MOUNT="/data/minimax-h3"
H3_MEDIA_OWNER="${H3_MEDIA_OWNER:-ubuntu:ubuntu}"

# Instance-store NVMe: scratch space and swap. Both are expendable across stops.
NVME_MOUNT="${NVME_MOUNT:-/mnt/nvme}"
NVME_SCRATCH="${NVME_MOUNT}/scratch"
SWAP_GIB="${SWAP_GIB:-256}"

MIN_RAM_GB="${MIN_RAM_GB:-350}"

# g7e.12xlarge has 2 GPUs, and the parallelism flags below assume it. Set
# H3_ALLOW_ANY_GPU=true plus H3_NUM_GPUS/H3_TP_SIZE/H3_ULYSSES to run anywhere
# else. DETECTED_GPUS is filled in by preflight and consumed when the systemd
# unit is written.
SUPPORTED_GPU_COUNTS="${SUPPORTED_GPU_COUNTS:-2}"
DETECTED_GPUS=0

log() {
  echo -e "[provision_h3_stack] $*"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log "This script must run as root (use: sudo $0)"
    exit 1
  fi
}

has_partition_weights() {
  compgen -G "${H3_MODEL_DIR}/${H3_PARTITION_DIR}/transformer/*.safetensors" >/dev/null
}

# The partition is ~144 GB; the rest covers the SGLang image, CUDA layers and
# generated MP4s. Weights already on disk do not need to be paid for again.
if has_partition_weights; then
  MIN_FREE_GB="${MIN_FREE_GB:-40}"
else
  MIN_FREE_GB="${MIN_FREE_GB:-190}"
fi

# shellcheck source=lib_docker_gpu.sh
source "${HERE}/lib_docker_gpu.sh"

########################################
# Step 0: preflight
#
# Fail loudly and immediately rather than 25 minutes and one 144 GB download
# into a boot that was never going to work. This instance class bills at
# roughly $13/hour.
########################################

preflight() {
  log "Preflight checks..."

  if ! command -v nvidia-smi >/dev/null 2>&1; then
    log "FATAL: nvidia-smi not found. H3 needs NVIDIA GPUs and drivers; the AWS"
    log "       Deep Learning OSS AMI provides both. Wrong AMI?"
    exit 1
  fi

  local gpu_count
  gpu_count="$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)"
  DETECTED_GPUS="${gpu_count}"
  log "  GPUs detected: ${gpu_count}"
  nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader | while read -r line; do
    log "    ${line}"
  done

  # sglang#34110: Ref2VA denoises to snow on compute capability 8.9 (L40S).
  # Fatal, not a warning -- this stack has no other partition to fall back to,
  # and the check costs nothing while the download it prevents costs ~$4.
  if nvidia-smi --query-gpu=compute_cap --format=csv,noheader | grep -q '^8\.9$'; then
    log "FATAL: compute-capability 8.9 GPU detected (L40S, i.e. g6e.12xlarge)."
    log "       Ref2VA produces snow/noise on EVERY run on that card --"
    log "       https://github.com/sgl-project/sglang/issues/34110 -- so this"
    log "       box would bill ~\$13/h to generate garbage. Relaunch on"
    log "       g7e.12xlarge (RTX PRO 6000 Blackwell, sm_120)."
    exit 1
  fi

  if ! grep -qw "${gpu_count}" <<<"${SUPPORTED_GPU_COUNTS}"; then
    if [[ "${H3_ALLOW_ANY_GPU:-false}" == "true" ]]; then
      log "  WARNING: ${gpu_count} GPUs is not a topology this script has a profile for"
      log "           (known: ${SUPPORTED_GPU_COUNTS}). Continuing because H3_ALLOW_ANY_GPU=true."
      log "           Set H3_NUM_GPUS/H3_TP_SIZE/H3_ULYSSES yourself."
    else
      log "FATAL: found ${gpu_count} GPUs; the supported topology is ${SUPPORTED_GPU_COUNTS}"
      log "       (g7e.12xlarge). The launch flags depend on this. Set"
      log "       H3_ALLOW_ANY_GPU=true and adjust H3_NUM_GPUS/H3_TP_SIZE/H3_ULYSSES"
      log "       if you really mean it."
      exit 1
    fi
  fi

  local ram_gb
  ram_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)"
  log "  Host RAM: ${ram_gb} GiB"
  if [[ "${ram_gb}" -lt "${MIN_RAM_GB}" ]]; then
    log "FATAL: only ${ram_gb} GiB of host RAM, need at least ${MIN_RAM_GB}."
    log "       Layerwise offload streams the model through host RAM; the"
    log "       reference recipe wants ~377 GiB. Use g7e.12xlarge (512 GiB)."
    exit 1
  fi

  local free_gb
  free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
  log "  Free space on /: ${free_gb} GB (need ${MIN_FREE_GB})"
  if [[ "${free_gb}" -lt "${MIN_FREE_GB}" ]]; then
    log "FATAL: only ${free_gb} GB free on /, need at least ${MIN_FREE_GB}."
    log "       The Ref2VA partition is ~144 GB. Raise root_volume_size (Terraform) and redeploy."
    exit 1
  fi

  log "Preflight OK."
}

########################################
# Step 1: system deps
########################################

install_system_deps() {
  log "Installing system deps..."
  apt-get update -y
  apt-get install -y curl ca-certificates jq python3-venv python3-pip nvtop htop
  log "System deps installed."
}

########################################
# Step 2: instance-store NVMe -> scratch + swap
#
# Installed as a systemd oneshot unit rather than done inline, because the
# instance store is BLANK after every stop/start cycle and cloud-init only runs
# on first boot. Without this the swap cushion silently disappears on the second
# morning -- exactly when a run would OOM.
########################################

install_nvme_scratch_unit() {
  log "Installing NVMe scratch/swap setup unit..."

  install -d -m 0755 /opt/llm-lab/bin

  cat > /opt/llm-lab/bin/setup-nvme-scratch.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

# Prepare the instance-store NVMe as scratch space and swap.
#
# Runs on EVERY boot: AWS instance storage is wiped whenever the instance is
# stopped, so the filesystem, the swapfile and the mount all have to be
# recreated. Everything here is expendable by design; nothing that must survive
# a stop is allowed to live on this device.

NVME_MOUNT="${NVME_MOUNT}"
NVME_SCRATCH="${NVME_SCRATCH}"
SWAP_GIB="${SWAP_GIB}"

log() { echo "[setup-nvme-scratch] \$*"; }

# Identify instance-store devices by model string. The root EBS volume reports
# "Amazon Elastic Block Store" and must never be touched here.
mapfile -t devices < <(
  lsblk -dno NAME,MODEL 2>/dev/null \
    | grep -i 'Instance Storage' \
    | awk '{print "/dev/"\$1}'
)

if [[ \${#devices[@]} -eq 0 ]]; then
  log "No instance-store NVMe found; skipping scratch/swap setup."
  log "H3 will run without the swap cushion - watch host RAM closely."
  exit 0
fi

device="\${devices[0]}"
log "Using \${device} for scratch and swap (\${#devices[@]} instance-store device(s) present)."

mkdir -p "\${NVME_MOUNT}"

# The Deep Learning AMI formats and mounts the instance store on its own (at
# /opt/dlami/nvme). ext4 refuses a second mount of the same device, so bind the
# existing mountpoint instead of failing the unit -- and with it the bootstrap.
existing_mount="\$(lsblk -no MOUNTPOINT "\${device}" | awk 'NF {print; exit}')"

if mountpoint -q "\${NVME_MOUNT}"; then
  log "\${NVME_MOUNT} is already a mountpoint; leaving it alone."
elif [[ -n "\${existing_mount}" ]]; then
  log "\${device} is already mounted at \${existing_mount}; bind-mounting it to \${NVME_MOUNT}."
  mount --bind "\${existing_mount}" "\${NVME_MOUNT}"
else
  if ! blkid "\${device}" >/dev/null 2>&1; then
    log "Formatting \${device} as ext4 (fresh after instance stop)..."
    mkfs.ext4 -F -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "\${device}"
  fi
  mount -o discard,noatime "\${device}" "\${NVME_MOUNT}"
fi

mkdir -p "\${NVME_SCRATCH}"
chmod 1777 "\${NVME_SCRATCH}"

# Swap cushion. Host RAM (384 GiB) sits only ~2% above what the reference
# layerwise-offload recipe needs, so a slow swap beats an OOM kill.
swapfile="\${NVME_MOUNT}/swapfile"
if [[ "\${SWAP_GIB}" -gt 0 ]] && ! swapon --show=NAME --noheadings | grep -qx "\${swapfile}"; then
  log "Creating \${SWAP_GIB} GiB swapfile at \${swapfile}..."
  rm -f "\${swapfile}"
  fallocate -l "\${SWAP_GIB}G" "\${swapfile}" || dd if=/dev/zero of="\${swapfile}" bs=1M count=\$((SWAP_GIB*1024)) status=none
  chmod 600 "\${swapfile}"
  mkswap "\${swapfile}" >/dev/null
  swapon "\${swapfile}"
  # Only spill under real pressure; this is a safety net, not a design target.
  sysctl -q -w vm.swappiness=10
  log "Swap active: \$(swapon --show=NAME,SIZE --noheadings | tr '\\n' ' ')"
fi

log "Scratch ready at \${NVME_SCRATCH}"
EOF
  chmod +x /opt/llm-lab/bin/setup-nvme-scratch.sh

  cat > /etc/systemd/system/llm-lab-nvme-scratch.service <<'EOF'
[Unit]
Description=Prepare instance-store NVMe as scratch space and swap
DefaultDependencies=no
After=local-fs.target
Before=docker.service sglang-h3.service
Wants=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/llm-lab/bin/setup-nvme-scratch.sh

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable llm-lab-nvme-scratch.service

  # Non-fatal on purpose: the swap cushion is insurance, not a dependency. On a
  # ~$13/h box, aborting the whole bootstrap here means paying for an instance
  # that never downloads the model.
  if systemctl start llm-lab-nvme-scratch.service; then
    log "NVMe scratch/swap unit installed and started."
  else
    log "WARNING: llm-lab-nvme-scratch.service failed; continuing WITHOUT the swap cushion."
    log "         H3 will run closer to the host-RAM ceiling - watch free RAM."
    log "         Diagnose with: journalctl -xeu llm-lab-nvme-scratch.service"
    systemctl status --no-pager --full llm-lab-nvme-scratch.service || true
    # Keep the path valid so the SGLang container's -v mount still resolves,
    # falling back to the root volume.
    mkdir -p "${NVME_SCRATCH}"
  fi
}

########################################
# Step 3: download the Ref2VA partition
#
# The HF repo is ~498 GB in total because it ships FOUR overlapping things:
# a self-contained FL2VA pipeline (144 GB), a self-contained Ref2VA pipeline
# (144 GB), and a parallel root-level diffusers layout (transformer,
# transformer_ref, text_encoder, vae ~210 GB). SGLang's --model-variant selects
# a partition subdirectory, so we fetch only Ref2VA plus the small root metadata
# and skip both FL2VA and the parallel diffusers layout entirely.
########################################

create_download_venv() {
  log "Creating download venv in ${H3_DIR}/.venv ..."
  mkdir -p "${H3_DIR}"
  if [[ ! -d "${H3_DIR}/.venv" ]]; then
    # Deliberately WITHOUT --system-site-packages: this venv only needs a modern
    # huggingface_hub, and the DLAMI's preinstalled copies would shadow it.
    python3 -m venv "${H3_DIR}/.venv"
  fi
  "${H3_DIR}/.venv/bin/pip" install --quiet --upgrade pip
  # [cli] pulls the `hf` entry point; Xet is the current high-throughput
  # transfer path (hf_transfer is deprecated and no longer a valid extra).
  "${H3_DIR}/.venv/bin/pip" install --quiet "huggingface_hub[cli,hf_xet]>=0.34"
  "${H3_DIR}/.venv/bin/hf" version || true
  log "Download venv ready."
}

download_model() {
  log "Downloading ${H3_REPO_ID} partition '${H3_PARTITION_DIR}' into ${H3_MODEL_DIR} ..."
  log "  ~144 GB. Expect ~3 min at 1000 MiB/s gp3 throughput, ~19 min at the 125 MiB/s default."
  mkdir -p "${H3_MODEL_DIR}"

  HF_XET_HIGH_PERFORMANCE=1 \
  H3_REPO_ID="${H3_REPO_ID}" \
  H3_MODEL_DIR="${H3_MODEL_DIR}" \
  H3_PARTITION_DIR="${H3_PARTITION_DIR}" \
  "${H3_DIR}/.venv/bin/python" - <<'PY'
import os
from huggingface_hub import snapshot_download

repo = os.environ["H3_REPO_ID"]
dest = os.environ["H3_MODEL_DIR"]
partition = os.environ["H3_PARTITION_DIR"]

patterns = ["*.json", "LICENSE", "README.md", f"{partition}/**"]

# local_dir gives a plain directory tree (no blobs/ + symlink cache), so the
# container mount is a single physical copy and `du` tells the truth.
path = snapshot_download(
    repo_id=repo,
    local_dir=dest,
    allow_patterns=patterns,
    max_workers=16,
)
print("Downloaded to:", path)
PY

  local dir="${H3_MODEL_DIR}/${H3_PARTITION_DIR}"
  # snapshot_download exits 0 on an allow_patterns typo that matched nothing,
  # and SGLang then reports a bare "no safetensors files found" at startup.
  if ! compgen -G "${dir}/transformer/*.safetensors" >/dev/null; then
    log "FATAL: no .safetensors in ${dir}/transformer after download."
    log "       The Ref2VA partition did not land. Check the log above for HTTP or disk errors."
    exit 1
  fi
  log "Checkpoint on disk: $(du -sh "${dir}" | cut -f1) at ${dir}"
}

# Reference assets must be readable INSIDE the container, so the UI and the
# server agree on one host directory bind-mounted at ${H3_MEDIA_MOUNT}.
create_media_dir() {
  log "Creating reference-media directory ${H3_MEDIA_DIR} ..."
  install -d -m 0755 -o "${H3_MEDIA_OWNER%%:*}" -g "${H3_MEDIA_OWNER##*:}" "${H3_MEDIA_DIR}"
}

########################################
# Step 4: pull the pinned SGLang image
#
# Pinned, never ':latest'. H3 landed in SGLang-Diffusion recently and CLI flags
# and offload behavior still move between releases; a lab you cannot reproduce
# next month is not a lab.
########################################

pull_image() {
  log "Pulling ${H3_SGLANG_IMAGE} (several GB, this takes a while)..."
  docker pull "${H3_SGLANG_IMAGE}"
  log "Image pulled."
}

########################################
# Step 5: systemd service running the SGLang server
########################################

install_systemd_service() {
  log "Installing ${H3_NAME}.service ..."
  install -d -m 0755 /opt/llm-lab/bin

  # Parallelism / offload knobs, overridable without editing the unit.
  #
  # There is no published RTX PRO 6000 profile: the SGLang cookbook covers H200,
  # H100, B200, RTX 5090 and RTX 4090. Ulysses sequence parallelism is only worth
  # paying for when there are more GPUs than the tensor-parallel degree, so it
  # stays at 1 here.
  #
  # The DiT is resident. H3's DiT is ~62 GB of weights; TP2 halves that to ~31 GB
  # per GPU, which a 96 GB card holds outright. Streaming it also blocks Cache-DiT
  # and CUDA-graph execution, which are worth far more than the PCIe traffic it
  # saves. The text encoder and VAE stay layerwise because they run once per
  # request, not once per denoise step, so streaming them is nearly free.
  #
  # H3_DIT_CPU_OFFLOAD=true is the one escape hatch if the DiT stops fitting - a
  # different card, or a longer clip whose activations eat the headroom. Write
  # whatever ends up working into the Terraform defaults so the next deploy does
  # not re-discover it at $13/hour.

  cat > /etc/llm-lab-h3.env <<EOF
# Serving the Ref2VA checkpoint partition: task "ref2va" with image, video and
# audio references. The FL2VA partition (t2va / first-and-last-frame) is not on
# disk and this stack does not download it.
H3_NUM_GPUS=${H3_NUM_GPUS:-${DETECTED_GPUS}}
H3_TP_SIZE=${H3_TP_SIZE:-2}
H3_ULYSSES=${H3_ULYSSES:-1}
H3_PERFORMANCE_MODE=${H3_PERFORMANCE_MODE:-memory}
H3_DIT_CPU_OFFLOAD=${H3_DIT_CPU_OFFLOAD:-false}
EOF

  cat > /opt/llm-lab/bin/run-sglang-h3.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source /etc/llm-lab-h3.env

# SGLang's own message for a missing partition is a bare "no safetensors files
# found"; name the command that actually fixes it instead.
if ! compgen -G "${H3_MODEL_DIR}/${H3_PARTITION_DIR}/transformer/*.safetensors" >/dev/null; then
  echo "FATAL: ${H3_PARTITION_DIR} weights are not on disk at ${H3_MODEL_DIR}/${H3_PARTITION_DIR}." >&2
  echo "       Download them with: sudo bash provision_h3_stack.sh" >&2
  exit 1
fi

dit_residency=(--dit-layerwise-offload false)
if [[ "\${H3_DIT_CPU_OFFLOAD}" == "true" ]]; then
  dit_residency=(--dit-cpu-offload true --dit-layerwise-offload true)
fi

exec docker run --rm --name ${H3_NAME} \\
  --gpus all \\
  --ipc=host \\
  --ulimit memlock=-1 --ulimit stack=67108864 \\
  -p ${H3_PORT}:${H3_PORT} \\
  -v ${H3_MODEL_DIR}:/models/MiniMax-H3 \\
  -v ${H3_MEDIA_DIR}:${H3_MEDIA_MOUNT}:ro \\
  -v ${NVME_SCRATCH}:/scratch \\
  -e HF_HOME=/scratch/hf \\
  -e TMPDIR=/scratch/tmp \\
  ${H3_SGLANG_IMAGE} \\
  sglang serve \\
    --model-path /models/MiniMax-H3 \\
    --model-variant ref2va \\
    --num-gpus "\${H3_NUM_GPUS}" \\
    --tp-size "\${H3_TP_SIZE}" \\
    --ulysses-degree "\${H3_ULYSSES}" \\
    --performance-mode "\${H3_PERFORMANCE_MODE}" \\
    --layerwise-offload-components text_encoder,vae \\
    "\${dit_residency[@]}" \\
    --enable-torch-compile false \\
    --host 0.0.0.0 \\
    --port ${H3_PORT}
EOF
  chmod +x /opt/llm-lab/bin/run-sglang-h3.sh

  cat > "/etc/systemd/system/${H3_NAME}.service" <<EOF
[Unit]
Description=MiniMax-H3 video+audio generation (SGLang-Diffusion)
After=docker.service network-online.target llm-lab-nvme-scratch.service
Requires=docker.service
Wants=llm-lab-nvme-scratch.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/docker rm -f ${H3_NAME}
ExecStart=/opt/llm-lab/bin/run-sglang-h3.sh
ExecStop=/usr/bin/docker stop ${H3_NAME}
# Loading 144 GB of weights through layerwise offload is slow by construction;
# a short startup timeout would kill a healthy server mid-load.
TimeoutStartSec=2400
TimeoutStopSec=120
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  # enable, so the server comes back by itself after every autostop/restart
  # cycle -- cloud-init does not run again.
  systemctl enable "${H3_NAME}"
  systemctl restart "${H3_NAME}"
  log "Service ${H3_NAME} installed and starting on port ${H3_PORT}."
}

########################################
# Step 6: wait for readiness
########################################

wait_for_ready() {
  # Weight loading over PCIe with offload legitimately takes many minutes.
  local max_wait=2400
  local waited=0
  local delay=15

  log "Waiting for SGLang to accept requests on :${H3_PORT} (up to $((max_wait / 60)) min)..."
  while (( waited < max_wait )); do
    # /v1/videos is a POST endpoint, so a healthy server answers GET with 405 or
    # 422, not 200. Anything other than curl's "000" (connection refused) means
    # the HTTP server is listening and past weight loading.
    local code
    code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
      "http://127.0.0.1:${H3_PORT}/v1/videos" 2>/dev/null || echo 000)"
    if [[ "${code}" =~ ^(200|405|422)$ ]]; then
      log "SGLang is up after ${waited}s (GET /v1/videos -> HTTP ${code})."
      return 0
    fi

    if ! systemctl is-active --quiet "${H3_NAME}"; then
      log "ERROR: ${H3_NAME} is not running. Last log lines:"
      journalctl -u "${H3_NAME}" -n 40 --no-pager || true
      return 1
    fi

    sleep "${delay}"
    waited=$((waited + delay))
    (( waited % 120 == 0 )) && log "  still loading weights (${waited}s)... free RAM: $(awk '/MemAvailable/ {printf "%d GiB", $2/1024/1024}' /proc/meminfo)"
  done

  log "WARNING: SGLang did not become ready within ${max_wait}s (non-fatal)."
  log "         Check: journalctl -fu ${H3_NAME}"
  return 0
}

########################################
# Main
########################################

main() {
  require_root

  log "Provisioning MiniMax-H3 (Ref2VA image/video/audio reference conditioning, image=${H3_SGLANG_IMAGE})"
  if has_partition_weights; then
    log "  Checkpoint already on disk; skipping the 144 GB download."
  fi

  preflight
  install_system_deps
  install_docker_if_needed
  configure_nvidia_toolkit_if_needed
  install_nvme_scratch_unit
  create_download_venv
  download_model
  create_media_dir
  pull_image
  install_systemd_service
  wait_for_ready

  log ""
  log "=== MiniMax-H3 stack ready ==="
  log "  Model dir : ${H3_MODEL_DIR}/${H3_PARTITION_DIR}"
  log "  Serving   : ref2va -> image / video / audio reference conditioning"
  log "  REST API  : http://<EIP>:${H3_PORT}/v1/videos"
  log "  Media dir : ${H3_MEDIA_DIR} -> ${H3_MEDIA_MOUNT} in the container (reference uploads)"
  log "  Scratch   : ${NVME_SCRATCH} (instance store, wiped on stop)"
  log ""
  log "  Status    : sudo systemctl status ${H3_NAME}"
  log "  Logs      : sudo journalctl -fu ${H3_NAME}"
  log "  Tuning    : sudo nano /etc/llm-lab-h3.env && sudo systemctl restart ${H3_NAME}"
  log ""
  log "  Reminder: this box bills at roughly \$13/hour. Generation is minutes per"
  log "  clip, so a single 5s video costs a couple of dollars. The autostop timers"
  log "  are there for a reason - leave them on."
}

main "$@"
