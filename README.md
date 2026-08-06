# runpod-comfyui-template

Init script for a RunPod Pod template: starts ComfyUI and installs the
[Antigravity CLI](https://antigravity.google/docs/cli/install) (`agy`) on boot.

## RunPod template config

In **Create/Edit Template → Config**:

- **Container image**: `runpod/pytorch:1.0.3-cu1290-torch290-ubuntu2204` (or any current
  `runpod/pytorch` tag — check [Docker Hub](https://hub.docker.com/r/runpod/pytorch/tags)
  for the latest CUDA/torch combo). **Do not use `runpod/worker-comfyui:*`** — that image
  is a serverless-worker build with its own baked-in entrypoint that runs a local
  self-test and never hands off to a custom Start Command; it'll crash-loop instead
  of running this script.
- **Start command** (click "Start command" in the template config, paste into the
  field it opens — it overrides the image's Docker `CMD`; verify it actually
  saved, the field has silently dropped it before):

  ```bash
  bash -c "rm -rf /tmp/rpct && git clone -q --depth 1 https://github.com/ptfrey/runpod-comfyui-template.git /tmp/rpct && cp /tmp/rpct/start.sh /start.sh && chmod +x /start.sh && /start.sh"
  ```

  Uses `git clone` rather than `curl raw.githubusercontent.com` — GitHub's raw-file
  CDN can serve a stale cached copy for a few minutes after a push, even with a
  cache-busting query string. `git clone` always gets the latest commit.

- **Expose HTTP ports**: `8188` (ComfyUI web UI), `8888` (JupyterLab)
- **Persistent storage**: mounted at `/workspace` (used for logs + Antigravity install cache)

Pulling the script from GitHub at boot (rather than baking it into the image) means
you can update `start.sh` and just restart the pod to pick up changes — no rebuild.

## What it does

1. Installs `agy` (Antigravity CLI) to `~/.local/bin` if not already present.
2. Clones ComfyUI + installs its `requirements.txt` into `/workspace/ComfyUI` on
   first boot only (persists on the volume — skipped on restart), then launches
   it with `--listen 0.0.0.0 --port 8188`.
3. Installs JupyterLab (if missing) and launches it on `0.0.0.0:8888`,
   rooted at `/workspace`, **with no token/password**.
4. Tails `/dev/null` to keep the container's PID 1 alive.

Logs: `/workspace/logs/start.log`, `/workspace/logs/comfyui.log`, `/workspace/logs/jupyter.log`.

### ⚠️ JupyterLab has no auth

Anyone with the pod's RunPod proxy URL for port 8888 gets a full code-exec
shell. RunPod URLs aren't indexed/guessable, but they're not secret either.
For longer-lived pods, set a token instead of blanking it:
in `start.sh`, replace `--ServerApp.token=''` with
`--ServerApp.token="$JUPYTER_TOKEN"` and set `JUPYTER_TOKEN` as a template
env var.

## Troubleshooting

### HTTP 403 "Access to `<pod>-8188.proxy.runpod.net` was denied"

One proxy port 403s while another (e.g. 8888) loads fine, and the service is
demonstrably up (`ss -lntp` shows it listening, `curl` from outside returns 200).

Cause: a stale RunPod auth cookie on `.proxy.runpod.net` in your browser. It's
`HttpOnly` and `SameSite`-scoped, so it's sent on top-level page navigations but
omitted on cross-site subresource requests — which is why the *same URL* loads as
an `<img>` but 403s in the address bar. Clearing the cache doesn't remove it.

Fix: Chrome → Settings → Privacy → Third-party cookies → *See all site data* →
search `runpod.net` → delete → reload. Confirm first in an incognito window
(no cookies) — if it loads there, this is it.

Nothing in `start.sh` can fix this; the cookie is client-side.

### `RuntimeError: CUDA unknown error` / `torch.cuda.is_available()` is False

Two distinct causes, distinguished by the error text:

- **`Error 804: forward compatibility was attempted on non supported HW`** —
  the image registers `/usr/local/cuda-*/compat` ahead of the real driver in
  `ldconfig`. That shim is Nvidia-restricted to datacenter GPUs and fails on
  GeForce cards. Already handled by the `LD_LIBRARY_PATH` line in `start.sh`.
  Confirm with `ldconfig -p | grep "libcuda.so.1 "` — two entries means the bug
  is present.
- **Generic "CUDA unknown error", no 804, empty `/dev/nvidia-caps`** — host-side
  RunPod flake. `nvidia-smi` works, CUDA init doesn't. Not fixable from the
  container. Terminate and deploy a new pod.

## First-time Antigravity auth

This is a headless pod, so the first time you run `agy` in a terminal (e.g. via
RunPod's web terminal) it prints an authorization URL + one-time code — open the
URL in your local browser, approve, paste the code back. Session is cached in
`~/.local/bin`/keyring fallback for subsequent runs.

## Overrides

- `COMFY_PORT` — change the ComfyUI listen port (default `8188`)
- `COMFY_DIR` — not yet wired as an override in the script; edit the
  `CANDIDATES` array in `start.sh` if your image installs ComfyUI elsewhere.
