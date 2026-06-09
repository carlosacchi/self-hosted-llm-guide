#!/usr/bin/env bash
set -euo pipefail

########################################
# Landing page (portal) provisioner
#
# Serves a single static index page on port 80 that lists every service in
# the lab with a clickable link, so you can open http://<EIP>/ and jump to
# Open WebUI, the TTS lab, VibeVoice, Netdata, etc. from one place.
#
# Links are built in the browser from window.location.hostname, so the page
# works on any IP/host without baking the address in. Served by nginx.
#
# Access on port 80 is restricted to your IP by the security group
# (see infra/compute.tf).
#
# Usage:
#   sudo bash provision_landing_stack.sh
########################################

LANDING_PORT="${LANDING_PORT:-80}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

log() {
  echo -e "[provision_landing_stack] $*"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    log "This script must run as root (use: sudo $0)"
    exit 1
  fi
}

########################################
# Step 1: install nginx
########################################

install_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    log "nginx already installed, skipping apt install."
  else
    log "Installing nginx..."
    apt-get update -y
    apt-get install -y nginx
  fi
}

########################################
# Step 2: write the portal page
#
# The service list is rendered client-side from a JS array. Each link is
# built as <protocol>//<current-host>:<port>, so the page is host-agnostic.
########################################

write_page() {
  log "Writing portal page to ${WEB_ROOT}/index.html ..."
  mkdir -p "${WEB_ROOT}"

  # Remove the default nginx welcome page so it can't shadow ours.
  rm -f "${WEB_ROOT}/index.nginx-debian.html"

  cat > "${WEB_ROOT}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>AI Hub — Service Portal</title>
  <style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      background: #0d1117;
      color: #e6edf3;
      min-height: 100vh;
    }
    header {
      padding: 40px 24px 8px;
      max-width: 1000px;
      margin: 0 auto;
    }
    h1 { margin: 0 0 4px; font-size: 1.8rem; }
    .sub { color: #8b949e; font-size: 0.95rem; }
    main {
      max-width: 1000px;
      margin: 0 auto;
      padding: 24px;
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
      gap: 16px;
    }
    a.card {
      display: block;
      text-decoration: none;
      color: inherit;
      background: #161b22;
      border: 1px solid #30363d;
      border-radius: 12px;
      padding: 18px 20px;
      transition: border-color .15s, transform .15s;
    }
    a.card:hover { border-color: #58a6ff; transform: translateY(-2px); }
    .card .name { font-size: 1.1rem; font-weight: 600; margin-bottom: 6px; }
    .card .desc { color: #8b949e; font-size: 0.88rem; line-height: 1.4; }
    .card .url  { margin-top: 12px; font-size: 0.82rem; color: #58a6ff; word-break: break-all; }
    .tag {
      display: inline-block; font-size: 0.7rem; font-weight: 600;
      padding: 2px 8px; border-radius: 999px; margin-left: 8px;
      background: #1f6feb33; color: #58a6ff; vertical-align: middle;
    }
    footer { max-width: 1000px; margin: 0 auto; padding: 8px 24px 40px; color: #6e7681; font-size: 0.8rem; }
  </style>
</head>
<body>
  <header>
    <h1>AI Hub — Service Portal</h1>
    <div class="sub">Self-hosted LLM lab · click a service to open it</div>
  </header>
  <main id="grid"></main>
  <footer>Links point to this host on the listed port. Disabled stacks are not shown.</footer>

  <script>
    // Each entry: name, description, port, optional tag.
    const SERVICES = [
      { name: "Open WebUI",            desc: "Chat with the local LLMs (llama3.2, qwen3.5, qwen2.5-coder) via Ollama.", port: 3000 },
      { name: "TTS Lab",               desc: "Multi-engine text-to-speech (Kokoro · XTTS · Piper). Text/PDF → audio.", port: 7860 },
      { name: "VibeVoice 1.5B",        desc: "Multi-speaker long-form / podcast TTS with voice cloning.", port: 7861 },
      { name: "Netdata Monitoring",    desc: "Live GPU / CPU / RAM / disk / network dashboard.", port: 19999 },
      { name: "Ollama API",            desc: "REST API endpoint for the local models.", port: 11434, tag: "API" },
    ];

    const base = (port) => `${window.location.protocol}//${window.location.hostname}:${port}`;
    const grid = document.getElementById("grid");

    for (const s of SERVICES) {
      const href = base(s.port);
      const a = document.createElement("a");
      a.className = "card";
      a.href = href;
      a.target = "_blank";
      a.rel = "noopener";
      a.innerHTML =
        `<div class="name">${s.name}${s.tag ? `<span class="tag">${s.tag}</span>` : ""}</div>` +
        `<div class="desc">${s.desc}</div>` +
        `<div class="url">${href}</div>`;
      grid.appendChild(a);
    }
  </script>
</body>
</html>
HTML

  log "Portal page written."
}

########################################
# Step 3: ensure nginx serves on the chosen port and (re)start it
########################################

start_service() {
  if [[ "${LANDING_PORT}" != "80" ]]; then
    log "Pointing the default site at port ${LANDING_PORT} ..."
    sed -i "s/listen 80 default_server;/listen ${LANDING_PORT} default_server;/" /etc/nginx/sites-available/default || true
    sed -i "s/listen \[::\]:80 default_server;/listen [::]:${LANDING_PORT} default_server;/" /etc/nginx/sites-available/default || true
  fi

  log "Enabling and restarting nginx..."
  systemctl enable nginx
  systemctl restart nginx
  log "nginx serving the portal on port ${LANDING_PORT}."
}

########################################
# Main
########################################

main() {
  require_root
  install_nginx
  write_page
  start_service

  log ""
  log "=== Landing page ready ==="
  log "  Portal : http://<EIP>:${LANDING_PORT}/"
  log "  Lists  : Open WebUI, TTS Lab, VibeVoice 1.5B, Netdata, Ollama API"
}

main "$@"
