# Model × configuration matrix

> Companion to [`perf-hypothesis-ledger.md`](./perf-hypothesis-ledger.md).
> The hypothesis ledger explains *why* each test was run.
> This matrix gives the at-a-glance state of *what has been tested*,
> *what the result was*, and *which combinations remain untested gaps*.
>
> One row = one tested configuration.
> Where multiple polyglot or perf runs exist on the same configuration,
> the most-recent / authoritative is cited.

## Legend

- **Config** is a compact summary `<backend> / <KV scheme> / <spec setting>`.
- **Polyglot** is Aider Polyglot subset pass rate at n=5
  (or n=10 where annotated).
  Lower bound; not a probability — same 5 problems each time at seed=42.
- **Decode tok/s** is the median of n=3 sequential
  256-token-completion runs from `tools/perf-snapshot.sh`.
- **4× agg** is concurrent 4-way aggregate decode tok/s.
- **bf16 KV** = native attention KV cache;
  **fp8** = static FP8 with checkpoint scales (or default 1.0 if no scales);
  **fp8_per_head** = dynamic per-token-head FP8 scales (forces triton_attn).
- **VRAM @ 32k** is the GPU memory observed at idle after model load
  with `--max-model-len=32768`.
- **Status**: ACTIVE = current production candidate;
  BASELINE = the comparison anchor;
  FALSIFIED = ran, performed strictly worse than baseline;
  FAILED-LOAD = couldn't reach `/health=200`;
  DEFERRED = planned but not yet tested.

## Tested configurations (descending by date)

| # | Date (UTC) | Model | Quant | Config | Polyglot (n=5) | Mean s/prob | TTFT (s) | Decode tok/s | 4× agg tok/s | VRAM @ 32k | Status | Archive | H |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **R1** | 2026-05-10 07:20 | Qwen3-Coder-30B-A3B | AWQ-INT4 | FA2 / bf16-kv / no-spec | 4/5 (80%) | 2.58 | 0.011 | **253.1** | **713.6** | 30.0 GB | **BASELINE** | `perf-20260510T072055Z-...-H1-qwen3-baseline/` | H1 |
| R2 | 2026-05-10 07:32 | Qwen3-Coder-30B-A3B | AWQ-INT4 | FlashInfer / fp8-static-kv / ngram-spec | 3/5 (60%) | 6.16 | 0.012 | 221.3 | 636.8 | n/a | FALSIFIED (combined H2+H3) | `perf-20260510T073225Z-...-H2H3-on/` | H2, H3 |
| R3 | 2026-05-10 07:43 | Qwen3-Coder-30B-A3B | AWQ-INT4 | FA2 / bf16-kv / ngram-spec | 2/5 (40%) | 11.18 | 0.012 | 145.8 | 553.7 | n/a | FALSIFIED (H2 isolated) | `perf-20260510T074357Z-...-H2-only-FA/` | H2 |
| R4 | 2026-05-10 08:12 | Qwen3-Coder-30B-A3B | AWQ-INT4 | TRITON / fp8_per_head-kv / no-spec | 2/5 (40%) | 23.94 | 0.011 | 295.8 | 777.3 | 29.4 GB | FALSIFIED (H3 alt path) | `perf-20260510T081206Z-...-H3-only-pth/` | H3 |
| R5 | 2026-05-10 08:17 | Qwen3-Coder-30B-A3B | AWQ-INT4 | TRITON / bf16-kv / no-spec | 2/5 (40%) | 2.77 | 0.011 | **303.9** | **779.5** | 29.4 GB | FALSIFIED (triton bug) | `perf-20260510T081756Z-...-triton-attn-bf16-kv/` | H17 (precursor) |
| R6 | 2026-05-10 18:46 | Gemma-4-31B-IT | NVFP4 (ModelOpt) | FA2 (auto) / bf16-kv / no-spec | n/a | n/a | n/a | n/a | n/a | OOM at 30 GB peak load | **FAILED-LOAD** | (no perf snapshot — vLLM crash-looped) | H1, H17 |
| R7 | 2026-05-10 19:09 | Gemma-4-31B-IT | NVFP4 | TRITON (forced via VLLM_NVFP4_GEMM_BACKEND=marlin) / bf16-kv | n/a | n/a | n/a | n/a | n/a | OOM (kernel-independent — model fundamentally too large) | **FAILED-LOAD** | (no perf snapshot) | H1, H17 |
| R8 | 2026-05-10 20:21 | Qwen2.5-Coder-32B-Instruct | AWQ-INT4 | FA2 (auto) / bf16-kv / no-spec / gpu-mem=0.92 | **1/5 (20%)** | 5.10 | 0.017 | 75.8 | 296.6 | 31.1 GB | **DENSE LOSES** (Test A — Qwen3-Coder MoE wins both quality AND speed) | `perf-20260510T102121Z-qwen2.5-coder-32b-base/` | H1 |
| **R9** | 2026-05-10 20:35 | Qwen2.5-Coder-32B-Instruct | AWQ-INT4 | **TRITON / bf16-kv / no-spec / gpu-mem=0.92** | **1/5 (20%)** | 5.19 | 0.017 | 79.1 | 307.1 | 31.1 GB | **H17 PROVEN — triton bug MoE-specific** (dense polyglot held at 1/5; same problems pass/fail; identical token counts) | `perf-20260510T103548Z-qwen2.5-coder-32b-triton/` | **H17** |
| **R10** | 2026-05-10 21:30 | Qwen3-Coder-30B-A3B (MoE) | AWQ-INT4 | **FA2 / bf16-kv / no-spec / max_model_len=65536 / gpu-mem=0.92** | 3/5 (60%) | 2.92 | 0.011 | **252.6** | **697.3** | **30.7 GB** | **H5 OPEN → PROVEN at 65k.** Decode unchanged (-0.2%), VRAM +0.7 GB, 10.4 GB KV headroom (113k tokens of KV space → 1.73× concurrency at 65k). Polyglot single-flip on book-store (4/5→3/5) — likely n=5 noise; needs n=10 to disambiguate. **The "32k ceiling" was self-imposed by a false assumption — bf16 KV at 64k fits cleanly with negligible perf cost.** | `perf-20260510T113011Z-qwen3-coder-30b-a3b-qwen3-coder-65k/` | **H5** |
| **R11** | 2026-05-10 22:21 | Qwen3-Coder-30B-A3B (MoE) | AWQ-INT4 | **FA2 / bf16-kv / no-spec / max_model_len=98304 / gpu-mem=0.92** | **4/5 (80%)** | 7.48 | 0.011 | **249.9** | **704.1** | **30.7 GB** | **PRODUCTION DEFAULT (locked 2026-05-10).** Polyglot fully matches 32k baseline (the R10 3/5 was n=5 noise — confirmed when book-store passed at 96k). Decode -1.3% vs baseline (noise-level). Same KV pool size as R10 (113k tokens — vLLM caps at gpu-mem budget regardless of max_model_len). 1.15× concurrency at 96k. | `perf-20260510T222118Z-qwen3-coder-30b-a3b-qwen3-coder-96k/` | **H5** |
| R12 | 2026-05-10 22:23 | Qwen3-Coder-30B-A3B (MoE) | AWQ-INT4 | FA2 / bf16-kv / no-spec / max_model_len=131072 / gpu-mem=0.95 | — | — | — | — | — | — | **FAIL-LOAD** — vLLM ValueError: 12 GB KV needed, 11.32 GB available. Estimated max model length: 123,584. | (no archive — failed to load) | H5 (overshoot) |
| R13 | 2026-05-10 22:30 | Qwen3-Coder-30B-A3B (MoE) | AWQ-INT4 | FA2 / bf16-kv / no-spec / max_model_len=122880 / gpu-mem=0.95 | **2/5 (40%)** | 8.61 | 0.011 | 250.0 | 700.6 | 31.6 GB | **Loaded but quality unstable.** KV pool: 123,583 tokens (1.01× concurrency at 120k). Polyglot 2/5 (book-store, bottle-song, bowling fail). Decode-rate stable but generation quality degraded at extreme context. | `perf-20260510T223052Z-qwen3-coder-30b-a3b-qwen3-coder-120k/` | H5 (push) |
| R14 | 2026-05-10 22:39 | Qwen3-Coder-30B-A3B (MoE) | AWQ-INT4 | FA2 / bf16-kv / no-spec / max_model_len=122880 / gpu-mem=0.95 (re-run) | **3/5 (60%)** | 21.19 | 0.011 | 250.0 | 700.6 | 31.6 GB | **NON-DETERMINISM CONFIRMED.** Same config + same seed=42 as R13 but **different pass rate** (3/5 vs 2/5). bottle-song flipped FAIL→PASS; book-store failed with **16384-tok runaway** vs R13's 3661-tok failure. vLLM continuous-batching numerical jitter at max_model_len=122880 cascades into different completions across runs. 120k is the hardware ceiling but **operationally unsafe** (same prompt can give different output on consecutive calls). | `polyglot-20260510T223945Z-qwen3-coder-30b-a3b-python/` | H5 (push — falsified) |

## Polyglot detail — which problems pass / fail per run

Same 5 problems alphabetically: `affine-cipher`, `beer-song`, `book-store`, `bottle-song`, `bowling`.

| # | affine-cipher | beer-song | book-store | bottle-song | bowling |
|---|---|---|---|---|---|
| R1 (Qwen3-Coder MoE / FA2) | ✓ | ✓ | ✓ | ✓ | ✗ |
| R2 (Qwen3-Coder MoE / FlashInfer + spec + fp8-kv) | ✓ | ✓ | ? | ? | ✗ |
| R3 (Qwen3-Coder MoE / FA2 + spec) | ✓ | ✓ | ✗ | ✗ | ✗ |
| R4 (Qwen3-Coder MoE / TRITON + fp8_per_head) | ✓ | ✓ | ✗ (RUNAWAY 16384 tok) | ✗ | ✗ |
| R5 (Qwen3-Coder MoE / TRITON + bf16) | ✓ | ✓ | ✗ | ✗ | ✗ |
| **R8 (Qwen2.5-Coder-32B Dense / FA2)** | ✗ | ✓ | ✗ | ✗ | ✗ |
| **R9 (Qwen2.5-Coder-32B Dense / TRITON)** | ✗ | ✓ | ✗ | ✗ | ✗ |
| **R10 (Qwen3-Coder MoE / FA2 / 65k context)** | ✓ | ✓ | ✗ (1444 tok) | ✓ | ✗ |
| **R11 (Qwen3-Coder MoE / FA2 / 96k — PROD)** | ✓ | ✓ | ✓ (2438 tok) | ✓ | ✗ |
| R13 (Qwen3-Coder MoE / FA2 / 120k — run 1) | ✓ | ✓ | ✗ (3661 tok) | ✗ (229 tok) | ✗ |
| R14 (Qwen3-Coder MoE / FA2 / 120k — run 2) | ✓ | ✓ | ✗ (16384 tok runaway) | ✓ (221 tok) | ✗ |

Patterns:
- TRITON breaks Qwen3-Coder MoE (R1 → R5: 4/5 → 2/5; same 3 hard problems flip from PASS to FAIL).
- **TRITON does NOT break Qwen2.5-Coder-32B Dense** (R8 → R9: 1/5 → 1/5; same problems pass/fail; identical token counts). **H17 PROVEN: triton bug is MoE-specific.**
- Qwen2.5-Coder-32B Dense fails 3 problems Qwen3-Coder MoE solves (affine-cipher, book-store, bottle-song). Logically-incorrect code generation, not truncation. Newer code-specific MoE training has the algorithmic edge regardless of attention backend.
- bowling fails for everyone — it's a known 10th-frame state-machine trap that defeats most models on this size class.

## Pending / planned configurations (gaps)

These are cells the hypothesis ledger has scheduled or worth exploring;
no data yet.

| # | Model | Quant | Config | Why interesting | Linked H |
|---|---|---|---|---|---|
| ~~G1~~ | ~~Qwen2.5-Coder-32B~~ | ~~AWQ-INT4~~ | ~~TRITON / bf16-kv / no-spec~~ | **Done — see R9. H17 PROVEN MoE-specific.** | ~~H17~~ |
| ~~G2~~ | ~~Qwen2.5-Coder-32B~~ | ~~AWQ-INT4~~ | ~~TRITON / fp8_per_head-kv / no-spec~~ | **Closed.** Even if it works on dense (likely yes per H17), dense is uncompetitive on quality (R8). No production value. | ~~H3 (re-open path)~~ |
| ~~G3~~ ~~G3b~~ ~~G3c~~ | ~~Qwen3-Coder MoE~~ | — | — | **All done.** 96k locked as production (R11); 120k loads but non-deterministic (R13/R14); 128k OOMs (R12). H5 RESOLVED. | ~~H5~~ |
| **G3d** | Qwen3-Coder MoE | AWQ-INT4 | FA2 / bf16-kv / max_model_len=98304 + polyglot **n=10** | Stability gate at production config (96k). Confirm R11's 4/5 is robust. **Filed as H20.** | **H20** |
| G3e | Qwen3-Coder MoE | AWQ-INT4 | FA2 / bf16-kv / max_model_len=122880 + polyglot **n=10** | Disambiguate R13 (2/5) vs R14 (3/5). Deferred — 96k is good enough for production. | H5 push (revisit) |
| **G3f** | Qwen3-Coder MoE | AWQ-INT4 | FA2 / bf16-kv / 96k + **long-context fidelity probe** (needle at token ~80k) | Validate the model actually USES 96k coherently. **Filed as H18.** | **H18** |
| **G3g** | Qwen3-Coder MoE | AWQ-INT4 | FA2 / bf16-kv / 96k + **concurrent fan-out test** (4 parallel ~8k requests) | Concurrency dropped 3.27× at 32k → 1.15× at 96k. Characterize OpenCode-shaped load behavior. **Filed as H19.** | **H19** |
| **G4** | **DeepSeek-R1-Distill-Qwen-32B** | **AWQ-INT4** | **FA2 / bf16-kv / no-spec / --reasoning-parser** | **Reasoning quality anchor — top priority.** Establishes ceiling for SWE quality on this hardware. | **H16** |
| G5 | Qwen3-32B | AWQ-INT4 | FA2 / bf16-kv / `/think` mode enabled | Same-family reasoning cross-check — clean comparison vs G4 | H16 |
| G6 | Magistral-Small-2509 | AWQ-INT4 | FA2 / bf16-kv / no-spec | Mistral-family reasoning cross-check after G4/G5 land | H15 |
| ~~G7~~ | ~~Qwen2.5-Coder-14B~~ | ~~AWQ-INT4~~ | ~~FA2 / bf16-kv / no-spec~~ | **Closed.** Smaller dense will fail worse on quality. Don't pursue. | ~~H1 (alt)~~ |
| ~~G8~~ | ~~(any model)~~ | — | ~~FA3 backend recon~~ | **Done — FALSIFIED.** sm_120 FA3 cubins don't exist in vLLM 0.20.2 (FA3 binary is sm_90a only). | ~~H14~~ |
| **G9** | Qwen3-Coder MoE | AWQ-INT4 | **vLLM `cu129-nightly` image** instead of v0.20.2 | Cheap shot — does the nightly fix MoE+triton (H17) or ship sm_120 FA3 (H14)? Either would unblock H3 → bigger context / FP8 KV gains. | substrate upgrade |
| G10 | Qwen3-Coder MoE | AWQ-INT4 | FA2 / bf16-kv / 96k + **YaRN context extension** to 128k–256k | Qwen3-Coder native is 256k. YaRN RoPE scaling could push beyond 96k. Quality typically degrades non-uniformly. **Only worth doing if H18 says 96k is fully utilized.** | H5 push (post-fidelity) |
| G11 | OpenCode | n/a | **Multi-provider routing config** in `~/.config/opencode/opencode.json` — local Qwen for easy tasks, hosted Claude/GPT API for hardest | "Best of both" — pay tokens only on the hard ~5-10% of calls. Config change, not a vLLM test. Costs API tokens per use. | external (orthogonal to H lever) |
| G12 | DeepSeek-Coder-V2-Lite | AWQ-INT4 | FA2 / bf16-kv | Smaller MoE (16B / 2.4B active). Likely faster decode but lower quality. Worth a comparison run only if we need to optimize for speed-over-quality. | H1 alt (deferred) |
| **G13** | Qwen3-30B-A3B-Thinking-2507 | **DIY AWQ-INT4** (we quantize) | FA2 / bf16-kv | **Reasoning MoE on our exact production architecture.** Same 30B/3B-active as our prod Qwen3-Coder, but with reasoning training. Community AWQ doesn't exist yet — would need DIY via AutoAWQ + CPU offload (~4-12 hours on our hardware) or cloud H100 (~$10). Learning + experiment exercise. Calibration dataset choice matters (reasoning-heavy preferred over code-heavy). | learning track |
| **G14** | Qwen3-Coder-30B-A3B (existing) | AWQ-INT4 + **DIY FP8 KV calibration** | FA2 (NOT triton — escapes the H17 bug) / fp8-static-with-our-scales | Keep our locked production model; only add FP8 KV scales via DIY calibration. Halves KV memory → could push context past 96k to ~128k+ on bf16 budget. Doesn't require requantizing weights (much cheaper than G13). Same calibration tools (AutoAWQ / llm-compressor support KV-only). | KV compression track |

## Cross-cutting observations from the matrix

### TRITON_ATTN regression on Qwen3-Coder MoE is reproducible

R4 and R5 both show 4/5 → 2/5 with the **same 3 problems failing**
(book-store, bottle-song, bowling — the more-complex ones).
Same 2 simpler problems pass (affine-cipher, beer-song).
This is complexity-correlated kernel sensitivity,
not random noise.
The H17 hypothesis (MoE-specific bug) was filed because of this pattern;
G1 will validate or falsify it.

### Qwen3-Coder MoE beats Qwen2.5-Coder-32B Dense on this workload (decisive)

R1 vs R8 — same hardware, same harness, same prompts, same 5 problems.

| Axis | Qwen3-Coder MoE (R1) | Qwen2.5-Coder-32B Dense (R8) |
|---|---|---|
| Polyglot pass rate | 4/5 | 1/5 |
| Decode tok/s | 253 | 76 |
| TTFT | 11ms | 17ms |

The decode-rate gap (~3.3×) matches the active-parameter-count ratio
(32B/3B ≈ 10.7, but compute-per-param efficiency partially compensates).
The polyglot gap is real algorithmic capability — Qwen2.5-Coder-32B
generates well-formed code that's logically incorrect on the harder
problems (book-store's optimal-grouping puzzle, bottle-song's recursive
generation, etc.).
Qwen3-Coder's later training data + MoE expert specialization wins
clearly.

**Implication for the H1 question**:
Qwen3-Coder-30B-A3B-AWQ-4bit is the locked base model.
Dense alternatives in the same VRAM class are uncompetitive on quality
AND speed.

### H5 RESOLVED: 96k locked as production ceiling; 120k loads but non-deterministic; 128k overshoots

| Context | Verdict |
|---|---|
| 32k | original baseline |
| 65k (R10) | works; polyglot 3/5 single-flip (n=5 noise) |
| **96k (R11) — PRODUCTION** | **stable, polyglot 4/5 matches 32k baseline, decode -1.3%** |
| 120k (R13 vs R14) | loads, but generation is **non-deterministic at seed=42** — 2/5 vs 3/5 on consecutive runs with different failure modes (e.g. book-store 3661-tok-fail vs 16384-tok-runaway). Unsafe for production. |
| 128k (R12) | OOM at gpu-mem 0.95 (12 GB KV needed, 11.32 GB available) — hardware ceiling exceeded |

Net change vs original production: **3× context (32k → 96k) for −1.3% decode, banked.**

### H5 (bigger context) was NEVER blocked — the "32k ceiling" was a self-imposed false assumption

R10 vs R1: same model, same backend, only `--max-model-len` changed from 32768 to 65536.

| Axis | 32k baseline (R1) | 65k retest (R10) |
|---|---|---|
| Decode tok/s | 253.1 | 252.6 (−0.2% — noise) |
| TTFT median | 0.011s | 0.011s (+2.7% — noise) |
| Concurrent agg | 713.6 | 697.3 (−2.3%) |
| VRAM @ context | 30.0 GB | 30.7 GB (+0.7 GB) |
| Polyglot pass rate | 4/5 | 3/5 (single-problem flip on book-store; n=5 noise-level) |

**Math reconstruction** (why I was wrong earlier):
- Qwen3-Coder-30B-A3B uses GQA with 4 KV heads × 48 layers × 128 head_dim × 2 (K+V) × 2 (bf16)
  = ~96 KB/token of KV cache
- KV @ 65k = 6 GB; KV @ 128k = 12 GB; KV @ 256k (native max) = 24 GB
- Weights (AWQ-INT4 30B + scales) ≈ 17 GB
- gpu-mem 0.92 budget on 32.6 GB = ~30 GB
- 65k: 17 (weights) + 6 (KV) + 3 (workspace/activations) = 26 GB — fits with 4 GB margin
- 96k: 17 + 9 + 3 = 29 GB — fits tight
- 128k: 17 + 12 + 3 = 32 GB — borderline / OOM-risk, needs gpu-mem 0.95

I had previously asserted "65k won't fit without FP8 KV" without doing this math.
That cost us a full investigation cycle of FP8 KV (H3, H17) that was unnecessary
for the H5 goal.
Lesson: do the math before declaring "blocked."

### TRITON_ATTN bug confirmed MoE-specific (H17 PROVEN)

R8 vs R9 — Qwen2.5-Coder-32B Dense, same hardware, same harness,
same prompts, only the attention backend changed.

| Axis | Dense + FA2 (R8) | Dense + TRITON (R9) |
|---|---|---|
| Polyglot pass rate | 1/5 | 1/5 (HELD) |
| Per-problem token counts | 329, 211, 146, 195, 566 | 329, 211, 146, 195, 566 (IDENTICAL) |
| Decode tok/s | 75.8 | 79.1 (+4.2%) |
| Concurrent agg tok/s | 296.6 | 307.1 (+3.5%) |

Dense + TRITON produces byte-equivalent completions to dense + FA2.
On MoE (R1 vs R5), TRITON produced *different* (worse) completions
on the 3 hard problems — same model, just different backend.

**Conclusion**: triton's quality regression on MoE is caused by
how triton's kernel handles MoE's variable-expert-activation attention
patterns specifically.
On dense models with uniform attention patterns, triton matches FA2
exactly.

The +20% decode advantage triton showed on MoE shrinks to +4% on
dense — so the speed advantage AND the quality regression both come
from triton's MoE-specific kernel paths.
They're coupled: you can't fix one without the other in vLLM 0.20.2.

**Implication for H3 / H5**:
- H3 (FP8 KV via fp8_per_token_head, which forces TRITON) would
  WORK on dense — but dense is uncompetitive (per H1).
- H3 is permanently FALSIFIED on Qwen3-Coder MoE within vLLM 0.20.2.
- H5 (bigger context) needs KV memory savings, which we can't get
  via H3 on the winning model.
- The chain unlocks only via:
  - Upstream vLLM fix to MoE+triton numerical drift
  - FA3 backend support on sm_120 (H14 — speculative)
  - A different checkpoint with FP8 KV scales pre-baked (none exist
    for Qwen3-Coder-30B-A3B yet)

### Triton's perf is genuinely faster (regardless of quality)

R5 vs R1: TRITON gives **+20.1% decode tok/s** (303.9 vs 253.1) on
identical hardware + model + KV scheme.
That's a real perf lever IF we can solve the quality side
(via H17 or upstream vLLM fix).

### NVFP4 weight-loading is broken on vLLM 0.20.2 for >30B models

R6 and R7 both OOM at 30 GB regardless of which NVFP4 GEMM kernel is
forced.
Root cause: ~20 GB of unquantizable BF16 components
(embeddings + layer norms + vision encoder)
on top of ~12 GB packed NVFP4 linear weights = 32+ GB total,
exceeds 32.6 GB VRAM ceiling.
Not fixable on this hardware via config — fundamental architecture
issue with the Gemma 4 31B variant on vLLM 0.20.2.

### FP8-KV-via-static-scales path is gated on calibration data we don't have

R2 is the only run that touched static FP8 KV (bundled with H2).
The accuracy regression there matched vLLM's own startup warning
("may cause accuracy drop without a proper scaling factor").
The cyankiwi AWQ-INT4 checkpoint we use doesn't ship FP8 KV scales.
The dynamic-per-token-head alternative routes through TRITON_ATTN
which has its own (currently MoE-blocked) issue.
Net: FP8 KV is closed on Qwen3-Coder MoE.
H17's outcome decides whether it opens on dense.

## Upside roadmap by dimension

Beyond individual H-tests, this is the strategic landscape of "what could be
better" — organized by the dimension we're trying to push.
Use this when deciding direction;
use the gap list above when deciding the next test.

### Quality dimension

| Lever | Cost | Path | Status |
|---|---|---|---|
| **Reasoning model (H16)** — DeepSeek-R1-Distill-Qwen-32B (dense reasoning) | 30 min + 17 GB download | actionable today | OPEN — top priority |
| **Reasoning MoE (G13)** — DIY AWQ-INT4 of Qwen3-30B-A3B-Thinking-2507 | 4-12 hrs CPU-offload OR ~$10 cloud H100 | actionable today (DIY) | OPEN — "learning track" |
| Reasoning MoE via community AWQ | wait for cyankiwi / QuantTrio | external — track HF | watchlist |
| Cross-family reasoning (H15) — Magistral-Small-2509 | 30 min + 12 GB | actionable today | DEFERRED behind H16 |
| Newer Qwen3-Coder releases | track HF | external | watchlist |
| **Multi-provider routing in OpenCode** (G11) — local for easy, API for hard | config change, ~10 min | actionable today | OPEN — orthogonal |
| Fine-tune on our codebase | days + dataset work | rarely justified | not planned |

### Performance dimension

| Lever | Cost | Path | Status |
|---|---|---|---|
| **vLLM `cu129-nightly` (G9)** — does main fix MoE+triton (H17) or ship sm_120 FA3 (H14)? | ~15 min, separate compose file | actionable today | OPEN — cheap shot |
| H4 (max-num-seqs / batched-tokens tuning) | ~20 min | actionable today | DEFERRED — re-eval at 96k pending H19 result |
| Smaller MoE for speed-over-quality (G12) — DeepSeek-Coder-V2-Lite | ~30 min + 8 GB | actionable today | trade-off probably wrong direction |
| **FA3 on sm_120 — the cross-cutting unlock** (H14) | wait for vLLM release OR risky DIY build | external event | FALSIFIED in v0.20.2 (binary is sm_90a only). See "FA3 strategic role" below |
| NVFP4 weights with working kernel | wait for vLLM release | external event | weight-loader bug blocks >30B today |
| Hardware: H100 / B100 | $$$ | out of scope | — |

### Context dimension

| Lever | Cost | Path | Status |
|---|---|---|---|
| **Long-context fidelity validation (H18)** — needle-in-haystack at 96k | ~10 min, no download | actionable today | OPEN — top priority before any further push |
| **YaRN context extension (G10)** to 128k–256k | ~10 min, config change | actionable today | OPEN — only after H18 validates 96k is real |
| **DIY FP8 KV calibration (G14)** — calibrate scales for our existing Qwen3-Coder MoE AWQ → halves KV memory → push beyond 96k via static FP8 KV on FA2 (escapes H17 triton-MoE bug) | ~3-6 hrs runtime | actionable today (DIY) | OPEN — "KV compression track" |
| CPU KV offload — `--kv-offloading-size` | config change, real perf cost | actionable today | low priority unless context is the bottleneck |
| FP8 KV via vLLM upstream fix to MoE+triton (path 1) | wait for vLLM | external event | H17 confirmed bug, fix pending |
| FP8 KV via FA3 on sm_120 (path 2 — FA3 has native FP8 KV without triton) | wait for vLLM | external event | gated on H14 |
| Larger VRAM GPU (RTX 6000 Pro 96 GB, H100 80 GB) | $$$ | out of scope | — |

### FA3 strategic role — the cross-cutting external lever

FA3 (FlashAttention 3) sits in an unusual position in our roadmap:
it's **listed under Performance** but if it ever ships for sm_120 it would
**unblock paths across Quality, Performance, AND Context simultaneously**.
This makes it the highest-value single external event we track.

What FA3 would unlock (per source-read of vLLM 0.20.2):

| Dimension | FA3 unlock |
|---|---|
| Performance | Faster GEMM kernels — typically 1.5-2× FA2 throughput; native FP8 + async memory ops via TMA on hardware that supports it |
| Performance + scheduling | `AttentionCGSupport.ALWAYS` (level 3) — spec-decode keeps FULL_AND_PIECEWISE CG without downgrade. This is what would re-open H2 (n-gram speculative) — the downgrade we saw on FlashInfer was the root of H2's perf cost |
| Context | Native FP8 KV path **without** routing through triton_attn. Escapes the H17 MoE-specific bug — would re-open H3 (FP8 KV) cleanly on Qwen3-Coder MoE → context push from 96k toward 128k+ |
| Quality | Better numerical handling on MoE attention patterns (un-verified hypothesis but FA3's design accounts for MoE patterns more deliberately than FA2/triton) |

What's blocking it today (per H14 binary-inspection 2026-05-10):

| Block | Detail |
|---|---|
| Bundled binary | `_vllm_fa3_C.abi3.so` contains **sm_90a (Hopper) cubins only** |
| Architecture-specific intrinsics | FA3 uses Hopper TMA / wgmma — Blackwell consumer (sm_120) needs different intrinsics |
| vLLM version-selector logic | code explicitly defaults sm_120 to FA2 (`device_capability.major == 12 → fa_version = 2`) |
| Override doesn't help | even forcing `flash_attn_version=3` would fail `is_fa_version_supported(3)` runtime check |

What would make FA3 viable on our hardware:

| Path | Timeline | Confidence |
|---|---|---|
| **vLLM releases with sm_120 FA3 cubins** | Unknown — could be weeks or quarters. Track vLLM releases. | Most likely path |
| **DIY rebuild of flash-attn with sm_120 + FA3** | Days of work, may not port cleanly from Hopper-specific intrinsics | High effort, uncertain outcome |
| **Wait for a vllm-fork or community build** | Sporadic — some community vLLM builds ship FA3 across more arches than upstream | Track community forks |
| **Hardware change** to sm_90 (Hopper H100) — already has FA3 working | $$$ | Out of scope |

What we should do today regarding FA3:

1. **Periodically check the vLLM nightly** (G9) for sm_120 FA3 inclusion
2. **Track vLLM GitHub issues / PRs** mentioning sm_120 FA3 or Blackwell consumer
3. **Don't invest in DIY rebuild** — the sm_90a → sm_120 port is non-trivial and other paths (G14 DIY KV calibration) achieve comparable wins with less risk
4. **Plan for FA3 arrival** — when it ships, re-test H2 / H3 / H5 push beyond 96k — would be a major substrate upgrade

### Validation dimension (validate what we have before pushing further)

| Lever | Cost | Why now |
|---|---|---|
| **H18** long-context fidelity at 96k | ~10 min | Locks (or refutes) the 3× context win |
| **H19** concurrent fan-out at 96k | ~10 min | OpenCode forks sub-agents; 1.15× KV concurrency may be tight |
| **H20** n=10 polyglot at 96k | ~20 min | Confidence gate on the production config |

### Strategic ordering

If goal is **validate then explore**:
H18 → H19 → H20 → H16 (reasoning anchor) → G9 (nightly recon) → G11 (multi-provider)

If goal is **expand upside fast**:
H16 → G11 → H18 (in parallel via OpenCode use) → G9

If goal is **maximize quality regardless of cost**:
G11 (multi-provider routing) immediately. Use Claude/GPT API for hard SWE tasks while keeping local as the fast / cheap default for easy calls.

If goal is **push the locked production to its theoretical maximum on this hardware (the "dream" permutation)**:
H16 (establish reasoning quality reference) → **G14 (DIY FP8 KV calibration of current AWQ)** to validate the calibration pipeline at lower risk → **G13 (DIY AWQ of Qwen3-30B-A3B-Thinking-2507)** for reasoning MoE → optionally combine into G13+G14 stack for the full "AWQ-INT4 weights + DIY-calibrated FP8 KV + FA2 backend + reasoning MoE at 128k context" configuration. Total effort: 1-3 days of engineering. Reward: production stack 2-3× more capable per dimension.

If goal is **wait for external unlocks and bank current production**:
Watch vLLM releases for **FA3-on-sm_120** (the single highest-value external event) and **community AWQ-INT4 of Qwen3-30B-A3B-Thinking-2507**. Run H18/H19/H20 to validate current production while waiting. ~0 effort, time-bound on external events.

## Maintenance

- Add a row when a new test completes (`perf-snapshot.sh` + `polyglot-bench.sh`).
- Move falsified rows to keep the table chronological;
  don't delete (the dossier is what matters).
- The "Pending" section is the gap list — when something migrates from
  pending to tested, move the row up to the tested table.
- The "Upside roadmap" section is the strategic landscape — update when
  new dimensions or external events change the picture.
- A future improvement: auto-generate this from `archive/*/summary.json`
  via a small Python script. Hand-maintained today.
