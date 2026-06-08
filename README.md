# Self-Hosted LLM Lab on AWS

Terraform + GitHub Actions to provision a **single or multi-GPU EC2 VM** (g5 family) across **4 supported AWS regions**. The full application stack — Ollama + Open WebUI (LLM chat), a Gradio multi-engine TTS UI, and the Microsoft VibeVoice Realtime TTS UI — deploys **automatically via cloud-init on first boot**. No SSH key, no manual steps.

---

## What gets deployed

| Component | Technology | Port |
|---|---|---|
| LLM inference | [Ollama](https://ollama.com) (Docker, GPU) | 11434 (internal) |
| LLM chat UI | [Open WebUI](https://github.com/open-webui/open-webui) (Docker) | 3000 |
| TTS engines | Kokoro · XTTS-v2 · Piper (Python venv, GPU) | — |
| TTS UI | [Gradio](https://www.gradio.app) multi-engine app | 7860 |
| VibeVoice TTS | [Microsoft VibeVoice-Realtime-0.5B](https://github.com/microsoft/VibeVoice) (Python venv, GPU) | 7861 |
| Monitoring | [Netdata](https://www.netdata.cloud) real-time dashboard (GPU, CPU, RAM, disk) | 19999 |

### TTS engines

| Engine | Voices | GPU | Best for |
|---|---|---|---|
| **Kokoro** | 9 presets (EN US/UK, IT, FR, ES, PT, JA) | Optional | Fast, low-latency |
| **XTTS-v2** | 21 presets + voice cloning from audio sample | Required for quality | Multilingual, expressive |
| **Piper** | EN US + IT (more downloadable) | No (CPU) | Ultra-light, always available |
| **VibeVoice** | Multi-speaker conversational synthesis (served on its own port 7861) | Required | Long-form, expressive, podcast-style |

---

## Infrastructure

Terraform under [`infra/`](infra/) provisions:

- **Networking**: VPC (`10.42.0.0/16`), public subnet, internet gateway, route table.
- **Compute**: EC2 g5 instance on the **AWS Deep Learning AMI (Ubuntu 22.04, NVIDIA drivers pre-installed)**, Elastic IP.
- **Provisioning**: private encrypted S3 bucket holding the bootstrap scripts; IAM instance profile granting the VM read-only access to that bucket.
- **Access control**: security group allowing inbound traffic **only from your IP** (`ipv4_allowed`):
  - `22/tcp` — SSH (optional, only if `key_pair_name` is set)
  - `3000/tcp` — Open WebUI
  - `7860/tcp` — Gradio TTS UI
  - `7861/tcp` — VibeVoice Realtime TTS UI
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
  outputs.tf        Instance ID, public IP, URLs, SSH command

scripts/
  user-data.sh                  Cloud-init entry point (downloads scripts from S3)
  bootstrap_all.sh              Orchestrator: runs monitoring, LLM, TTS, then VibeVoice provisioners in order
  provision_monitoring_stack.sh Netdata agent + real-time GPU/CPU/RAM/disk dashboard (port 19999)
  provision_llm_stack.sh        Docker + NVIDIA toolkit + Ollama + Open WebUI
  provision_tts_stack.sh        Python venv + Kokoro + XTTS-v2 + Piper + Gradio app
  provision_vibevoice_stack.sh  Python venv + VibeVoice-Realtime-0.5B + web UI (port 7861)

.github/workflows/
  manage-llm-vm.yml       Manual workflow: apply / destroy
```

---

## Prerequisites

1. **AWS credentials** with permissions for EC2, VPC, IAM, S3, EventBridge Scheduler.
2. **S3 bucket** for Terraform remote state (one per AWS account is enough; use region-specific keys). The bucket lives in a single region regardless of where you deploy the VM — set `TF_STATE_REGION` if it is not in `eu-central-1`.
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
  -backend-config="key=llm-gpu/terraform.tfstate" \
  -backend-config="region=eu-west-1"

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
        ├── provision_monitoring_stack.sh
        │     ├── installs Netdata (stable, no telemetry)
        │     ├── binds dashboard to 0.0.0.0:19999
        │     └── auto-collects GPU (nvidia-smi), CPU, RAM, disk, network
        ├── provision_llm_stack.sh
        │     ├── installs Docker + NVIDIA Container Toolkit
        │     ├── writes docker-compose.yml (Ollama + Open WebUI)
        │     └── pulls default Ollama models
        └── provision_tts_stack.sh
              ├── installs system deps (ffmpeg, espeak-ng, python3-venv)
              ├── creates Python venv (reuses GPU PyTorch from DLAMI)
              ├── installs Kokoro, XTTS-v2 (coqui-tts), Piper
              ├── downloads Piper voice models (EN US + IT)
              ├── writes Gradio app (app.py) with 3 TTS engine tabs
              └── registers tts-app.service (systemd, auto-restart)
        └── provision_vibevoice_stack.sh
              ├── clones github.com/microsoft/VibeVoice
              ├── creates Python venv (reuses GPU PyTorch from DLAMI)
              ├── installs VibeVoice with the streamingtts extra
              ├── pre-downloads microsoft/VibeVoice-Realtime-0.5B
              └── registers vibevoice.service (systemd, port 7861)
```

**Logs on the VM**: `/var/log/llm-lab-bootstrap.log`

Provisioning takes **15–25 minutes** on a `g5.xlarge` (large Python packages + model downloads). The apps are not reachable until it completes.

---

## Accessing the apps

| App | URL | Notes |
|---|---|---|
| Monitoring | `http://<EIP>:19999` | Netdata: real-time GPU, GPU memory, CPU, RAM, disk |
| Open WebUI | `http://<EIP>:3000` | LLM chat, model management |
| Gradio TTS UI | `http://<EIP>:7860` | 3-tab TTS: Kokoro / XTTS-v2 / Piper |
| VibeVoice TTS UI | `http://<EIP>:7861` | Multi-speaker, long-form conversational synthesis |
| Ollama API | `http://<EIP>:11434` | REST API, restricted to your IP — **no auth, anyone on that IP can use the GPU** |

Query the Ollama API directly (from your allowed IP):
```bash
curl http://<EIP>:11434/api/tags
curl http://<EIP>:11434/api/generate -d '{"model":"llama3","prompt":"Hello"}'
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

