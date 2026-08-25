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
# UI indexed by the landing portal, so H3 gets one too: reference image +
# prompt in, MP4 player out, with the polling loop hidden.
#
# The backend serves the Ref2VA partition, so every request is task "ref2va"
# with an image condition. Reference assets are passed as server-local file://
# URIs, which means the upload has to land in the directory that
# provision_h3_stack.sh bind-mounts read-only into the container: H3_MEDIA_DIR
# on the host, /data/minimax-h3 inside it.
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

# Must match provision_h3_stack.sh: host path and its mount point inside the
# SGLang container. The UI writes uploads to the first and sends the second.
H3_MEDIA_DIR="${H3_MEDIA_DIR:-/opt/h3/media}"
H3_MEDIA_MOUNT="${H3_MEDIA_MOUNT:-/data/minimax-h3}"

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
"""Gradio front-end for the MiniMax-H3 SGLang video API (Ref2VA).

Wraps the asynchronous submit/poll/download flow so the browser gets a plain
"upload a reference image, type a prompt, watch a video" experience.

Generation on 2x PCIe-connected RTX PRO 6000 with layerwise offload takes
MINUTES per clip, not seconds, so the UI streams progress updates instead of
blocking on a silent request.
"""

import os
import shutil
import time
import uuid

import gradio as gr
import requests

API_BASE = os.environ.get("H3_API_BASE", "http://127.0.0.1:30010").rstrip("/")
MODEL_NAME = os.environ.get("H3_MODEL_NAME", "MiniMaxAI/MiniMax-H3")
OUTPUT_DIR = os.environ.get("H3_UI_OUTPUT_DIR", "/opt/h3-ui/outputs")

# Reference uploads are handed to SGLang as file:// URIs, so they must be
# written where the container can read them: MEDIA_DIR on the host is the same
# directory as MEDIA_MOUNT inside it.
MEDIA_DIR = os.environ.get("H3_MEDIA_DIR", "/opt/h3/media")
MEDIA_MOUNT = os.environ.get("H3_MEDIA_MOUNT", "/data/minimax-h3")

# Generous: a 5s clip can legitimately take 15+ minutes on this hardware.
POLL_TIMEOUT_S = int(os.environ.get("H3_POLL_TIMEOUT_S", "3600"))
POLL_INTERVAL_S = 5

# Ref2VA resolves "auto" to the model's 16:9 fallback rather than inheriting the
# reference image's geometry, so an explicit ratio is usually what you want.
ASPECT_RATIOS = ["16:9", "9:16", "1:1", "4:3", "3:4", "auto"]
SHORT_EDGES = [512, 768, 1024]
ALLOWED_IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".bmp"}

os.makedirs(OUTPUT_DIR, exist_ok=True)


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


def stage_reference(image_path: str) -> str:
    """Copy an upload into the container-visible media dir, return its file:// URI."""
    ext = os.path.splitext(image_path)[1].lower()
    if ext not in ALLOWED_IMAGE_EXT:
        raise gr.Error(
            f"Unsupported image type {ext or '(no extension)'}. "
            f"Use one of: {', '.join(sorted(ALLOWED_IMAGE_EXT))}."
        )

    name = f"ref-{uuid.uuid4().hex}{ext}"
    try:
        shutil.copyfile(image_path, os.path.join(MEDIA_DIR, name))
    except OSError as exc:
        raise gr.Error(
            f"Could not stage the reference image in {MEDIA_DIR}: {exc}. "
            "That directory is created by provision_h3_stack.sh and must be "
            "writable by this service."
        ) from exc
    return f"file://{MEDIA_MOUNT}/{name}"


def generate(image_path, prompt, seconds, short_edge, aspect_ratio, steps, seed, progress=gr.Progress()):
    if not image_path:
        raise gr.Error("Upload a reference image first — this backend serves ref2va only.")

    prompt = (prompt or "").strip()
    if not prompt:
        raise gr.Error("Enter a prompt first.")

    # Ref2VA condition order is semantic: the prompt refers to the first image
    # condition as <Picture 1>. Without that tag the reference is ignored.
    if "<Picture 1>" not in prompt:
        prompt = f"Use <Picture 1> as the visual subject and style reference. {prompt}"

    progress(0, desc="Staging reference image...")
    reference_uri = stage_reference(image_path)

    seconds = int(seconds)
    payload = {
        "model": MODEL_NAME,
        "task": "ref2va",
        "prompt": prompt,
        "seconds": seconds,
        "conditions": [
            {"type": "image", "uri": reference_uri, "role": "reference"},
        ],
        "target": {
            "short_edge": int(short_edge),
            "aspect_ratio": aspect_ratio,
            "duration_seconds": seconds,
        },
        "num_outputs_per_prompt": 1,
        "num_inference_steps": int(steps),
        "flow_shift": 12.0,
        "audio_flow_shift": 3.0,
        "seed": int(seed),
    }

    progress(0.02, desc="Submitting job...")
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
        f"Reference: {reference_uri}\n"
        f"Saved to {out_path}"
    )
    return out_path, info


with gr.Blocks(title="MiniMax-H3 — image reference to video + audio") as demo:
    gr.Markdown("# MiniMax-H3 — image reference → video *and* audio")
    gr.Markdown(
        "Upload a reference image, describe the scene, and one request produces an "
        "H.264 MP4 with a synchronized stereo AAC track. "
        "**Generation takes minutes, not seconds**: this box runs 2x RTX PRO 6000 "
        "with layerwise offload, so budget roughly 8-15 minutes for a 5-second clip. "
        "The instance bills at about $13/hour — the autostop timers will shut it "
        "down when idle."
    )
    status_md = gr.Markdown(server_status())

    with gr.Row():
        with gr.Column(scale=3):
            reference = gr.Image(
                label="Reference image (required)",
                type="filepath",
                sources=["upload", "clipboard"],
            )
            prompt = gr.Textbox(
                label="Prompt",
                placeholder=(
                    "Use <Picture 1> as the visual subject; slow dolly shot at night, "
                    "humming servers, shallow depth of field"
                ),
                lines=4,
            )
            with gr.Row():
                seconds = gr.Slider(4, 15, value=5, step=1, label="Duration (s)")
                steps = gr.Slider(20, 50, value=50, step=1, label="Inference steps")
            with gr.Row():
                short_edge = gr.Dropdown(SHORT_EDGES, value=768, label="Short edge (px)")
                aspect_ratio = gr.Dropdown(ASPECT_RATIOS, value="16:9", label="Aspect ratio")
                seed = gr.Number(value=3101, precision=0, label="Seed")
            go = gr.Button("Generate", variant="primary")
            refresh = gr.Button("Refresh server status", size="sm")
        with gr.Column(scale=2):
            video_out = gr.Video(label="Result", autoplay=False)
            info_out = gr.Textbox(label="Details", lines=5, show_copy_button=True)

    gr.Markdown(
        "This UI submits `ref2va` requests against the **Ref2VA** checkpoint partition — "
        "the only one this stack downloads. The image is *semantic reference material*, "
        "not a pixel-aligned first frame: H3 may recompose or crop it. Reference the "
        "upload in the prompt as `<Picture 1>`; if you leave the tag out, the UI "
        "prepends a default sentence that does."
    )

    go.click(
        generate,
        inputs=[reference, prompt, seconds, short_edge, aspect_ratio, steps, seed],
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

  # provision_h3_stack.sh normally creates this; make it writable here too so a
  # standalone UI re-run does not fail on the first upload.
  install -d -m 0755 -o "${H3_UI_USER}" -g "${H3_UI_GROUP}" "${H3_MEDIA_DIR}"

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
Environment=H3_MEDIA_DIR=${H3_MEDIA_DIR}
Environment=H3_MEDIA_MOUNT=${H3_MEDIA_MOUNT}
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
  log "  Backend : ${H3_API_BASE} (ref2va)"
  log "  Uploads : ${H3_MEDIA_DIR} -> ${H3_MEDIA_MOUNT} in the SGLang container"
  log "  Logs    : sudo journalctl -fu ${H3_UI_NAME}"
}

main "$@"
