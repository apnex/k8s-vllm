# Audit C — 30-day bug/regression themes

**Date:** 2026-05-24
**Auditor:** subagent C (5-of-5 parallel)
**Window:** 2026-04-24 to 2026-05-24 (30 days)
**Total bug-labeled issues in window:** 301 (219 open, 82 closed)
**Methodology:** label-filtered via `gh api search/issues` (`label:bug` plus `installation`, `performance`, `nvidia`); titles tokenised into themes; bodies + top comments pulled for the 25 highest-signal exemplars across themes most relevant to our deployment surface (single-GPU Blackwell sm_120 + AWQ-4bit + OpenAI tool-call server + `vllm/vllm-openai` Docker image + k3s).

Cross-references:
- A (release notes / CHANGELOG)
- B (post-v0.21.0 early-adopter signal — narrower window, individual issues)
- D (code-diff v0.20.2..v0.21.0)
- E (PR landscape)

---

## TL;DR (3 themes that matter most for us)

1. **Streaming tool-call / reasoning parsers are broken in multiple ways across Qwen / Gemma / DeepSeek / Kimi families** — and the "multiple ways" all trace to the v0.21.0 `DelegatingParser.parse_delta` refactor + MTP delivering >1 token per delta. We use `--enable-auto-tool-choice` + family-specific parsers for AWQ Qwen3-Coder / Gemma — this is **the** theme most likely to hit us. (#43221, #43436, #42696, #42747, #41739, #43238, #42210, #41691, #40911, #40801, #40816, #41967)
2. **The cu13/cu130 transition broke the install/Docker surface in 0.21.0** — vLLM 0.21 wheel against `cu129` torch still tries to `dlopen("libcudart.so.13")`; the `vllm-openai:*-cu130` images bundle a pre-fix flashinfer; mooncake / nixl can't find `libcudart.so.12`; the `nightly` image fails import because `cupy.testing` pulls `pytest` which isn't installed. Multiple `cu13`-related landings in v0.21.0 didn't make the wheel/image matrix coherent. We pin to a tagged image so this hits us at upgrade time. (#43435, #43480, #42906, #42525, #42511)
3. **Blackwell sm_120 hits a stack of pre-existing kernel/backend pain that v0.21.0 only partially addresses** — `_dummy_sampler_run` startup hang on RTX 5090 (#42987), CUTLASS MoE backend missing on SM_120/121 (#43507), CutlassFp8BlockScaledMM still failing post-#41215 (#43367), FlashInfer + FP8-KV producing random output on sm_120 with CUDA graphs (#41651, closed but with TRITON_ATTN workaround), Triton MXFP4 MoE using Hopper-only PTX (#41477), `apply_top_k_top_p_pytorch.scatter_` crashing under cudagraph on sm_121a (#42745), stale Triton cache producing silent garbage on sm_121 (#41871), Engine `cuEventSynchronize` hang on RTX 5090 under sustained MoE traffic (#42897). We're on consumer Blackwell — most of these are class hazards for the rig even though we only run AWQ-4bit dense.

---

## Theme 1 — Streaming tool-call / reasoning parser regressions

- **Pattern:** v0.21.0 unified the streaming parser stack behind `DelegatingParser.parse_delta`. Three failure modes converge in this stack:
  1. The reasoning parser correctly extracts the reasoning content, then the tool parser **overwrites** the same `delta_message`, dropping the reasoning content (#43221, root-caused in `vllm/parser/abstract_parser.py`).
  2. MTP / spec-decode now routinely deliver `</think><tool_call>` in a single delta — every per-family parser was written assuming one boundary per delta and silently mis-attributes (#43221, #43436, #41691, #41967).
  3. `tool_choice="none"` is honoured in non-streaming but ignored in streaming — the streaming path can still enter the tool-call phase and emit `finish_reason="tool_calls"` (#42747). Same regression in the unified path.
  4. Per-family parsers each have their own state-machine bugs: Gemma4 streaming float-truncation (`108.2` → `108.02`, #42047 — closed but reopened-in-spirit by #42696); Gemma4 multi-boundary delta mis-attribution under load (#42696); Kimi K2 / K2.6 passes malformed JSON in `arguments` without validation (#41739); Qwen3-XML parser's `ast.literal_eval` fails on JSON booleans/null and string-encodes complex array args (#43238); GLM5.1 can't combine streamed arguments into a complete dict (#42167); MiniMax buffers function-call content instead of streaming incrementally (#40779).
  5. Stop-string interruption drops partial content (#42210). Tool-call leaks into content for some models (#40911).
- **Affected versions:** the unified-parser refactor landed by v0.21.0; reporters reproduce on `vllm/vllm-openai:v0.21.0` and on `0.21.1rc1.dev*` nightlies. Some symptoms (#43221 case 1, lost-reasoning-tokens) pre-date 0.21 — reporter in #43436 says *"it was here for months already"* — but the multi-boundary class became worse with v0.21.0's broader MTP enablement.
- **Affects us?:** **YES, directly and high-confidence.** Our serving args are exactly the trigger:
  - `--enable-auto-tool-choice` + `--tool-call-parser` (family-specific: `qwen3_coder`, `gemma4`, etc.) + `--reasoning-parser`
  - OpenAI streaming Chat Completions clients (Claude-Code-style / opencode / aider) — all use the same Zod-strict schema #42696 documents
  - We're not locked to one model — we rotate Qwen3-Coder, Gemma, etc. — so we inherit each family's parser bugs
  - AWQ-4bit doesn't change the parser path (parsers run on tokens, post-sampler), so AWQ doesn't insulate us
- **Example issues:**
  - #43221 [open, 4c] Streaming reasoning tokens truncated when `</think>` and `<tool_call>` appear in the same delta — https://github.com/vllm-project/vllm/issues/43221
  - #43436 [open, 2c] Qwen parsers broken all around with MTP and/or stream-interval > 1 — https://github.com/vllm-project/vllm/issues/43436
  - #42696 [open, 9c] Gemma4 tool parser is broken in the streaming mode (for OpenCode) — https://github.com/vllm-project/vllm/issues/42696
  - #42747 [open, 0c] Chat Completions streaming invokes tool parser despite `tool_choice="none"` — https://github.com/vllm-project/vllm/issues/42747
  - #41739 [open, 7c] Kimi 2.6 + Kimi K2 tool parser passes malformed JSON in tool-call arguments to client without validation — https://github.com/vllm-project/vllm/issues/41739
  - #43238 [open, 1c] qwen3xml_tool_parser ast.literal_eval fails on JSON booleans/null — https://github.com/vllm-project/vllm/issues/43238
- **Workaround if any:**
  - Disable MTP / spec-decode (`--speculative-config '{}'` or omit) — kills the multi-token-per-delta class of bugs at the cost of decode TPS.
  - Set `--stream-interval 1` (no batching of tokens into deltas) — kills the multi-boundary class but loses some of the `0.21` streaming throughput gain.
  - Use non-streaming chat for tool-call-heavy paths; switch to streaming only for free-form generation. Painful UX but airtight.
  - Per-family: pin to known-good parser commits or set `tool_choice="required"` (#42696 notes the wire shape differs and `required` skips the parser via structured-output → tool_calls converter at `chat_completion/serving.py:~480`).
- **Fix in flight / merged?:** #42696 has a draft patch from `@dchichkov` (rewrite Gemma4 emitter to compute end-count diffs and emit one DeltaToolCall per newly-closed tool call); #43221 has a root-cause analysis pointing at `DelegatingParser.parse_delta` requiring an additive merge instead of overwrite, no PR linked yet. #43267 is a tracking RFC for "Support streaming output for tool_calls arguments" — implies the broader path is being looked at.

## Theme 2 — cu13 / cu130 / wheel / Docker image incoherence in v0.21.0

- **Pattern:** v0.21.0 added cu13 builds but the wheel + Docker matrix is internally inconsistent. Specific failures:
  - vLLM 0.21 + `torch 2.11.0+cu129` tries to `dlopen("libcudart.so.13")` (#43435). User workaround documented: `uv pip install vllm --extra-index-url https://wheels.vllm.ai/0.21.0/cu129 --extra-index-url https://download.pytorch.org/whl/cu129 --index-strategy unsafe-best-match`. Fixed indirectly — issue is closed — but indicates wheel-selection is not robust on stock `pip install vllm` paths.
  - `vllm-openai:v0.19.1-cu130` / `:v0.16.0-cu130` images ship pre-fix flashinfer (≤ 0.6.6) → CUDA IMA on MoE FP8 decode (#42906). The :cu130 image flavour is not equal to the :cu128/cu129 flavour quality-wise.
  - mooncake-transfer-engine fails to import in CUDA 13 images because `libcudart.so.12` is missing (#42511, #42525). Affects users of disagg / KV-transfer, not us, but signals the image is not self-consistent.
  - `vllm/vllm-openai:nightly` (`0.21.1rc1.dev243+ga5bbd81e2`) crashes at startup importing `humming` → `cupy.testing` → `pytest` (not in runtime image, #43480). Closed quickly but tells us "nightly = production-ready" is false.
  - `vllm serve … --prefix-caching-hash-algo xxhash` starts healthy then ModuleNotFoundError on every request (#42720) — `xxhash` is an optional dep the CLI accepts without checking.
- **Affected versions:** v0.19.1+, but the cluster around the cu13 transition is concentrated in v0.20.x → v0.21.0.
- **Affects us?:** **YES, at upgrade boundaries.** We use `vllm/vllm-openai:vX.Y.Z` (not `:nightly`, not from-source). Pinning to a tagged image insulates us from #43480 directly. But:
  - We'd need to choose between `:v0.21.0` and `:v0.21.0-cu130` (or whatever the published variants are) — A's findings should tell us; verify the image we pull doesn't have the flashinfer-pre-fix problem of #42906.
  - Our injector ships CUDA driver 595.x; the container is `cuda:13.0-base-ubuntu24.04` already (per project memory). So we're on the cu13 side of the split — exactly the side that broke for nixl / mooncake. Run a smoke test against our image post-upgrade before any production switch.
- **Example issues:**
  - #43435 [closed, 3c] installing vllm 0.21 with cu129 torch backend tries to open libcudart.so.13 — https://github.com/vllm-project/vllm/issues/43435
  - #43480 [closed, 3c] vllm-openai nightly fails to start due to missing pytest via humming/cupy — https://github.com/vllm-project/vllm/issues/43480
  - #42906 [open, 0c] vllm-openai:v0.19.1-cu130 / v0.16.0-cu130 bundle pre-fix flashinfer — https://github.com/vllm-project/vllm/issues/42906
  - #42511 [open, 0c] mooncake-transfer-engine fails to import in CUDA 13 images — https://github.com/vllm-project/vllm/issues/42511
  - #42720 [open, 0c] vllm serve starts healthy but all requests fail when `--prefix-caching-hash-algo xxhash` — https://github.com/vllm-project/vllm/issues/42720
- **Workaround if any:** stay on cu128/cu129 image variants if A or D confirms they're still published for v0.21.0; smoke-test the image we pull with `from mooncake.engine import TransferEngine` even though we don't use it (proxy signal for libcudart consistency).
- **Fix in flight / merged?:** #43435 closed (resolved by index-strategy guidance); #43480 closed; others open.

## Theme 3 — Blackwell sm_120 / sm_121 (consumer/server Blackwell) kernel + backend hazards

- **Pattern:** consumer/server Blackwell (sm_120 RTX 5090 / RTX PRO 6000; sm_121 / GB10 / DGX Spark) hits a long list of kernel-coverage and backend-stability bugs that are independent of our model choice or our reliability stack. The cluster:
  - **Startup hang on RTX 5090:** `_dummy_sampler_run` calls the sampler with `top_k = vocab_size - 1` (`151935` for Qwen2.5-3B), and the sm_120 top-k Triton kernel hangs. Reporter has a one-line fix (use `top_k=50` for the dummy run, identical KV-cache memory footprint). One-liner not yet merged (#42987).
  - **CUTLASS MoE backend missing for SM_120/SM_121:** dropped to a non-CUTLASS path that's slower / less coverage (#43507). Affects any token/tensor-scaled FP8 MoE.
  - **CutlassFp8BlockScaledMMKernel still fails on SM12.1 / GB10 after #41215** (#43367) — the upstream "fix" was incomplete.
  - **FlashInfer + FP8 KV + CUDA graphs → random output on sm_120** (#41651, closed with TRITON_ATTN workaround documented). H100/B200 unaffected; consumer Blackwell only.
  - **Triton MXFP4 MoE kernel uses `.tile::scatter4` PTX (Hopper/SM10 only) — fails on SM 12.1**, Marlin fallback hits #37030 (#41477). Forces eager mode for MXFP4 on Blackwell server / DGX Spark.
  - **`apply_top_k_top_p_pytorch.scatter_` crashes under cudagraph on sm_121a** (#42745).
  - **Stale Triton kernel cache on DGX Spark sm_121** produces silently-garbled outputs; `rm -rf ~/.triton/cache` restores correctness (#41871). This is a silent-corruption class hazard — no error, wrong tokens.
  - **EngineCore hangs in `cuEventSynchronize` under sustained traffic on RTX 5090 sm_120** with Qwen3.6-35B-A3B-NVFP4 (#42897, closed but root cause not in release notes). Symptom: HTTP healthy, engine produces nothing, only restart clears.
  - **`/wake_up` fails on hybrid-SWA / Mamba / DeltaNet on sm_120 NVFP4** — `'list' object has no attribute 'zero_'` (#41564). Doesn't affect us (we don't sleep/wake).
  - **DeepEP MoE all-to-all unusable on Blackwell (SM103/GB300)** (#41687).
  - **`MiMo v2.5` broken on SM12x** (#41519, 15c) — wide enough symptom to surface even though we don't run it.
- **Affected versions:** v0.20.x and v0.21.0. The sm_120 hazards are a stack of independent kernel bugs that v0.21.0 partially patches (#41215 attempt, #43298 Eagle fix, more) but does not exhaustively close.
- **Affects us?:** **MAYBE → YES, by class hazard.** We run AWQ-4bit dense models on a single sm_120 RTX 5090 over TB4:
  - We don't run FP8 KV, MoE, NVFP4, MXFP4, or `/wake_up`, so most specific bugs miss.
  - We DO hit the same top-k / sampler / cudagraph paths as #42987 (`_dummy_sampler_run` hang) and #42745 (`scatter_` cudagraph crash) — these are model-agnostic. The #42987 fix is a one-liner not yet merged → check if our image v0.21.0 has the hang, mitigate with `--enforce-eager` if so.
  - We're on `vllm/vllm-openai:vX.Y.Z`; the Triton cache is inside the container so #41871's "wipe `~/.triton/cache`" is a no-op for us under image-as-immutable, **but** if we ever rebuild on top, the silent-garbled-output class is real.
  - #42897 (EngineCore `cuEventSynchronize` hang under sustained traffic on RTX 5090) is the highest-impact for our long-running k3s DaemonSet pattern even though the reporter was on NVFP4 MoE and we're on AWQ-4bit dense. Worth a liveness-probe with token-output-rate check rather than just `/health`.
- **Example issues:**
  - #42987 [open, 3c] `_dummy_sampler_run` hangs indefinitely on RTX 5090 — https://github.com/vllm-project/vllm/issues/42987
  - #42897 [closed, 1c] EngineCore hangs in `cuEventSynchronize` under sustained traffic on RTX 5090 — https://github.com/vllm-project/vllm/issues/42897
  - #43507 [open, 0c] CUTLASS MoE backend unavailable on SM_120/SM_121 — https://github.com/vllm-project/vllm/issues/43507
  - #43367 [open, 3c] SM12.1 / GB10 still fails in CutlassFp8BlockScaledMMKernel after #41215 — https://github.com/vllm-project/vllm/issues/43367
  - #41651 [closed, 5c] FlashInfer + FP8 KV + CUDA graphs random output on sm_120 — https://github.com/vllm-project/vllm/issues/41651
  - #41871 [open, 3c] Stale Triton kernel cache on DGX Spark sm_121 produces silently garbled outputs — https://github.com/vllm-project/vllm/issues/41871
- **Workaround if any:** known per-bug — `--enforce-eager`, `TRITON_ATTN` backend, wipe Triton cache, avoid `--kv-cache-dtype fp8` on FlashInfer. None unconditionally needed for our AWQ-dense path; smoke-test required.
- **Fix in flight / merged?:** #42987 one-liner not yet merged; #41651 closed (workaround); #41215 was the partial sm_120 cutlass attempt and #43367 says it's still broken on SM12.1.

## Theme 4 — `0.21.0` engine init / startup crash regressions

- **Pattern:** v0.21.0 introduced several engine-init regressions that the release notes don't surface:
  - `EagleMistralLarge3Model` crashes with `AttributeError: 'use_mha'` because PR #16383 moved `load_weights` to `DeepseekV2Model` but `EagleMistralLarge3Model.__init__` calls `nn.Module.__init__` directly instead of `super().__init__()` (#43298). Same class of bug as previous #37232 with `aux_hidden_state_layers`.
  - `kv_cache_offload` crashes on 0.21.0 with KeyError in `_block_id_to_pending_jobs[bid]` (#42761).
  - TurboQuant + MTP workspace-reservation mismatch (#42808, #43357) — TurboQuant locks workspace size after CUDA-Graph capture, MTP draft model forward asks for additional 0.76 MB, AssertionError dies on first request.
  - v0.21.0 release missing PR #42320 → DeepSeek-V4 MTP fails with `TypeError: missing required positional argument: post_mix` (#42701) — a known-fix-not-cherry-picked regression.
  - DeepSeek-V4-pro PP+TP CUBLAS error on H800 8x2 (#43080).
  - `--block-size 0`, `--hash-block-size 0` silently pass CLI validation, crash engine init with `ZeroDivisionError` (#43521, #43496).
  - `--block-size 1 or 8` listed as valid CLI choices but crash KV cache init (#42510).
  - `--runner draft` / `--runner generate` silently accepted for embedding models, opaque crash during weight loading (#43061).
  - Various `--kv-cache-dtype` values (`fp8_ds_mla`, `fp8_e5m2`, `fp8_inc`, `bfloat16`) accepted by CLI but crash at engine init (#42587).
  - `--convert` with a causal LM silently accepted, crashes (#42480).
- **Affected versions:** specifically v0.21.0.
- **Affects us?:** **NO for the specific bugs** (we don't use Eagle / Mistral-Large / kv_cache_offload / TurboQuant / `--runner` / `--block-size` / `--convert` / `fp8_ds_mla`). **YES for the pattern**: v0.21.0 has weak CLI validation — invalid configs silently pass argparse and crash at engine init with opaque errors. We should sanity-grep our serve args against the new CLI surface (A or E should produce a diff).
- **Example issues:**
  - #43298 [open] EagleMistralLarge3Model crashes 'use_mha' on vLLM 0.21.0 — https://github.com/vllm-project/vllm/issues/43298
  - #42761 [open, 4c] kv_cache_offloadig crashes on 0.21.0 — https://github.com/vllm-project/vllm/issues/42761
  - #42808 [open, 3c] TurboQuant + MTP workspace assertion on v0.21.0 — https://github.com/vllm-project/vllm/issues/42808
  - #42701 [open, 3c] v0.21.0 release missing PR #42320 — https://github.com/vllm-project/vllm/issues/42701
  - #43521 [open, 0c] `--hash-block-size 0` silently passes validation — https://github.com/vllm-project/vllm/issues/43521
- **Workaround if any:** validate CLI args against actual serve start under `--enforce-eager --max-model-len 1024` smoke before promotion.
- **Fix in flight / merged?:** #43298 has a one-line suggested fix in the issue body; #42701's missing PR #42320 implies a 0.21.1 roll-up is appropriate.

## Theme 5 — Speculative decoding / MTP / Eagle as a regression amplifier

- **Pattern:** MTP and Eagle speculative-decoding are the common factor in a disproportionate share of v0.21.0 crashes and output-quality bugs. The pattern is "spec-decode delivers >1 token per scheduler step → downstream code assumed 1 token per step":
  - MTP causes the streaming-parser multi-boundary class above (Theme 1).
  - MTP + TurboQuant workspace mismatch (#42808, #41726, #43357, #40807, #41700).
  - DeepSeek-V4-Pro TP=8 MTP RPC timeout / TP-Worker hang (#41530).
  - DeepSeek-V4-Flash MTP fails after release missed PR #42320 (#42701).
  - MTP speculative-decoding illegal-memory-access on long sequences (Qwen3.6-27B-FP8) — #40756 (31 comments, the most-commented bug in the window).
  - DFlash speculative decoding dtype mismatch float vs c10::Half (#42588).
  - Eagle 2/3 acceptance length regression over time (#41838, 16c).
  - Gemma4 MTP avg draft acceptance 0.2% (#41789, 8c) — effectively dead spec-decode.
  - Frequent crashes with Gemma4 MTP enabled (#42261).
  - Gemma4 + MTP first-tool-call arguments dropped in streaming multi-tool auto-tool-choice (#41967).
  - `--decode-context-parallelism` output drift + gibberish (#41623, 14c) — adjacent to spec-decode.
- **Affected versions:** entrenched through v0.20.x and v0.21.0; v0.21.0's broader MTP enablement increases attack surface.
- **Affects us?:** **NO directly** — we don't enable speculative decoding. We've never asked for spec-decode and there's no good draft model for our AWQ-Coder/Gemma rotation that's worth the complexity. **YES indirectly**: spec-decode is a default in some recipe configs the Docker entrypoint might pick up. Confirm our serve args don't enable `--speculative-config` or `--num-speculative-tokens` (a sed-grep is sufficient).
- **Example issues:**
  - #40756 [open, 31c] MTP illegal memory access on long sequences — https://github.com/vllm-project/vllm/issues/40756
  - #42808 [open, 3c] TurboQuant + MTP workspace assertion v0.21.0 — https://github.com/vllm-project/vllm/issues/42808
  - #41789 [open, 8c] Gemma4 MTP 0.2% draft acceptance — https://github.com/vllm-project/vllm/issues/41789
  - #41838 [open, 16c] Eagle 2/3 acceptance length regression — https://github.com/vllm-project/vllm/issues/41838
- **Workaround if any:** don't enable spec-decode. If a model's recipe defaults it on, override with `--speculative-config '{}'` or omit the flag.
- **Fix in flight / merged?:** scattered; no single rollup.

## Theme 6 — v0.20.0 MoE perf regression (still open into v0.21.0)

- **Pattern:** v0.20.0 introduced a 21% TPOT / 59% TTFT / -19% throughput regression on Mixtral-8x7B (MoE) vs v0.19.0; dense models unaffected (#41306). Other reporters confirm Qwen3.5-35B-A3B-NVFP4 and Kimi K2.6 slower on v0.20.0+ (12 comments, 3 independent reports). Implication: v0.21.0 likely inherits unless explicit MoE perf fix in release notes (A's scope).
- **Affected versions:** v0.20.0+; suspected through v0.21.0.
- **Affects us?:** **NO** — we run dense AWQ-4bit models exclusively. MoE is out of scope per project memory.
- **Example issues:**
  - #41306 [open, 12c] v0.20 latency and throughput regression on MoE models — https://github.com/vllm-project/vllm/issues/41306
  - #43096 [closed, 1c] Performance degradation on MoE models with low batch sizes since vLLM v0.20.0 — https://github.com/vllm-project/vllm/issues/43096
- **Workaround if any:** stay on v0.19.x for MoE workloads (not applicable to us).
- **Fix in flight / merged?:** unclear.

## Theme 7 — AWQ-specific bugs (small but directly on our path)

- **Pattern:** AWQ-quantization issues, low in count but each one is on our serving path:
  - **AWQ MLA prefill regression after PR #34695** — AttributeError in `mla_attention.py:L2094` `_compute_prefill_context` on long prefill with AWQ model (#43263). MLA is DeepSeek-V2/V3 family — we don't run MLA models, so this is not directly ours, but the regression site is in `vllm/attention/backends/mla/`.
  - **LoRA on AWQ-quantized Llama-3.1-8B / Llama-3.2-3B produces degenerate output** (#42488). Same LoRA infra works on AWQ Mistral and on FP8/BF16 Llama — Llama-AWQ-LoRA specifically is broken. Doesn't affect us (we don't use LoRA), but indicates AWQ + adapter paths are not exhaustively tested.
  - **Qwen 3.6 AWQ can't load, always OOM** (#42147). 2 comments. Our exact model family (different generation but same quant). Watch for whether v0.21.0 is the trigger.
  - **`'_C' object has no attribute 'awq_dequantize'` on Intel Arc B580 XPU** (#41469). Not our hardware.
- **Affected versions:** v0.20.x → v0.21.0.
- **Affects us?:** **MAYBE — direct on path, low count.** AWQ-4bit on Qwen3-Coder is what we serve. #42147 is the live concern even though it's only 2 comments — small comment count may reflect "everyone working around it silently" since AWQ OOM is the kind of bug an operator just sees as "model too big for the GPU".
- **Example issues:**
  - #42147 [open, 2c] Qwen 3.6 awq can't load, always OOM — https://github.com/vllm-project/vllm/issues/42147
  - #43263 [open, 1c] AttributeError in mla_attention.py L2094 on long prefill with AWQ model — https://github.com/vllm-project/vllm/issues/43263
  - #42488 [open, 0c] LoRA on AWQ-quantized Llama-3.1-8B / Llama-3.2-3B produces degenerate output — https://github.com/vllm-project/vllm/issues/42488
- **Workaround if any:** for #42147 specifically, halve `--gpu-memory-utilization` and / or set explicit `--max-model-len` rather than relying on auto.
- **Fix in flight / merged?:** none visible.

## Theme 8 — KV-transfer / disagg / NIXL / Mooncake / kv_offload instability

- **Pattern:** the disaggregated-prefill + KV-transfer stack (NIXL, Mooncake, OffloadingConnector, HMA) generated ~14 issues in the window — most around startup failure or KeyError mid-stream (#42761, #41515, #40993, #41048, #42395, #42385, #43093, #41830, #42895). Some are CUDA-13-image-related (Theme 2 overlap: #42511, #42525).
- **Affected versions:** v0.20.x → v0.21.0.
- **Affects us?:** **NO** — we don't use KV transfer / disagg / HMA / NIXL / mooncake. Single-GPU + single-node.
- **Example issues:** (excluded from headline list)
- **Workaround if any:** N/A.

## Themes touching our stack specifically

### AWQ-4bit (Qwen3-Coder, Gemma, etc.)
- **In scope:** Theme 1 (parsers run after AWQ — unaffected by quant), Theme 4 (engine init), Theme 7 (AWQ-specific OOM and LoRA bugs).
- **Hot issue:** #42147 (Qwen 3.6 AWQ OOM) — directly on our model family.

### Blackwell sm_120 / RTX 5090
- **In scope:** Theme 3 (entire cluster), Theme 4 (init crashes), and the silent-corruption hazard #41871 (Triton cache).
- **Hot issues:** #42987 (RTX 5090 startup hang, one-line fix not yet merged), #42897 (RTX 5090 EngineCore hang under sustained traffic — closed but root cause opaque), #43507 (CUTLASS MoE backend missing — moot for us since we're dense, but indicates kernel-coverage gaps).
- **Specific to our hardware:** we are the targets of this cluster. Mandatory: smoke-test our build against `--enforce-eager` baseline and against full CUDA-graph mode separately.

### TB4-tunneled PCIe
- **In scope:** nothing directly in the bug-issue corpus — vLLM doesn't surface TB4 as a distinct failure mode. The kernel hangs (#42897, #42987) could *interact* with our PCIe-recovery stack (the project's A2/A3 watchdog might mistake an engine-side hang for a PCIe transient). Worth telemetry-checking.

### OpenAI-compatible HTTP server + tool-call parser
- **In scope:** Theme 1 (the headline risk), plus #42747 (`tool_choice="none"` ignored in streaming).
- **Hot issues:** ALL of Theme 1. This is the single biggest user-visible risk for us.

### Docker image / startup / Kubernetes
- **In scope:** Theme 2 (Docker), Theme 4 (engine init), plus:
  - #42389 — `vllm serve` TP=8 on Kubernetes + vGPU NCCL TCPStore broken pipe (not our config — TP=1).
  - #42017 — GPU memory not freed after vLLM crash (relevant: if engine OOMs in k3s, will the pod restart free GPU memory? Our DaemonSet model with `restartPolicy: Always` should, but verify).
  - #41933 — Wrongful detection of WSL (we're on bare-metal Linux, doesn't apply).

### k3s / DaemonSet deployment substrate (migration in flight per project memory)
- **In scope:** #42389 (k8s + vGPU TCPStore), #42017 (post-crash GPU memory), #43206 (port collision when launching multiple LLM instances concurrently on a node — not our config but DaemonSet means one pod per node).
- No `k8s`/`kubernetes`/`daemonset` themes in the window beyond these point bugs. DaemonSet path is not exercised by enough users to surface as a theme — both an opportunity (we're early enough to define patterns) and a risk (we'd be one of few hitting any k3s-specific edge case).

---

## "Noise" themes excluded (one-line each)

- **DeepSeek-V4 family bugs (~34 issues)** — we don't run DeepSeek-V4. Largest in count but not on our path.
- **ROCm / AMD MI355 / R9700 bugs (~8 issues)** — different vendor entirely.
- **Intel Arc / XPU bugs (#41663, #41469)** — different vendor.
- **MoE-specific bugs (Kimi-K2, Mixtral, GLM-5.1 MoE, etc.)** — we're dense-only.
- **NVFP4 / FP8 / MXFP4 / fp8_e5m2 KV bugs** — we're AWQ-4bit only.
- **`/wake_up`, `sleep`, `/v2/embed` bugs** — features we don't use.
- **Long-context bugs ≥64k (#41125, #43428)** — our context bound is well below this.
- **Pipeline-parallel / multi-node bugs (#41864, #41287, #41530)** — single GPU.
- **collect_env crashing on macOS/Windows (#41906)** — we're on Linux.
- **Distributed RDMA / IB / NIXL (Theme 8 in full)** — single-node.

---

## Risk score for our use case: **3 / 5**

Rationale:
- **+2** Theme 1 (streaming tool-call parsers) is **directly on our serving path** with multiple confirmed open bugs and a known-fragile post-refactor code site (`DelegatingParser.parse_delta`). High likelihood of user-visible bugs as we rotate models.
- **+1** Theme 3 (Blackwell sm_120) is a class hazard — most specific bugs miss us, but #42987 (RTX 5090 startup hang) and the Triton-cache silent-corruption class are real and one-liner-not-yet-merged.
- **+0.5** Theme 4 (CLI validation looseness in v0.21.0) — small effort to mitigate (smoke-test serve args), real if skipped.
- **−0.5** Themes 5/6/7/8 mostly miss us (we don't enable spec-decode, don't run MoE, don't use KV-transfer, don't use LoRA).
- **−0.5** We pin to a tagged Docker image (not `:nightly`), which dodges Theme 2's nightly-image failure modes.

Net: not a "stop-the-press" upgrade — but not a no-op either. Treat as a v0.21.0 → smoke-test → soak → cutover cycle (analogous to our patch cutover discipline), not a drop-in.

---

## Open questions for consolidation

1. **A:** Does v0.21.0's release-notes / CHANGELOG mention the `DelegatingParser.parse_delta` refactor? If yes, that's the primary upgrade-risk to call out. If no, surface it from C.
2. **A/D:** Is the `vllm/vllm-openai:v0.21.0` image cu128 / cu129 / cu130 by default? Does it bundle a post-fix flashinfer (≥ 0.6.7)? This determines whether #42906 affects us.
3. **B:** Of the post-v0.21.0 release issues, how many cluster into Theme 1 (streaming parsers)? If B sees the same theme dominate, that's strong corroboration → mitigation priority.
4. **B:** Has #42987 (RTX 5090 `_dummy_sampler_run` hang) reproduced post-v0.21.0 specifically, or is it a v0.20.x-era issue someone bumped? The fix is one-line; check if it's in v0.21.0.
5. **D:** What is the v0.20.2..v0.21.0 diff in `vllm/parser/` and `vllm/entrypoints/openai/serving_chat.py`? Theme 1 root cause should be visible there.
6. **D:** Is PR #42320 (DeepSeek-V4 MTP `post_mix`) in v0.21.0? Reporter #42701 says no.
7. **E:** Are there merged-but-not-released fixes for Theme 1 parsers on `main` that point at a near-term v0.21.1?
8. **Cross-cutting:** should our upgrade plan be:
   (a) skip v0.21.0, wait for v0.21.1 with Theme 1 fixes;
   (b) take v0.21.0 with `--stream-interval 1` workaround;
   (c) take v0.21.0 with parsers disabled (non-streaming tool-calls only);
   (d) stay on v0.20.2?
   C's answer leans (a) if v0.21.1 is imminent (E to confirm) or (b) if it is not. (d) is dispreferred — v0.20.2 has the MoE perf regression (irrelevant to us) but also has the `/v2/embed` API-key bypass (#42591, security).
