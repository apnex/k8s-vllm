# vLLM on AORUS RTX 5090 eGPU (Fedora 42, Docker)

vLLM-specific setup, smoke tests, and operational notes — Docker-based. The host platform configuration (Thunderbolt, NVIDIA driver, persistenced, modprobe blocks) is handled by `/root/aorus-5090-gpu/`. This repo is everything that depends on having a healthy CUDA stack to start vLLM containers against.

## Why Docker

- Official vLLM container images pin every Python / torch / triton / CUDA version against tested combos. Avoids dependency hell.
- vLLM's CI primarily exercises the container path; fewer "this combo doesn't work" surprises.
- Clean install/uninstall — no leftover venv files; `docker rmi` and we're done.
- Natural fit for systemd-managed service-on-boot.
- vLLM upgrades are a tag change, not a 6-10 GB pip dance.

The kernel-level bugs in NVIDIA's Blackwell-over-Thunderbolt path are NOT fixed by Docker; they live below the container boundary. The host platform setup (`aorus-5090-gpu` repo) is still load-bearing — Docker just simplifies the userspace layer.

## Prerequisites

The host must already pass:

```bash
sudo /root/aorus-5090-gpu/status.sh
```

with **0 FAIL**. Specifically required: NVIDIA driver loaded, GPU bound, `nvidia_uvm` pre-loaded, `nvidia-persistenced.service` active, `nvidia-smi` repeatable.

If platform status is not green, fix that first via `aorus-5090-gpu` rather than papering over it here.

Also required (and `setup.sh` installs / configures these):

- `nvidia-container-toolkit` (from NVIDIA's container repo)
- Docker runtime configured for the `nvidia` runtime
- Docker daemon restarted to pick up the runtime change

## Goal

Serve LLM inference using vLLM's OpenAI-compatible API, container-native, on the RTX 5090. Concretely:

1. nvidia-container-toolkit installed and working (a CUDA test container can see the GPU).
2. vLLM container image pulled.
3. vLLM container starts and detects the GPU.
4. A small model loads without freezing the host.
5. A single inference request returns sensible tokens.
6. The OpenAI API server starts and serves multiple concurrent requests.
7. systemd unit starts the API on boot, stops cleanly on shutdown.

## Layout

```
/root/vllm/
├── README.md                         # this file
├── setup.sh                          # idempotent installer (toolkit + runtime config + image pull)
├── status.sh                         # comprehensive health check
├── remove.sh                         # tear down (uninstall toolkit, stop containers, optional: remove images)
├── docs/
│   ├── architecture.md
│   ├── recovery.md
│   └── install-decisions.md
├── etc/
│   └── systemd/system/
│       └── aorus-vllm.service        # systemd unit for the API server (created by phase 4)
├── tools/
│   ├── README.md
│   ├── docker-gpu-smoke.sh           # phase 1 verification: test container sees GPU
│   ├── vllm-cuda-detect.sh           # phase 2: vllm container starts, sees device
│   └── vllm-tiny-model-test.sh       # phase 3: load a tiny model, single inference
└── archive/                          # validation evidence (per-stage results)
```

Model weights / HuggingFace cache: kept on the host at `/root/.cache/huggingface/` (default location, mounted into the container). NOT in the repo (see `.gitignore`).

## Status

- [ ] nvidia-container-toolkit installed and runtime configured
- [ ] GPU passthrough test container runs `nvidia-smi`
- [ ] vLLM container image pulled
- [ ] vLLM container starts cleanly with `--gpus all`
- [ ] Tiny model loads + one inference returns sensible output
- [ ] systemd unit + service-on-boot
- [ ] Validation evidence archived

## Files installed on host

After running `setup.sh`:

| Path | Purpose |
|---|---|
| `/etc/yum.repos.d/nvidia-container-toolkit.repo` | NVIDIA's container toolkit dnf repo |
| `nvidia-container-toolkit` package and deps | container GPU access tooling |
| `/etc/docker/daemon.json` | docker runtime configured for `nvidia` (modified, not replaced — preserves existing `insecure-registries`) |
| `/etc/systemd/system/aorus-vllm.service` | (after phase 4) systemd unit running the API server |

Things explicitly NOT created by `setup.sh`:

- The vLLM container itself (created by `tools/...` test scripts during validation, or by the systemd unit at boot once configured).
- Model weights — those download on first use.
