# Audit B — post-v0.21.0 issue triage

**Date:** 2026-05-24
**Auditor:** subagent B (5-of-5 parallel)
**Window:** 2026-05-15 to 2026-05-24 (9 days post-release)
**Total issues filed in window:** 185
**Triaged as relevant to our stack:** 34 (full read of bodies + comments)
**Total reviewed at title/label level:** 185 (all)

## Methodology

185 issues across 2 search pages. Title + label-triaged all 185; pulled full body + all comments for 34 most likely to affect us (Blackwell/sm_120, Docker/install, OpenAI server, tool/reasoning parsers, AWQ, quant model loading, startup hangs). ROCm-only, DeepSeek-V4 internals, NIXL disagg, MoE fusion RFCs, and vLLM-internal CI failures were title-only.

---

## TL;DR (top 3 concerns)

1. **RTX 5090 / sm_120 has at least three confirmed startup-or-hang failure modes on stock v0.21.0**, all unfixed at the time of release. The most discriminating is the `_dummy_sampler_run` infinite hang in `profile_run` (issue #42987 — startup hangs forever, no error). This will bite us on first launch unless we apply the one-line workaround or run with `VLLM_USE_FLASHINFER_SAMPLER=0` + a patched dummy-sampler `top_k`.
2. **Two install paths in v0.21.0 are broken for non-default CUDA versions.** cu128 wheels are not shipped (#42756 — community wheels only); cu129 install with the default wheel index pulls cu130-built `_C.abi3.so` which then dies with `ImportError: libcudart.so.13: cannot open shared object file` (#43435). Both have user-side workarounds but neither is documented in release notes. The official Docker image (`vllm/vllm-openai:v0.21.0`) is built against cu130 so the inside-container CUDA libs match; this is our planned install path and is unaffected.
3. **Streaming tool-call parsers have multiple severe correctness bugs spanning every parser we'd plausibly use.** `qwen3_coder`, `qwen3_xml`, `gemma4`, `granite4`, `deepseekv4` (DSML), and `glm47_moe` all have at-least-one open streaming bug filed in this 9-day window. Several silently corrupt JSON arguments under load (#42696 — Gemma4 args mis-attributed across tool indices at concurrency ≥500; #43238 — qwen3_xml string-encodes complex arrays). `tool_choice="none"` does not suppress tool parsing in streaming mode (#42747). For a tool-heavy production deployment this is the dominant risk surface.

---

## High-severity regressions (break startup / model loading / output generation)

### #42987 — SM120 `_dummy_sampler_run` hangs indefinitely on RTX 5090 (OPEN, no fix merged at audit time)
- Root cause: the dummy sampler in `_dummy_sampler_run` runs with `top_k = vocab_size - 1` (151,935 for Qwen2.5-3B). Both the Triton (`apply_top_k_top_p_triton`) and FlashInfer (`top_k_mask_logits`) implementations of top-k masking hang silently on SM120 when `top_k` approaches `vocab_size`. `cuLaunchKernel` is dispatched, host blocks in `clock_gettime` for `cudaEventSynchronize`, GPU at 0% util, allocated 7128 MiB. No error, no timeout — observed for >9 hours before manual SIGTERM.
- Reproduces on **0.20.1** stable (and per submitter's note "likely 0.21.x too"). Real RTX 5090 bare-metal hardware. NOT WSL2, NOT SM121.
- Impact on us: **Severe**. Our exact target hardware. With default flags (`--enable-flashinfer` is not even required — both paths hang), `vllm serve` will appear to start, log `Loading...`, complete weight loading, then sit in `profile_run` forever. We will hit this on first launch.
- Workaround: monkey-patch `_dummy_sampler_run` to substitute `top_k = 50` (memory footprint of profiling run is independent of top_k). Submitter confirmed this brings startup to ~5 s. A PR is open (daniel-devlab, not yet merged at our audit time).
- Two further SM120 hangs flagged in the same issue as "after applying the workaround": (a) `default_unquantized_gemm` lm-head matmul stalls under `--enforce-eager`, (b) weight loading stalls at 6752 MiB with `cudagraph_mode=FULL_AND_PIECEWISE` → GPU enters `[requires reset]`. Submitter plans to file separately. **These are unsolved.**
- Link: https://github.com/vllm-project/vllm/issues/42987

### #42897 — EngineCore hangs in `_to_list → cuEventSynchronize` after hours on RTX 5090 (CLOSED by reporter as "not actionable", but cause UNRESOLVED)
- Symptom: after hours of sustained chat-completion traffic with concurrency >1, vLLM stops producing tokens. HTTP layer returns 200 OK on `/health`; periodic stats line `Avg prompt throughput` stops being emitted. No exception, no traceback. Engine never recovers; restart required.
- Hardware: bare-metal RTX 5090 (sm_120), driver 595.45.04, CUDA 13.2, torch 2.11+cu130, FlashInfer 0.6.8.post1 (on 0.21.0).
- Reproduced on three vLLM builds: `0.21.0` (commit ad7125a) stable, plus nightlies dev39 and dev42. py-spy native shows host blocked in `cuEventSynchronize` waiting for an event that never fires. DCGM: 100% "compute utilization" but `sm_active=0.8%`, tensor cores at 0, DRAM at 1%, 140 W on a 600 W card — stream is parked on an event that won't signal.
- Model: `RedHatAI/Qwen3.6-35B-A3B-NVFP4` (hybrid GDN + attention MoE). Launch includes `--enable-auto-tool-choice --reasoning-parser qwen3 --tool-call-parser qwen3_coder` — overlaps heavily with our planned config. Adding `--no-async-scheduling` did NOT prevent the hang.
- Issue was closed by the reporter because the stack location is "where vLLM parks every forward pass" so the trace isn't a vLLM-side bug as filed. But the underlying behavior — a Blackwell RTX 5090 silently wedging after hours of sustained traffic — is unresolved. The reporter listed the missing isolation work (different model on same hardware; `--enforce-eager`; cu128 vs cu130) as future work.
- Impact on us: **High** if confirmed on AWQ models too. Our use case is sustained chat-completion traffic with concurrency. We should expect this and build a watchdog (reporter's was a journal-heartbeat watcher: 83 s after last `Avg prompt throughput` log → snapshot + restart).
- Link: https://github.com/vllm-project/vllm/issues/42897

### #42745 — `apply_top_k_top_p_pytorch` `scatter_` crashes under cudagraph capture on sm_121a / GB10 (OPEN)
- DGX Spark (GB10, sm_121a) hardware not ours, but the failure mode is instructive. `torch.AcceleratorError: CUDA error: operation not permitted` (the standard "operation not permitted when stream is capturing") from `logits.scatter_(...)` in `apply_top_k_top_p_pytorch`. Triggered by spec decoding + FlashInfer-sampler-unavailable falling back to PyTorch path.
- The reason FlashInfer falls back: FlashInfer's JIT-time arch detection rejects `sm_121a`. Not our issue (we're sm_120), but it confirms FlashInfer's Blackwell support is fragile.
- Workaround: `--enforce-eager` or `cudagraph_mode=NONE` — both kill the crash at ~20-30% throughput cost.
- Impact on us: **Low directly** (we're sm_120 not sm_121, and we're not on spec-decode). Indirectly: the same `scatter_` line is a cudagraph-capture risk on sm_120 too, so worth knowing.
- Link: https://github.com/vllm-project/vllm/issues/42745

### #43435 — `installing vllm 0.21 with cu129 torch backend tries to open libcudart.so.13` (CLOSED, user-side workaround)
- Install via `uv pip install vllm==0.21 --torch-backend=cu129` succeeds but `import vllm` dies with `ImportError: libcudart.so.13: cannot open shared object file: No such file or directory`. The compiled `_C.abi3.so` is cu13-built but the user's torch is cu12.9.
- Root cause: pypi `vllm` wheel under default index resolution prefers a cu13-built artifact. Workaround per `khluu` (vLLM release maintainer) and `HakimTaoufik`: explicitly pin the wheel index — `uv pip install vllm --extra-index-url https://wheels.vllm.ai/0.21.0/cu129 --extra-index-url https://download.pytorch.org/whl/cu129 --index-strategy unsafe-best-match`.
- Impact on us: **None directly** — we use the prebuilt Docker image. But documents the fragility of pip-based install for v0.21.0.
- Link: https://github.com/vllm-project/vllm/issues/43435

### #42756 — cu128 wheels not shipped for v0.21.0 (CLOSED, by design)
- Confirmed by @khluu: "We only release cu129 and cu130 wheels at the moment". Multiple users (joshuakoh1, dl2gomi) failed to build cu128 from source. Community member `dl2gomi` eventually built and shared a cu128 wheel on HuggingFace.
- Impact on us: **None** — we don't need cu128.
- Link: https://github.com/vllm-project/vllm/issues/42756

### #43480 — vllm-openai nightly Docker image fails to start: `ModuleNotFoundError: No module named 'pytest'` (CLOSED, fixed)
- The `vllm/vllm-openai:nightly` image (digest `sha256:0175610003dc...`) crashed during startup when loading `humming` quantization (a new compressed-tensors variant). Import chain `humming → torch._library → cupy.testing → pytest`. `pytest` not in the runtime image.
- Fixed same day by reverting the humming dep addition (mgoin, 2026-05-23 21:21). Will re-land after upstream humming fix.
- Impact on us: **Low** — only the `:nightly` tag was affected; the stable `v0.21.0` image was not. Reinforces: never pin `:nightly`.
- Link: https://github.com/vllm-project/vllm/issues/43480

### #43263 — `AttributeError: 'ColumnParallelLinear' object has no attribute 'weight'` in MLA prefill on AWQ model (OPEN)
- **This is the single most relevant code-correctness bug for our stack.**
- vLLM 0.21.1rc1.dev110 on `cyankiwi/GLM-4.7-Flash-AWQ-4bit` (AWQ 4-bit compressed-tensors). Short prompts work; the **first prompt long enough to hit `_compute_prefill_context`** (~27k tokens) crashes the EngineCore worker. Subsequent requests return 500.
- Root cause: `vllm/model_executor/layers/attention/mla_attention.py:2094`. The code defines a safe `_kv_b_proj_w_dtype` via `hasattr(self.kv_b_proj, "weight")` fallback (because AWQ/GPTQ layers don't expose `.weight`) but then five lines later still calls `kv_c_normed.to(self.kv_b_proj.weight.dtype)` directly, bypassing the guard. Regression introduced after PR #34695 by a subsequent NVFP4 rewrite.
- One-line fix proposed (use `_kv_b_proj_w_dtype` instead of `.weight.dtype`). Submitter verified fix locally. Comment from `liulanze` points at open PR #38771 as a broader fix.
- Impact on us: **High-conditional**. We're running AWQ 4-bit. MLA is DeepSeek-V3/V4-specific attention — most Qwen3.5 / Llama / Mistral models do NOT use MLA, but GLM/Kimi/DeepSeek-family do. If we run a GLM-4.7-AWQ model with prompts >~25k tokens, we will hit this. Mitigation: pin to non-MLA AWQ models OR pin to ≤25k context windows OR apply the one-line patch.
- Link: https://github.com/vllm-project/vllm/issues/43263

### #43411 — `OpenAIServingChat` silently requires new `openai_serving_render` kwarg since v0.18 (OPEN)
- Custom `OpenAIServingChat()` constructions (KubeRay + Ray Serve users) hit `TypeError: OpenAIServingChat.__init__() missing 1 required keyword-only argument: 'openai_serving_render'`. Not our path (we use `vllm serve`). https://github.com/vllm-project/vllm/issues/43411

### #42813 — Pre-quantized BnB NF4 Gemma 4 fails to load (OPEN, PR #42825 in flight)
- `AssertionError: Tried to load weights of size torch.Size([3096576, 1]) to a parameter of size torch.Size([5376, 1152])`. Gemma 4 multimodal embedder's `embedding_projection` is created without `quant_config`. Affects only pre-quantized BnB (not AWQ). Useful proof that quant-config plumbing through vision tower / projector is fragile in v0.21.0. https://github.com/vllm-project/vllm/issues/42813

---

## Medium-severity (degraded behavior, intermittent, or workarounded)

### #42696 — Gemma4 tool parser broken in streaming mode (OPEN, ~150-line rewrite proposed)
- Two distinct streaming bugs in `Gemma4ToolParser`:
  - (a) **Strict-client field re-emission**: upstream only emits `id`/`type`/`function.name` on the FIRST chunk. `@ai-sdk`'s OpenAI-compatible provider (used by OpenCode) Zod-validates EVERY chunk → 64% of agents in production fail with `AI_InvalidResponseDataError: Expected 'id' to be a string`, then 42% with `Expected 'function.name' to be a string`.
  - (b) **Multi-boundary delta mis-attribution** under high concurrency: when continuous-batching produces a delta that spans `end-of-tool-N + start-of-tool-N+1`, Case 2's guard `start_count > end_count` is false, so `current_tool_id` is never advanced; tool N's stripped trailing arg fragments leak under index N+1 in the next delta. Per-request success collapses from 100% at c≤100 → 35% at c=500 → 21% at c=1000.
- Impact on us: **High if we use Gemma 4 + tool calling at concurrency**. Direct hit on our `--enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4` path if we serve Gemma 4 models.
- Link: https://github.com/vllm-project/vllm/issues/42696

### #43238 — `qwen3xml_tool_parser`: `ast.literal_eval` fails on JSON booleans/null, complex arrays silently string-encoded (OPEN)
- `ast.literal_eval` requires Python literal syntax. Qwen3.6-27B generates standard JSON with lowercase `true`/`false`/`null`, which is NOT a valid Python literal. `ast.literal_eval('[{"multiSelect": false}]')` raises `ValueError: malformed node or string`.
- The except handler falls back to `json.dumps(raw_text)` — wrapping the raw text as a JSON string. Client receives `"questions": "\n[{\"question\": ...}]\n"` (a string) instead of `"questions": [{...}]` (an array). **Schema-validating clients fail.**
- Only triggers on `array<object>` parameters (flat `array<string>` works because `[a,b,c]` is a valid Python literal). One-line fix: try `json.loads` first, fall back to `ast.literal_eval`.
- Impact on us: **High if we use `--tool-call-parser qwen3_xml` with structured tool schemas**. Likely whenever we run Qwen3.5/3.6 with non-trivial tool argument schemas.
- Link: https://github.com/vllm-project/vllm/issues/43238

### #43436 — Qwen parsers broken all around with MTP and/or `stream-interval > 1` (OPEN)
- Title-only review. Combined MTP + Qwen tool parsers. Comments link to #43221 as the same root cause.
- Link: https://github.com/vllm-project/vllm/issues/43436

### #43221 — Streaming reasoning tokens truncated when `</think>` and `<tool_call>` appear in the same delta (OPEN)
- Qwen3.5 + `--reasoning-parser qwen3` + `--tool-call-parser qwen3_coder` + MTP (`num_speculative_tokens=3`). When MTP emits `["Write", ".", "</think>", "<tool_call>"]` in one step, the reasoning parser correctly extracts reasoning content but the tool parser overwrites `delta_message` instead of merging, dropping `Write.` from the streamed reasoning.
- Existing PRs #42691 and #43055 referenced as fixes; not yet merged at audit time.
- Workaround: turn MTP off (we don't plan to use MTP — low impact for us).
- Link: https://github.com/vllm-project/vllm/issues/43221

### #42747 — Chat Completions streaming invokes tool parser despite `tool_choice="none"` (OPEN)
- After the `DelegatingParser.parse_delta()` migration, the streaming path still calls `extract_tool_calls_streaming(...)` even when the request sets `tool_choice="none"`. Model output that matches the parser's format can be emitted as `delta.tool_calls` with `finish_reason="tool_calls"`. Non-streaming respects `tool_choice="none"` correctly — streaming does not.
- Affects any parser; example uses Kimi K2 but generic.
- Impact on us: **Medium**. If our clients ever set `tool_choice="none"` while we have a parser configured, model "tool-call-shaped" text leaks into `tool_calls`. Surprising but recoverable.
- Link: https://github.com/vllm-project/vllm/issues/42747

### #43078 — Gemma3 MM throughput regression ~5% in offline benchmark (CLOSED — turned out to be warmup, not real)
- Reporter saw ~5% throughput drop on `gemma-3-12B-it-quantized.w8a8`. Investigation showed it disappears with online benchmarking and with explicit `--num-warmup`. Root cause: PR #41181 introduced longer first-iteration warmup (more tokenizer instances?). Steady-state perf is unchanged.
- Impact on us: **None**. But worth knowing: `vllm bench throughput` without warmup gives misleadingly slow numbers for v0.21.0. If we ever bench, use `vllm bench serve` with online traffic or pass `--num-warmup`.
- Link: https://github.com/vllm-project/vllm/issues/43078

### #43308 — Massive (~9.5×) increase in KV cache capacity for Gemma 4 in v0.21.0 (OPEN — a WIN, not regression)
- `cyankiwi/gemma-4-31B-it-AWQ-4bit` on A100 80GB: vLLM 0.20.0 supported ~55k tokens KV cache; v0.21.0 supports ~525k. v0.20.0 was over-allocating by treating all Gemma 4 layers as full-attention global non-shared; v0.21.0 correctly accounts for sliding-window (1024 tok local) + shared-KV last-N-layers.
- Impact on us: **Positive**. If we run Gemma 4 AWQ, expect dramatically more headroom for long context. No code change needed on our side.
- Link: https://github.com/vllm-project/vllm/issues/43308

### #43295 — MTP appears slower than no-MTP for Qwen3.6-35B-A3B-NVFP4 (OPEN, no resolution)
- User benchmarked with and without `qwen3_next_mtp` speculative decoding. Total tok/s actually drops with MTP enabled (881 vs 1042); TPOT improves (9.4ms vs 17.4ms) but TTFT regresses badly (213s vs 153s mean). MTP acceptance is healthy (80% rate, 2.61 length).
- Note: also references a Triton JIT compilation latency spike during inference — see #43009.
- Impact on us: **None directly** (we don't plan to use MTP / spec decode), but warns that MTP-on-Qwen-NVFP4 is not a clean win.
- Link: https://github.com/vllm-project/vllm/issues/43295

### #43507 — CUTLASS MoE backend unavailable on SM_120/SM_121 for tensor/token-scaled FP8 models (OPEN, upstream blocker)
- Diagnoses why on SM_120 the FP8 MoE backend selector picks `TRITON` instead of `VLLM_CUTLASS`. Root cause is upstream in CUTLASS 4.5: there is no `CollectiveBuilder` specialization for tensor/token-scaled FP8 grouped GEMM on SM_120. The dispatch policies exist (`KernelPtrArrayTmaWarpSpecializedCooperativeSm120`) but no usages anywhere in CUTLASS — pure placeholders.
- The current `TRITON` fallback is "correct backend choice" — generating a tuned Triton MoE config for Blackwell consumer cards is a separate (lower-leverage) optimization.
- Impact on us: **Information only**. We're running AWQ, not FP8 MoE. But this is the same class as #43367 below — "SM12.1 / GB10 still fails in CutlassFp8BlockScaledMMKernel after #41215" — Blackwell consumer FP8 paths are immature.
- Link: https://github.com/vllm-project/vllm/issues/43507

### #43367 — SM12.1 / GB10 still fails in `CutlassFp8BlockScaledMMKernel` after PR #41215 (OPEN)
- Title-level read. Confirms the CUTLASS-on-Blackwell-consumer story above is broader than one model family.
- Link: https://github.com/vllm-project/vllm/issues/43367

### #43009 — Triton kernel JIT compilation during inference (OPEN)
- Warning surfaced during inference: `Triton kernel JIT compilation during inference: _topk_topp_kernel. This causes a latency spike; consider extending warmup to cover this shape/config.` Appears under sustained traffic on Qwen3.6-NVFP4.
- Impact on us: **Low-medium**. We may see latency spikes for shapes the warmup didn't cover; recoverable but cosmetically annoying in metrics.
- Link: https://github.com/vllm-project/vllm/issues/43009

### #43116 / #43104 — Granite 3.3 / 4.0 H-Small Python-style tool calls not converted to OpenAI format (OPEN, PR #43113 in flight)
- Granite 3.3 + 4.0 H-Small emit Python-style function calls (`get_weather(location="San Francisco", unit="celsius")`) as raw text in `content`. The existing `granite4` parser handles the XML `<tool_call>` format used by Granite 4.0 Tiny/Base, not the Python format. Fix is a new `granite_pythonic` parser (PR #43113).
- Impact on us: **None unless we run Granite-family models**. Workaround exists via `--tool-parser-plugin` pointing at the external file.
- Link: https://github.com/vllm-project/vllm/issues/43116, https://github.com/vllm-project/vllm/issues/43104

---

## Low-severity / noise (one-line each)

- **#43398** — `SyntaxWarning: invalid escape sequence '\e'` + duplicate `trust_remote_code` warning on startup. Cosmetic.
- **#43381** — `UVA is not available` on WSL2 + RTX 4060 Laptop. Not us.
- **#43108 / #43109** — `Triton Attention AssertionError on supported kv_cache_dtype`. Title-only.
- **#43174** — `ZeroDivisionError in deepgemm_post_process_fp8_weight_block`, TP=16 dual-node H20. Not us.
- **#43298** — `EagleMistralLarge3Model crashes with AttributeError: 'use_mha'`. Eagle + Mistral-Large-3 only.
- **#43094** — Disagg + reasoning correctness bug. Not our deployment.
- **#43521 / #43496** — `--hash-block-size 0` / `--block-size 0` → `ZeroDivisionError`. Validation hardening only.
- **#42720** — xxhash module missing when `--prefix-caching-hash-algo xxhash`. Cosmetic if unused.
- **#42932** — vLLM wheel version mismatch. Cosmetic.
- **#43163** — GLM-5.1-FP8 gibberish with RunAI streamer. Not us.
- **#43141** — DSv4 cutlass.base_dsl ImportError. Not us.
- **#42949** — DSv4-Flash on L20 worker assertion. Not us.
- **#43423** — Kimi-K2.5 8×H800 deadlock. Not us.
- **#42801** — DeepSeek R1 MMLU accuracy drop 0.10.2→0.20.2 (8×H20). Reporter shows `vllm serve` regresses while `LLM.generate()` does not — implicates serving-path (sampling/tokenization/post-processing). Open, no fix.

---

## Themes (recurring patterns across 3+ issues)

### Theme 1: **Blackwell consumer (SM_120/SM_121) is functional but immature in v0.21.0.** (#42987, #42897, #42745, #43507, #43367)
Top-k sampler hangs on first launch (#42987), event-sync hangs after hours of traffic (#42897), cudagraph-capture crashes in PyTorch fallback (#42745), CUTLASS MoE backend simply does not exist for tensor-scaled FP8 (#43507), CUTLASS FP8 block-scaled MM fails on GB10 (#43367). The pattern: NVIDIA datacenter Blackwell (SM_100, H200, B200) and Hopper (SM_90) paths are tested; consumer Blackwell (SM_120 = RTX 50; SM_121 = GB10) paths have either no implementation or untested implementation. **vLLM treats SM_120 as supported but in practice the kernel ecosystem is not there.** Our RTX 5090 with the open-driver patches is doubly off the beaten path.

### Theme 2: **Streaming tool-call parsers are uniformly buggy.** (#42696, #43238, #43221, #43436, #42747, #43411, #42878, #43116, #43104, #43267)
Of the 10+ parser bugs filed in 9 days: `gemma4` (multi-tool delta mis-attribution + strict-client fields), `qwen3_xml` (JSON booleans), `qwen3_coder` (no streaming arg deltas; reasoning/tool-call delta merge bug), `qwen3_xml + qwen3_coder` (MTP truncation), `kimi_k2` (`tool_choice="none"` not respected), `deepseekv4 DSML` (fake-streamed args), `granite4` (doesn't handle Python-style format used by Granite 3.3 / 4.0 H-Small), and the unified `DelegatingParser.parse_delta` introduced in v0.18 has its own regression (#43411 — silent constructor kwarg break). The streaming-tool-call refactor that landed v0.18-v0.20 is still settling.

### Theme 3: **ROCm-side perf regressions v0.18 → v0.21 are progressive and large (~38%).** (#43029, #43153, #43187)
Two distinct ~38% regressions on AMD MI325X (MiniMax-M2.5 FP8) and MI355X (Kimi K2.5 INT4) trace to a default attention-backend change in PR #36702 (ROCM_AITER_FA → ROCM_ATTN). Fix is config-side (`--attention-config '{"backend": "ROCM_AITER_FA"}'`) and recipes have been updated. **Not our hardware, but pattern matters: default-flag changes between releases can silently halve throughput.** We should not assume v0.20.2 → v0.21.0 perf parity on our setup without re-benchmarking.

### Theme 4: **Install-path fragility for non-default CUDA versions.** (#42756, #43435, #43480)
cu128 isn't shipped; cu129 install picks cu130-built `_C` and dies; nightly Docker pulled a broken dep transitively. The official `vllm/vllm-openai:v0.21.0` Docker image (cu130-built, all deps pinned) is the only path that "just works".

---

## Issues touching our specific stack

| Stack element | Affected? | Issues |
|---|---|---|
| AWQ 4-bit | YES | #43263 (MLA prefill `.weight` AttributeError — Severe if we run AWQ on MLA models like GLM/Kimi/DeepSeek); #43308 (positive: Gemma4-AWQ gets 9.5× KV cache) |
| Blackwell sm_120 / RTX 5090 | YES | #42987 (startup hang — severe), #42897 (steady-state event-sync hang — severe), plus #42745/#43507/#43367 indirect |
| `--enable-auto-tool-choice` + parser | YES | #42747 (`tool_choice=none` ignored in streaming); #42696, #43238, #43221, #43436, #42878 (every parser has a streaming bug) |
| OpenAI HTTP server | YES | #43411 (silent constructor kwarg break in v0.18); #42747 (streaming tool_choice); #43466 (logprob_token_ids not accepted); #43398 (cosmetic warnings) |
| Docker image (`vllm/vllm-openai`) | Partial | #43480 (`:nightly` broken for a day; reverted same day); #42906 (older `v0.19.1-cu130` image bundles pre-fix flashinfer ≤0.6.6 → CUDA IMA on MoE FP8 — confirms history of image bundling bugs) |
| Startup / engine init / weight loading | YES | #42987 (sm_120 hang); #42813 (Gemma4 BnB load fail); #43480 (Docker startup); #43521/#43496 (validation crashes) |
| TB4 / low PCIe bandwidth | Not directly mentioned | No issues filed about TB-tunneled / low-bandwidth PCIe in this window. Our setup is unusual enough that nobody else is reporting it. |
| Open driver | No issues | The vLLM team doesn't differentiate driver flavors; if it crashes, it crashes whether the driver is open or closed. |

---

## Issues NOT relevant (count + categories)

| Category | Count |
|---|---|
| Pure feature requests / RFCs | ~30 |
| DeepSeek-V4-Pro/Flash internals (MTP, NVFP4 calibration, deepgemm, megamoe) | ~30 |
| ROCm-only | ~12 |
| Internal vLLM CI failures | 9 |
| Multi-node disagg / NIXL / KV-connector | ~10 |
| TPU / XPU / CPU-only / Intel ARC | ~6 |
| Meta / code-scan dumps | 2 |

Total filtered out: ~100 of 185.

---

## Cross-link to PR landscape (audit E covers)

PRs in flight or merged: **#42987** (daniel-devlab PR awaiting RTX 5090 verification), **#42813** (PR #42825 reporter-confirmed), **#43263** (one-line fix; also in broader PR #38771), **#43221** (PRs #42691, #43055), **#43116** (PR #43113), **#43078** (PR #43245), **#43480** (closed via revert; refix pending). **No PR yet**: #42747, #42696 (rewrite proposed), #43411 (under design discussion).

---

## Risk score for our use case: **3.5 / 5** (proceed with caution; do not adopt v0.21.0 as a drop-in)

| Risk dimension | Score | Note |
|---|---|---|
| Startup will succeed at all | **3** (medium-high risk) | #42987 says we'll likely hit a silent startup hang on first launch with default sampler args on sm_120. Need monkey-patch or top_k override before we can serve. |
| Steady-state stability over hours | **3** (medium-high risk) | #42897 is unresolved and matches our hardware exactly. Build watchdog + restart-on-heartbeat-loss before relying on long-running deployments. |
| Tool-call correctness (auto-tool-choice + parser) | **4** (high risk) | Every parser we'd plausibly use has at least one open streaming bug. Pin to non-streaming OR pin to a parser we've manually validated end-to-end. |
| AWQ + MLA combination | **4** (high risk if we use it) | #43263 — guaranteed crash on long prefill for AWQ-MLA models. Avoid GLM-4.7/DeepSeek-V4 AWQ family, OR cap context, OR cherry-pick the one-line fix. |
| AWQ + non-MLA models | **2** (low-medium risk) | The MLA bug doesn't fire on non-MLA AWQ (e.g. Qwen3.5-AWQ, Llama3-AWQ); other AWQ failure modes not surfaced in this window. |
| Install via Docker image | **1** (low risk) | The official `:v0.21.0` Docker image is the safest path. Do NOT use `:nightly`. |
| Cu128 / cu129 / source builds | **3** | Not our path. |

**Bottom line for production migration**: hold v0.21.0 until either (a) #42987 lands a fix in a `.post` release we can re-test, OR (b) we verify on our specific hardware that our specific model + flags don't trip the dummy-sampler hang. If we proceed, **stay on `v0.21.0` Docker image, avoid AWQ-MLA model families, build a heartbeat watchdog, and confirm whichever tool-call parser we pick on our actual prompt distribution before flipping production traffic.**

---

## Open questions for consolidation

1. **Does the v0.21.0 Docker image's bundled FlashInfer + Triton versions reproduce #42987 on our RTX 5090?** (We need a single test launch with a small Qwen2.5/Llama3-AWQ model to find out before we plan further. Cheap: ~5 min.) If yes, the workaround monkey-patch is mandatory.
2. **Has anyone confirmed the #42897 hang on a non-MoE non-NVFP4 model on RTX 5090?** Reporter's repro is MoE+NVFP4-specific. We're AWQ — possibly safe, possibly not. Audit C / D may have evidence from older 30-day window.
3. **Which tool-call parsers in v0.21.0 actually have streaming-safe implementations?** From this audit: `hermes`, `llama3_json` are mentioned as "expose streaming `extract_tool_calls`" with the implication that they work. We should validate that claim before committing to a streaming + auto-tool-choice deployment.
4. **Does PR #38771 (broader AWQ-MLA fix) supersede the one-line #43263 fix?** Worth checking before patch picks.
5. **Should we wait for a `v0.21.1` point release?** This window saw 185 issues including ~10 high-severity fixes either merged or under-review (mgoin reverted #43480 same day; the daniel-devlab PR for #42987 awaits verification). A `.1` cleanup is plausible within 2-3 weeks based on vLLM's release cadence — and would absorb most of what we'd otherwise carry as patches.
