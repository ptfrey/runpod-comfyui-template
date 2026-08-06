# runpod-comfyui-template

Init script for a RunPod Pod template: starts ComfyUI and installs the
[Antigravity CLI](https://antigravity.google/docs/cli/install) (`agy`) on boot.

## RunPod template config

In **Create/Edit Template → Config**:

- **Container image**: `runpod/worker-comfyui:main-base` (or your own ComfyUI image)
- **Start command**:

  ```bash
  bash -c "curl -fsSL https://raw.githubusercontent.com/ptfrey/runpod-comfyui-template/main/start.sh -o /start.sh && chmod +x /start.sh && /start.sh"
  ```

- **Expose HTTP port**: `8188` (ComfyUI web UI)
- **Persistent storage**: mounted at `/workspace` (used for logs + Antigravity install cache)

Pulling the script from GitHub at boot (rather than baking it into the image) means
you can update `start.sh` and just restart the pod to pick up changes — no rebuild.

## What it does

1. Installs `agy` (Antigravity CLI) to `~/.local/bin` if not already present.
2. Locates ComfyUI (`main.py`) in common install paths and launches it with
   `--listen 0.0.0.0 --port 8188`.
3. Tails `/dev/null` to keep the container's PID 1 alive.

Logs: `/workspace/logs/start.log`, `/workspace/logs/comfyui.log`.

## First-time Antigravity auth

This is a headless pod, so the first time you run `agy` in a terminal (e.g. via
RunPod's web terminal) it prints an authorization URL + one-time code — open the
URL in your local browser, approve, paste the code back. Session is cached in
`~/.local/bin`/keyring fallback for subsequent runs.

## Overrides

- `COMFY_PORT` — change the ComfyUI listen port (default `8188`)
- `COMFY_DIR` — not yet wired as an override in the script; edit the
  `CANDIDATES` array in `start.sh` if your image installs ComfyUI elsewhere.
