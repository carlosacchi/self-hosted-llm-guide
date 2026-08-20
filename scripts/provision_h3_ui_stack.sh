#!/usr/bin/env bash
set -euo pipefail

########################################
# MiniMax-H3 Gradio UI provisioner
#
# SGLang only exposes an asynchronous three-call REST flow:
#   POST /v1/videos              -> {"id": ...}
#   GET  /v1/videos/{id}         -> poll until status is completed/failed
#   GET  /v1/videos/{id}/content -> MP4 bytes
#
# Every other tool in this lab (TTS, VibeVoice, ASR, Open WebUI) has a browser
# UI indexed by the landing portal, so H3 gets one too: prompt in, MP4 player
# out, with the polling loop hidden.
#
# Depends on provision_h3_stack.sh having installed the SGLang server. Talks to
# it over localhost, so the UI works even before the server finishes loading
# weights (it just reports that it is not up yet).
#
# Usage:
#   sudo bash provision_h3_ui_stack.sh
#   sudo H3_UI_PORT=7865 bash provision_h3_ui_stack.sh
########################################

H3_UI_NAME="${H3_UI_NAME:-h3-ui}"
H3_UI_DIR="${H3_UI_DIR:-/opt/h3-ui}"
H3_UI_PORT="${H3_UI_PORT:-7865}"
H3_UI_USER="${H3_UI_USER:-ubuntu}"
H3_UI_GROUP="${H3_UI_GROUP:-ubuntu}"
H3_API_BASE="${H3_API_BASE:-http://127.0.0.1:30010}"
H3_MODEL_NAME="${H3_MODEL_NAME:-MiniMaxAI/MiniMax-H3}"

log() {
  echo -e "[provision_h3_ui_stack] $*"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log "This script must run as root (use: sudo $0)"
    exit 1
  fi
}

########################################
# Step 1: venv + packages
########################################

create_venv() {
  log "Creating venv in ${H3_UI_DIR}/.venv ..."
  apt-get update -y
  apt-get install -y python3-venv python3-pip
  mkdir -p "${H3_UI_DIR}"
  [[ -d "${H3_UI_DIR}/.venv" ]] || python3 -m venv "${H3_UI_DIR}/.venv"
  "${H3_UI_DIR}/.venv/bin/pip" install --quiet --upgrade pip

  # Same Gradio 6 pin as the other UIs in this repo: it ships a self-consistent
  # fastapi/starlette/gradio_client set. See the long note in
  # provision_asr_stack.sh for the failure modes older pins caused.
  "${H3_UI_DIR}/.venv/bin/pip" install --quiet \
    "gradio==6.17.3" \
    "jinja2>=3.1" \
    "markupsafe>=2.1.1" \
    "requests>=2.31"
  log "Venv ready."
}

########################################
# Step 2: the app
########################################

write_app() {
  log "Writing app to ${H3_UI_DIR}/app.py ..."

  cat > "${H3_UI_DIR}/app.py" <<'PYTHON'
"""Gradio front-end for the MiniMax-H3 SGLang video API.

Wraps the asynchronous submit/poll/download flow so the browser gets a plain
"type a prompt, watch a video" experience.

Generation on 4x PCIe-connected L40S with layerwise offload takes MINUTES per
clip, not seconds, so the UI streams progress updates instead of blocking on a
silent request.
"""

import os
import time
import uuid

import gradio as gr
import requests

API_BASE = os.environ.get("H3_API_BASE", "http://127.0.0.1:30010").rstrip("/")
MODEL_NAME = os.environ.get("H3_MODEL_NAME", "MiniMaxAI/MiniMax-H3")
OUTPUT_DIR = os.environ.get("H3_UI_OUTPUT_DIR", "/opt/h3-ui/outputs")

# Generous: a 5s clip can legitimately take 15+ minutes on this hardware.
POLL_TIMEOUT_S = int(os.environ.get("H3_POLL_TIMEOUT_S", "3600"))
POLL_INTERVAL_S = 5

os.makedirs(OUTPUT_DIR, exist_ok=True)

ASPECT_RATIOS = ["16:9", "9:16", "1:1", "4:3", "3:4"]
SHORT_EDGES = [512, 768, 1024]


def server_status() -> str:
    """One-line health string for the header."""
    try:
        # /v1/videos is POST-only; any HTTP answer means the server is listening.
        r = requests.get(f"{API_BASE}/v1/videos", timeout=5)
        return f"🟢 SGLang reachable at {API_BASE} (HTTP {r.status_code})"
    except requests.RequestException:
        return (
            f"🔴 SGLang not reachable at {API_BASE}. It is probably still loading "
            "weights (this takes several minutes on first boot). "
            "Check: sudo journalctl -fu sglang-h3"
        )


def generate(prompt, seconds, short_edge, aspect_ratio, steps, seed, progress=gr.Progress()):
    prompt = (prompt or "").strip()
    if not prompt:
        raise gr.Error("Enter a prompt first.")

    seconds = int(seconds)
    payload = {
        "model": MODEL_NAME,
        "task": "t2va",
        "prompt": prompt,
        "seconds": seconds,
        "conditions": [],
        "target": {
            "short_edge": int(short_edge),
            "aspect_ratio": aspect_ratio,
            "duration_seconds": seconds,
        },
        "num_outputs_per_prompt": 1,
        "num_inference_steps": int(steps),
        "seed": int(seed),
    }

    progress(0, desc="Submitting job...")
    try:
        r = requests.post(f"{API_BASE}/v1/videos", json=payload, timeout=30)
    except requests.RequestException as exc:
        raise gr.Error(
            f"Could not reach SGLang at {API_BASE}: {exc}. "
            "If the box just booted, weights may still be loading."
        ) from exc

    if r.status_code >= 400:
        raise gr.Error(f"Server rejected the request (HTTP {r.status_code}): {r.text[:500]}")

    job = r.json()
    job_id = job.get("id") or job.get("video_id")
    if not job_id:
        raise gr.Error(f"No job id in the response: {str(job)[:500]}")

    started = time.time()
    last_status = ""
    while True:
        elapsed = time.time() - started
        if elapsed > POLL_TIMEOUT_S:
            raise gr.Error(
                f"Job {job_id} did not finish within {POLL_TIMEOUT_S // 60} minutes. "
                "It may still be running; check the server logs."
            )

        try:
            s = requests.get(f"{API_BASE}/v1/videos/{job_id}", timeout=15)
            s.raise_for_status()
            state = s.json()
        except requests.RequestException as exc:
            # A transient blip while the GPU is saturated should not kill the job.
            progress(0.5, desc=f"Poll failed ({exc}); retrying...")
            time.sleep(POLL_INTERVAL_S)
            continue

        status = str(state.get("status", "")).lower()
        if status != last_status:
            last_status = status

        if status in ("completed", "succeeded", "success"):
            break
        if status in ("failed", "error", "cancelled"):
            raise gr.Error(f"Generation failed: {str(state)[:500]}")

        pct = state.get("progress")
        frac = min(0.95, float(pct) / 100.0) if isinstance(pct, (int, float)) else min(0.95, elapsed / 900.0)
        progress(frac, desc=f"{status or 'running'} — {int(elapsed)}s elapsed")
        time.sleep(POLL_INTERVAL_S)

    progress(0.97, desc="Downloading MP4...")
    c = requests.get(f"{API_BASE}/v1/videos/{job_id}/content", timeout=300)
    c.raise_for_status()

    out_path = os.path.join(OUTPUT_DIR, f"h3-{uuid.uuid4().hex[:8]}.mp4")
    with open(out_path, "wb") as fh:
        fh.write(c.content)

    total = int(time.time() - started)
    info = (
        f"Done in {total // 60}m {total % 60}s · job {job_id} · "
        f"{seconds}s @ {short_edge}p {aspect_ratio} · {int(steps)} steps · seed {int(seed)}\n"
        f"Saved to {out_path}"
    )
    return out_path, info


with gr.Blocks(title="MiniMax-H3 — video + audio") as demo:
    gr.Markdown("# MiniMax-H3 — text to video *and* audio")
    gr.Markdown(
        "One request produces an H.264 MP4 with a synchronized stereo AAC track. "
        "**Generation takes minutes, not seconds**: this box runs 4x L40S over PCIe "
        "with layerwise offload, so budget roughly 8-15 minutes for a 5-second clip. "
        "The instance bills at about $13/hour — the autostop timers will shut it "
        "down when idle."
    )
    status_md = gr.Markdown(server_status())

    with gr.Row():
        with gr.Column(scale=3):
            prompt = gr.Textbox(
                label="Prompt",
                placeholder="A futuristic data center at night, slow dolly shot, humming servers",
                lines=4,
            )
            with gr.Row():
                seconds = gr.Slider(4, 15, value=5, step=1, label="Duration (s)")
                steps = gr.Slider(20, 50, value=50, step=1, label="Inference steps")
            with gr.Row():
                short_edge = gr.Dropdown(SHORT_EDGES, value=768, label="Short edge (px)")
                aspect_ratio = gr.Dropdown(ASPECT_RATIOS, value="16:9", label="Aspect ratio")
                seed = gr.Number(value=1101, precision=0, label="Seed")
            go = gr.Button("Generate", variant="primary")
            refresh = gr.Button("Refresh server status", size="sm")
        with gr.Column(scale=2):
            video_out = gr.Video(label="Result", autoplay=False)
            info_out = gr.Textbox(label="Details", lines=4, show_copy_button=True)

    gr.Markdown(
        "Only the **fl2va** checkpoint partition is served, which covers text-to-video "
        "(`t2va`) and first/last-frame conditioning. The `ref2va` partition is "
        "deliberately not deployed: it produces noise on L40S-class GPUs "
        "([sglang#34110](https://github.com/sgl-project/sglang/issues/34110))."
    )

    go.click(
        generate,
        inputs=[prompt, seconds, short_edge, aspect_ratio, steps, seed],
        outputs=[video_out, info_out],
    )
    refresh.click(lambda: server_status(), outputs=status_md)


if __name__ == "__main__":
    port = int(os.environ.get("H3_UI_PORT", "7865"))
    demo.queue().launch(server_name="0.0.0.0", server_port=port)
PYTHON

  log "App written."
}

########################################
# Step 3: systemd service
########################################

install_systemd_service() {
  log "Installing ${H3_UI_NAME}.service ..."

  mkdir -p "${H3_UI_DIR}/outputs"
  chown -R "${H3_UI_USER}:${H3_UI_GROUP}" "${H3_UI_DIR}"

  cat > "/etc/systemd/system/${H3_UI_NAME}.service" <<EOF
[Unit]
Description=MiniMax-H3 video generation UI (Gradio)
After=network.target sglang-h3.service
Wants=sglang-h3.service

[Service]
User=${H3_UI_USER}
WorkingDirectory=${H3_UI_DIR}
Environment=H3_API_BASE=${H3_API_BASE}
Environment=H3_MODEL_NAME=${H3_MODEL_NAME}
Environment=H3_UI_PORT=${H3_UI_PORT}
Environment=H3_UI_OUTPUT_DIR=${H3_UI_DIR}/outputs
ExecStart=${H3_UI_DIR}/.venv/bin/python ${H3_UI_DIR}/app.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${H3_UI_NAME}"
  systemctl restart "${H3_UI_NAME}"
  log "Service ${H3_UI_NAME} started on port ${H3_UI_PORT}."
}

########################################
# Main
########################################

main() {
  require_root
  create_venv
  write_app
  install_systemd_service

  log ""
  log "=== MiniMax-H3 UI ready ==="
  log "  UI      : http://<EIP>:${H3_UI_PORT}"
  log "  Backend : ${H3_API_BASE}"
  log "  Logs    : sudo journalctl -fu ${H3_UI_NAME}"
}

main "$@"
