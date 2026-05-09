# vLLM performance discovery roadmap

> **Status:** PLANNING (2026-05-08). vLLM bring-up is currently blocked
> upstream (see `next-session-ollama.md`). This document captures
> performance-investigation directions for when vLLM becomes runnable
> on this stack — borrowing observations from ollama work in
> `/root/aorus-5090-gpu/` to seed the vLLM-side investigation.

## Context — what we know from ollama

The companion `aorus-5090-gpu` project achieved ollama parity with WSL2
on this hardware as of 2026-05-08:

| Metric | This stack (ollama) | WSL2 closed driver | Ratio |
|---|---|---|---|
| Decode (llama3.1:8b) | 256 tok/s | ~244 tok/s | **105%** |
| Decode (llama3.2:1b) | similar | similar | **98%** |
| **Cold model load (llama3.1:8b, 4.9 GB)** | **~3.95 s** | **~30 ms** | **~130×** |

Decode is at parity. The remaining perf delta is **cold-load** — first
model load from cold filesystem cache to GPU-resident weights. This is
where vLLM perf investigation has the most headroom.

Reference dossiers:
- `/root/aorus-5090-gpu/archive/loop-2026-05-08-204450/` — ollama 8B run
  with full perf telemetry (load_duration, eval rate, ioctl counts)
- `/root/aorus-5090-gpu/docs/lever-catalog.md` — host-platform optimisation levers
- Memory: `feedback_perf_parity_confirmed` — methodology + measurement provenance

## Why vLLM is a different problem class

ollama (llama.cpp under the hood):
- Single process, single CUDA context
- Model loaded once into a single GPU's VRAM
- Per-token decode through a captured CUDA graph
- Simple memcpy from host → device for weights

vLLM:
- Multi-process worker model + paged attention KV cache manager
- Continuous batching + prefix caching
- Triton JIT'd kernels (build-on-first-use cost)
- Tensor / pipeline parallelism support
- Heavier startup cost, but lower per-request marginal cost at high concurrency

So cold-load on vLLM has additional components ollama doesn't pay:
- Triton JIT compilation of fused kernels
- Worker process spawning + communication setup
- Profile-run for memory budgeting
- KV cache pre-allocation

Some of which are amortised across many requests; some are pure overhead.

## Investigation directions (deferred missions)

Each item is a self-contained mission. None block the others. Order is
not authoritative — pick based on which has the cleanest expected
methodology + lowest blocking cost when picked up.

### 1. mmap + on-demand fault-in for weights

**Hypothesis:** the current load model is "block-read full weight file
into host buffer, then DMA-copy to GPU". This serialises filesystem-read
behind weight transfer. mmap'ing the model file and letting on-demand
faults stream weights as they're touched could overlap weight DMA with
prefill (the layers used first arrive first).

**What to test:**
- vLLM startup with model-loader using `torch.load(map_location="cuda")`
  vs `torch.load(map_location="cpu")` + manual `.to("cuda")`
- Compare against `safetensors` mmap load path (`safetensors.torch.load_file` with `device="cuda"`)
- Measure: total time from process start to first-token-ready

**Risk:** GPUDirect-style mmap needs IOMMU + page-table cooperation;
on TB-tunneled paths this might trigger the same DMAR class issues we
hit with `iommu=off`. Worth testing whether mmap'd CUDA copies bypass
or trigger IOMMU translation.

**Reference:** safetensors documentation; PyTorch dispatch traces
during model load.

### 2. GPUDirect Storage (GDS)

**Hypothesis:** the current path is `NVMe → kernel page cache → CPU
buffer → cudaMemcpy → GPU VRAM`. GDS bypasses CPU staging via
`cuFile`, with NVMe → GPU DMA directly. NVIDIA-supported, well-tested
on standard PCIe; less-tested on TB-tunneled GPUs.

**What to test:**
- Install `nvidia-fs` package (kernel module + userspace cuFile lib)
- Verify GDS-ready filesystem (xfs, ext4 with O_DIRECT support)
- Modify vLLM model loader to use cuFile API for the weight file
- Benchmark vs default path

**Risk:** TB-tunneled GDS may not work — the underlying PCIe topology
matters for peer-to-peer DMA. May fall back to bounce-buffer transparently.
If it works, expect 2-4× cold-load speedup.

**Reference:** [NVIDIA GDS docs](https://docs.nvidia.com/gpudirect-storage/);
nvidia-fs Fedora packaging.

### 3. Hot model cache in GPU memory

**Hypothesis:** if vLLM stays running between requests (it does, by
design), the load tax is paid once per server lifetime. The cold-load
gap matters for "fresh-start" scenarios — host reboots, container
restarts, model swap. Keeping weights in GPU memory across vLLM
process lifecycles via SHM-style memory pinning could reduce the
"server start" cost to ~zero on warm restart.

**What to test:**
- vLLM `--enable-prefix-caching` (already used in the gloo-preinit
  workaround) — preserves KV cache across prefix-shared requests
- IPC handle sharing via CUDA IPC for cross-process weight sharing
- Memory pinning in CUDA via `cuMemMap` + `cuMemSetAccess` for explicit
  GPU residency control

**Risk:** non-trivial state management. Cross-process CUDA IPC has
limitations. Could be a multi-week mission for marginal gains.

**Reference:** vLLM's `EnginePool` / `Worker` lifecycle design;
CUDA IPC documentation.

### 4. Async pipelining — load chunks while parsing rest of model

**Hypothesis:** cold load is currently ~serial: read header → read
metadata → read tensors → upload tensors → ready. If tensor upload to
GPU started concurrently with metadata parsing on CPU, the ~3.95s
total could shrink to ~max(filesystem-read, GPU-upload, CPU-parse).

**What to test:**
- Profile vLLM model-load with `nsys` to see which phases serialise
- Check for prefetch / chunked load support in vLLM's model_loader
- Compare against `torch.load(_use_new_zipfile_serialization=True)`
  (which has internal chunking)

**Risk:** vLLM's loader may already do this; needs profiling-driven
decision before any work is started.

**Reference:** vLLM `model_executor/model_loader/`; PyTorch zipfile
serialization internals.

### 5. CUDA Graphs — confirmation, not optimisation

**Status from ollama work (2026-05-08):** confirmed via bpftrace that
ollama+ggml-cuda+CUDA Graphs are active during decode (229 graph
launches per 230 tokens). Decode at WSL2 parity = ~256 tok/s already
includes the graph optimisation.

**vLLM analogue:** vLLM's CUDAGraph support is per-batch, captured during
the first profile-run pass. Is it active by default on this stack? Is
it captured for our specific batch sizes / sequence lengths?

**What to test:**
- Same bpftrace methodology used in 2026-05-08 ollama check, retargeted
  at vLLM's runtime path. cudaGraphLaunch count ≥ 1 per decode step
  confirms graphs are active.
- vLLM has knobs: `--enforce-eager` disables graphs (worth testing
  enforce_eager OFF vs ON to confirm graph speedup is meaningful)

**Risk:** none. Pure observational + flag-flip experiment.

**Reference:** vLLM `--enforce-eager`; ollama bpftrace methodology
in `aorus-5090-gpu` chat history.

## Cross-cutting: what to instrument first

Before tackling any of (1)-(5), establish a clean baseline measurement
methodology for vLLM cold-load:

1. Reproducible "fresh start": evict OS page cache (`drop_caches`),
   ensure GPU memory is empty, restart vLLM container.
2. Wall-clock from container-start to first-token-ready (mirrors what
   ollama does with `total_duration`).
3. Per-phase decomposition via `nsys profile` to attribute time to
   filesystem read / CPU parse / DMA / Triton JIT / profile run.
4. Compare against WSL2 / Windows running the same model + similar
   container config.

Without per-phase attribution, all five items above are guess-driven.
With it, we'll know which actually matter on this stack.

## Cross-references

- `/root/aorus-5090-gpu/docs/lever-catalog.md` — platform reliability levers
- `/root/aorus-5090-gpu/docs/cuda-bandwidth-methodology.md` — bandwidth measurement
- `/root/aorus-5090-gpu/archive/loop-2026-05-08-204450/` — ollama 8B baseline
- This repo: `next-session-ollama.md` — vLLM bring-up status (blocked)
- This repo: `tools/tty-native-vllm-test.sh` — test harness scaffold
- This repo: `archive/vllm-attempts-2026-05-01/` — prior vLLM attempts (host-freeze evidence)
