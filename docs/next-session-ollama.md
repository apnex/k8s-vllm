# Handover: pivot to ollama

This document is the entry point for whoever picks up the LLM-serving work next session. The vLLM track is blocked on an upstream NVIDIA bug; the next viable path is `ollama` (or `llama.cpp` directly).

## Read first

- The host platform (Thunderbolt, NVIDIA driver, persistenced) is fully working — `/root/aorus-5090-gpu/status.sh` returns 45/45 OK. Do not change platform config without re-validating.
- `nvidia-smi` works repeatedly, CUDA Driver API works, PyTorch matmul + cuBLAS GEMM works (validated 2026-05-01 evidence in `/root/aorus-5090-gpu/archive/cuda-validation-2026-05-01/`).
- vLLM 0.20.0 does NOT work — it freezes the host at NCCL/torch.distributed setup or at the post-load profile run. Eight-plus host freezes confirmed across docker and native installs; see this repo's `archive/vllm-attempts-2026-05-01/` for evidence.
- The `vllm-gloo-preinit.py` workaround (this repo, `tools/`) does get past the NCCL freeze, but a second freeze hits later in vLLM's profile run. Preserved for revisiting after upstream fixes.

## Why ollama (or llama.cpp) is expected to work

- Single process, no multiprocessing fork, no `torch.distributed`, no NCCL communicator init.
- Kernels are precompiled at build time (`llama.cpp` ships with CUDA kernels in the binary), no runtime Triton JIT.
- Simple CUDA usage path that mirrors what we already validated on this stack: `cuInit -> cuMemAlloc -> cuMemcpy -> cuBLAS GEMM -> cleanup`.
- ollama wraps llama.cpp with model management and an OpenAI-compatible HTTP API on port `11434`.

## Suggested first session

### 1. Confirm host is healthy

```bash
sudo /root/aorus-5090-gpu/status.sh
```

Expect 45/45. If anything is FAIL, fix the platform first (see `/root/aorus-5090-gpu/docs/recovery.md`).

### 2. Install ollama (one binary)

The official install script puts the binary at `/usr/local/bin/ollama` and creates a systemd unit:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Verify:

```bash
systemctl status ollama
```

The default unit may try to detect GPUs at startup — that's our risk surface. ollama uses CUDA via llama.cpp's `ggml-cuda` backend. Watch for any host responsiveness drop in the first 30-60 seconds after `systemctl start ollama`.

### 3. First model pull and inference

Smallest reasonable test:

```bash
ollama pull tinyllama:latest          # ~640 MB
# OR even smaller: there's no SmolLM2 in ollama's catalog by default;
# 'qwen2.5:0.5b' is ~400 MB and a good first-test substitute.

ollama run tinyllama "The capital of France is"
```

If that produces text and the host stays alive: ollama works on this stack.

### 4. If ollama freezes the host

Same fingerprint as vLLM (`NVRM: GPU lost from the bus`)?  Same forced-reboot recovery. Then:
- Set `CUDA_VISIBLE_DEVICES=""` in the ollama unit's environment to force CPU-only — useful as a baseline to confirm install works at all.
- Try `OLLAMA_NUM_GPU=0` env var (CPU-only override).
- If even CPU works but GPU freezes, file the bug pattern as evidence the eGPU's NCCL-or-equivalent issue is broader than just vLLM.
- Consider llama.cpp directly (build from source against host CUDA 580.142). It exposes more knobs for diagnosing.

### 5. If ollama works

- Build a systemd unit that depends on `aorus-5090-compute-load-nvidia.service` and `nvidia-persistenced.service` so the eGPU is bound and persistenced is up before ollama starts. (Pattern is identical to the existing `aorus-egpu.conf` drop-in for nvidia-persistenced.)
- Bind ollama to `127.0.0.1:11434` (not `0.0.0.0`) unless deliberately exposing on LAN.
- Document the working state in this repo's README and create a clean install script.

## Things to NOT do

- Do not try vLLM 0.20 again without an upstream change. Eight host freezes is enough evidence.
- Do not run `nvidia-smi` repeatedly with persistenced down — the close-path bug is still present (see `/root/aorus-5090-gpu/docs/architecture.md#problem-2`).
- Do not unload the `nvidia` module while NVML has been used in this boot — second module load can wedge the host.
- Do not run `systemctl isolate multi-user.target` for ollama tests unless you have specific reason; ollama's failure modes do not need TTY isolation. The TTY-with-fsync runners we used for vLLM are over-engineered for ollama.

## What's preserved in this repo

- `tools/vllm-gloo-preinit.py` — workaround for vLLM's torch.distributed NCCL init freeze. Genuinely works for that one specific phase.
- `tools/tty-native-vllm-test.sh`, `tools/tty-cuda-test.sh`, etc — TTY-with-fsync test runners. Useful templates for any future freeze-risk test.
- `archive/vllm-attempts-2026-05-01/` — captured logs and progress markers from each freeze, including the ones where gloo-preinit got us past the prior freeze point.
- `docs/architecture.md`, `docs/future-investigations.md` — the technical write-up of what we found and the upstream NVIDIA bug-report drafts (Bug A: open() hang, Bug B: failed cuInit panic). The vLLM-specific findings (NCCL freeze, profile-run freeze) should be added to those docs as a Bug C variant if/when filed upstream.

## What's at /root that this repo does not own

- `/root/torch-test/` — Python 3.13 venv with torch 2.11.0+cu130 + huggingface_hub. Created during the platform-validation phase. **Do not delete** without good reason — the platform's validation evidence references it.
- `/root/vllm-venv/` — Python 3.13 venv with vllm 0.20.0 + torch + transformers. ~6 GB. Safe to delete if pivoting fully to ollama and not revisiting vLLM. Alternatively keep around as the staging environment for when vLLM becomes viable again.
- `/root/.cache/huggingface/hub/models--HuggingFaceTB--SmolLM2-135M-Instruct/` — pre-downloaded model. Reusable for any future tests via huggingface_hub.

## File the upstream bug while you're at it

The upstream NVIDIA bug report draft is in `docs/future-investigations.md` at `/root/aorus-5090-gpu/`. We now have a third distinct failure mode to add:

> **Bug C: NCCL communicator init at torch.distributed.init_process_group(backend='nccl') with TP=1 takes the GPU off the bus on Blackwell over Thunderbolt 4.** Reproducer: any vLLM 0.20.0 invocation. Workaround: pre-initialize torch.distributed with `gloo` backend so vLLM skips its NCCL init entirely (see `/root/vllm/tools/vllm-gloo-preinit.py`). Workaround does not survive past the post-load profile run, where a second freeze occurs.

Filing time: ~30 min if doing all three bugs at once. Each freeze cycle this session has produced filing-quality evidence already.
