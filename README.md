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
  bash -c "rm -rf /tmp/rpct && git clone -q --depth 1 https://github.com/ptfrey/runpod-comfyui-template.git /tmp/rpct && chmod +x /tmp/rpct/start.sh && /tmp/rpct/start.sh"
  ```

  It runs the script *in place* inside the clone rather than copying it to
  `/start.sh` — the script reads `workflows/` from its own directory.

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
4. Downloads the Z-Image Base weights in the background (~20 GB) and installs
   the bundled workflow into ComfyUI's sidebar. See below.
5. Tails `/dev/null` to keep the container's PID 1 alive.

Logs: `/workspace/logs/start.log`, `/workspace/logs/comfyui.log`,
`/workspace/logs/jupyter.log`, `/workspace/logs/models.log`.

## Models

Fetched from [`Comfy-Org/z_image_turbo`](https://huggingface.co/Comfy-Org/z_image_turbo)
and [`Comfy-Org/z_image`](https://huggingface.co/Comfy-Org/z_image) into
`/workspace/ComfyUI/models/`, **in this order**:

| # | File | Destination | Size |
|--:|---|---|---:|
| 1 | `z_image_turbo_bf16.safetensors` | `diffusion_models/` | 12,309,866,400 |
| 2 | `qwen_3_4b.safetensors` | `text_encoders/` | 8,044,982,048 |
| 3 | `ae.safetensors` | `vae/` | 335,304,388 |
| 4 | `z_image_bf16.safetensors` | `diffusion_models/` | 12,309,866,400 |

Turbo comes first because it's the few-step model — you can start generating
with it soonest. The text encoder and VAE are shared by both models, so they're
fetched before the second 12 GB unet; once item 3 lands, Turbo is fully usable
while Base is still downloading. Total is roughly 33 GB.

Downloads run in the background — the web UIs come up immediately and only
generation has to wait. Progress is in `/workspace/logs/models.log`.

Two details worth knowing:

- **`curl`, not `aria2c`.** HuggingFace serves large files from
  `us.aws.cdn.hf.co/xet-bridge-us` behind a signed, expiring URL. aria2's
  parallel connections each re-request the redirect and get `403`, so `-x16`
  fails outright — and even `-x1` is far slower. Measured on a RunPod host
  against the 12 GB Turbo unet:

  | Method | 8s sample | Rate |
  |---|---:|---:|
  | `curl -sSL` | 575 MB | ~72 MB/s |
  | `aria2c -x1 -s1` | 130 MB | ~16 MB/s |
  | `aria2c -x16 -s16` | — | 403 Forbidden |

  `curl -C -` resumes, so restarts stay free.
- Each file's expected byte count is checked before and after. A file that
  already matches is skipped, so restarts are free and partial downloads
  resume rather than starting over.

Set `DOWNLOAD_MODELS=0` as a template env var to skip this entirely.

### Speed test

HuggingFace throughput varies wildly between RunPod hosts — the same 33 GB is
~6 minutes on a good machine and over an hour on a bad one. Rather than find
out 40 minutes in, boot samples the link first and prints the verdict to
`start.log`:

```
[speedtest] sampling HuggingFace for 12s...
[speedtest] 84 MB/s — good (est. 6 min for ~33GB)
```

It probes the real Turbo unet with `curl -C -`, so the bytes it pulls are kept
and resumed by the download that follows — the test costs 12 seconds, not a
wasted transfer. Verdicts: `good` ≥ 40 MB/s, `ok` ≥ 15, `slow` below that,
which also prints a banner suggesting you re-roll the pod. Machine-readable
copy lands in `/workspace/logs/hf_speed.json`:

```json
{"mbps":84,"verdict":"good","eta_min":6,"sampled_bytes":887046144,"secs":12}
```

| Env var | Default | Effect |
|---|---:|---|
| `HF_SPEED_TEST_SECS` | `12` | Sample duration |
| `HF_MIN_MBPS` | `0` (off) | Below this, skip the download entirely so a bad pod is obvious in seconds |

### Which Z-Image?

Both are installed. The bundled workflow targets **Base** — 30 steps, CFG 4.0.
**Turbo** is a distilled few-step model and needs 8 steps with CFG 1.0. Don't
mix the settings: Base at 8 steps or Turbo at CFG 4.0 both produce garbage.
Switch models in `UNETLoader` and change the sampler settings together.

LoRAs are also build-specific — a `ZImageBase` LoRA won't work on Turbo and
vice versa, unless its CivitAI page explicitly says it covers both.

## Bundled workflow

`workflows/Realistic_AI_Mirror_Selfie_ZImage_Base_GUI_Workflow.json` is copied
to `/workspace/ComfyUI/user/default/workflows/` on boot, so it shows up in
ComfyUI's workflow sidebar. Existing files are never overwritten (`cp -n`), so
your edits survive a restart.

See `docs-mirror-selfie-workflow.md` for the prompting guide.

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
