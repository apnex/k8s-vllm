# vLLM on AORUS RTX 5090 eGPU (Fedora 42)

vLLM-specific setup, smoke tests, and operational notes. Assumes the host platform configuration from `/root/aorus-5090-gpu/` has already been applied — that repo handles the eGPU bring-up (Thunderbolt, NVIDIA driver, persistenced, modprobe blocks). This repo is everything that depends on having a healthy CUDA stack.

## Prerequisites

Before doing anything in this repo, the host must already pass:

```bash
sudo /root/aorus-5090-gpu/status.sh
```

with **0 FAIL**. Specifically required:

- NVIDIA driver loaded, GPU bound (`status.sh` section 6).
- `nvidia_uvm` pre-loaded (`status.sh` section 2).
- `nvidia-persistenced.service` active (`status.sh` section 8).
- `nvidia-smi` repeatable.
- PyTorch CUDA roundtrip works (validated separately at `/root/aorus-5090-gpu/archive/cuda-validation-2026-05-01/`).

If any of these are not green, fix the platform first via `aorus-5090-gpu` rather than working around it here.

## Goal

Serve LLM inference using vLLM's OpenAI-compatible API on the RTX 5090. Concretely:

1. vLLM installs cleanly into a venv.
2. vLLM detects the RTX 5090.
3. A small model loads without freezing the host.
4. A single inference request returns sensible tokens.
5. The API server starts and serves multiple concurrent requests.
6. Each step is validated under the same TTY-with-fsync methodology used in `aorus-5090-gpu/tools/`.

## Layout

```
/root/vllm/
├── README.md                 # this file
├── setup.sh                  # idempotent installer (creates venv, pip install vllm)
├── status.sh                 # comprehensive health check (parallels aorus-5090-gpu/status.sh)
├── remove.sh                 # tear down (nuke venv, optional: remove downloaded models)
├── docs/
│   ├── architecture.md       # how vLLM is wired into this stack, what's load-bearing
│   ├── recovery.md           # what to do when vLLM hangs / OOMs / freezes the host
│   └── install-decisions.md  # why Python version, why this vLLM version, why this torch version
├── tools/
│   ├── README.md             # usage guide for diagnostic tools
│   ├── vllm-import-test.py   # phase 1: import vllm, no CUDA
│   ├── vllm-cuda-detect.py   # phase 2: vllm sees the GPU, no model load
│   ├── vllm-tiny-model-test.py # phase 3: load a small model, single inference
│   └── tty-vllm-test.sh      # TTY-with-fsync runner adapted from aorus-5090-gpu pattern
└── archive/                  # validation evidence (per-stage results)
```

A separate venv at `/root/vllm-venv/` is intentional — keeps vLLM's ~6-10 GB dependency tree isolated from the existing `/root/torch-test/` venv (which is pinned to torch 2.11). vLLM brings its own torch.

## Status

- [ ] Repo scaffolding
- [ ] setup.sh: venv creation + vllm install
- [ ] status.sh: health check parallel to platform repo
- [ ] Phase 1: vllm import test
- [ ] Phase 2: vllm CUDA detect test
- [ ] Phase 3: tiny model load + single inference
- [ ] Phase 4: API server + concurrent request validation
- [ ] Day-to-day operational documentation

This document gets updated as each phase passes.
