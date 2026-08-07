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
# 4. Z-Image Base models + the mirror-selfie workflow.
#
#    Runs in the background: ~20GB of weights, and ComfyUI only needs them at
#    prompt time, so there's no reason to block the UIs on it.
#
#    aria2c with 16 connections rather than curl — HuggingFace throttles a
#    single connection down to ~125KB/s partway through a large file, which
#    turns an 8GB download into a 3-hour one. Both tools resume, so a killed
#    or restarted pod picks up where it left off.
# ---------------------------------------------------------------------------
DOWNLOAD_MODELS="${DOWNLOAD_MODELS:-1}"

# Throughput from HuggingFace to a given RunPod host varies enormously — the
# same 33GB of weights is ~6 minutes on a good machine and over an hour on a
# bad one. Measure it up front so you can kill the pod and re-roll instead of
# discovering it 40 minutes later.
#
# HF_SPEED_TEST_SECS  how long to sample                     (default 12)
# HF_MIN_MBPS         below this, skip downloads entirely so
#                     the pod is obviously re-rollable        (default 0 = never skip)
HF_SPEED_TEST_SECS="${HF_SPEED_TEST_SECS:-12}"
HF_MIN_MBPS="${HF_MIN_MBPS:-0}"
SPEED_FILE="$LOG_DIR/hf_speed.json"

hf_speedtest() {
  # Samples against the real Turbo unet with -c, so the bytes fetched are kept
  # and resumed later rather than wasted on a throwaway file.
  local dir="$1" name="$2" url="$3"
  mkdir -p "$dir"
  local path="$dir/$name"

  local before after delta mbps eta verdict
  # --file-allocation=none keeps the file sparse, so disk usage (du) tracks
  # bytes actually received. Plain `stat -c %s` would report the full
  # preallocated length immediately and measure nothing.
  before="$(du -B1 "$path" 2>/dev/null | cut -f1 || echo 0)"
  before="${before:-0}"

  echo "[speedtest] sampling HuggingFace for ${HF_SPEED_TEST_SECS}s..."
  timeout "$HF_SPEED_TEST_SECS" \
    aria2c -c -x16 -s16 -k4M --file-allocation=none \
      --console-log-level=error --summary-interval=0 \
      -d "$dir" -o "$name" "$url" >/dev/null 2>&1

  after="$(du -B1 "$path" 2>/dev/null | cut -f1 || echo 0)"
  after="${after:-0}"
  delta=$(( after - before ))
  [ "$delta" -lt 0 ] && delta=0

  mbps=$(( delta / 1048576 / HF_SPEED_TEST_SECS ))
  # 33GB total for turbo + base + encoder + vae
  if [ "$mbps" -gt 0 ]; then
    eta=$(( 33792 / mbps / 60 ))
  else
    eta=-1
  fi

  if   [ "$mbps" -ge 40 ]; then verdict=good
  elif [ "$mbps" -ge 15 ]; then verdict=ok
  else                          verdict=slow
  fi

  printf '{"mbps":%d,"verdict":"%s","eta_min":%d,"sampled_bytes":%d,"secs":%d}\n' \
    "$mbps" "$verdict" "$eta" "$delta" "$HF_SPEED_TEST_SECS" > "$SPEED_FILE"

  echo "[speedtest] ${mbps} MB/s — $verdict (est. ${eta} min for ~33GB)"
  if [ "$verdict" = "slow" ]; then
    echo "[speedtest] ############################################################"
    echo "[speedtest] #  SLOW HUGGINGFACE LINK (${mbps} MB/s)"
    echo "[speedtest] #  ~33GB will take roughly ${eta} minutes on this host."
    echo "[speedtest] #  Consider terminating this pod and deploying another."
    echo "[speedtest] ############################################################"
  fi

  # Set a global rather than echoing the value — stdout is teed to the log,
  # so $(hf_speedtest ...) would swallow every message above.
  HF_MBPS="$mbps"
}

fetch_model() {
  # fetch_model <dest_dir> <filename> <expected_bytes> <url>
  local dir="$1" name="$2" want="$3" url="$4"
  local path="$dir/$name"
  mkdir -p "$dir"
  local have
  have="$(stat -c %s "$path" 2>/dev/null || echo 0)"
  if [ "$have" = "$want" ]; then
    echo "[models] $name already complete"
    return 0
  fi
  echo "[models] fetching $name ($((want / 1024 / 1024)) MB)"
  aria2c -c -x16 -s16 -k4M --summary-interval=60 --console-log-level=warn \
    -d "$dir" -o "$name" "$url"
  have="$(stat -c %s "$path" 2>/dev/null || echo 0)"
  if [ "$have" = "$want" ]; then
    echo "[models] $name OK"
  else
    echo "[models] $name SIZE MISMATCH: got $have, want $want"
  fi
}

ensure_aria2() {
  command -v aria2c >/dev/null 2>&1 && return 0
  echo "[models] installing aria2..."
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq aria2 >/dev/null 2>&1 || {
    echo "[models] aria2 install failed"
    return 1
  }
}

M_DIR="$COMFY_DIR/models"
HF="https://huggingface.co/Comfy-Org/z_image/resolve/main/split_files"
# Turbo ships from its own repo, not Comfy-Org/z_image.
HFT="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files"

download_models() {
  local M="$M_DIR"

  # Turbo first: it's the few-step model, so it's the one you can actually
  # generate with while the rest is still downloading. Base follows.
  fetch_model "$M/diffusion_models" z_image_turbo_bf16.safetensors 12309866400 \
    "$HFT/diffusion_models/z_image_turbo_bf16.safetensors"

  # The text encoder and VAE are shared by Turbo and Base — fetch them before
  # the second 12GB unet so Turbo is actually usable as early as possible.
  fetch_model "$M/text_encoders" qwen_3_4b.safetensors 8044982048 \
    "$HF/text_encoders/qwen_3_4b.safetensors"
  fetch_model "$M/vae" ae.safetensors 335304388 \
    "$HF/vae/ae.safetensors"

  fetch_model "$M/diffusion_models" z_image_bf16.safetensors 12309866400 \
    "$HF/diffusion_models/z_image_bf16.safetensors"

  echo "[models] done"
}

if [ "$DOWNLOAD_MODELS" = "1" ] && [ -d "$COMFY_DIR" ]; then
  # The speed test runs in the FOREGROUND (~12s) so its verdict lands in
  # start.log where you'll actually see it on boot, rather than scrolling past
  # in the background models.log. Only the bulk download is backgrounded.
  HF_MBPS=0
  if ensure_aria2; then
    hf_speedtest "$M_DIR/diffusion_models" z_image_turbo_bf16.safetensors \
      "$HFT/diffusion_models/z_image_turbo_bf16.safetensors"
  fi

  if [ "$HF_MIN_MBPS" -gt 0 ] && [ "$HF_MBPS" -lt "$HF_MIN_MBPS" ]; then
    echo "[models] ABORTED: ${HF_MBPS} MB/s is below HF_MIN_MBPS=${HF_MIN_MBPS}."
    echo "[models] Nothing downloaded — terminate this pod and deploy another,"
    echo "[models] or restart with a lower HF_MIN_MBPS."
  else
    echo "[models] starting background download (log: $LOG_DIR/models.log)"
    download_models >> "$LOG_DIR/models.log" 2>&1 &
  fi
else
  echo "[models] skipped (DOWNLOAD_MODELS=$DOWNLOAD_MODELS)"
fi

# Drop the bundled workflow where ComfyUI's sidebar picks it up.
WF_SRC="$(dirname "$0")/workflows"
WF_DST="$COMFY_DIR/user/default/workflows"
if [ -d "$WF_SRC" ] && [ -d "$COMFY_DIR" ]; then
  mkdir -p "$WF_DST"
  cp -n "$WF_SRC"/*.json "$WF_DST/" 2>/dev/null
  echo "[workflows] installed to $WF_DST"
fi

# ---------------------------------------------------------------------------
# 5. Keep the container alive (RunPod kills the pod when PID 1 exits).
# ---------------------------------------------------------------------------
echo "=== init complete, tailing logs ==="
tail -f /dev/null
