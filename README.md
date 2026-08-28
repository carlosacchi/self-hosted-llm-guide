# Self-Hosted AI Lab on AWS

Terraform + GitHub Actions to provision a **single or multi-GPU EC2 VM** across **5 supported AWS regions**. The VM is launched by an **Auto Scaling group that hunts for GPU capacity** across every compatible instance type and availability zone, and the application stack deploys **automatically via cloud-init on first boot** — no SSH key, no manual steps — with a **service portal on port 80** giving you one clickable index of everything running.

Pick one **workload**:

| Workload | Hardware | What runs |
|---|---|---|
| `llm-lab` *(default)* | g5 family, 1–4× A10G 24 GB | Ollama + Open WebUI, multi-engine TTS, VibeVoice, optional ASR |
| `speech-lab` | g5 family | TTS + VibeVoice + ASR, no LLM |
| `minimax-h3` | **g6e.12xlarge (4× L40S 48 GB) or g7e.12xlarge (2× RTX PRO 6000 96 GB)** | [MiniMax-H3](https://github.com/MiniMax-AI/MiniMax-H3) text → video **with synchronized audio**, alone on the box |

The `llm-lab` default is sized to fit a single 24 GB GPU (`g5.xlarge`): a **landing portal**, **Ollama + Open WebUI** (LLM chat), a **Gradio multi-engine TTS UI**, and **VibeVoice-1.5B multi-speaker** (podcast) TTS.

`minimax-h3` is a different animal: a 33B flow-matching diffusion transformer that needs every GPU and most of the host RAM, on an instance that bills at **~$13/hour**. It is mutually exclusive with every other stack, and Terraform refuses to plan a deployment that mixes them. Read [MiniMax-H3](#minimax-h3--video--audio-generation) before running it.

> **Cost guardrails are on by default** for every workload: a hard TTL stops the VM 4 hours after boot, an idle probe stops it after 30 minutes of no GPU work and no traffic, and a nightly schedule scales the group to zero as a backstop. See [Cost guardrails](#cost-guardrails).

---

## What gets deployed

| Component | Technology | Port | Default |
|---|---|---|---|
| Service portal | [nginx](https://nginx.org) static landing page (links to every service) | 80 | ✅ on |
| LLM inference | [Ollama](https://ollama.com) (Docker, GPU) | 11434 | ✅ on |
| LLM chat UI | [Open WebUI](https://github.com/open-webui/open-webui) (Docker) | 3000 | ✅ on |
| TTS engines | Kokoro · XTTS-v2 · Piper (Python venv, GPU) | — | ✅ on |
| TTS UI | [Gradio](https://www.gradio.app) multi-engine app | 7860 | ✅ on |
| VibeVoice multi-speaker | [VibeVoice-1.5B (community fork)](https://github.com/vibevoice-community/VibeVoice) (Python venv, GPU) | 7861 | ✅ on |
| Monitoring | [Netdata](https://www.netdata.cloud) real-time dashboard (GPU, CPU, RAM, disk) | 19999 | ✅ on |
| VibeVoice Realtime | [Microsoft VibeVoice-Realtime-0.5B](https://github.com/microsoft/VibeVoice) (single-speaker streaming) | 7862 | ⛔ disabled |
| VibeVoice 7B | [VibeVoice-7B (community fork)](https://github.com/vibevoice-community/VibeVoice) multi-speaker | 7863 | ⛔ disabled |
| Speech-to-text | Whisper-large-v3 / Granite-8B (Python venv, GPU) | 7864 | ⛔ disabled |
| **MiniMax-H3 video** | [SGLang-Diffusion](https://docs.sglang.io/cookbook/diffusion/MiniMax/MiniMax-H3) serving [MiniMax-H3](https://github.com/MiniMax-AI/MiniMax-H3) (Docker, 4 GPUs) | 30010 | ⛔ workload `minimax-h3` only |
| MiniMax-H3 UI | Gradio wrapper around the async video API | 7865 | ⛔ workload `minimax-h3` only |

**Default Ollama models** (pulled on first boot): `llama3.2:3b` (small generalist), `qwen3.5:27b` (27B MoE all-rounder, 256K context), `qwen2.5-coder:32b` (code specialist). All three live on disk; Ollama loads them into VRAM lazily and swaps them on demand, so the two large coders never need to fit at the same time. Override via the first argument to `provision_llm_stack.sh`.

### TTS engines

| Engine | Voices | GPU | Best for |
|---|---|---|---|
| **Kokoro** | 9 presets (EN US/UK, IT, FR, ES, PT, JA) | Optional | Fast, low-latency |
| **XTTS-v2** | 21 presets + voice cloning from audio sample | Required for quality | Multilingual, expressive |
| **Piper** | EN US + IT (more downloadable) | No (CPU) | Ultra-light, always available |
| **VibeVoice multi-speaker** | Up to 4 speakers, podcast/turn-taking (1.5B, own port 7861) | Required | Long-form, expressive, podcast-style |
| **VibeVoice Realtime** *(disabled)* | Single-speaker streaming synthesis (Realtime-0.5B, port 7862) | Required | Low-latency, real-time, voice presets |

---

## Infrastructure

Terraform under [`infra/`](infra/) provisions:

- **Networking**: VPC (`10.42.0.0/16`), **one public `/24` subnet per capable availability zone**, internet gateway, route table.
- **Compute**: a **launch template** on the AWS Deep Learning AMI (Ubuntu 22.04, NVIDIA drivers pre-installed — it lists G6e among its supported families, so no AMI change was needed for L40S), plus an **Auto Scaling group** (`min=0`, `max=1`) that finds a GPU for it. An Elastic IP is allocated up front and claimed by the instance on boot.
- **Provisioning**: private encrypted S3 bucket holding the bootstrap scripts; IAM instance profile granting the VM read-only access to that bucket and permission to associate its own Elastic IP.
- **Access control**: security group allowing inbound traffic **only from your IP** (`ipv4_allowed`):
  - `22/tcp` — SSH (optional, only if `key_pair_name` is set)
  - `80/tcp` — Service portal (nginx landing page)
  - `3000/tcp` — Open WebUI
  - `7860/tcp` — Gradio TTS UI
  - `7861/tcp` — VibeVoice multi-speaker TTS UI (1.5B podcast)
  - `7862/tcp` — VibeVoice Realtime TTS UI (single speaker, disabled by default)
  - `7863/tcp` — VibeVoice 7B multi-speaker TTS UI (disabled by default)
  - `7864/tcp` — Speech-to-text UI (disabled by default)
  - `7865/tcp` — MiniMax-H3 video UI (`minimax-h3` workload only)
  - `8000/tcp` — FastAPI (reserved)
  - `11434/tcp` — Ollama REST API
  - `19999/tcp` — Netdata monitoring dashboard
  - `30010/tcp` — MiniMax-H3 SGLang REST API (`minimax-h3` workload only)
- **Ops guardrails**: three independent autostop layers (see below).

### Capacity hunting, not autoscaling

`g6e.12xlarge` and `g7e.12xlarge` pools are **thin per availability zone**, and there is no AWS API that tells you whether a pool has capacity before you try to launch into it. A single `aws_instance` gets exactly one attempt at exactly one pool:

```
aws_instance -> one type, one AZ -> InsufficientInstanceCapacity -> done
```

So the instance is owned by an Auto Scaling group instead. It is not there to scale anything — `min=0`, `max=1`, `desired=1` — it is there to *search*:

```
                    desired = 1
                         |
                 MixedInstancesPolicy
                         |
          +--------------+--------------+
     instance types                    AZs
          |                             |
    g6e.12xlarge  --+           eu-central-1a
          |          +- prioritized     1b
    g7e.12xlarge  --+                   1c
          |                             |
          +--------------+--------------+
                         v
                  first pool that
                   has capacity
```

`on_demand_allocation_strategy = "prioritized"` walks the instance-type overrides in declared order and moves to the next when a pool cannot satisfy the launch. The AZ list comes from `aws_ec2_instance_type_offerings`, so the group is only ever pointed at zones that genuinely offer one of the requested types.

Three consequences worth knowing:

- **`terraform apply` does not wait for capacity** (`wait_for_capacity_timeout = "0"`). It returns as soon as the group exists, and the group keeps retrying in the background. Failing the apply would only destroy the thing doing the retrying. The workflow prints the scaling activities at the end of the job; locally, use the `capacity_hunt_command` output.
- **There is no `instance_id` output any more** — the instance does not exist at plan time. Use the `instance_id_command` output to resolve it.
- **The group runs with `HealthCheck`, `ReplaceUnhealthy` and `AZRebalance` suspended.** This is load-bearing, not incidental — see below.

### Cost guardrails

A g5.xlarge costs ~$1.20/h, so forgetting it running overnight is a $20 mistake. A **g6e.12xlarge costs ~$13.12/h in eu-central-1** — booting at 09:00 and relying only on a 01:00 nightly schedule burns **~$210 in a single day**. So three independent layers shut the VM down:

| Layer | Where | Action | Default | Tune with |
|---|---|---|---|---|
| **Hard TTL** | systemd timer, `OnBootSec` | **stop** | stop **4 h** after boot | `auto_stop_hours` workflow input (`0` disables) |
| **Idle stop** | systemd timer, probed every 5 min | **stop** | stop after **30 min** with GPU < 5 % and no connections on the service ports | `idle_stop_minutes` Terraform var |
| **Nightly** | EventBridge Scheduler → ASG `desired=0` | **terminate** | **01:00 Europe/Amsterdam** | `infra/aws/operations.tf` |

The first two layers call `systemctl poweroff`. The launch template pins `instance_initiated_shutdown_behavior = "stop"`, so an OS shutdown **stops** the instance rather than terminating it — the root volume and any cached models survive untouched, and no extra IAM permissions are needed.

**That only works because the ASG has `HealthCheck` and `ReplaceUnhealthy` suspended.** A default Auto Scaling group fails a stopped member's EC2 health check, terminates it, and launches a replacement — which would turn the cheapest cost guardrail into a $13/h billing loop. `AZRebalance` is suspended for a related reason: with subnets in several zones the group would otherwise be free to terminate a healthy instance just to even out the distribution of a one-instance group. If you ever un-suspend those processes, the two in-VM layers must be rewritten to call `aws autoscaling set-desired-capacity --desired-capacity 0` instead of `poweroff`.

The **nightly layer is different in kind: it terminates.** That is not a preference — EventBridge can only call `StopInstances` with an explicit instance ID, and under an ASG there is no instance ID at plan time. `SetDesiredCapacity` works on the group name, which Terraform does know. The trade is a model re-download the next morning (~30–45 min of instance time for H3) instead of ~$210 of runtime.

The idle probe deliberately treats these as *busy*, so it never stops a machine that is still working:

- cloud-init has not finished (first boot downloads up to 144 GB with the GPU idle)
- a service unit is still `activating` (SGLang spends many minutes loading H3's weights at ~0 % GPU)
- `/run/llm-lab-busy` exists — `sudo touch` it to pin the box up for a long unattended job

Netdata (19999) and the static portal (80) are **excluded** from the activity check: a dashboard left open in a background tab is not work, and counting it would keep the instance alive all night.

```bash
systemctl list-timers 'llm-lab-*'      # what is armed
journalctl -t llm-lab-idle             # why it did or did not stop
sudo nano /etc/llm-lab/autostop.env    # retune without redeploying
```

### "Autostop" is not "no-cost"

The first two layers **stop** the instance; only the nightly one destroys it. While stopped you still pay for EBS (a 500 GiB gp3 root volume for H3 is ~$50/month on its own) and the Elastic IP. Run `destroy` when you want zero ongoing charges — but note that destroying an H3 deployment throws away the 144 GB checkpoint, which then has to be re-downloaded next time.

Restarting after a TTL/idle stop keeps the checkpoint:

```bash
ASG=$(terraform -chdir=infra output -raw asg_name)
ID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
       --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ec2 start-instances --instance-ids "$ID"
```

Scaling the group to zero does not — it terminates:

```bash
aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" --desired-capacity 0
```

The durable fix is a snapshot-backed `/opt/models` volume so the weights outlive the instance. Not implemented yet.

---

## Supported regions

| Region | Location | Notes |
|---|---|---|
| `eu-central-1` | Frankfurt, DE | Default. H3-capable |
| `eu-west-1` | Ireland, IE | Cheapest EU option for g5. **No G6e/G7e** |
| `eu-north-1` | Stockholm, SE | Good EU alternative. H3-capable |
| `eu-south-2` | Spain, ES | H3-capable |
| `us-east-2` | Ohio, US | Typically lowest overall price |

> `eu-west-1` is typically 10–15 % cheaper than `eu-central-1` for g5 on-demand. `us-east-2` is usually cheapest.

**For the `minimax-h3` workload the choice is narrower.** G6e/G7e `.12xlarge` are offered in three EU regions — Frankfurt, Stockholm and Spain — and while `g6e.12xlarge` exists in `us-east-2`, the *Running On-Demand G and VT instances* quota there is commonly 0 on accounts that have never requested it. Terraform therefore restricts `enable_h3` to `eu-central-1`, `eu-north-1` and `eu-south-2`.

An Auto Scaling group is a **regional** resource: it waterfalls across instance types and AZs, but not across Frankfurt → Stockholm → Spain. Covering all three means three deployments — the Terraform state key is already scoped per region — and choosing which one to bring to `desired=1`.

---

## Supported instance types

### Single GPU — 1× NVIDIA A10G, 24 GB GPU RAM

| Instance | vCPU | RAM | NVMe | Network |
|---|---|---|---|---|
| `g5.xlarge` | 4 | 16 GiB | 1×250 GB | Up to 10 Gbps |
| `g5.2xlarge` | 8 | 32 GiB | 1×450 GB | Up to 10 Gbps |
| `g5.4xlarge` | 16 | 64 GiB | 1×600 GB | Up to 25 Gbps |
| `g5.8xlarge` | 32 | 128 GiB | 1×900 GB | 25 Gbps |

### Multi-GPU — 4× NVIDIA A10G, 96 GB total GPU RAM

| Instance | vCPU | RAM | NVMe | Network |
|---|---|---|---|---|
| `g5.12xlarge` | 48 | 192 GiB | 1×3800 GB | 40 Gbps |
| `g5.24xlarge` | 96 | 384 GiB | 1×3800 GB | 50 Gbps |

### Video generation — H3-capable shapes

Required by, and only usable with, the `minimax-h3` workload. The Auto Scaling group treats these two as interchangeable and takes whichever has capacity.

| Instance | GPUs | Total VRAM | vCPU | RAM | Network | eu-central-1 on-demand |
|---|---|---|---|---|---|---|
| `g6e.12xlarge` | 4× NVIDIA L40S 48 GB | 192 GB | 48 | 384 GiB | 100 Gbps | **~$13.12/h** |
| `g7e.12xlarge` | 2× NVIDIA RTX PRO 6000 Blackwell 96 GB | 192 GB | — | 512 GiB | — | — |

Note what those numbers mean in practice: 192 GB of total VRAM is **not** enough to hold H3 resident (published datacenter recipes peak at 50–94 GB per GPU), so layerwise offload to host RAM is mandatory on either shape — which makes host RAM the binding constraint, not VRAM. L40S also has **no NVLink**, so tensor/sequence parallelism crosses PCIe.

The two shapes need different parallelism flags (4 GPUs wants `--ulysses-degree 2`, 2 GPUs wants `1`), so `provision_h3_stack.sh` derives them from `nvidia-smi` at boot rather than from Terraform — the instance type is not known until the ASG picks one. **`g7e.12xlarge` is untested with H3 here**; it is in the waterfall because 96 GB per card removes a lot of parallelism complexity, not because it has been measured.

---

## Repository layout

```
infra/
  network.tf        VPC, one subnet per capable AZ, internet gateway, routing
  compute.tf        Security group, launch template, capacity-hunting ASG, Elastic IP
  provisioning.tf   S3 scripts bucket, IAM role/instance profile
  operations.tf     Nightly scale-to-zero EventBridge schedule
  variables.tf      All tunable inputs
  locals.tf         Instance-type waterfall, computed values, shared tags
  outputs.tf        ASG name, public IP, portal + app URLs, lifecycle commands

scripts/
  user-data.sh                  Cloud-init entry point (claims the EIP, downloads scripts from S3)
  bootstrap_all.sh              Orchestrator: gates every stack on an ENABLE_* flag
  lib_docker_gpu.sh             Shared Docker + NVIDIA Container Toolkit setup (sourced, no side effects)
  provision_monitoring_stack.sh Netdata agent + real-time GPU/CPU/RAM/disk dashboard (port 19999)
  provision_llm_stack.sh        Ollama + Open WebUI via docker compose
  provision_tts_stack.sh        Python venv + Kokoro + XTTS-v2 + Piper + Gradio app
  provision_vibevoice_tts_stack.sh  Python venv + VibeVoice-1.5B (community fork) multi-speaker podcast UI (port 7861)
  provision_vibevoice_stack.sh  Python venv + VibeVoice-Realtime-0.5B + web UI (disabled by default, port 7862)
  provision_asr_stack.sh        Python venv + Whisper/Granite speech-to-text UI (port 7864)
  provision_h3_stack.sh         NVMe scratch+swap, Ref2VA checkpoint, pinned SGLang container (port 30010)
  provision_h3_ui_stack.sh      Gradio wrapper around the async video API: image reference in, MP4 out (port 7865)
  provision_autostop.sh         Hard-TTL and idle-stop systemd timers (all workloads)
  provision_landing_stack.sh    nginx + service portal listing the stacks that were installed (port 80)

.github/workflows/
  manage-llm-vm.yml       Manual workflow: apply / destroy
```

---

## Prerequisites

1. **AWS credentials** with permissions for EC2, VPC, Auto Scaling, IAM, S3, EventBridge Scheduler.
2. **S3 bucket** for Terraform remote state (one per AWS account is enough). State is keyed per deploy region (`llm-gpu/<region>/terraform.tfstate`) so each region is independent and never collides. The bucket itself lives in a single region regardless of where you deploy the VM — set `TF_STATE_REGION` if it is not in `eu-central-1`.
3. **Your public IPv4 address** for the `ipv4_allowed` parameter.
4. **EC2 key pair** *(optional)* — only needed for SSH access. Leave `key_pair_name` blank if you don't need it.

---

## Quickstart — GitHub Actions

### 1. Add repository secrets

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform state |
| `TF_STATE_REGION` | *(optional)* Region of the state bucket — defaults to `eu-central-1`. Set this if your state bucket lives elsewhere. |

### 2. Run the workflow

Go to **Actions → Manage GPU VM → Run workflow** and fill in:

| Input | Description | Default |
|---|---|---|
| `action` | `apply` to create, `destroy` to tear down | `apply` |
| `instance_type` | **Preferred** instance size (see tables above). The ASG falls back to the other H3-capable type if this pool is empty | `g5.xlarge` |
| `aws_region` | Target region (see table above) | `eu-central-1` |
| `availability_zone` | Optional AZ **pin**. Leave blank so the ASG can search every capable zone | *(blank)* |
| `key_pair_name` | EC2 key pair name for SSH — leave blank to skip | *(blank)* |
| `ipv4_allowed` | Your public IPv4 (e.g. `203.0.113.25`) | *(required)* |
| `workload` | `llm-lab`, `speech-lab`, or `minimax-h3` | `llm-lab` |
| `vibevoice` | `none` / `1.5b` / `realtime` / `7b` — ignored for `minimax-h3` | `1.5b` |
| `asr` | `none` / `whisper-large-v3` / `granite-8b` — ignored for `minimax-h3` | `none` |
| `auto_stop_hours` | Hard TTL from boot; `0` disables it | `4` |

> `workflow_dispatch` caps a workflow at **10 inputs** and this list uses all 10. That is why `workload` is a single picker rather than separate `enable_llm` / `enable_tts` booleans — the stacks were never freely combinable anyway (they compete for the same VRAM, and H3 is exclusive by construction). Root volume size and throughput are derived from `workload`; override them with `TF_VAR_root_volume_size` / `TF_VAR_root_volume_throughput`. IOPS is derived from throughput (gp3 caps the ratio at 0.25 MiB/s per IOPS, so 1000 MiB/s forces 4000 IOPS); override with `TF_VAR_root_volume_iops`. The instance-type waterfall is derived too; override it with `TF_VAR_instance_type_fallbacks`.

Terraform outputs (Elastic IP, app URLs, the instance-type waterfall, the H3 curl example, and the active autostop summary) are printed at the end of the job, followed by the ASG's scaling activities — that last table is where you find out whether a GPU was actually found, and why not.

Note that **apply does not wait for capacity**. If the group is still hunting when the job ends, re-run the report or use the `capacity_hunt_command` output; there is nothing to re-apply.

---

## Quickstart — local Terraform

```bash
terraform -chdir=infra init \
  -backend-config="bucket=<your-tfstate-bucket>" \
  -backend-config="key=llm-gpu/eu-west-1/terraform.tfstate" \
  -backend-config="region=eu-central-1"

terraform -chdir=infra apply -auto-approve \
  -var='aws_region=eu-west-1' \
  -var='instance_type=g5.xlarge' \
  -var='ipv4_allowed=203.0.113.25'
```

For the video workload, every other stack has to be off and the volume has to be big and fast:

```bash
terraform -chdir=infra apply -auto-approve \
  -var='aws_region=eu-central-1' \
  -var='instance_type=g6e.12xlarge' \
  -var='ipv4_allowed=203.0.113.25' \
  -var='enable_h3=true' \
  -var='enable_llm=false' -var='enable_tts=false' -var='enable_vibevoice_15b=false' \
  -var='root_volume_size=500' -var='root_volume_throughput=1000' \
  -var='auto_stop_hours=3'
```

Get any of that wrong and Terraform fails during `plan` with an explanation, rather than 20 minutes into a $13/h boot.

`apply` returns as soon as the Auto Scaling group exists — it does not block waiting for a GPU. Watch the hunt with:

```bash
eval "$(terraform -chdir=infra output -raw capacity_hunt_command)"
```

`Successful` means a GPU was found; repeated `Failed` rows with `InsufficientInstanceCapacity` mean every pool in the waterfall is currently empty and the group is still retrying. Nothing needs re-applying either way.

---

## Provisioning pipeline

Once Terraform creates the instance, AWS runs `scripts/user-data.sh` as root via cloud-init:

```
cloud-init (user-data.sh)
  └── associates the Elastic IP with itself (the ASG picked the AZ, not Terraform)
  └── downloads scripts from S3 via IAM instance role
  └── bootstrap_all.sh
        ├── [1/7] provision_monitoring_stack.sh   (ENABLE_MONITORING)
        │     ├── installs Netdata (stable, no telemetry)
        │     ├── binds dashboard to 0.0.0.0:19999
        │     └── auto-collects GPU (nvidia-smi), CPU, RAM, disk, network
        ├── [2/7] provision_llm_stack.sh          (ENABLE_LLM)
        │     ├── installs Docker + NVIDIA Container Toolkit
        │     ├── writes docker-compose.yml (Ollama + Open WebUI)
        │     └── pulls default models (llama3.2:3b, qwen3.5:27b, qwen2.5-coder:32b)
        ├── [3/7] provision_tts_stack.sh          (ENABLE_TTS)
        │     ├── installs system deps (ffmpeg, espeak-ng, python3-venv)
        │     ├── creates Python venv (reuses GPU PyTorch from DLAMI)
        │     ├── installs Kokoro, XTTS-v2 (coqui-tts), Piper
        │     ├── downloads Piper voice models (EN US + IT)
        │     ├── writes Gradio app (app.py) with 3 TTS engine tabs
        │     └── registers tts-app.service (systemd, port 7860)
        ├── [4/7] provision_vibevoice_tts_stack.sh   (ENABLE_VIBEVOICE_15B, VVT_PORT=7861)
        │     ├── clones github.com/vibevoice-community/VibeVoice (official TTS code was removed by Microsoft)
        │     ├── creates an isolated Python venv (reuses GPU PyTorch from DLAMI)
        │     ├── installs the community VibeVoice package (editable)
        │     ├── patches the Gradio demo to bind 0.0.0.0 on port 7861 (no public share tunnel)
        │     ├── pre-downloads vibevoice/VibeVoice-1.5B (up to 4 speakers)
        │     └── registers vibevoice-tts.service (systemd, port 7861)
        ├── [5/7] provision_h3_stack.sh + provision_h3_ui_stack.sh   (ENABLE_H3, exclusive)
        │     ├── preflight: 2 or 4 GPUs, >=350 GiB RAM, >=220 GB free — fail fast, this box is expensive
        │     ├── derives the parallelism flags from the GPU count the ASG actually landed on
        │     ├── installs llm-lab-nvme-scratch.service (NVMe scratch + 256 GiB swap, re-run every boot)
        │     ├── downloads the requested partition(s) (~144 GB each) into /opt/models on EBS
        │     ├── pulls the PINNED SGLang image (never :latest)
        │     ├── registers sglang-h3.service (systemd, port 30010)
        │     └── registers h3-ui.service (Gradio wrapper, port 7865)
        ├── [6/7] provision_autostop.sh      (ALWAYS, every workload)
        │     ├── llm-lab-ttl.timer   → poweroff N hours after boot
        │     └── llm-lab-idle.timer  → poweroff after N minutes idle
        └── [7/7] provision_landing_stack.sh
              ├── installs nginx
              ├── writes a portal page listing the stacks that were actually installed
              └── serves it on port 80 (links built client-side from the host)
```

Every stack is gated by an `ENABLE_*` environment variable that Terraform renders into cloud-init, so `bootstrap_all.sh` installs exactly what the `workload` picker asked for. `ENABLE_H3` is enforced as **exclusive**: combining it with any other GPU stack is a hard error in both `terraform plan` and `bootstrap_all.sh`.

**Logs on the VM**: `/var/log/llm-lab-bootstrap.log`

Provisioning takes **15–25 minutes** on a `g5.xlarge` (large Python packages + model downloads), and **30–45 minutes** for `minimax-h3` (the 144 GB checkpoint dominates — which is why that workload provisions a 500 GiB gp3 volume at 1000 MiB/s instead of the 125 MiB/s default). The apps are not reachable until it completes.

---

## Accessing the apps

| App | URL | Notes |
|---|---|---|
| **Service portal** | `http://<EIP>/` | **Start here** — landing page linking every running service |
| Monitoring | `http://<EIP>:19999` | Netdata: real-time GPU, GPU memory, CPU, RAM, disk |
| Open WebUI | `http://<EIP>:3000` | LLM chat, model management |
| Gradio TTS UI | `http://<EIP>:7860` | 3-tab TTS: Kokoro / XTTS-v2 / Piper |
| VibeVoice TTS UI | `http://<EIP>:7861` | Multi-speaker (1.5B), long-form conversational synthesis |
| MiniMax-H3 UI | `http://<EIP>:7865` | Image reference → video + audio (`minimax-h3` workload) |
| MiniMax-H3 API | `http://<EIP>:30010` | Async video API — see below |
| Ollama API | `http://<EIP>:11434` | REST API, restricted to your IP — **no auth, anyone on that IP can use the GPU** |

Query the Ollama API directly (from your allowed IP):
```bash
curl http://<EIP>:11434/api/tags
curl http://<EIP>:11434/api/generate -d '{"model":"llama3.2:3b","prompt":"Hello"}'
```

Prefer not to expose it? Keep the `11434` ingress rule out of the security group and use an SSH tunnel instead (requires `key_pair_name`):
```bash
ssh -L 11434:localhost:11434 ubuntu@<EIP>
curl http://localhost:11434/api/tags
```

---

## MiniMax-H3 — image reference → video + audio

[MiniMax-H3](https://github.com/MiniMax-AI/MiniMax-H3) is a 33B dense flow-matching diffusion transformer that denoises **joint video and audio latents**: one request returns an H.264 MP4 (24 fps) with a synchronized stereo AAC track (32 kHz), 4–15 seconds long, up to 2K. It is served here by [SGLang-Diffusion](https://docs.sglang.io/cookbook/diffusion/MiniMax/MiniMax-H3).

This stack serves the **Ref2VA** checkpoint partition only — `task: "ref2va"`, driven by an **image reference** plus a prompt.

```
                    Internet
                       │  your IP /32 only
                  Security Group
                       │
           EC2 g7e.12xlarge · 2× RTX PRO 6000 96 GB · 512 GiB RAM
                       │
        ┌──────────────┼──────────────┬───────────────┐
     Netdata      Gradio UI       SGLang          NVMe scratch
      :19999        :7865          :30010          + 256 GiB swap
                       └──────────────┤
                                 MiniMax-H3 (Ref2VA)
                                      │
                                  /v1/videos → MP4 + audio
```

### Set expectations before you spend

| | |
|---|---|
| Instance cost | **~$13.12/h** on-demand, eu-central-1 |
| First-boot provisioning | ~30–45 min (144 GB checkpoint + multi-GB container) ≈ **$7–10 before the first video** |
| Generation time | **~8–15 min for a 5 s clip** ⇒ roughly **$2–3 per video** |
| Restart from stopped | Weights re-read from EBS, plus offload setup — minutes, not seconds |

The generation estimate is extrapolated, not measured on this exact box: the closest published datapoint is 559 s (~9.3 min) for a 1344×768 / 124-frame / 50-step clip on 2× RTX 5090 with layerwise offload. Measure it on your first run and replace this paragraph.

### Why the instance type is pinned to g7e.12xlarge

H3 splits its capabilities across two checkpoint partitions and one SGLang server can only mount one of them. This lab mounts `ref2va`:

| Partition | Tasks served | Conditioning | Downloaded here |
|---|---|---|---|
| `Ref2VA` | `ref2va` | image, video and audio references | ✅ ~144 GB |
| `FL2VA` | `t2va`, `fl2va` | none, or a first frame, a last frame, or both | ❌ |

> On compute capability 8.9 — the 4× L40S `g6e.12xlarge` shape — `ref2va` produces snow/noise on **every** run, while `fl2va` is healthy on the identical box ([sgl-project/sglang#34110](https://github.com/sgl-project/sglang/issues/34110)). Since `fl2va` is not the mode this lab wants, `g6e.12xlarge` is excluded from `h3_capable_instance_types` and `terraform plan` rejects it. The RTX PRO 6000 Blackwell (`g7e.12xlarge`, sm_120) is unaffected. The provisioner repeats the check at boot and aborts **before** the 144 GB download if it somehow lands on an sm_89 card.

The Hugging Face repo is **~498 GB in total** because it ships four overlapping things: a self-contained FL2VA pipeline (144 GB), a self-contained Ref2VA pipeline (144 GB), and a parallel root-level diffusers layout (~210 GB). This stack fetches **only the Ref2VA partition plus the small root metadata**, so `root_volume_size >= 300` is enough — enforced as a `terraform plan` precondition.

### Reference images

`conditions[].uri` must be a `file://` path the **SGLang container** can read, so the provisioner bind-mounts a host directory into it:

| Host | Container | Written by |
|---|---|---|
| `/opt/h3/media` | `/data/minimax-h3` (read-only) | the Gradio UI, on every upload |

Drop files there yourself to reference them from `curl`. The image is *semantic reference material*, not a pixel-aligned first frame — H3 may recompose or crop it. Condition order is semantic too: the prompt refers to the first image as `<Picture 1>`, and the UI prepends a default sentence containing that tag if your prompt omits it.

### Using the API

The API is **asynchronous — three calls**, not one:

```bash
# 0. make the reference visible to the container
sudo cp subject.png /opt/h3/media/

# 1. submit
ID=$(curl -sS http://<EIP>:30010/v1/videos \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "MiniMaxAI/MiniMax-H3",
    "task": "ref2va",
    "prompt": "Use <Picture 1> as the visual subject; slow dolly shot at night, humming servers",
    "seconds": 5,
    "conditions": [
      {"type": "image", "uri": "file:///data/minimax-h3/subject.png", "role": "reference"}
    ],
    "target": {"short_edge": 768, "aspect_ratio": "16:9", "duration_seconds": 5},
    "num_inference_steps": 50,
    "flow_shift": 12.0,
    "audio_flow_shift": 3.0,
    "seed": 3101
  }' | jq -r '.id')

# 2. poll until status is completed (this takes minutes)
watch -n 10 "curl -sS http://<EIP>:30010/v1/videos/$ID | jq '.status'"

# 3. download
curl -sS -o out.mp4 "http://<EIP>:30010/v1/videos/$ID/content"
```

The Gradio UI on `:7865` does all of that for you and shows a progress bar.

### Storage layout

| Path | Backing | Survives a stop? | Holds |
|---|---|---|---|
| `/opt/models/MiniMax-H3` | root gp3 EBS | ✅ yes | the ~144 GB Ref2VA checkpoint |
| `/opt/h3/media` | root gp3 EBS | ✅ yes | uploaded reference images |
| `/mnt/nvme/scratch` | instance store | ❌ wiped | temp files, HF metadata, intermediates |
| `/mnt/nvme/swapfile` | instance store | ❌ recreated on boot | 256 GiB swap cushion |

Instance storage is wiped on every stop, and the autostop guardrails stop this VM several times a day — so the checkpoint lives on EBS and only expendable data goes on NVMe. A `llm-lab-nvme-scratch.service` oneshot re-creates the filesystem, the mount and the swapfile on **every** boot, because cloud-init only runs once.

The swap exists for a specific reason: layerwise offload streams the model through host RAM, and the reference recipe wants **~377 GiB**. Swapping is slow; an OOM kill loses the whole run.

### Tuning when it OOMs

There is no published RTX PRO 6000 profile — the SGLang cookbook covers H200, H100, B200, RTX 5090 and RTX 4090. The DiT is kept resident here: it is ~62 GB of weights, TP2 halves that to ~31 GB per GPU, and a 96 GB card holds it outright. Only the text encoder and the VAE are streamed, because they run once per request rather than once per denoise step.

If the DiT stops fitting — a different card, or a longer clip whose activations eat the headroom — edit `/etc/llm-lab-h3.env`:

1. `H3_PERFORMANCE_MODE=memory` — already the default; confirm it was not overridden
2. `H3_DIT_CPU_OFFLOAD=true` — full CPU offload of the transformer, much slower

Then `sudo systemctl restart sglang-h3`. Whatever ends up working, commit it to the Terraform defaults so the next deploy does not rediscover it at $13/hour.

```bash
sudo systemctl status sglang-h3
sudo journalctl -fu sglang-h3          # weight loading is slow and quiet; watch here
free -g                                # the number that actually decides success
```

### Licence

MiniMax-H3 is released under the **MiniMax H3 Community License Agreement**, not Apache/MIT. Read it before any commercial use.

---

## Security notes

- `ipv4_allowed` is converted to a `/32` CIDR internally — all inbound ports are restricted to your single IP.
- IMDSv2 is enforced on the instance (`http_tokens = "required"`).
- The scripts S3 bucket is private, server-side encrypted (AES-256), and has all public access blocked.
- The instance IAM role grants **read-only** access to the scripts bucket, plus `ec2:AssociateAddress` scoped to this deployment's Elastic IP — it cannot scale, stop or terminate anything.
- The workflow uses long-lived AWS access keys; consider migrating to **GitHub OIDC** for keyless authentication.

