#!/usr/bin/env bash
set -euo pipefail

########################################
# ASR (speech-to-text) stack provisioner
#
# Installs a Gradio app that turns audio, video, or a YouTube URL into text
# using an automatic speech recognition (ASR) model. Audio is extracted with
# ffmpeg and YouTube links are fetched with yt-dlp, so you can drop in an .mp3,
# an .mp4, or paste a video URL and get back a transcript (+ .txt / .srt).
#
# Selectable backend model via ASR_MODEL:
#   whisper-large-v3  -> openai/whisper-large-v3            (multilingual incl.
#                        Italian; ~3-5 GB VRAM; great long-form; DEFAULT)
#   granite-8b        -> ibm-granite/granite-speech-3.3-8b  (EN/FR/DE/ES/PT only,
#                        no Italian; ~16-18 GB VRAM; heavier)
#
# Assumes Docker/NVIDIA + system tools were set up by provision_llm_stack.sh.
# The DLAMI already ships CUDA + PyTorch, which the venv reuses via
# --system-site-packages.
#
# Usage:
#   sudo bash provision_asr_stack.sh [app-dir]
#   sudo ASR_MODEL=granite-8b bash provision_asr_stack.sh
#
# Default app dir: /opt/asr
########################################

ASR_NAME="${ASR_NAME:-asr}"
ASR_DIR="${1:-${ASR_DIR:-/opt/${ASR_NAME}}}"
ASR_USER="${ASR_USER:-ubuntu}"
ASR_GROUP="${ASR_GROUP:-ubuntu}"
ASR_PORT="${ASR_PORT:-7864}"
ASR_MODEL="${ASR_MODEL:-whisper-large-v3}"

# Shared HF cache so the model downloaded as root during provisioning is
# readable by the service user at runtime.
HF_CACHE="${ASR_DIR}/hf-cache"

log() {
  echo -e "[provision_asr_stack] $*"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log "This script must run as root (use: sudo $0)"
    exit 1
  fi
}

########################################
# Step 1: system deps (ffmpeg for audio IO, venv/pip)
########################################

install_system_deps() {
  log "Installing system-level deps (ffmpeg, python3-venv, python3-pip)..."
  apt-get update -y
  apt-get install -y ffmpeg python3-venv python3-pip
  log "System deps installed."
}

########################################
# Step 2: Python virtual environment
########################################

create_venv() {
  log "Creating Python venv in ${ASR_DIR}/.venv ..."
  mkdir -p "${ASR_DIR}"
  if [[ ! -d "${ASR_DIR}/.venv" ]]; then
    # --system-site-packages reuses the GPU PyTorch shipped with the DLAMI
    # instead of pulling a CPU-only torch via pip.
    python3 -m venv --system-site-packages "${ASR_DIR}/.venv"
    log "Venv created (with system site-packages for GPU torch)."
  else
    log "Venv already exists, skipping creation."
  fi
}

########################################
# Step 3: Python packages
########################################

install_python_packages() {
  log "Installing Python packages into venv (model=${ASR_MODEL})..."
  "${ASR_DIR}/.venv/bin/pip" install --upgrade pip

  # Shared deps: Gradio UI, YouTube download, audio IO, recent transformers.
  #
  # Gradio is PINNED to a recent 6.x. Two reasons:
  #  1) The venv uses --system-site-packages, so an UNPINNED `gradio` is treated
  #     as already satisfied by the OLD gradio (<4.0) the DLAMI ships and is
  #     never upgraded (that old build lacks e.g. Textbox(show_copy_button=...)).
  #  2) Gradio 6 ships gradio_client 2.5.0 (fixes the "argument of type 'bool'
  #     is not iterable" API-schema crash) and is written against the modern
  #     starlette 1.x TemplateResponse API. Older gradio 4.x paired with the
  #     newer starlette that pip pulls in crashed with
  #     "TypeError: unhashable type: 'dict'" in jinja2, surfacing as the
  #     misleading "localhost is not accessible" launch error. Pinning gradio 6
  #     makes it install a self-consistent fastapi/starlette/gradio_client set
  #     into the venv. (Known gradio issues: #10813, #11090, #11116, #11722.)
  #
  # jinja2 and markupsafe are pinned ABOVE the versions Ubuntu 22.04 ships in
  # /usr/lib/python3/dist-packages (jinja2 3.0.x, markupsafe 2.0.1). Because of
  # --system-site-packages, an unconstrained requirement would be considered
  # already satisfied by those stale system copies and never installed into the
  # venv; the higher floor forces pip to put modern ones in the venv so they
  # shadow the system packages at runtime.
  "${ASR_DIR}/.venv/bin/pip" install \
    "gradio==6.17.3" \
    "jinja2>=3.1" \
    "markupsafe>=2.1.1" \
    "yt-dlp" \
    soundfile \
    librosa \
    accelerate \
    "transformers>=4.52.4,<5"

  # torchaudio matching the DLAMI's torch (used to load/resample audio tensors).
  # Newer torch (e.g. 2.12) may not yet have a same-versioned torchaudio wheel;
  # fall back to the latest torchaudio in that case (mismatch is tolerated; the
  # default Whisper path uses librosa/soundfile, not torchaudio, for IO).
  TORCH_VER="$("${ASR_DIR}/.venv/bin/python" -c 'import torch; print(torch.__version__.split("+")[0])')"
  "${ASR_DIR}/.venv/bin/pip" install "torchaudio==${TORCH_VER}" || \
    "${ASR_DIR}/.venv/bin/pip" install torchaudio

  # Granite uses a LoRA adapter applied at load time -> needs peft.
  if [[ "${ASR_MODEL}" == "granite-8b" ]]; then
    "${ASR_DIR}/.venv/bin/pip" install peft
  fi

  log "Python packages installed."
}

########################################
# Step 4: write the Gradio app
########################################

write_app() {
  log "Writing ${ASR_DIR}/app.py ..."
  cat > "${ASR_DIR}/app.py" <<'PYTHON'
"""
Gradio ASR (speech-to-text) application.

Inputs (use whichever is handiest):
  - Upload an audio file (mp3/wav/m4a/...)
  - Upload a video file (mp4/mkv/...) -> audio is extracted with ffmpeg
  - Paste a YouTube (or other yt-dlp supported) URL -> audio is downloaded

Output: the transcript as text, plus downloadable .txt and (Whisper) .srt.

The backend model is chosen at provisioning time via the ASR_MODEL env var:
  whisper-large-v3  -> openai/whisper-large-v3            (multilingual)
  granite-8b        -> ibm-granite/granite-speech-3.3-8b  (EN/FR/DE/ES/PT)

The model is loaded lazily on first transcription to keep startup fast and
VRAM free until actually used.
"""

import os
import subprocess
import tempfile

import gradio as gr

ASR_MODEL = os.environ.get("ASR_MODEL", "whisper-large-v3")

MODEL_IDS = {
    "whisper-large-v3": "openai/whisper-large-v3",
    "granite-8b": "ibm-granite/granite-speech-3.3-8b",
}
MODEL_ID = MODEL_IDS.get(ASR_MODEL, MODEL_IDS["whisper-large-v3"])
IS_WHISPER = ASR_MODEL.startswith("whisper")

# Target sample rate expected by the ASR models (16 kHz mono).
SAMPLE_RATE = 16000

# A small, curated language list for the UI. "Auto" lets Whisper detect it.
LANGUAGES = {
    "Auto-detect": None,
    "Italian": "it",
    "English": "en",
    "French": "fr",
    "German": "de",
    "Spanish": "es",
    "Portuguese": "pt",
}


# ---------------------------------------------------------------------------
# Audio acquisition / normalization
# ---------------------------------------------------------------------------

def _ffmpeg_to_wav(src_path: str) -> str:
    """Extract/convert any audio or video file to 16 kHz mono WAV via ffmpeg."""
    out_path = tempfile.mktemp(suffix=".wav")
    # List args (no shell) to avoid any command injection from file names.
    subprocess.run(
        [
            "ffmpeg", "-y", "-i", src_path,
            "-ac", "1", "-ar", str(SAMPLE_RATE),
            "-vn", out_path,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return out_path


def _download_youtube(url: str) -> str:
    """Download bestaudio from a URL with yt-dlp and return a 16 kHz mono WAV."""
    tmp_dir = tempfile.mkdtemp()
    out_tmpl = os.path.join(tmp_dir, "audio.%(ext)s")
    # yt-dlp extracts audio to wav; args passed as a list (no shell).
    subprocess.run(
        [
            "yt-dlp",
            "-f", "bestaudio/best",
            "-x", "--audio-format", "wav",
            "--no-playlist",
            "-o", out_tmpl,
            url,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    wav = os.path.join(tmp_dir, "audio.wav")
    if not os.path.exists(wav):
        # Some sources land on a different extension; normalize whatever we got.
        produced = [f for f in os.listdir(tmp_dir) if f.startswith("audio.")]
        if not produced:
            raise RuntimeError("yt-dlp produced no audio file.")
        wav = _ffmpeg_to_wav(os.path.join(tmp_dir, produced[0]))
    else:
        wav = _ffmpeg_to_wav(wav)  # force 16 kHz mono
    return wav


def resolve_audio(audio_path, video_path, youtube_url) -> str:
    """Return a path to a normalized 16 kHz mono WAV from whichever input is set."""
    if youtube_url and youtube_url.strip():
        return _download_youtube(youtube_url.strip())
    if video_path:
        return _ffmpeg_to_wav(video_path)
    if audio_path:
        return _ffmpeg_to_wav(audio_path)
    raise gr.Error("Provide an audio file, a video file, or a YouTube URL.")


# ---------------------------------------------------------------------------
# SRT helpers (Whisper returns word/segment timestamps)
# ---------------------------------------------------------------------------

def _fmt_ts(seconds: float) -> str:
    if seconds is None:
        seconds = 0.0
    ms = int(round(seconds * 1000))
    h, ms = divmod(ms, 3600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def chunks_to_srt(chunks) -> str:
    lines = []
    for i, ch in enumerate(chunks, start=1):
        start, end = ch.get("timestamp", (None, None))
        lines.append(str(i))
        lines.append(f"{_fmt_ts(start)} --> {_fmt_ts(end)}")
        lines.append((ch.get("text") or "").strip())
        lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Engine: Whisper (transformers pipeline, multilingual, long-form via chunking)
# ---------------------------------------------------------------------------

_whisper_pipe = None


def _get_whisper():
    global _whisper_pipe
    if _whisper_pipe is None:
        import torch
        from transformers import pipeline
        _whisper_pipe = pipeline(
            "automatic-speech-recognition",
            model=MODEL_ID,
            torch_dtype=torch.float16,
            device="cuda" if torch.cuda.is_available() else "cpu",
            chunk_length_s=30,
            batch_size=8,
        )
    return _whisper_pipe


def transcribe_whisper(wav_path, lang_code, task):
    pipe = _get_whisper()
    generate_kwargs = {"task": task}
    if lang_code:
        generate_kwargs["language"] = lang_code
    result = pipe(wav_path, return_timestamps=True, generate_kwargs=generate_kwargs)
    text = (result.get("text") or "").strip()
    srt = chunks_to_srt(result.get("chunks") or [])
    return text, srt


# ---------------------------------------------------------------------------
# Engine: Granite (transformers, EN/FR/DE/ES/PT). Long audio is chunked to ~30s
# windows so it stays within the model's effective context.
# ---------------------------------------------------------------------------

_granite = {"model": None, "processor": None}


def _get_granite():
    if _granite["model"] is None:
        import torch
        from transformers import AutoProcessor, AutoModelForSpeechSeq2Seq
        _granite["processor"] = AutoProcessor.from_pretrained(MODEL_ID)
        _granite["model"] = AutoModelForSpeechSeq2Seq.from_pretrained(
            MODEL_ID, device_map="cuda", torch_dtype=torch.bfloat16
        )
    return _granite["model"], _granite["processor"]


def transcribe_granite(wav_path, lang_code, task):
    import torch
    import torchaudio

    model, processor = _get_granite()
    tokenizer = processor.tokenizer

    wav, sr = torchaudio.load(wav_path, normalize=True)
    if wav.shape[0] > 1:
        wav = wav.mean(dim=0, keepdim=True)
    if sr != SAMPLE_RATE:
        wav = torchaudio.functional.resample(wav, sr, SAMPLE_RATE)

    window = 30 * SAMPLE_RATE  # ~30s windows
    total = wav.shape[1]
    pieces = []
    system_prompt = (
        "You are Granite, developed by IBM. You are a helpful AI assistant."
    )
    user_prompt = "<|audio|>can you transcribe the speech into a written format?"

    for start in range(0, total, window):
        seg = wav[:, start:start + window]
        if seg.shape[1] == 0:
            continue
        chat = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]
        prompt = tokenizer.apply_chat_template(
            chat, tokenize=False, add_generation_prompt=True
        )
        inputs = processor(prompt, seg, device="cuda", return_tensors="pt").to("cuda")
        with torch.no_grad():
            out = model.generate(
                **inputs, max_new_tokens=400, do_sample=False, num_beams=1
            )
        n_in = inputs["input_ids"].shape[-1]
        new_tokens = out[:, n_in:]
        piece = tokenizer.batch_decode(
            new_tokens, add_special_tokens=False, skip_special_tokens=True
        )[0].strip()
        if piece:
            pieces.append(piece)

    return " ".join(pieces).strip(), ""


# ---------------------------------------------------------------------------
# Gradio callback
# ---------------------------------------------------------------------------

def transcribe(audio_path, video_path, youtube_url, language_label, task, progress=gr.Progress()):
    progress(0.05, desc="Preparing audio...")
    wav_path = resolve_audio(audio_path, video_path, youtube_url)

    lang_code = LANGUAGES.get(language_label)
    progress(0.4, desc=f"Transcribing with {ASR_MODEL}...")

    if IS_WHISPER:
        text, srt = transcribe_whisper(wav_path, lang_code, task)
    else:
        text, srt = transcribe_granite(wav_path, lang_code, task)

    if not text:
        raise gr.Error("No speech was transcribed. Try a different input.")

    txt_file = tempfile.mktemp(suffix=".txt")
    with open(txt_file, "w", encoding="utf-8") as f:
        f.write(text)

    srt_file = None
    if srt:
        srt_file = tempfile.mktemp(suffix=".srt")
        with open(srt_file, "w", encoding="utf-8") as f:
            f.write(srt)

    progress(1.0, desc="Done")
    return text, txt_file, srt_file


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

with gr.Blocks(title="AI Hub — Speech-to-Text") as demo:
    gr.Markdown(
        f"# Speech-to-Text\n"
        f"Upload **audio** or **video**, or paste a **YouTube URL**, and get a transcript.\n\n"
        f"**Model:** `{MODEL_ID}`"
    )
    with gr.Row():
        with gr.Column():
            audio_in = gr.Audio(label="Audio file", type="filepath", sources=["upload", "microphone"])
            video_in = gr.Video(label="Video file (audio is extracted)")
            youtube_in = gr.Textbox(label="YouTube / video URL", placeholder="https://www.youtube.com/watch?v=...")
            language_in = gr.Dropdown(
                label="Language", choices=list(LANGUAGES.keys()),
                value="Auto-detect" if IS_WHISPER else "English",
            )
            task_in = gr.Radio(
                label="Task", choices=["transcribe", "translate"], value="transcribe",
                visible=IS_WHISPER,
                info="translate = output English (Whisper only)",
            )
            go = gr.Button("Transcribe", variant="primary")
        with gr.Column():
            text_out = gr.Textbox(label="Transcript", lines=18)
            txt_dl = gr.File(label="Download .txt")
            srt_dl = gr.File(label="Download .srt (subtitles)", visible=IS_WHISPER)

    go.click(
        transcribe,
        inputs=[audio_in, video_in, youtube_in, language_in, task_in],
        outputs=[text_out, txt_dl, srt_dl],
    )


if __name__ == "__main__":
    port = int(os.environ.get("ASR_PORT", "7864"))
    demo.queue().launch(server_name="0.0.0.0", server_port=port)
PYTHON

  log "App written."
}

########################################
# Step 5: pre-download the model into the shared cache
########################################

download_model() {
  log "Pre-downloading model ${MODEL_ID} into ${HF_CACHE} ..."
  mkdir -p "${HF_CACHE}"
  HF_HOME="${HF_CACHE}" ASR_MODEL="${ASR_MODEL}" "${ASR_DIR}/.venv/bin/python" - <<PY || log "Model pre-download failed (non-fatal); the service will download on first use."
import os
from huggingface_hub import snapshot_download
ids = {
    "whisper-large-v3": "openai/whisper-large-v3",
    "granite-8b": "ibm-granite/granite-speech-3.3-8b",
}
model_id = ids.get(os.environ.get("ASR_MODEL", "whisper-large-v3"), ids["whisper-large-v3"])
snapshot_download(model_id)
print("Model downloaded:", model_id)
PY
}

########################################
# Step 6: systemd service
########################################

install_systemd_service() {
  log "Installing systemd service (${ASR_NAME}.service)..."

  cat > "/etc/systemd/system/${ASR_NAME}.service" <<EOF
[Unit]
Description=ASR speech-to-text (${MODEL_ID}, Gradio UI)
After=network.target

[Service]
User=${ASR_USER}
WorkingDirectory=${ASR_DIR}
Environment=HF_HOME=${HF_CACHE}
Environment=ASR_MODEL=${ASR_MODEL}
Environment=ASR_PORT=${ASR_PORT}
ExecStart=${ASR_DIR}/.venv/bin/python ${ASR_DIR}/app.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${ASR_NAME}"
  systemctl restart "${ASR_NAME}"
  log "Service ${ASR_NAME} installed and started on port ${ASR_PORT}."
}

# Resolve the model id once for messages/service (mirrors app.py mapping).
case "${ASR_MODEL}" in
  granite-8b)       MODEL_ID="ibm-granite/granite-speech-3.3-8b" ;;
  whisper-large-v3) MODEL_ID="openai/whisper-large-v3" ;;
  *)                MODEL_ID="openai/whisper-large-v3" ;;
esac

########################################
# Main
########################################

main() {
  require_root
  install_system_deps
  create_venv
  install_python_packages
  write_app
  download_model

  # Hand the whole tree to the service user so it can write caches at runtime.
  chown -R "${ASR_USER}:${ASR_GROUP}" "${ASR_DIR}"

  install_systemd_service

  log ""
  log "=== ASR speech-to-text stack ready ==="
  log "  App dir : ${ASR_DIR}"
  log "  Model   : ${MODEL_ID}"
  log "  Port    : ${ASR_PORT}"
  log "  Access  : http://<EIP>:${ASR_PORT}"
  log ""
  log "  Status  : sudo systemctl status ${ASR_NAME}"
  log "  Logs    : sudo journalctl -fu ${ASR_NAME}"
}

main "$@"
