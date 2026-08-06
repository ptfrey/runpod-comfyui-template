#!/usr/bin/env bash
# start.sh — RunPod init script: ComfyUI + Antigravity CLI
# Runs as the Pod's Container Start Command. Idempotent — safe to re-run on restart.
set -uo pipefail

LOG_DIR="/workspace/logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/start.log") 2>&1

echo "=== [$(date -u +%FT%TZ)] runpod-comfyui-template start.sh ==="

# ---------------------------------------------------------------------------
# 1. Antigravity CLI (agy) — install once, persisted on the volume so it
#    survives pod restarts without a full reinstall.
# ---------------------------------------------------------------------------
export HOME="${HOME:-/root}"
AGY_BIN="$HOME/.local/bin/agy"

if [ ! -x "$AGY_BIN" ]; then
  echo "[antigravity] installing CLI..."
  curl -fsSL https://antigravity.google/cli/install.sh | bash || \
    echo "[antigravity] install failed, continuing without it"
else
  echo "[antigravity] already installed at $AGY_BIN"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

if [ -x "$AGY_BIN" ]; then
  echo "[antigravity] version: $("$AGY_BIN" --version 2>&1 || echo unknown)"
  echo "[antigravity] no saved session detected (if any) — this is a headless"
  echo "[antigravity] pod, so on first 'agy' run you'll get a URL + code to"
  echo "[antigravity] approve from your local browser (SSH-style auth loop)."
fi

# ---------------------------------------------------------------------------
# 2. ComfyUI — clone + install once to /workspace (persists across restarts),
#    reuse if already there. Falls back to checking a few baked-in image
#    locations first, in case the base image already ships it.
# ---------------------------------------------------------------------------
COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"

if [ ! -f "$COMFY_DIR/main.py" ]; then
  for d in /ComfyUI /comfyui; do
    if [ -f "$d/main.py" ]; then
      COMFY_DIR="$d"
      break
    fi
  done
fi

if [ ! -f "$COMFY_DIR/main.py" ]; then
  echo "[comfyui] not found — cloning to $COMFY_DIR (first boot only, persists on volume)"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
  pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"
fi

if [ -f "$COMFY_DIR/main.py" ]; then
  echo "[comfyui] launching $COMFY_DIR on 0.0.0.0:$COMFY_PORT"
  cd "$COMFY_DIR"
  nohup python3 main.py --listen 0.0.0.0 --port "$COMFY_PORT" \
    >> "$LOG_DIR/comfyui.log" 2>&1 &
  echo "[comfyui] pid $!"
else
  echo "[comfyui] install failed — check $LOG_DIR/start.log above"
fi

# ---------------------------------------------------------------------------
# 3. JupyterLab — install if missing, launch token-free on the volume root.
# ---------------------------------------------------------------------------
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
JUPYTER_DIR="${JUPYTER_DIR:-/workspace}"

if ! command -v jupyter-lab >/dev/null 2>&1 && ! python3 -m jupyterlab --version >/dev/null 2>&1; then
  echo "[jupyter] installing jupyterlab..."
  pip install --no-cache-dir jupyterlab || echo "[jupyter] install failed, continuing without it"
fi

if command -v jupyter-lab >/dev/null 2>&1 || python3 -m jupyterlab --version >/dev/null 2>&1; then
  echo "[jupyter] launching on 0.0.0.0:$JUPYTER_PORT (dir: $JUPYTER_DIR, no token/password)"
  mkdir -p "$JUPYTER_DIR"
  nohup python3 -m jupyterlab \
    --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
    --notebook-dir="$JUPYTER_DIR" \
    --ServerApp.token='' --ServerApp.password='' \
    >> "$LOG_DIR/jupyter.log" 2>&1 &
  echo "[jupyter] pid $!"
fi

# ---------------------------------------------------------------------------
# 4. Keep the container alive (RunPod kills the pod when PID 1 exits).
# ---------------------------------------------------------------------------
echo "=== init complete, tailing logs ==="
tail -f /dev/null
