#!/usr/bin/env bash
set -euo pipefail

########################################
# TTS stack provisioner
#
# Installs Kokoro + Gradio on top of a
# machine already set up by provision_llm_stack.sh
# (Docker + NVIDIA Container Toolkit are assumed present).
#
# Usage:
#   sudo bash provision_tts_stack.sh [app-dir]
#
# Default app dir: /opt/tts-app
########################################

APP_DIR="${1:-/opt/tts-app}"
APP_USER="${APP_USER:-ubuntu}"
GRADIO_PORT="${GRADIO_PORT:-7860}"

log() {
  echo -e "[provision_tts_stack] $*"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log "This script must run as root (use: sudo $0)"
    exit 1
  fi
}

########################################
# Step 1: system Python deps
# (python3-venv and ffmpeg for audio concat)
########################################

install_system_deps() {
  log "Installing system-level deps (python3-venv, ffmpeg, espeak-ng)..."
  apt-get update -y
  apt-get install -y \
    python3-venv python3-pip \
    ffmpeg \
    espeak-ng   # phoneme backend required by Kokoro
  log "System deps installed."
}

########################################
# Step 2: Python virtual environment
########################################

create_venv() {
  log "Creating Python venv in ${APP_DIR}/.venv ..."
  mkdir -p "${APP_DIR}"
  chown "${APP_USER}:${APP_USER}" "${APP_DIR}"

  if [[ ! -d "${APP_DIR}/.venv" ]]; then
    python3 -m venv "${APP_DIR}/.venv"
    log "Venv created."
  else
    log "Venv already exists, skipping creation."
  fi
}

########################################
# Step 3: Python packages
########################################

install_python_packages() {
  log "Installing Python packages into venv..."
  "${APP_DIR}/.venv/bin/pip" install --upgrade pip

  # Core deps
  "${APP_DIR}/.venv/bin/pip" install \
    gradio \
    pypdf \
    kokoro \
    soundfile \
    numpy

  # Optional: XTTS-v2 via Coqui TTS (commented out — large download ~2 GB)
  # Uncomment to enable the XTTS tab in the app:
  # "${APP_DIR}/.venv/bin/pip" install TTS

  log "Python packages installed."
}

########################################
# Step 4: write app.py (Gradio TTS UI)
########################################

write_app() {
  log "Writing ${APP_DIR}/app.py ..."
  cat > "${APP_DIR}/app.py" <<'PYTHON'
"""
Gradio TTS application — Kokoro backend.
Run: python app.py
Then open http://<VM-IP>:7860 in your browser (or via SSH tunnel).
"""

import io
import os
import tempfile

import gradio as gr
import numpy as np
import soundfile as sf
from pypdf import PdfReader

# ---------------------------------------------------------------------------
# Text extraction (mirrors ai_reader.py logic)
# ---------------------------------------------------------------------------

def read_text_from_file(path: str) -> str:
    if path.endswith(".pdf"):
        reader = PdfReader(path)
        return "\n".join(page.extract_text() or "" for page in reader.pages)
    else:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()


def chunk_text(text: str, max_chars: int = 4000) -> list[str]:
    """Split on paragraph boundaries, keeping chunks under max_chars."""
    paragraphs = [p.strip() for p in text.split("\n") if p.strip()]
    chunks, current = [], ""
    for para in paragraphs:
        if len(current) + len(para) + 1 <= max_chars:
            current = (current + "\n" + para).strip()
        else:
            if current:
                chunks.append(current)
            current = para
    if current:
        chunks.append(current)
    return chunks


# ---------------------------------------------------------------------------
# Kokoro TTS (loaded once at startup)
# ---------------------------------------------------------------------------

try:
    from kokoro import KPipeline
    _pipeline_cache: dict = {}

    def get_pipeline(lang: str = "en-us"):
        if lang not in _pipeline_cache:
            _pipeline_cache[lang] = KPipeline(lang_code=lang[:2])
        return _pipeline_cache[lang]

    KOKORO_AVAILABLE = True
except ImportError:
    KOKORO_AVAILABLE = False


def synthesize_kokoro(text: str, voice: str, lang: str, progress=None) -> str:
    if not KOKORO_AVAILABLE:
        raise RuntimeError("Kokoro is not installed. Run: pip install kokoro espeak-ng")

    pipeline = get_pipeline(lang)
    chunks = chunk_text(text)
    audio_parts: list[np.ndarray] = []
    sample_rate = 24000

    for i, chunk in enumerate(chunks):
        if progress:
            progress((i + 1) / len(chunks), desc=f"Chunk {i + 1}/{len(chunks)}")
        for _, _, audio in pipeline(chunk, voice=voice, speed=1.0):
            audio_parts.append(audio)

    combined = np.concatenate(audio_parts) if audio_parts else np.zeros(0)
    out_path = tempfile.mktemp(suffix=".wav")
    sf.write(out_path, combined, sample_rate)
    return out_path


# ---------------------------------------------------------------------------
# Gradio UI
# ---------------------------------------------------------------------------

VOICES = [
    "af_heart", "af_bella", "af_sarah",
    "am_adam", "am_michael",
    "bf_emma", "bm_george",
]

LANGS = {
    "English (US)": "en-us",
    "English (UK)": "en-gb",
    "Italian": "it",
    "French": "fr-fr",
    "Spanish": "es",
    "German": "de",
    "Japanese": "ja",
}


def convert(file_obj, voice: str, lang_label: str, progress=gr.Progress()):
    if file_obj is None:
        raise gr.Error("Please upload a PDF or TXT file.")
    lang = LANGS.get(lang_label, "en-us")
    text = read_text_from_file(file_obj.name)
    char_count = len(text)
    progress(0, desc=f"Loaded {char_count:,} characters — starting synthesis…")
    out_path = synthesize_kokoro(text, voice, lang, progress=progress)
    return out_path, f"Done — {char_count:,} characters converted."


with gr.Blocks(title="AI Hub — TTS") as demo:
    gr.Markdown("## Text-to-Speech (Kokoro)")

    with gr.Row():
        file_input = gr.File(label="Upload PDF or TXT", file_types=[".pdf", ".txt"])

    with gr.Row():
        voice_dd  = gr.Dropdown(choices=VOICES, value="af_heart",   label="Voice")
        lang_dd   = gr.Dropdown(choices=list(LANGS.keys()), value="English (US)", label="Language")

    convert_btn  = gr.Button("Convert", variant="primary")
    audio_out    = gr.Audio(label="Output audio", type="filepath")
    status_label = gr.Textbox(label="Status", interactive=False)

    convert_btn.click(
        fn=convert,
        inputs=[file_input, voice_dd, lang_dd],
        outputs=[audio_out, status_label],
    )

if __name__ == "__main__":
    demo.launch(
        server_name="0.0.0.0",
        server_port=int(os.environ.get("GRADIO_PORT", "7860")),
    )
PYTHON

  chown "${APP_USER}:${APP_USER}" "${APP_DIR}/app.py"
  log "app.py written."
}

########################################
# Step 5: systemd service (optional)
########################################

install_systemd_service() {
  log "Installing systemd service (tts-app.service)..."
  cat > /etc/systemd/system/tts-app.service <<EOF
[Unit]
Description=AI Hub TTS Gradio App
After=network.target

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/.venv/bin/python ${APP_DIR}/app.py
Restart=on-failure
RestartSec=5
Environment=GRADIO_PORT=${GRADIO_PORT}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable tts-app
  systemctl restart tts-app
  log "Service tts-app installed and started on port ${GRADIO_PORT}."
}

########################################
# Main
########################################

main() {
  require_root
  install_system_deps
  create_venv
  install_python_packages
  write_app
  install_systemd_service

  log ""
  log "=== TTS stack ready ==="
  log "  App dir : ${APP_DIR}"
  log "  Port    : ${GRADIO_PORT}"
  log "  Access  : ssh -L ${GRADIO_PORT}:localhost:${GRADIO_PORT} ubuntu@<EIP>"
  log "            then open http://localhost:${GRADIO_PORT}"
  log ""
  log "  Status  : sudo systemctl status tts-app"
  log "  Logs    : sudo journalctl -fu tts-app"
}

main "$@"
