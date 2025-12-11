# Self-Hosted LLM Lab on AWS

Terraform + GitHub Actions to provision a **single GPU EC2 VM** (g5 family) in **`eu-central-1` by default**, with a dedicated VPC, a stable Elastic IP, and a minimal security group. After provisioning, you can bootstrap an Ollama + Open WebUI stack via a helper script.

This repo contains **infrastructure + runbooks**, not an application server implementation.

## What this repository creates
Terraform under [`infra/`](infra:1) provisions:

- **Networking**: VPC, public subnet, internet gateway, and route table association.
- **Compute**: an EC2 instance running the latest **AWS Deep Learning AMI (Ubuntu 22.04, NVIDIA drivers)**, plus an **Elastic IP**.
- **Access control**: a security group allowing inbound **22 (SSH)**, **3000 (Open WebUI)**, and **8000 (FastAPI, if you run one)** from a single allow-listed IP.
- **Ops guardrail**: an EventBridge Scheduler rule to **stop** the instance nightly at **01:00 Europe/Amsterdam**.

Outputs include instance ID, public IP, and an SSH helper command.

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

1. **EC2 key pair**: create/import a key pair in the target region (default: `llm-keypair`).
2. **Terraform remote state bucket**: create an S3 bucket for the backend (and optionally a DynamoDB table for locking).
3. **IP allow-list**: set `ipv4_allowed` to a single IPv4 address (your workstation egress IP).

## Quickstart (GitHub Actions)

1. Add GitHub repository secrets:

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS credentials used by the workflow |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials used by the workflow |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform backend state |
| `AWS_REGION` *(optional)* | Overrides default `eu-central-1` |

2. Run the workflow [`.github/workflows/manage-llm-vm.yml`](.github/workflows/manage-llm-vm.yml:1) with:

- `action=apply`
- `key_pair_name=<your-existing-keypair>`
- `ipv4_allowed=<your.public.ip.v4>`

Terraform outputs (EIP, SSH command, etc.) are printed in the job logs.

## Quickstart (local Terraform)

```bash
terraform -chdir=infra init \
  -backend-config="bucket=self-hosted-llm-tfstate" \
  -backend-config="key=llm-gpu/terraform.tfstate" \
  -backend-config="region=eu-central-1"

terraform -chdir=infra apply -auto-approve \
  -var='key_pair_name=llm-keypair' \
  -var='ipv4_allowed=203.0.113.25'
```

## Post-provision: bootstrap Ollama + Open WebUI

After Terraform reports success, bootstrap the VM with [`scripts/provision_llm_stack.sh`](scripts/provision_llm_stack.sh:1):

```bash
scp scripts/provision_llm_stack.sh ubuntu@<EIP>:/tmp/
ssh ubuntu@<EIP> 'chmod +x /tmp/provision_llm_stack.sh'
ssh ubuntu@<EIP> 'sudo /tmp/provision_llm_stack.sh llama3.2:3b'
```

When it completes:

- Open WebUI: `http://<EIP>:3000`
- Ollama API (tunneled):
  ```bash
  ssh -L 11434:localhost:11434 ubuntu@<EIP>
  curl http://localhost:11434/api/tags
  ```

## Security notes
- Prefer a single `ipv4_allowed` and keep it updated; it is converted to `/32` internally.
- Instance metadata requires IMDSv2 (see [`infra/compute.tf`](infra/compute.tf:1)).
- The workflow uses long-lived AWS keys; consider migrating to GitHub OIDC (`configure-aws-credentials` with role assumption) if you harden this further.
