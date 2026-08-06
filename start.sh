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
# 2. ComfyUI — find install dir, launch listening on all interfaces.
#    Checks the common locations used by ComfyUI-based images/templates.
# ---------------------------------------------------------------------------
COMFY_PORT="${COMFY_PORT:-8188}"
CANDIDATES=(
  "/workspace/ComfyUI"
  "/ComfyUI"
  "/comfyui"
  "/workspace/comfyui"
)

COMFY_DIR=""
for d in "${CANDIDATES[@]}"; do
  if [ -f "$d/main.py" ]; then
    COMFY_DIR="$d"
    break
  fi
done

if [ -z "$COMFY_DIR" ]; then
  echo "[comfyui] main.py not found in known locations (${CANDIDATES[*]})"
  echo "[comfyui] set COMFY_DIR env var to override, or check the base image layout"
else
  echo "[comfyui] found install at $COMFY_DIR — launching on 0.0.0.0:$COMFY_PORT"
  cd "$COMFY_DIR"
  nohup python3 main.py --listen 0.0.0.0 --port "$COMFY_PORT" \
    >> "$LOG_DIR/comfyui.log" 2>&1 &
  echo "[comfyui] pid $!"
fi

# ---------------------------------------------------------------------------
# 3. Keep the container alive (RunPod kills the pod when PID 1 exits).
# ---------------------------------------------------------------------------
echo "=== init complete, tailing logs ==="
tail -f /dev/null
