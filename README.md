# Self-Hosted LLM Lab on AWS

Terraform + GitHub Actions to provision a **single or multi-GPU EC2 VM** (g5 family) across **4 supported AWS regions**, with a dedicated VPC, a stable Elastic IP, and a minimal security group. Provisioning (Ollama + Open WebUI + TTS stack) runs automatically via cloud-init on first boot — **no SSH key or manual steps needed**.

## What this repository creates
Terraform under [`infra/`](infra:1) provisions:

- **Networking**: VPC, public subnet, internet gateway, and route table association.
- **Compute**: an EC2 instance running the latest **AWS Deep Learning AMI (Ubuntu 22.04, NVIDIA drivers)**, plus an **Elastic IP**.
- **Access control**: a security group allowing inbound **22 (SSH)**, **3000 (Open WebUI)**, and **8000 (FastAPI, if you run one)** from a single allow-listed IP.
- **Ops guardrail**: an EventBridge Scheduler rule to **stop** the instance nightly at **01:00 Europe/Amsterdam**.

Outputs include instance ID, public IP, and an SSH helper command.

## Supported regions

| Region | Location | Notes |
|---|---|---|
| `eu-central-1` | Frankfurt, DE | Default; highest EU price |
| `eu-west-1` | Ireland, IE | Cheapest EU option for g5 |
| `eu-north-1` | Stockholm, SE | Good EU alternative |
| `us-east-2` | Ohio, US | Typically lowest overall price |

## Supported instance types

### Single GPU (1× NVIDIA A10G, 24 GB GPU RAM)

| Instance | vCPU | RAM | Storage | Network |
|---|---|---|---|---|
| `g5.xlarge` | 4 | 16 GiB | 1×250 GB | Up to 10 Gbps |
| `g5.2xlarge` | 8 | 32 GiB | 1×450 GB | Up to 10 Gbps |
| `g5.4xlarge` | 16 | 64 GiB | 1×600 GB | Up to 25 Gbps |
| `g5.8xlarge` | 32 | 128 GiB | 1×900 GB | 25 Gbps |

### Multi GPU (4× NVIDIA A10G, 96 GB total GPU RAM)

| Instance | vCPU | RAM | Storage | Network |
|---|---|---|---|---|
| `g5.12xlarge` | 48 | 192 GiB | 1×3800 GB | 40 Gbps |
| `g5.24xlarge` | 96 | 384 GiB | 1×3800 GB | 50 Gbps |

> **Cost tip**: `eu-west-1` (Ireland) is typically 10–15% cheaper than `eu-central-1` (Frankfurt) for g5 on-demand. `us-east-2` (Ohio) is usually the cheapest overall.

## Repository layout
- [`infra/`](infra:1): Terraform root module.
  - [`infra/network.tf`](infra/network.tf:1): VPC + subnet + routing.
  - [`infra/compute.tf`](infra/compute.tf:1): security group, EC2 instance, Elastic IP.
  - [`infra/operations.tf`](infra/operations.tf:1): nightly autostop schedule.
  - [`infra/variables.tf`](infra/variables.tf:1): tunables (instance type, IP allow-list, CIDRs, disk size).
  - [`infra/outputs.tf`](infra/outputs.tf:1): instance/public IP/SSH command outputs.
- [`scripts/provision_llm_stack.sh`](scripts/provision_llm_stack.sh:1): bootstraps **Docker + Ollama + Open WebUI** on the VM.
- [`.github/workflows/manage-llm-vm.yml`](.github/workflows/manage-llm-vm.yml:1): manual (“workflow_dispatch”) pipeline to run `terraform apply` / `terraform destroy`.
- [`aws_llm_setup.txt`](aws_llm_setup.txt:1): original manual runbook (PyTorch + example FastAPI server).

## Key behaviors / caveats found in the code

### Ingress ports
The Terraform security group in [`infra/compute.tf`](infra/compute.tf:1) currently opens **only**:

- `22/tcp` (SSH)
- `3000/tcp` (Open WebUI)
- `8000/tcp` (FastAPI)

Ollama’s API default port (`11434`) is **not** opened to the internet. Access it via:

- Open WebUI (recommended), or
- an SSH tunnel, e.g. `ssh -L 11434:localhost:11434 ubuntu@<EIP>`.

### “Autostop” is not “no-cost”
The scheduler in [`infra/operations.tf`](infra/operations.tf:1) **stops** the instance nightly; it does **not** destroy it.

Even while stopped, you still pay for:
- **EBS** volumes, and
- potentially the **Elastic IP** (AWS bills EIPs in several “idle” scenarios).

Use `destroy` when you want to avoid ongoing charges.

## Prerequisites (manual)
You still need to do a few one-time setup steps:

1. **Terraform remote state bucket**: create an S3 bucket for the backend (one per region you deploy into, or share one bucket with per-region state keys).
2. **IP allow-list**: set `ipv4_allowed` to a single IPv4 address (your workstation egress IP).
3. **EC2 key pair** *(optional)*: only needed if you want SSH access. Leave `key_pair_name` blank to rely on cloud-init provisioning alone.

## Quickstart (GitHub Actions)

1. Add GitHub repository secrets:

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS credentials used by the workflow |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials used by the workflow |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform backend state |

2. Run the workflow [`.github/workflows/manage-llm-vm.yml`](.github/workflows/manage-llm-vm.yml:1) with:

- `action` — `apply` or `destroy`
- `instance_type` — pick from the table above (default: `g5.xlarge`)
- `aws_region` — pick a supported region (default: `eu-central-1`)
- `ipv4_allowed` — your public IPv4 address
- `key_pair_name` — optional; leave blank if you don't need SSH access

## Quickstart (local Terraform)

```bash
terraform -chdir=infra init \
  -backend-config="bucket=self-hosted-llm-tfstate" \
  -backend-config="key=llm-gpu/terraform.tfstate" \
  -backend-config="region=eu-west-1"

terraform -chdir=infra apply -auto-approve \
  -var='aws_region=eu-west-1' \
  -var='instance_type=g5.xlarge' \
  -var='ipv4_allowed=203.0.113.25'
```

## Post-provision

Provisioning runs **automatically** on first boot via cloud-init (`scripts/user-data.sh`). It downloads and runs:
1. `provision_llm_stack.sh` — Docker + NVIDIA + Ollama + Open WebUI
2. `provision_tts_stack.sh` — Kokoro/XTTS/Piper + Gradio TTS UI

Logs on the VM: `/var/log/llm-lab-bootstrap.log`

When it completes:
- Open WebUI: `http://<EIP>:3000`
- Gradio TTS UI: `http://<EIP>:7860`
- Ollama API (tunneled): `ssh -L 11434:localhost:11434 ubuntu@<EIP>`

## Security notes
- Prefer a single `ipv4_allowed` and keep it updated; it is converted to `/32` internally.
- Instance metadata requires IMDSv2 (see [`infra/compute.tf`](infra/compute.tf:1)).
- The workflow uses long-lived AWS keys; consider migrating to GitHub OIDC (`configure-aws-credentials` with role assumption) if you harden this further.
