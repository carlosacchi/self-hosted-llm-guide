# Self-Hosted LLM Lab on AWS

Terraform + GitHub Actions to provision a **single or multi-GPU EC2 VM** (g5 family) across **4 supported AWS regions**. The application stack deploys **automatically via cloud-init on first boot** — no SSH key, no manual steps — and a **service portal on port 80** gives you one clickable index of everything running.

The default boot is sized to fit a single 24 GB GPU (`g5.xlarge`): a **landing portal**, **Ollama + Open WebUI** (LLM chat), a **Gradio multi-engine TTS UI**, and **VibeVoice-1.5B multi-speaker** (podcast) TTS. Two heavier VibeVoice stacks — the Realtime-0.5B single-speaker UI and the 7B multi-speaker model — ship in the repo but are **disabled by default** to avoid GPU oversubscription; re-enable them by uncommenting their blocks in `bootstrap_all.sh`.

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

- **Networking**: VPC (`10.42.0.0/16`), public subnet, internet gateway, route table.
- **Compute**: EC2 g5 instance on the **AWS Deep Learning AMI (Ubuntu 22.04, NVIDIA drivers pre-installed)**, Elastic IP.
- **Provisioning**: private encrypted S3 bucket holding the bootstrap scripts; IAM instance profile granting the VM read-only access to that bucket.
- **Access control**: security group allowing inbound traffic **only from your IP** (`ipv4_allowed`):
  - `22/tcp` — SSH (optional, only if `key_pair_name` is set)
  - `80/tcp` — Service portal (nginx landing page)
  - `3000/tcp` — Open WebUI
  - `7860/tcp` — Gradio TTS UI
  - `7861/tcp` — VibeVoice multi-speaker TTS UI (1.5B podcast)
  - `7862/tcp` — VibeVoice Realtime TTS UI (single speaker, disabled by default)
  - `7863/tcp` — VibeVoice 7B multi-speaker TTS UI (disabled by default)
  - `8000/tcp` — FastAPI (reserved)
  - `11434/tcp` — Ollama REST API
  - `19999/tcp` — Netdata monitoring dashboard
- **Ops guardrail**: EventBridge Scheduler stops the instance nightly at **01:00 Europe/Amsterdam** to reduce costs.

### "Autostop" is not "no-cost"

The scheduler **stops** the instance; it does not destroy it. While stopped you still pay for EBS and the Elastic IP. Run `destroy` when you want zero ongoing charges.

---

## Supported regions

| Region | Location | Notes |
|---|---|---|
| `eu-central-1` | Frankfurt, DE | Default |
| `eu-west-1` | Ireland, IE | Cheapest EU option for g5 |
| `eu-north-1` | Stockholm, SE | Good EU alternative |
| `us-east-2` | Ohio, US | Typically lowest overall price |

> `eu-west-1` is typically 10–15 % cheaper than `eu-central-1` for g5 on-demand. `us-east-2` is usually cheapest.

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

---

## Repository layout

```
infra/
  network.tf        VPC, subnet, internet gateway, routing
  compute.tf        Security group, EC2 instance, Elastic IP
  provisioning.tf   S3 scripts bucket, IAM role/instance profile
  operations.tf     Nightly autostop EventBridge schedule
  variables.tf      All tunable inputs
  locals.tf         Computed values and shared tags
  outputs.tf        Instance ID, public IP, portal + app URLs, SSH command

scripts/
  user-data.sh                  Cloud-init entry point (downloads scripts from S3)
  bootstrap_all.sh              Orchestrator: monitoring, LLM, TTS, VibeVoice 1.5B, portal (disabled stacks commented out)
  provision_monitoring_stack.sh Netdata agent + real-time GPU/CPU/RAM/disk dashboard (port 19999)
  provision_llm_stack.sh        Docker + NVIDIA toolkit + Ollama + Open WebUI
  provision_tts_stack.sh        Python venv + Kokoro + XTTS-v2 + Piper + Gradio app
  provision_vibevoice_tts_stack.sh  Python venv + VibeVoice-1.5B (community fork) multi-speaker podcast UI (port 7861)
  provision_vibevoice_stack.sh  Python venv + VibeVoice-Realtime-0.5B + web UI (disabled by default, port 7862)
  provision_landing_stack.sh    nginx + static service portal that links every running app (port 80)

.github/workflows/
  manage-llm-vm.yml       Manual workflow: apply / destroy
```

---

## Prerequisites

1. **AWS credentials** with permissions for EC2, VPC, IAM, S3, EventBridge Scheduler.
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
| `instance_type` | g5 size (see table above) | `g5.xlarge` |
| `aws_region` | Target region (see table above) | `eu-central-1` |
| `ipv4_allowed` | Your public IPv4 (e.g. `203.0.113.25`) | *(required)* |
| `root_volume_size` | EBS root volume in GiB | `200` |
| `key_pair_name` | EC2 key pair name for SSH — leave blank to skip | *(blank)* |

Terraform outputs (Elastic IP, app URLs, SSH command) are printed at the end of the job log.

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

---

## Provisioning pipeline

Once Terraform creates the instance, AWS runs `scripts/user-data.sh` as root via cloud-init:

```
cloud-init (user-data.sh)
  └── downloads scripts from S3 via IAM instance role
  └── bootstrap_all.sh
        ├── [1/5] provision_monitoring_stack.sh
        │     ├── installs Netdata (stable, no telemetry)
        │     ├── binds dashboard to 0.0.0.0:19999
        │     └── auto-collects GPU (nvidia-smi), CPU, RAM, disk, network
        ├── [2/5] provision_llm_stack.sh
        │     ├── installs Docker + NVIDIA Container Toolkit
        │     ├── writes docker-compose.yml (Ollama + Open WebUI)
        │     └── pulls default models (llama3.2:3b, qwen3.5:27b, qwen2.5-coder:32b)
        ├── [3/5] provision_tts_stack.sh
        │     ├── installs system deps (ffmpeg, espeak-ng, python3-venv)
        │     ├── creates Python venv (reuses GPU PyTorch from DLAMI)
        │     ├── installs Kokoro, XTTS-v2 (coqui-tts), Piper
        │     ├── downloads Piper voice models (EN US + IT)
        │     ├── writes Gradio app (app.py) with 3 TTS engine tabs
        │     └── registers tts-app.service (systemd, port 7860)
        ├── [4/5] provision_vibevoice_tts_stack.sh   (VVT_PORT=7861)
        │     ├── clones github.com/vibevoice-community/VibeVoice (official TTS code was removed by Microsoft)
        │     ├── creates an isolated Python venv (reuses GPU PyTorch from DLAMI)
        │     ├── installs the community VibeVoice package (editable)
        │     ├── patches the Gradio demo to bind 0.0.0.0 on port 7861 (no public share tunnel)
        │     ├── pre-downloads vibevoice/VibeVoice-1.5B (up to 4 speakers)
        │     └── registers vibevoice-tts.service (systemd, port 7861)
        └── [5/5] provision_landing_stack.sh
              ├── installs nginx
              ├── writes a static portal page linking every running service
              └── serves it on port 80 (links built client-side from the host)

  Disabled by default (commented out in bootstrap_all.sh — uncomment to enable):
    · provision_vibevoice_stack.sh        VibeVoice-Realtime-0.5B single-speaker → port 7862
    · provision_vibevoice_tts_stack.sh 7B VibeVoice-7B multi-speaker (~16 GB VRAM) → port 7863
```

**Logs on the VM**: `/var/log/llm-lab-bootstrap.log`

Provisioning takes **15–25 minutes** on a `g5.xlarge` (large Python packages + model downloads). The apps are not reachable until it completes.

---

## Accessing the apps

| App | URL | Notes |
|---|---|---|
| **Service portal** | `http://<EIP>/` | **Start here** — landing page linking every running service |
| Monitoring | `http://<EIP>:19999` | Netdata: real-time GPU, GPU memory, CPU, RAM, disk |
| Open WebUI | `http://<EIP>:3000` | LLM chat, model management |
| Gradio TTS UI | `http://<EIP>:7860` | 3-tab TTS: Kokoro / XTTS-v2 / Piper |
| VibeVoice TTS UI | `http://<EIP>:7861` | Multi-speaker (1.5B), long-form conversational synthesis |
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

## Security notes

- `ipv4_allowed` is converted to a `/32` CIDR internally — all inbound ports are restricted to your single IP.
- IMDSv2 is enforced on the instance (`http_tokens = "required"`).
- The scripts S3 bucket is private, server-side encrypted (AES-256), and has all public access blocked.
- The instance IAM role grants **read-only** access to the scripts bucket only.
- The workflow uses long-lived AWS access keys; consider migrating to **GitHub OIDC** for keyless authentication.

