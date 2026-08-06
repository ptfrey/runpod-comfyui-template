#!/usr/bin/env bash
# start.sh — RunPod init script: ComfyUI + Antigravity CLI
# Runs as the Pod's Container Start Command. Idempotent — safe to re-run on restart.
set -uo pipefail

LOG_DIR="/workspace/logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/start.log") 2>&1

echo "=== [$(date -u +%FT%TZ)] runpod-comfyui-template start.sh ==="

# ---------------------------------------------------------------------------
# 0. Pick the Python that actually has torch/CUDA installed. Some RunPod
#    base images ship multiple pythons (e.g. /usr/bin/python3 -> 3.10 with
#    nothing in it, /usr/bin/python3.12 with torch + everything preinstalled)
#    where bare `python3`/`pip` resolve inconsistently. Pinning avoids
#    installing into one interpreter and launching with another.
# ---------------------------------------------------------------------------
PY="python3"
for cand in python3.12 python3.11 python3.10; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import torch" >/dev/null 2>&1; then
    PY="$cand"
    break
  fi
done
echo "[python] using $PY ($($PY --version 2>&1))"

# ---------------------------------------------------------------------------
# 0b. Work around a CUDA "forward compatibility" bug: some nvidia/cuda base
#     images register /usr/local/cuda*/compat in ldconfig BEFORE the real
#     driver's libcuda.so. That compat shim is Nvidia-restricted to
#     datacenter GPUs (A100/H100) and refuses to init on GeForce cards,
#     surfacing as "Error 804: forward compatibility was attempted on non
#     supported HW" even though nvidia-smi and the device files are fine.
#     Force the real driver-matched libcuda first via LD_LIBRARY_PATH.
# ---------------------------------------------------------------------------
export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"

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
  "$PY" -m pip install --no-cache-dir -r "$COMFY_DIR/requirements.txt"
fi

if [ -f "$COMFY_DIR/main.py" ]; then
  echo "[comfyui] launching $COMFY_DIR on 0.0.0.0:$COMFY_PORT"
  cd "$COMFY_DIR"
  nohup "$PY" main.py --listen 0.0.0.0 --port "$COMFY_PORT" \
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

if ! "$PY" -m jupyterlab --version >/dev/null 2>&1; then
  echo "[jupyter] installing jupyterlab..."
  "$PY" -m pip install --no-cache-dir jupyterlab || echo "[jupyter] install failed, continuing without it"
fi

if "$PY" -m jupyterlab --version >/dev/null 2>&1; then
  echo "[jupyter] launching on 0.0.0.0:$JUPYTER_PORT (dir: $JUPYTER_DIR, no token/password)"
  mkdir -p "$JUPYTER_DIR"
  nohup "$PY" -m jupyterlab \
    --ip=0.0.0.0 --port="$JUPYTER_PORT" --no-browser --allow-root \
    --notebook-dir="$JUPYTER_DIR" \
    --ServerApp.token='' --ServerApp.password='' \
    >> "$LOG_DIR/jupyter.log" 2>&1 &
  echo "[jupyter] pid $!"
else
  echo "[jupyter] not available — check $LOG_DIR/start.log above"
fi

# ---------------------------------------------------------------------------
# 4. Keep the container alive (RunPod kills the pod when PID 1 exits).
# ---------------------------------------------------------------------------
echo "=== init complete, tailing logs ==="
tail -f /dev/null
