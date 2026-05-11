# vLLM perf hypothesis ledger

> **Living document.**
> Tracks every open hypothesis about how to push our vLLM stack
> for higher quality + higher throughput on heavy software-engineering
> workloads via OpenCode.
>
> **Companion: [`model-config-matrix.md`](./model-config-matrix.md)** —
> at-a-glance table of every (model × backend × KV scheme × spec) cell
> we've tested or plan to test, with results.
> Use the matrix to see *what's been measured*;
> use this ledger to understand *why each test was chosen*.
>
> **Discipline.**
> Mirrors `aorus-5090-egpu/docs/reliability-hypothesis-ledger.md`:
> no hypothesis declared resolved on n=1;
> quality gate before every speed change;
> measurement protocol locked before each test.
>
> **Companion docs.**
> [`perf-roadmap.md`](./perf-roadmap.md) — narrative, cold-load focus
> (now H11–H13 in this ledger).
> [`reliability-hypothesis-ledger.md`](https://github.com/apnex/aorus-5090-egpu/blob/main/docs/reliability-hypothesis-ledger.md)
> in the companion repo — pattern reference.

---

## Workload definition

What we're optimizing for, made explicit so every measurement
is interpretable:

- **Client.** OpenCode 1.14.x, agent mode (build / plan / edit sub-agents).
- **Tasks.** Heavy software engineering — codebase exploration,
  multi-file edits, long-context refactoring, test generation,
  debugging from stack traces.
- **Prompt shape.**
  System + tool definitions ~6–10k tokens, fixed across calls;
  conversation history grows 5–25k tokens during a session;
  occasional code attachments push prefill into 30k+.
- **Tool-call density.** 10–50 tool calls per non-trivial task.
- **Concurrency pattern.** Single user, but **OpenCode forks parallel
  sub-agents** — measure both single-stream latency and
  fan-out aggregate throughput.

## Quality dimensions (locked before any speed change)

| Dimension | Why it matters | How we measure |
|---|---|---|
| Tool-call success rate | Retries waste tokens + wall-clock | Count schema-failure retries on the regression suite |
| Code correctness | The whole point | Aider Polyglot pass-rate (subset of 30 problems) |
| Long-context fidelity | Real codebases are big | Manual: insert known fact mid-context, ask later |
| Reasoning depth | SWE needs plans, not patches | Subjective 1–5 on multi-step refactor tasks |
| Instruction following | Agents that ignore constraints are dangerous | Structured-output suite (JSON schemas) |

## Performance dimensions

| Dimension | Why it matters | How we measure |
|---|---|---|
| TTFT | Interactive UX driver | curl `--write-out` time-to-first-byte |
| Decode tok/s | Aggregate throughput | `usage.completion_tokens / wall_clock` over n=3 |
| Concurrent throughput | Sub-agent fan-out | Fire 4 parallel requests, sum tok/s |
| Cold start (warm cache) | Pod restart latency | Container start → `Application startup complete` |
| Cold load (cold cache) | First-ever start | Container start → ready, with HF cache empty |

## Hardware ceilings (NUC 15 Pro+ with AORUS RTX 5090 over TB4)

| Resource | Limit | Notes |
|---|---|---|
| VRAM | 32 GB | hard ceiling |
| 4-bit weight budget | ~64 GB params | AWQ / NVFP4 |
| 8-bit weight budget | ~32 GB params | FP8 / INT8 |
| bf16 weight budget | ~14 GB params | tightens fast with KV cache |
| H2D bandwidth | ~2.66 GB/s | TB4-saturated; first-load bottleneck |
| System RAM | 128 GB | huge — can stage models in CPU |
| Compute | Blackwell sm_120 | FP8 + INT4 native tensor cores |

## Measurement protocol

**Quality gate (must run before declaring any H complete):**

1. Aider Polyglot subset.
   See [`tools/polyglot-bench.sh`](../tools/polyglot-bench.sh) —
   custom minimal runner (no aider package dependency,
   directly drives vLLM via curl, runs language-native tests).
2. OpenCode hand-crafted suite (TODO) — 5 representative tasks, scored 1–5.
3. Tool-call retry count on the suite (target: 0 per task).

**Reproducibility caveats found 2026-05-09 during H1 baseline attempt:**

- vLLM with continuous batching is **non-deterministic at temp=0**
  unless `seed` is pinned.
  Greedy decoding's tie-breaking has small numerical jitter from batched
  forward passes.
  **The harness MUST send `seed: 42` (or any fixed int) on every request**
  for runs to be comparable.
- Some problems are token-budget-sensitive
  (Gemma 4 26B-A4B is verbose on `bowling`, `food-chain`, `beer-song`);
  `max_tokens=8192` is still tight.
  Either bump to 16384 or add "be concise" to the prompt.
- Both fixes pending (see "Open methodology issues" below).

**Performance benchmark (run before + after each change):**

```bash
./tools/perf-snapshot.sh > archive/perf-2026-MM-DD-<H>-<status>.log
```

Captures:
TTFT, decode tok/s ×3 runs, concurrent 4-way decode tok/s,
container start time,
prompt-prefill speed at 8k / 16k / 32k tokens.

**Reproducibility.** Every datapoint is captured at a frozen `vllm`
image tag, frozen model SHA, and frozen kernel cmdline.
The companion `aorus-5090-egpu/status.sh` snapshot goes alongside.

---

## Status legend

| Status | Meaning |
|---|---|
| **OPEN** | Hypothesis stated; measurement not yet run |
| **ACTIVE** | Currently testing |
| **SUPPORTED** | Evidence leans for; n insufficient to declare PROVEN |
| **PROVEN** | n≥3 consistent evidence; default config updated |
| **FALSIFIED** | n≥3 contradictory evidence |
| **DEFERRED** | Lower priority; revisit later |

---

## Hypotheses

### H1 — RESOLVED 2026-05-10: Qwen3-Coder-30B-A3B-AWQ is the locked base model

| Field | Value |
|---|---|
| Status | **RESOLVED 2026-05-10** — Qwen3-Coder-30B-A3B-AWQ wins decisively |
| Stated | 2026-05-09 |
| Motivation | Qwen3-Coder is code-pretrained + RLHF'd specifically for SWE; Gemma 4 is general-purpose. Both are MoE with ~3-4B active params, so decode speed should land in the same bucket. Quality on Aider Polyglot for Qwen3-Coder-30B-A3B reportedly leads dense 70B models. |
| Quality gate | Aider Polyglot subset pass-rate must beat alternatives. |
| Test plan | Pull each candidate. Swap `VLLM_MODEL`, restart, run polyglot-bench.sh + perf-snapshot. Compare. |
| Measurement | Aider Polyglot pass-rate (%); decode tok/s ×3; concurrent-4 decode tok/s. |
| **Result — Qwen3-Coder-30B-A3B-AWQ baseline (R1, 2026-05-10 07:20)** | 4/5 polyglot (80%); 253 tok/s decode; 714 tok/s concurrent-4. Archive: `perf-20260510T072055Z-qwen3-coder-30b-a3b-H1-qwen3-baseline/`. |
| **Result — Qwen2.5-Coder-32B-Instruct-AWQ dense challenger (R8, 2026-05-10 20:21)** | **1/5 polyglot (20%); 76 tok/s decode (-70%); 297 tok/s concurrent-4 (-58%).** Loses on both quality AND speed. The decode gap matches the ~3.3× active-param ratio (32B dense vs 3B MoE active). The polyglot gap is real algorithmic capability — Qwen2.5 generates well-formed code that's logically incorrect on the harder problems (book-store's optimal-grouping puzzle, bottle-song's recursive generation). Archive: `perf-20260510T102121Z-qwen2.5-coder-32b-base/`, `polyglot-20260510T102055Z-qwen2.5-coder-32b-python/`. |
| **Result — Gemma 4 31B NVFP4 dense challenger (R6/R7, 2026-05-10 18:46)** | FAILED-LOAD. Model fundamentally exceeds 32 GB VRAM regardless of NVFP4 GEMM kernel choice (~20 GB BF16 unquantized parts + ~12 GB NVFP4 weights = 32+ GB). 256K vocab + multimodal vision encoder are the unfixable bloat. Archive: no perf snapshot (vLLM crash-looped). |
| **Verdict** | **Qwen3-Coder-30B-A3B-AWQ-4bit is the locked production base model.** Dense alternatives in the same VRAM class are uncompetitive on quality AND speed. Reasoning models (H16) and Mistral-family cross-checks (H15) are now the only model-selection follow-ups worth running. |
| Pre-fix Gemma 4 26B-A4B baseline (historical) | n=10 polyglot 2026-05-09: 5/10 PASS at max_tokens=4096 — pre-fix harness, not authoritative. Archive: `archive/polyglot-20260509T11*-gemma-4-26b-a4b-it-python/`. Superseded by post-fix Qwen3-Coder result. |

### Open methodology issues — RESOLVED 2026-05-10

| Issue | Resolution | Where |
|---|---|---|
| Non-deterministic decoding | `seed: 42` added to request body | `tools/polyglot-bench.sh:171` (commit 90fd455) |
| Gemma 4 verbosity | `max_tokens=16384` + "Be concise — minimum lines of code that pass the tests" added to prompt template | `tools/polyglot-bench.sh:154-171` (commit 90fd455) |
| Test-runner false negatives | `_test_output.log` is captured per failing sandbox for spot-check; `^OK( \|$)` regex looks correct on inspection | `tools/polyglot-bench.sh:211,219` |

H1 baseline can resume on the corrected harness; prior `archive/polyglot-20260509T*` runs are pre-fix and should NOT be used as the baseline.

### H2 — n-gram speculative decoding gives 1.3–1.8× decode with zero quality loss

| Field | Value |
|---|---|
| Status | **FALSIFIED** (2026-05-10, n=2 across two backends; gated on H14 for any future revisit) |
| Stated | 2026-05-09 |
| Motivation | Code is highly repetitive (variable names, brackets, common patterns). vLLM's `--speculative-config '{"method": "ngram", "num_speculative_tokens": 5, "prompt_lookup_max": 4}'` predicts repeated text from the prompt itself — no draft model needed. Acceptance rate on code is typically 40–60%. Free 1.3–1.8× decode. |
| Quality gate | Speculative decoding must produce identical outputs to non-speculative for greedy temp=0 runs (verifies acceptance logic correctness). |
| Test plan | Add `--speculative-config '...'` to compose. n=3 perf snapshots before/after with seeded prompts. Diff outputs at temp=0. |
| Measurement | Decode tok/s; speculative-acceptance-rate (logged by vLLM); identical-output verification. |
| If proven | Add to default compose; keep flag on permanently. |
| If falsified | Drop; revisit if a code-tuned draft model emerges (H8). |
| **2026-05-10 run 1 (combined with H3, FlashInfer + PIECEWISE)** | Decode 253→221 tok/s (-12.6%); concurrent agg 714→637 tok/s (-10.8%); polyglot 4/5→3/5. Acceptance rate 37.9–46.4%. CUDAGraph mode forced to PIECEWISE because FlashInfer's spec-decode CG support is `UNIFORM_SINGLE_TOKEN_DECODE` (=1, below threshold). Async scheduling auto-disabled. Archive: `archive/perf-20260510T073225Z-qwen3-coder-30b-a3b-H2H3-on/`. |
| **2026-05-10 run 2 (isolated, FA2 backend, no FP8 KV)** | Decode 253→145.8 tok/s (-42.4%); concurrent agg 714→554 tok/s (-22.4%); polyglot 4/5→2/5. Acceptance rate 39.1–46.2% (similar to run 1 — speculation IS working). FULL CUDA graphs were captured (no downgrade warning) but FA2's spec-decode kernels are materially slower per-token than FlashInfer's, AND quality regressed further than in run 1. Archive: `archive/perf-20260510T074357Z-qwen3-coder-30b-a3b-H2-only-FA/`. |
| **Why both fail** | The CUDAGraph mode question turned out to NOT be the dominant factor. Both FlashInfer (with PIECEWISE downgrade) and FA2 (with FULL graphs) regress perf because vLLM 0.20.2's spec-decode kernels — on this Blackwell sm_120 + Qwen3-Coder MoE setup — are simply slower per-token than the non-spec decode path, regardless of which backend is selected. The 40% acceptance rate isn't enough to overcome the per-token kernel overhead. Quality also regressed in both — possibly numerical jitter in the verification step's temperature-zero tiebreaking. |
| **Gating revisit** | Drop H2 from rotation. Revisit ONLY if H14 (FA3 backend on Blackwell) lands AND ships better-tuned spec-decode kernels. Don't retry on FA2 / FlashInfer. |
| Note for `VLLM_ATTENTION_BACKEND` env var | This env var doesn't exist in vLLM 0.20.2 — startup logs `Unknown vLLM environment variable detected: VLLM_ATTENTION_BACKEND`. The H2-isolated test got FA2 anyway because that's the auto-selector default; the env override was a no-op. Documented for future reference: backend selection in 0.20.x is via the auto-selector, not env. |

### H3 — FP8 KV cache halves KV memory → enables 65k context or 2× concurrent sub-agents

| Field | Value |
|---|---|
| Status | **FALSIFIED on Qwen3-Coder MoE (the winning base model)** as of 2026-05-10. H17 confirmed the underlying triton bug is MoE-specific; FP8 KV via fp8_per_token_head requires triton; therefore H3 is closed for the production stack until either an upstream vLLM fix or FA3 (H14) lands. |
| Stated | 2026-05-09 |
| Motivation | `--kv-cache-dtype=fp8` halves KV memory at minimal quality loss (NVIDIA's published FP8-KV results show <0.5% accuracy delta on standard benchmarks). On Blackwell, FP8 has native tensor-core support — may even be faster than bf16 KV. Frees ~7 GB VRAM at 32k context, which can be spent on bigger context OR more concurrent sequences. |
| Quality gate | Aider Polyglot subset within −2pp of bf16 baseline. Long-context fidelity test: insert known fact at token ~20000, ask at end-of-context — must retrieve correctly. |
| Test plan (revised 2026-05-10) | Use `--kv-cache-dtype=fp8_per_token_head` (dynamic per-token-head scales computed at runtime, NOT static per-tensor scales). Forces triton_attn backend (the only one that implements per_token_head). Single variable; no spec-decode, no FP8 weights. Run polyglot quality gate + perf snapshot. |
| Measurement | Aider pass-rate; concurrent throughput delta; KV cache memory headroom (vLLM logs `Maximum concurrency for 32,768 tokens per request: Nx`). |
| If proven | Add to default; consider H5 (bigger context) on top. |
| If falsified | Stay on bf16 KV; consider INT8 if bf16 budget too tight. |
| **2026-05-10 run 1 (combined with H2, static `fp8` scheme)** | Polyglot pass-rate 4/5 (80%) → 3/5 (60%); mean problem time 2.58s → 6.16s (+139%). vLLM warned: *"may cause accuracy drop without a proper scaling factor."* The AWQ-4bit checkpoint does NOT ship FP8 calibration scales; vLLM fell back to default scales = 1.0. KV cache headroom did jump from ~2× to 6.21× concurrency at 32k context — memory-savings claim valid. Confounded with H2 spec-decode regression. Archive: `archive/perf-20260510T073225Z-qwen3-coder-30b-a3b-H2H3-on/`. |
| **Why path B (llmcompressor calibration) was abandoned** | llmcompressor requires a full-precision (bf16) input model. Qwen3-Coder-30B is ~60 GB at bf16, won't fit on 32 GB VRAM for calibration. Could be done with CPU offload but slow. Made obsolete by `fp8_per_token_head` runtime path which computes finer-grained scales (per-token, per-head) than calibrated static scales (per-tensor). |
| **Why path A (FP8 mirror) was abandoned** | `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` ships FP8 weights but NOT FP8 KV scales (verified via config.json — only `quantization_config.weight_block_size`). Combining FP8 weights (~30 GB) + FP8 KV (~7 GB at 32k) exceeds 32 GB VRAM, blocking H5 anyway. |
| Archive | `archive/perf-20260510T073225Z-qwen3-coder-30b-a3b-H2H3-on/` + `archive/polyglot-20260510T073154Z-qwen3-coder-30b-a3b-python/` |

### H4 — Tune `--max-num-seqs` and `--max-num-batched-tokens` for OpenCode parallel sub-agents

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-09 |
| Motivation | OpenCode's build agent forks parallel `bash`, `read`, `edit` sub-agents — typical fan-out 3–6 simultaneous requests. vLLM defaults `max-num-seqs=256` (fine) but `max-num-batched-tokens=8192` (we set explicitly). Increasing batched-tokens lets prefill of multiple sub-agents proceed in one forward pass; cost is more VRAM for activations. |
| Quality gate | None — pure scheduling change, output identical to non-batched. |
| Test plan | Sweep `max-num-batched-tokens ∈ {8192, 16384, 32768}`. Fire 4 parallel curl requests with mixed prompt sizes (8k, 16k, 24k, 8k). Measure aggregate throughput + p95 latency per request. |
| Measurement | Aggregate tok/s ×4 streams; p95 first-token latency; OOM check. |
| If proven | Adopt the winner. |
| If falsified | Default 8192 stays. |

### H5 — Bump `max_model_len` to 65k–128k — full repo context viable

| Field | Value |
|---|---|
| Status | **RESOLVED 2026-05-10 — 96k locked as production default.** Originally thought gated on H3 (FP8 KV); turned out bf16 KV fits cleanly up to 96k. 120k loads but is non-deterministic. 128k OOMs. |
| Stated | 2026-05-09 |
| Motivation | Real codebases routinely hit 50k+ tokens for whole-file reads. 32k context forces OpenCode to chunk / RAG, losing accuracy on whole-codebase reasoning. Native context for Gemma 4 / Qwen3-Coder is 128k–256k. |
| Quality gate | Aider Polyglot subset must not regress meaningfully. Long-context fidelity test (insert known fact at token ~50000, ask at end) is a follow-up. |
| Test plan (revised) | Bump `--max-model-len` and measure. No FP8 KV needed for 65k. Push to 96k / 128k as follow-ups if user wants more. |
| Measurement | VRAM headroom; concurrency at given context; polyglot pass rate; decode tok/s. |
| **R10 result (Qwen3-Coder MoE / bf16 KV / 65k, 2026-05-10 21:30)** | **WORKS cleanly.** VRAM 30.0→30.7 GB (+0.7 GB). KV cache memory 10.4 GB allocated for 113k tokens (1.73× concurrency at 65k). Decode tok/s 253.1→252.6 (−0.2% — within noise). Concurrent-4 agg 713.6→697.3 (−2.3%). Polyglot 4/5→3/5 — single-problem flip on book-store; needs n=10 to disambiguate from single-trial noise. Archive: `archive/perf-20260510T113011Z-qwen3-coder-30b-a3b-qwen3-coder-65k/` + `archive/polyglot-20260510T112956Z-qwen3-coder-30b-a3b-python/`. |
| **Why I previously thought H5 was blocked** | I assumed bf16 KV at 65k would consume ~28 GB and not fit alongside 17 GB weights in 32 GB VRAM. The actual KV memory is ~6 GB at 65k (96 KB/token × 65k). My estimate was off by ~5×. This false assumption caused us to chase H3 (FP8 KV) — which depends on triton — which has the MoE-specific bug (H17). All of that investigation cycle was unnecessary for H5's goal. |
| **Push targets — ALL TESTED 2026-05-10** | (1) **96k (R11)** ✓ PROVEN — polyglot 4/5 (matches 32k baseline), decode 249.9 tok/s (-1.3%), VRAM 30.7 GB. **Locked as production 2026-05-10.** (2) **120k (R13/R14)** ✗ non-deterministic — loads with KV pool 123k tokens, 1.01× concurrency, decode-rate stable at 250 tok/s, but polyglot swings 2/5 vs 3/5 across runs with same seed=42; book-store can runaway to 16384 tokens. Continuous-batching numerical jitter cascades at extreme max_model_len. (3) **128k (R12)** ✗ overshoots — vLLM ValueError: 12 GB KV needed, 11.32 GB available at gpu-mem 0.95. Hardware-budget ceiling. |
| **Outcome** | **96k locked as production default in `docker-compose.yml`.** Net result: 3× context (32k → 96k) for -1.3% decode and 4/5 polyglot equal to baseline. |
| Remaining follow-ups (deferred) | n=10 polyglot at 96k for higher-confidence stability gate (G3d). n=10 at 120k to characterize the non-determinism (G3e). Long-context fidelity probe — insert known fact at token ~80k, ask at end (G3f). All low priority since 96k is good enough for OpenCode's typical workload. |
| Archive | `archive/perf-20260510T113011Z-qwen3-coder-30b-a3b-qwen3-coder-65k/` (R10) + `archive/perf-20260510T222118Z-qwen3-coder-30b-a3b-qwen3-coder-96k/` (R11 — PROD) + `archive/perf-20260510T223052Z-qwen3-coder-30b-a3b-qwen3-coder-120k/` (R13) + `archive/polyglot-20260510T223945Z-qwen3-coder-30b-a3b-python/` (R14 re-run) |

### H6 — Aggressive prefix caching for OpenCode's repeated system+tool prompt

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-09 |
| Motivation | OpenCode sends the same 6–10k-token system+tool prompt prefix on every call within a session. vLLM's prefix caching reuses the KV for shared prefixes — should drop TTFT to ~0 for the prefix portion on the 2nd+ call. Already on by default in vLLM v0.20.x but worth verifying it's actually hitting. |
| Quality gate | None — output-identical optimization. |
| Test plan | Measure TTFT on first call vs 2nd-5th calls of an OpenCode session (same system prompt, varying user messages). vLLM logs prefix-cache hit-rate; capture. |
| Measurement | TTFT delta (first vs subsequent); prefix-cache hit-rate from `/metrics`. |
| If proven (= already working) | Document the win, no config change. |
| If falsified | Investigate why hit-rate is low — possibly OpenCode is varying the prefix in subtle ways. |

### H7 — FP8 weight quantization (vs AWQ-4bit) — better quality, native Blackwell tensor cores

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-09 |
| Motivation | AWQ-4bit is INT4 + scale; needs Marlin kernel (CUDA). FP8 weights run on Blackwell's native FP8 tensor cores — potentially faster, definitely higher quality (8 bits vs 4). VRAM cost: 2× the weights, so 26B model = ~32 GB FP8, exceeds budget for the 26B-A4B but fits 26B-A4B-it FP8 mirror does exist (`Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` does fit at ~30 GB, tight but feasible). |
| Quality gate | Aider Polyglot ≥ AWQ baseline. |
| Test plan | Pull FP8 variant of the chosen base model. Swap, measure quality + perf. KV cache headroom shrinks — check if 32k context still fits. |
| Measurement | Aider pass-rate; decode tok/s; max usable context length; VRAM at idle. |
| If proven | Switch default to FP8 if quality wins; quantify perf trade-off. |
| If falsified | Stay on AWQ-4bit; FP8 too tight. |

### H8 — Speculative decoding with draft model (Gemma E4B drafting for 26B target)

| Field | Value |
|---|---|
| Status | **DEFERRED** (revisit after H2 result) |
| Stated | 2026-05-09 |
| Motivation | Draft-model speculative is the gold standard for spec decoding speedup (2–3× possible). Cost: VRAM for both models + multi-process orchestration. With H1 model swap, the draft picks change — Gemma 4 family has E2B/E4B drafts; Qwen3-Coder-30B-A3B has Qwen3-1.7B as candidate. |
| Quality gate | Identical-output verification at temp=0. |
| Test plan | TBD pending H1 + H2 results. |
| Measurement | Decode tok/s; acceptance rate; VRAM cost. |

### H9 — Dual-model: heavy vLLM + lightweight Ollama for OpenCode lighter sub-agents

| Field | Value |
|---|---|
| Status | **OUT OF SCOPE** (2026-05-09) |
| Stated | 2026-05-09 |
| Closed | 2026-05-09 — host is vLLM-only by user preference. Ollama systemd integration retired in companion repo on the same date; reintroducing it via dual-model would reverse that decision. If a "fast small model for light sub-agents" need re-emerges, the right answer is a second vLLM instance (memory-carved on the same GPU) or a different OpenCode multi-agent config that picks a different served model from the *same* vLLM. |

### H10 — torch.compile + CUDAGraph capture tuning

| Field | Value |
|---|---|
| Status | **DEFERRED** (low expected ROI vs H1–H4) |
| Stated | 2026-05-09 |

### H11 — mmap + on-demand fault-in for weights (cold-load)

Inherited from `perf-roadmap.md` §1. Status: **DEFERRED** — cold load matters
less than ongoing decode for SWE.

### H12 — GPUDirect Storage (cold-load)

Inherited from `perf-roadmap.md` §2. Status: **DEFERRED**.

### H13 — Hot model cache in GPU memory across vLLM restarts

Inherited from `perf-roadmap.md` §3. Status: **DEFERRED**.

### H15 — Magistral-Small as alternate dense substrate

| Field | Value |
|---|---|
| Status | **DEFERRED** (parked 2026-05-10 for follow-on look after H1 + H16) |
| Stated | 2026-05-10 |
| Motivation | Magistral-Small is Mistral's reasoning-tuned dense ~24B model. Useful as a Mistral-family orthogonal-architecture test if Qwen-family results need cross-validation. ~12 GB AWQ-4bit → comfortable VRAM. Text-only (no multimodal cost). |
| Test plan | Pull `mistralai/Magistral-Small-2509` AWQ checkpoint (or community variant). Same swap pattern via .env. Polyglot quality gate + perf snapshot. |
| Triggers to revisit | (a) After H16 (reasoning anchor on Qwen-family) lands — H15 then validates Mistral family at similar reasoning style. (b) If Qwen-family results show family-specific quirks needing orthogonal cross-check. |

### H18 — Long-context fidelity at 96k (real context vs nominal)

| Field | Value |
|---|---|
| Status | **OPEN** (filed 2026-05-10 after H5 locked 96k as production) |
| Stated | 2026-05-10 |
| Motivation | H5 proved 96k LOADS and runs at baseline polyglot quality on SHORT prompts. But polyglot prompts are only a few hundred tokens — we never tested whether the model **actually uses** 96k of context coherently. Long-range attention degradation is a known issue: at high sequence lengths some models effectively only "see" the most recent N tokens despite the configured max_model_len. If our 96k is nominal but not real, the H5 win is illusory and chasing more context (YaRN, offload) is wasted effort. |
| Quality gate | Insert a known fact at token ~80,000 of a long synthetic prompt. Ask a question that requires retrieving that fact at the end. PASS if model correctly recalls the inserted fact. Run n=5 at different insertion positions (10k, 30k, 50k, 70k, 90k) to map the attention-degradation curve. |
| Test plan | (1) Build a long context filler (e.g., repeated lorem-ipsum or non-conflicting Python code). (2) Insert a needle: `"The secret API key is QV7-Z3F-9821"` at varying positions. (3) Append: `"What is the secret API key?"` (4) Score: exact-match PASS/FAIL per probe. (5) Output the position→accuracy curve. |
| Measurement | Pass rate at each needle position (10k, 30k, 50k, 70k, 90k); end-to-end latency for long-prompt inference (TTFT will be much higher than typical due to prefill); decode tok/s after long prefill. |
| If proven (≥4/5 across positions, including 90k) | 96k is real context. H5's win is fully banked. Worth pushing to YaRN extension for 128k+ as next step. |
| If partially proven (passes 10k/30k/50k but fails 70k/90k) | Attention degrades at long range. The "effective context" is somewhere below 96k. **Re-evaluate H5's production lock** — maybe 64k is the actual usable context. |
| If falsified (fails most positions) | Even 96k is nominal. Drop production back to ~32k (the proven working range). Investigate causes (RoPE config, attention sliding window, etc.). |
| Cross-references | H5 (resolved at 96k — this validates whether the resolution is real); potential follow-up H for YaRN context extension if H18 proves clean. |
| Archive when run | `archive/h18-long-context-fidelity-<TS>/` (custom probe — likely a new tools/h18-long-context-probe.sh script) |

### H19 — Concurrent fan-out behavior at 96k context

| Field | Value |
|---|---|
| Status | **OPEN** (filed 2026-05-10) |
| Stated | 2026-05-10 |
| Motivation | At 32k context, Qwen3-Coder MoE had 3.27× KV concurrency — i.e., the KV pool could hold 3+ concurrent 32k requests. At our new 96k production config, concurrency drops to **1.15×** — we have room for one full-size request plus a small fraction of a second. OpenCode's agent mode forks parallel `bash`/`read`/`edit` sub-agents, typical 3-6 concurrent. **What actually happens when OpenCode hits this limit?** Queue? OOM under bursty load? Graceful degradation with smaller request slices? We never measured the real-world concurrency behavior at 96k. |
| Quality gate | None — concurrency is a scheduling/throughput question, output identical to single-request. |
| Test plan | (1) Fire 4 simultaneous chat-completion requests against the running 96k vLLM via curl, each with ~8k input + 1k output. (2) Measure: p50/p95 first-token latency, total wall time, vLLM `num_requests_waiting` / `num_requests_running` from /metrics during the run. (3) Repeat at 8 concurrent and 16 concurrent to find the saturation point. (4) Also run a "mixed prompts" scenario: one 50k-context call alongside three small 4k calls — what happens to the small calls' TTFT? |
| Measurement | p50/p95 TTFT under concurrent load; aggregate decode tok/s with N concurrent streams; max sustained concurrency before queuing kicks in; behavior on the "one long + several short" scenario (most realistic for OpenCode). |
| If proven (graceful queueing + decent aggregate throughput) | 96k is production-safe under realistic OpenCode load. |
| If falsified (OOMs / pathological queueing / large p95 spikes) | May need to either (a) lower context to 64k for more concurrency headroom, (b) tune `max-num-seqs`/`max-num-batched-tokens` (H4) to handle the load better, or (c) rate-limit OpenCode sub-agent fan-out. |
| Cross-references | H4 (max-num-seqs tuning — H19 may surface H4 as urgent); H5 (the context-vs-concurrency trade-off). |
| Archive when run | `archive/h19-concurrency-<TS>/` (custom probe script) |

### H20 — Polyglot stability at production config (n=10 confidence)

| Field | Value |
|---|---|
| Status | **OPEN** (filed 2026-05-10) |
| Stated | 2026-05-10 |
| Motivation | Every polyglot test in the ledger has been n=5 single-trial. We've already seen this is noisy: R10 (65k) gave 3/5, R11 (96k) gave 4/5 on the same model with no real config change. R13 (120k) gave 2/5; R14 (re-run at same config) gave 3/5. Single-trial polyglot is too noisy for production-tier confidence. A higher-n gate at the locked production config (R11's 4/5 at 96k) tells us how stable that result actually is. |
| Quality gate | At max_model_len=98304, n=10 polyglot pass rate must be ≥ 7/10 (70%) to call the production config "stable enough." A pass rate consistent with R11's 4/5 = 8/10 would be good. |
| Test plan | (1) Polyglot-bench.sh with N_PROBLEMS=10 against the locked production vLLM. (2) Compare per-problem pass/fail to R1 (32k baseline n=5 — same 5 problems) and R11 (96k n=5). (3) Note problems 6-10 (more complex than the first 5). (4) If desired, repeat at seed=43 to get a second sample. |
| Measurement | Pass rate at n=10; per-problem failure pattern; which problems are stable PASS, stable FAIL, or boundary (flip-flop across runs). |
| If proven (≥7/10) | High-confidence stability gate at production. R11's 4/5 was representative, not lucky. |
| If between 5-7/10 | Production is OK but quality is on the boundary. May want a higher-quality model (reasoning anchor H16, multi-provider routing for hard tasks). |
| If <5/10 | Production config is less stable than R11 suggested. Investigate — possibly the 96k context is degrading quality on harder problems beyond the first 5. May warrant context rollback to 32k. |
| Cross-references | H1 (model selection — this validates the H1 winner at production config); H5 (context — this validates the H5 production lock); H16 (reasoning anchor — useful comparison data point for H16 to interpret against). |
| Archive when run | `archive/polyglot-<TS>-qwen3-coder-30b-a3b-python/` (n=10) |

### H21 — Host CPU thermal containment for sustained inference

| Field | Value |
|---|---|
| Status | **OPEN** (filed 2026-05-11 from in-flight H16 thermal observation) |
| Stated | 2026-05-11 |
| Motivation | During the H16 reasoning run, NUC 15 Pro+ host CPU pegged at **105 °C package** (Tjmax-5 °C on Core Ultra 9 285H) with package-throttle counter climbing continuously. Live mitigation `docker update --cpuset-cpus=6-13 aorus-vllm` (pin to E-cores) dropped package temp from **105 °C → 65-70 °C** within 60 s — a **35-40 °C** swing from a single config change. Root cause: vLLM's EngineCore was running at ~170% CPU spread over only 2 of the 6 P-cores (5.4 GHz boost), creating extreme local power density. E-cores (4.5 GHz, 8 units) absorb the same work at much lower thermal density. This proves a permanent host-side optimization is on the table; needs proper characterization before we lock production config. |
| Open questions | (a) Optimal cpuset: E-cores only (6-13), P+E mix, exclude LP-E (14-15)? (b) Decode tok/s penalty from E-core-only — likely 5-10% but unmeasured. (c) Does `OMP_NUM_THREADS` / `RAYON_NUM_THREADS` further reduce CPU load without throughput loss? (d) Should we permanently set `cpuset_cpus: "6-13"` in `docker-compose.yml`? (e) Are there vLLM-internal knobs (logging verbosity, detokenize batching) that reduce CPU-side tail per token? (f) Is there a kernel scheduler / cgroups-v2 approach better than docker cpuset for this? |
| Test plan | (1) Baseline: perf-snapshot.sh on Qwen3-Coder MoE 96k WITHOUT cpuset (record decode tok/s + CPU temp + package throttle count). (2) Pin to E-cores (6-13) — re-run perf-snapshot.sh. (3) Pin to P-cores (0-5) — re-run (counterfactual). (4) Mix P+E (0-13) — re-run. (5) E-cores + `OMP_NUM_THREADS=4` env — re-run. (6) Tabulate: tok/s, package temp, throttle count delta over the run, polyglot n=5 pass-rate (sanity gate). Pick the Pareto-best point and codify in `docker-compose.yml`. |
| Measurement | Decode tok/s (median of 3); CPU package temp (steady-state during decode); package_throttle_count delta over fixed-duration run; polyglot n=5 pass rate (must be unchanged). |
| Quality gate | Polyglot pass rate unchanged at the chosen config. No request timeouts. |
| If proven (E-core pin + minor perf cost) | Commit `cpuset_cpus: "6-13"` to `docker-compose.yml` as production posture. File companion entry in `docs/host-system-tuning.md` (new doc). |
| Cross-references | H4 (`max-num-seqs` — concurrency could change CPU pressure profile); H19 (concurrent fan-out — most likely to expose thermal limits); H20 (n=10 stability — if it runs unpinned, CPU throttle may inject noise). |
| Out of scope | BIOS-level tuning (NUC 15 Pro+ has no user-configurable thermal/power BIOS — see auto-memory `feedback_no_bios_options_nuc15.md`). |
| Archive when run | `archive/h21-cpu-thermal-<TS>/` (perf-snapshot per config + thermal trace) |

### H17 — Triton_attn quality regression is MoE-specific (not general)

| Field | Value |
|---|---|
| Status | **RESOLVED 2026-05-10 — PROVEN MoE-specific.** |
| Stated | 2026-05-10 |
| Motivation | When testing H3 (FP8 KV via `fp8_per_token_head`, which forces triton_attn backend) on Qwen3-Coder MoE, polyglot pass rate dropped 4/5 → 2/5. We then ran triton_attn alone (without FP8 KV) on the same MoE model — same regression to 2/5. So triton_attn ITSELF (independent of FP8 KV) is the issue on Qwen3-Coder. **Working hypothesis**: this is MoE-specific. MoE's variable expert activation across tokens creates attention patterns where triton's kernel implementation produces subtle numerical drift relative to FA2's. The same 3 problems failed in both triton runs (book-store, bottle-song, bowling — the more-complex ones) and the same 2 passed (affine-cipher, beer-song — simpler ones). If H17 holds (dense models pass triton's quality gate), H3 unblocks on dense substrates — but H1 settled that dense candidates lose decisively on this hardware, so the practical leverage from H17 is reduced. The remaining value is **mechanism-clarification**: confirming whether the triton bug is MoE-specific tells us if vLLM upstream has a fixable bug worth filing. |
| Substrate update (post-H1) | H1 Test A settled that Qwen3-Coder MoE wins on this hardware AND that dense Qwen2.5-Coder-32B is at 1/5 polyglot baseline. So H17's dense substrate is **at 1/5 to start, not 4/5**. The original "does triton hold quality?" question becomes "does triton drop the dense model further from 1/5 toward 0/5?" |
| Quality gate | Polyglot pass rate on dense + triton_attn must hold ≥ same dense + FA2 baseline = ≥1/5. Per-problem comparison: which problem(s) flip from PASS→FAIL or vice versa under triton. |
| Test plan | (1) Same Qwen2.5-Coder-32B-AWQ already loaded. (2) Apply `docker-compose.triton-attn.yml` overlay. (3) Run polyglot-bench n=5 same prompts/seed. (4) Run perf-snapshot at label `qwen2.5-coder-32b-triton`. (5) Compare quality vs R8 (FA2 dense baseline) AND vs R5 (triton MoE result for the symmetric comparison). |
| Measurement | Polyglot pass rate; per-problem failure pattern; decode tok/s delta (was +20% on Qwen3-Coder MoE); CUDAGraph mode (verify no downgrade warning); whether the same hard problems fail. |
| If proven (dense + triton holds 1/5) | **Triton bug confirmed MoE-specific.** Mechanism clarified. H3 unblocks on dense substrates *theoretically* but practically dense is uncompetitive — the win is documenting the bug for vLLM upstream + a future revisit when a stronger dense model emerges. |
| If falsified (dense + triton drops below 1/5) | **Triton bug is general.** All triton paths are closed for production use on this vLLM version. H3 stays FALSIFIED. H5 stays blocked. H14 (FA3) becomes the only path forward for KV compression on Blackwell. |
| Cross-references | H1 (resolved — dense underperforms on quality AND speed); H3 (FP8 KV — tied to triton's stability); H5 (bigger context — tied to KV memory savings via H3); H14 (FA3 — alternative path) |
| Archive when run | `archive/perf-<TS>-qwen2.5-coder-32b-triton-on/` + `archive/polyglot-<TS>-qwen2.5-coder-32b-python/` |
| **Result (R8 dense+FA2 vs R9 dense+TRITON, 2026-05-10 20:35)** | Polyglot **HELD at 1/5** — same problems pass/fail, **identical token counts** (329, 211, 146, 195, 566 across all 5 problems on both runs). TTFT identical. Decode +4.2% (vs +20% on MoE). CG mode held at FULL_AND_PIECEWISE. Conclusion: triton's bug is specific to MoE's variable-expert-activation attention patterns. On dense, triton produces byte-equivalent completions to FA2. The MoE-specific +20% decode AND the MoE-specific quality regression both originate from triton's MoE-specialized kernel paths — they're coupled. Archive: `archive/perf-20260510T103548Z-qwen2.5-coder-32b-triton/` + `archive/polyglot-20260510T103522Z-qwen2.5-coder-32b-python/`. |
| **Implications now confirmed** | (1) H3 unblocks on dense ONLY — but dense is uncompetitive on quality (per H1) so this isn't useful in production. (2) H3 stays permanently FALSIFIED for Qwen3-Coder MoE within vLLM 0.20.2 unless upstream patches the MoE+triton numerical drift. (3) H5 (bigger context) is gated on H3, hence also blocked. (4) Theoretical paths remaining: vLLM upstream fix, FA3 with sm_120 (H14), or a community-quantized Qwen3-Coder-30B-A3B with FP8 KV scales pre-baked (doesn't exist yet). (5) Worth filing the bug upstream — we now have a clean reproducer with comparative evidence. |

### H16 — Reasoning model as quality anchor (Aider Polyglot ceiling on this hardware)

| Field | Value |
|---|---|
| Status | **RUNNING** (DeepSeek-R1-Distill-Qwen-32B-AWQ, 32k context, validation chain in flight 2026-05-11) |
| Stated | 2026-05-10 |
| Context budget caveat | R1-Distill-Qwen-32B is a 32B **dense** model. At 96k production context it needs 24 GiB KV (vs MoE's 4 KV heads → ~96 KB/token → 9 GiB at 96k). vLLM caps this model at ~33k at gpu-mem 0.92. H16 runs at **`--max-model-len=32768`** since polyglot problems are all <30k tokens — context isn't the H16 variable, quality ceiling is. Confirmed empirically 2026-05-11 (first run with 96k overlay failed at engine init: `24.0 GiB KV cache is needed, ... available 8.09 GiB`). |
| Motivation | Reasoning models (chain-of-thought-trained) consistently lead the Aider Polyglot leaderboard at the cost of higher per-task token output. Running a reasoning model on this hardware establishes the **SWE quality ceiling reachable locally** — a known-good denominator against which all faster non-reasoning candidates can be measured. Without an anchor, "Qwen2.5-Coder-32B got 4/5 polyglot" is unmeaningful (4/5 vs what?). With an anchor, "reasoning model got 5/5 in 4× the wall time, Qwen2.5 got 4/5 in 1× — the trade is X quality for 4× speed" becomes a real product decision. |
| Quality gate | None — H16 IS the ceiling-establishing run. Whatever pass-rate the reasoning model achieves is the new H1-baseline-for-comparison. |
| Test plan | (1) Pull DeepSeek-R1-Distill-Qwen-32B-AWQ (top-quality candidate; same Qwen base family so parser compatible). (2) Configure vLLM with `--reasoning-parser` for `<think>...</think>` block extraction. (3) Run polyglot-bench n=5 (or n=10 since reasoning models are slower per problem — better statistics). (4) Run perf-snapshot. (5) Document task-completion-time including thinking tokens — this is the latency cost. |
| Measurement | Aider Polyglot pass-rate (the ceiling number); mean wall time per problem (reasoning is slow); decode tok/s; thinking-token-to-answer-token ratio (how many "wasted" tokens for the win). |
| If reasoning model reaches >90% on n=5 polyglot | Confirms hardware can drive top SWE quality. All other tested models compared as % of ceiling. |
| If <90% (e.g., bowling still fails everywhere) | bowling is a deep specification trap — reasoning won't fully solve it on small models. Treat ceiling as 4/5 = 80% on this 5-problem subset; expand subset to 10-20 problems for more meaningful ceiling. |
| Candidate models in priority order | (1) **DeepSeek-R1-Distill-Qwen-32B-AWQ** — top quality fit; ~17 GB. (2) **Qwen3-32B with /think mode** — same family as our other Qwen tests; minimal config drift. (3) **QwQ-32B-AWQ** — Qwen's own reasoning model. Pick #1 first; if quality ceiling found, cross-validate with #2. |
| Cross-references | H1 (model selection); H15 (Magistral as Mistral-family reasoning option); future H for "agent-mode latency tolerance" |

### H14 — FlashAttention 3 backend on Blackwell sm_120

| Field | Value |
|---|---|
| Status | **OPEN — promoted in priority 2026-05-10** (only theoretical path to revive H2; relevant for H3 quality recovery) |
| Stated | 2026-05-10 |
| Motivation | vLLM 0.20.2 currently auto-selects FA2 on this hardware (`Using FlashAttention version 2` in startup logs). FA3 advertises `AttentionCGSupport.ALWAYS` (level 3 vs FA2's UNIFORM_BATCH = level 2) and is reported ~1.5-2× faster than FA2 on H100, with native FP8 paths and async memory ops via TMA. **Unblocks H2 + H3**: H2 was falsified on this stack (n=2 across FlashInfer and FA2 backends, 2026-05-10) because vLLM 0.20.2's spec-decode kernels are slower per-token than non-spec on Blackwell — FA3 may have better-tuned spec-decode kernels. H3 quality regression was likely the missing FP8 calibration scales — FA3's native FP8 paths may handle this better. |
| Open question | Is FA3 actually built into vLLM 0.20.2's bundled flash-attn for Blackwell sm_120? FA3 was hand-tuned for Hopper sm_90; Blackwell support may require either a newer vllm image OR rebuilding flash-attn with `TORCH_CUDA_ARCH_LIST="12.0+PTX"` and FA3 enabled. Need to inspect the running container's flash-attn package to confirm what's available before designing the test. |
| Quality gate | None expected — same attention math, different kernel implementation. Aider Polyglot subset must remain at H1-baseline pass rate. |
| Test plan | (1) Inspect `flash_attn` package in the running container — list compiled archs; check whether FA3 kernels are present for sm_120. (2) If yes: force via `VLLM_ATTENTION_BACKEND=FLASH_ATTN` and a vllm env / config that selects FA3 over FA2. (3) If no: try a newer vllm image (e.g. v0.21.x) or rebuild flash-attn from upstream with sm_120 + FA3. (4) Run perf-snapshot before / after with the same Qwen3-Coder model. |
| Measurement | Decode tok/s; TTFT; concurrent agg tok/s; same dimensions as H2 perf snapshot. Compare against H1 baseline AND against H2-isolated result. |
| If proven | Switch default backend to FA3. Re-run H2 (potentially with `num_speculative_tokens=7` since CG cost is now zero). Re-run H3 with FP8 scales generated against FA3's native FP8 paths. |
| If falsified (FA3 unavailable) | Stay on FA2. Stop chasing FA3 unless we upgrade vllm or compile from source. |
| Cross-references | H2 (CG mode interaction); H3 (FP8 paths); H10 (CUDAGraph tuning more broadly — H14 may make H10 moot). |

---

## Resolved hypotheses

(empty — first pass, 2026-05-09)

---

## Phase plan

| Phase | Hypotheses | Goal |
|---|---|---|
| **Phase 1 — Lock the base model** | H1 | **DONE → Qwen3-Coder-30B-A3B-AWQ wins.** Dense Qwen2.5-Coder-32B and Gemma 4 31B both lost decisively. |
| **Phase 1.4 — Triton-MoE isolation** | H17 | **DONE — PROVEN MoE-specific.** Dense + TRITON = same outputs as dense + FA2. Triton breaks Qwen3-Coder MoE specifically. |
| **Phase 1.6 — Bigger context** | H5 | **RESOLVED — 96k locked production 2026-05-10.** bf16 KV fits cleanly; never needed FP8 KV. 120k loads but non-deterministic; 128k OOMs. |
| **Phase 1.7 — Validate production stack** | H18, H19, H20 | (1) H18 long-context fidelity — does the model actually USE 96k? (2) H19 concurrent fan-out — what happens when OpenCode forks 4+ sub-agents at 96k? (3) H20 n=10 polyglot — high-confidence stability gate. All three use the existing production config, no downloads. |
| **Phase 1.5 — Establish quality ceiling** | H16 | Run a reasoning model (DeepSeek-R1-Distill-Qwen-32B) to establish the SWE-quality ceiling reachable on this hardware. Anchor for all subsequent comparisons. |
| **Phase 2 — Free wins** | ~~H2~~, H3, H6 | ~~Speculative~~ FALSIFIED 2026-05-10 (gated on H14); FP8 KV (needs isolated retest with proper scales); prefix-cache verification |
| **Phase 3 — Quality / context** | H5, H7 | Bigger context + FP8 weights |
| **Phase 4 — Concurrency** | H4 | Tune for OpenCode sub-agent fan-out |
| **Phase 5 — Speculative-with-draft** | H8 | Last-mile decode speedup |
| **Phase 6 — Cold-load** | H11–H13 | Inherited from perf-roadmap; deferred until steady-state phases land |
| **Phase 2.5 — Kernel substrate (substrate, not phase)** | H14 | FA3 backend on Blackwell — *prerequisite* for revisiting H2 (better CG mode) and H3 (native FP8 paths). Slot in between Phase 2 and Phase 3 if available; defer if FA3 isn't yet built for sm_120. |
| **Phase 1.8 — Host CPU thermal containment** | H21 | Permanent fix for the 105 °C package throttle observed during H16. Empirically proven: E-core pin → 35-40 °C package drop. Needs proper Pareto sweep + perf cost measurement before codifying `cpuset_cpus` in `docker-compose.yml`. Companion doc: `host-system-tuning.md` (to be created). Run BEFORE H19/H20 since unpinned CPU throttle adds noise to those measurements. |

(H9 dual-model removed — host is vLLM-only by user preference, see H9 entry.)
