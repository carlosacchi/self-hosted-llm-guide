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
    espeak-ng   # phoneme backend required by Kokoro and Piper
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
    # --system-site-packages lets the venv reuse the GPU PyTorch
    # already shipped with the AWS Deep Learning AMI, instead of
    # pulling a CPU-only torch via pip.
    python3 -m venv --system-site-packages "${APP_DIR}/.venv"
    log "Venv created (with system site-packages for GPU torch)."
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

  # Core deps (shared + Kokoro engine)
  "${APP_DIR}/.venv/bin/pip" install \
    gradio \
    pypdf \
    kokoro \
    soundfile \
    numpy

  # XTTS-v2 (Coqui TTS): multilingual + voice cloning. ~2 GB of deps.
  # Pinned fork 'coqui-tts' is the maintained successor of the original 'TTS'.
  # The [codec] extra pulls 'torchcodec', required for audio IO from torch 2.9+.
  "${APP_DIR}/.venv/bin/pip" install "coqui-tts[codec]"

  # XTTS needs torchaudio. The DLAMI ships torch (reused via system-site-packages)
  # but not torchaudio, so install a build matching the existing torch version.
  TORCH_VER="$("${APP_DIR}/.venv/bin/python" -c 'import torch; print(torch.__version__.split("+")[0])')"
  "${APP_DIR}/.venv/bin/pip" install "torchaudio==${TORCH_VER}" || \
    "${APP_DIR}/.venv/bin/pip" install torchaudio

  # XTTS needs a recent 'transformers' (>=4.42 for isin_mps_friendly). The DLAMI
  # ships an older one via system-site-packages; install a compatible version
  # into the venv so it shadows the system package.
  "${APP_DIR}/.venv/bin/pip" install "transformers>=4.42,<5"

  # Piper: very light, fast, CPU-friendly.
  "${APP_DIR}/.venv/bin/pip" install piper-tts

  # Kokoro's English G2P (misaki) needs this spaCy model. Pre-install it here
  # as root, otherwise misaki tries to download it at runtime as the 'ubuntu'
  # service user and fails with a permission error.
  "${APP_DIR}/.venv/bin/python" -m spacy download en_core_web_sm

  # The venv is created with sudo (root). Hand it back to the service user so
  # it can write caches at runtime.
  chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}/.venv"

  log "Python packages installed."
}

########################################
# Step 3b: Piper voice models
# (Piper needs .onnx voice files downloaded separately)
########################################

download_piper_voices() {
  local voices_dir="${APP_DIR}/piper_voices"
  log "Downloading Piper voice models into ${voices_dir} ..."
  mkdir -p "${voices_dir}"

  # English (US) and Italian medium-quality voices from the official HF repo.
  "${APP_DIR}/.venv/bin/python" -m piper.download_voices \
    --download-dir "${voices_dir}" \
    en_US-lessac-medium it_IT-paola-medium || \
    log "Piper voice download failed (non-fatal). Piper tab may be unavailable."

  chown -R "${APP_USER}:${APP_USER}" "${voices_dir}"
  log "Piper voices ready."
}

########################################
# Step 4: write app.py (Gradio TTS UI)
########################################

write_app() {
  log "Writing ${APP_DIR}/app.py ..."
  cat > "${APP_DIR}/app.py" <<'PYTHON'
"""
Gradio multi-engine TTS application.

Engines (loaded lazily, only on first use, to save VRAM):
  - Kokoro  : tiny, very fast, preset voices
  - XTTS-v2 : multilingual, voice cloning from a short audio sample
  - Piper   : ultra-light, CPU-friendly, preset voices

Run: python app.py
Then open http://<VM-IP>:7860 in your browser (or via SSH tunnel).
"""

import os
import glob
import tempfile
import traceback

import gradio as gr
import numpy as np
import soundfile as sf
from pypdf import PdfReader

# XTTS-v2 (Coqui) requires accepting its non-commercial license at runtime.
os.environ.setdefault("COQUI_TOS_AGREED", "1")

APP_DIR = os.path.dirname(os.path.abspath(__file__))
PIPER_VOICES_DIR = os.path.join(APP_DIR, "piper_voices")


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


def _to_numpy(audio):
    # Models may return a torch tensor; soundfile needs a numpy array.
    if hasattr(audio, "detach"):
        audio = audio.detach().cpu().numpy()
    return np.asarray(audio, dtype=np.float32)


def _write_wav(samples: np.ndarray, sample_rate: int) -> str:
    out_path = tempfile.mktemp(suffix=".wav")
    sf.write(out_path, samples, sample_rate)
    return out_path


# ===========================================================================
# Engine: Kokoro
#
# Single-letter language codes: a=US, b=UK, i=IT, f=FR, e=ES, p=PT-BR, j=JA
# Voices are prefixed by language+gender, e.g. af_heart -> (a)merican (f)emale.
# ===========================================================================

KOKORO_VOICES = [
    "af_heart", "af_bella", "af_sarah",   # American English (female)
    "am_adam", "am_michael",              # American English (male)
    "bf_emma", "bm_george",               # British English
    "if_sara", "im_nicola",               # Italian
]

KOKORO_LANGS = {
    "English (US)": "a",
    "English (UK)": "b",
    "Italian": "i",
    "French": "f",
    "Spanish": "e",
    "Portuguese (BR)": "p",
    "Japanese": "j",
}

_kokoro_cache: dict = {}


def _kokoro_pipeline(lang_code: str):
    from kokoro import KPipeline
    if lang_code not in _kokoro_cache:
        _kokoro_cache[lang_code] = KPipeline(lang_code=lang_code)
    return _kokoro_cache[lang_code]


def synth_kokoro(text, voice, lang_label, speaker_wav, progress):
    lang_code = KOKORO_LANGS.get(lang_label, "a")
    if voice[0] != lang_code:
        raise gr.Error(
            f"Voice '{voice}' does not match language '{lang_label}'. "
            f"Pick a voice starting with '{lang_code}'."
        )
    pipeline = _kokoro_pipeline(lang_code)
    chunks = chunk_text(text)
    parts = []
    for i, chunk in enumerate(chunks):
        progress((i + 1) / len(chunks), desc=f"[Kokoro] chunk {i + 1}/{len(chunks)}")
        for _, _, audio in pipeline(chunk, voice=voice, speed=1.0):
            parts.append(_to_numpy(audio))
    if not parts:
        raise RuntimeError("Kokoro produced no audio.")
    return _write_wav(np.concatenate(parts), 24000)


# ===========================================================================
# Engine: XTTS-v2 (Coqui) — multilingual + voice cloning
# ===========================================================================

XTTS_LANGS = {
    "English (US)": "en",
    "English (UK)": "en",
    "Italian": "it",
    "French": "fr",
    "Spanish": "es",
    "Portuguese (BR)": "pt",
    "Japanese": "ja",
}

# Built-in XTTS speakers (used when no cloning sample is provided).
XTTS_VOICES = ["Claribel Dervla", "Daisy Studious", "Andrew Chipper", "Damien Black"]

_xtts_cache: dict = {}


def _xtts_model():
    import torch
    from TTS.api import TTS
    if "model" not in _xtts_cache:
        device = "cuda" if torch.cuda.is_available() else "cpu"
        _xtts_cache["model"] = TTS(
            "tts_models/multilingual/multi-dataset/xtts_v2"
        ).to(device)
    return _xtts_cache["model"]


def _prepare_speaker_wav(path: str) -> str:
    """Convert any uploaded sample (m4a/mp3/...) to 22.05kHz mono WAV via ffmpeg.

    XTTS reads the reference clip with torchaudio, which does not reliably
    decode compressed formats like .m4a. Normalising to WAV avoids that.
    """
    import subprocess
    if path.lower().endswith(".wav"):
        return path
    out_path = tempfile.mktemp(suffix=".wav")
    subprocess.run(
        ["ffmpeg", "-y", "-i", path, "-ac", "1", "-ar", "22050", out_path],
        check=True,
        capture_output=True,
    )
    return out_path


def synth_xtts(text, voice, lang_label, speaker_wav, progress):
    lang = XTTS_LANGS.get(lang_label, "en")
    model = _xtts_model()
    if speaker_wav:
        speaker_wav = _prepare_speaker_wav(speaker_wav)
    chunks = chunk_text(text, max_chars=1000)  # XTTS prefers shorter chunks
    parts = []
    for i, chunk in enumerate(chunks):
        progress((i + 1) / len(chunks), desc=f"[XTTS] chunk {i + 1}/{len(chunks)}")
        kwargs = dict(text=chunk, language=lang)
        if speaker_wav:
            kwargs["speaker_wav"] = speaker_wav   # voice cloning
        else:
            kwargs["speaker"] = voice             # built-in speaker
        wav = model.tts(**kwargs)
        parts.append(_to_numpy(wav))
    if not parts:
        raise RuntimeError("XTTS produced no audio.")
    return _write_wav(np.concatenate(parts), 24000)


# ===========================================================================
# Engine: Piper — ultra-light, CPU-friendly
# ===========================================================================

def _piper_voice_files() -> dict:
    """Map a friendly name to its .onnx model file."""
    voices = {}
    for onnx in glob.glob(os.path.join(PIPER_VOICES_DIR, "*.onnx")):
        name = os.path.basename(onnx).replace(".onnx", "")
        voices[name] = onnx
    return voices


PIPER_VOICES = list(_piper_voice_files().keys()) or ["(no voices installed)"]

_piper_cache: dict = {}


def _piper_load(model_path: str):
    from piper import PiperVoice
    if model_path not in _piper_cache:
        _piper_cache[model_path] = PiperVoice.load(model_path)
    return _piper_cache[model_path]


def synth_piper(text, voice, lang_label, speaker_wav, progress):
    files = _piper_voice_files()
    if voice not in files:
        raise gr.Error("No Piper voice installed. Re-run the provisioning script.")
    pv = _piper_load(files[voice])
    chunks = chunk_text(text)
    parts = []
    rate = pv.config.sample_rate
    for i, chunk in enumerate(chunks):
        progress((i + 1) / len(chunks), desc=f"[Piper] chunk {i + 1}/{len(chunks)}")
        for audio_chunk in pv.synthesize(chunk):
            arr = np.frombuffer(audio_chunk.audio_int16_bytes, dtype=np.int16)
            parts.append(arr.astype(np.float32) / 32768.0)
    if not parts:
        raise RuntimeError("Piper produced no audio.")
    return _write_wav(np.concatenate(parts), rate)


# ===========================================================================
# Engine registry
# ===========================================================================

ENGINES = {
    "Kokoro (fast)":            {"fn": synth_kokoro, "voices": KOKORO_VOICES, "cloning": False},
    "XTTS-v2 (clone/quality)":  {"fn": synth_xtts,   "voices": XTTS_VOICES,   "cloning": True},
    "Piper (lightweight)":      {"fn": synth_piper,  "voices": PIPER_VOICES,  "cloning": False},
}

LANG_CHOICES = list(KOKORO_LANGS.keys())

# Rough synthesis throughput (characters per second) on a single GPU.
# Used only to give the user an up-front time estimate; not exact.
ENGINE_CPS = {
    "Kokoro (fast)": 600.0,
    "XTTS-v2 (clone/quality)": 120.0,
    "Piper (lightweight)": 800.0,
}


def _format_duration(seconds: float) -> str:
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    m, s = divmod(seconds, 60)
    if m < 60:
        return f"{m}m {s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h {m:02d}m"


def _estimate_line(char_count: int, engine_name: str) -> str:
    cps = ENGINE_CPS.get(engine_name, 300.0)
    eta = _format_duration(char_count / cps)
    return f"~{eta} with {engine_name}"


def estimate(file_obj, engine_name):
    """Runs on file upload / engine change: count chars and estimate time."""
    if file_obj is None:
        return "Upload a PDF or TXT to see size and time estimate."
    try:
        text = read_text_from_file(file_obj.name)
    except Exception as exc:
        return f"Could not read file: {exc}"
    char_count = len(text)
    word_count = len(text.split())
    if char_count == 0:
        return "File appears empty or has no extractable text (scanned PDF?)."
    lines = [
        f"{char_count:,} characters · {word_count:,} words",
        "Estimated synthesis time:",
    ]
    for name in ENGINES:
        marker = "→ " if name == engine_name else "   "
        lines.append(f"{marker}{_estimate_line(char_count, name)}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Gradio UI
# ---------------------------------------------------------------------------

def on_engine_change(engine_name):
    cfg = ENGINES[engine_name]
    return (
        gr.update(choices=cfg["voices"], value=cfg["voices"][0]),
        gr.update(visible=cfg["cloning"]),
    )


def convert(file_obj, engine_name, voice, lang_label, speaker_audio, progress=gr.Progress()):
    try:
        if file_obj is None:
            raise gr.Error("Please upload a PDF or TXT file.")

        text = read_text_from_file(file_obj.name)
        char_count = len(text)
        if char_count == 0:
            raise gr.Error("The uploaded file appears to be empty or unreadable.")

        cfg = ENGINES[engine_name]
        speaker_wav = speaker_audio if (cfg["cloning"] and speaker_audio) else None

        eta = _format_duration(char_count / ENGINE_CPS.get(engine_name, 300.0))
        progress(
            0,
            desc=f"{char_count:,} chars · est. ~{eta} — starting {engine_name}…",
        )
        import time as _time
        _t0 = _time.time()
        out_path = cfg["fn"](text, voice, lang_label, speaker_wav, progress)
        elapsed = _format_duration(_time.time() - _t0)
        return out_path, f"Done — {char_count:,} characters via {engine_name} in {elapsed}."
    except gr.Error:
        raise
    except Exception as exc:  # surface the real error instead of a blank "Error"
        traceback.print_exc()  # full traceback goes to journalctl -fu tts-app
        return None, f"FAILED: {type(exc).__name__}: {exc}"


with gr.Blocks(title="AI Hub — TTS") as demo:
    gr.Markdown("## Text-to-Speech")

    file_input = gr.File(label="Upload PDF or TXT", file_types=[".pdf", ".txt"])

    with gr.Row():
        engine_dd = gr.Dropdown(
            choices=list(ENGINES.keys()),
            value="Kokoro (fast)",
            label="Engine",
        )
        voice_dd = gr.Dropdown(
            choices=KOKORO_VOICES, value=KOKORO_VOICES[0], label="Voice",
        )
        lang_dd = gr.Dropdown(
            choices=LANG_CHOICES, value="English (US)", label="Language",
        )

    speaker_audio = gr.Audio(
        label="Voice cloning sample (XTTS only, ~6–20s of clean speech)",
        type="filepath",
        visible=False,
    )

    estimate_box = gr.Textbox(
        label="File size & time estimate",
        value="Upload a PDF or TXT to see size and time estimate.",
        interactive=False,
        lines=5,
    )

    convert_btn  = gr.Button("Convert", variant="primary")
    audio_out    = gr.Audio(label="Output audio", type="filepath")
    status_label = gr.Textbox(label="Status", interactive=False)

    engine_dd.change(
        fn=on_engine_change,
        inputs=engine_dd,
        outputs=[voice_dd, speaker_audio],
    )

    # Update the size/time estimate whenever the file or engine changes.
    file_input.change(
        fn=estimate,
        inputs=[file_input, engine_dd],
        outputs=estimate_box,
    )
    engine_dd.change(
        fn=estimate,
        inputs=[file_input, engine_dd],
        outputs=estimate_box,
    )

    convert_btn.click(
        fn=convert,
        inputs=[file_input, engine_dd, voice_dd, lang_dd, speaker_audio],
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
  download_piper_voices
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
