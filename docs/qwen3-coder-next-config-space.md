# Qwen3-Coder-Next configuration space

> Companion to [`model-config-matrix.md`](./model-config-matrix.md) — that
> doc is one-row-per-tested-config; this doc enumerates the *design*
> space we're testing across before each row exists. Use it to decide
> which permutations are worth measuring vs which are dominated.

> **Status (2026-05-13): PARKED pending vLLM PR #37190 merge.**
> Initial bring-up tested 3 sub-configurations (R16 in matrix). vLLM 0.20.2
> and nightly both lack the MoE-aware expert offload path. See
> [§ Empirical findings 2026-05-13](#empirical-findings-2026-05-13) below.

## Hardware envelope

| Resource | Value | Constraint |
|---|---|---|
| GPU VRAM (RTX 5090) | 32 GB usable | All quantizations except sub-30-GB GGUF require CPU offload |
| Host RAM (NUC 15 Pro+) | 128 GB DDR5 | Headroom for spilled experts |
| TB4 H2D bandwidth | ~2.8 GB/s sustained | Per memory `feedback_lspci_lnkcap_tb_virtual` |
| GPU bus | TB4-tunneled PCIe Gen3 x4 | ~10% of native PCIe x16 Gen4 |

**Binding constraint**: TB4 H2D bandwidth is the bottleneck for any
configuration where experts are routed from CPU. Quality and absolute
weight size are secondary to "how often does a routed expert have to
cross TB4 per token."

## Model fundamentals (Qwen3-Coder-Next)

| Property | Value |
|---|---|
| Total params | 80B (MoE) |
| Active params per token | 3B (10 of 512 experts) |
| Architecture | Hybrid Gated DeltaNet (linear, 75% of layers) + Gated Attention (full, 25% — `full_attention_interval: 4`) |
| Full-attention KV | GQA-2 (only 2 KV heads × 256 head_dim) → small per-token KV |
| Native context | 256K (extensible to 1M with YaRN per model card) |
| FP16 size | ~160 GB |
| AWQ-4bit size | ~45 GB |
| FP8 size | ~80 GB |
| GGUF Q4_K_M | ~48 GB |
| GGUF Q3_K_M | ~32-35 GB (estimated; would just-fit pure-GPU) |

KV cost is unusually small for this architecture — only 12 of 48 layers
store full KV, the rest are constant-state linear. **Context length is
NOT the binding constraint here; expert offload bandwidth is.**

## Configuration axes

### Axis 1 — Quantization variant (with maintainer + workflow fit)

| Variant | Repo | Size | Workflow match | Notes |
|---|---|---|---|---|
| **AWQ-INT4** | `cyankiwi/Qwen3-Coder-Next-AWQ-4bit` | ~45 GB | ✓ same maintainer as locked production | Smallest viable variant on vLLM. INT4 quantization quality drift well-characterised. |
| AWQ-INT8 | `cyankiwi/Qwen3-Coder-Next-AWQ-8bit` | ~85 GB | ✓ vLLM | Strictly worse than FP8 at same size — skip. |
| **FP8** | `unsloth/Qwen3-Coder-Next-FP8` | ~80 GB | ✓ vLLM | Per-tensor scales. Closer-to-bf16 quality. ~50 GB CPU offload required. |
| FP8 Dynamic | `unsloth/Qwen3-Coder-Next-FP8-Dynamic` | ~80 GB | ✓ vLLM | Same size as FP8 but dynamic per-channel scales. Marginally better quality, same offload pressure. |
| **GGUF Q4_K_M** | `bartowski/Qwen_Qwen3-Coder-Next-GGUF` | ~48 GB | ✗ llama.cpp (or vLLM GGUF loader, experimental) | External validation: 38-48 tok/s on RTX 5090 + 64 GB DDR5 per compute-market.com. Layer-based offload, different mechanism than vLLM's expert-routing offload. |
| GGUF Q3_K_M | `bartowski/...-GGUF` (smaller quant in same repo) | ~32-35 GB | ✗ llama.cpp | Potentially fits pure-GPU with no offload, but more quality drop. |
| GGUF Q5_K_M | `bartowski/...-GGUF` | ~60 GB | ✗ llama.cpp | More offload than Q4_K_M, slightly better quality. Skip — Q4_K_M is the sweet spot per external benchmarks. |
| NVFP4 | `RedHatAI/Qwen3-Coder-Next-NVFP4` | ~50 GB est. | ✗ vLLM (weight-loader bug per R6/R7 in matrix) | Marlin kernel exists but the weight-loader bug we hit on Gemma-4 31B may bite — skip until vLLM nightly. |

**Three viable variants to actually test**: AWQ-4bit, FP8, GGUF Q4_K_M.

### Axis 2 — Runtime

| Runtime | MoE offload mechanism | Maturity for 80B MoE on TB4 | Notes |
|---|---|---|---|
| **vLLM v0.20.2 (current)** | `--cpu-offload-gb N` (V0.15+ added expert-aware variant) | Less battle-tested at this scale | Same as locked production R11 — workflow continuity. |
| vLLM cu129-nightly | Same as above, possibly fixes H17 triton-MoE bug | Unknown | Already filed as G9 in matrix; could combine "G15 + G9" if nightly is needed. |
| **llama.cpp** | `--n-gpu-layers N` (layer-based, not expert-aware) | Mature for exactly this pattern | The 38-48 tok/s external benchmark used this. Adds a second OpenAI-server endpoint to maintain. |
| SGLang ≥0.5.8 | Different scheduler | Not our path | Skip — would duplicate vLLM's role. |

**Two viable runtimes**: vLLM (workflow match), llama.cpp (external-validated path).

### Axis 3 — Offload aggressiveness (vLLM `--cpu-offload-gb`)

For AWQ-4bit (~45 GB total weights):

| `--cpu-offload-gb` | GPU weights | Hot expert cache size | KV+workspace headroom | Expected behaviour |
|---|---|---|---|---|
| 0 | full | n/a | n/a | **OOM** — won't load |
| 10 | ~35 GB | large | ~5 GB | OOM — too much GPU pressure, KV pool starves |
| **13-15** | ~30-32 GB | medium-large | ~8-10 GB | **Sweet spot candidate** — comfortable KV headroom, most experts stay GPU-resident |
| **17-20** | ~25-28 GB | medium | ~10-12 GB | More headroom for big context; more routed experts pay TB4 cost |
| 22-25 | ~20-23 GB | small | ~12-14 GB | Frequent expert streaming; perf hit. Only justified if huge context needed. |
| 30+ | ~15 GB | very small | huge | Cold-cache thrashing; near-llama.cpp-layer-offload behaviour. Probably dominated by GGUF in this regime. |

Per-token expert traffic estimate:
- 10 experts routed per token, each ~~~45 GB / 512 ≈ 90 MB at INT4 (rough)
- If hot cache holds top ~30% of experts → ~70% of routed-expert volume hits TB4 = ~630 MB/token = ~225 ms/token at 2.8 GB/s = **~4.5 tok/s** worst-case
- If hot cache holds top ~80% → ~20% TB4-bound = ~80 ms/token = **~13 tok/s**
- Achievable target: hot cache locality + KV reuse → **~15-25 tok/s** sustained

### Axis 4 — Context length

| max_model_len | KV @ hybrid attention (12 full-attn layers, bf16) | KV @ same, FP8 |
|---|---|---|
| 32K | ~1 GB | ~0.5 GB |
| **65K** (≈ R10 target) | ~2 GB | ~1 GB |
| **96K** (≈ R11 production parity) | ~3 GB | ~1.5 GB |
| 128K | ~4 GB | ~2 GB |
| 192K | ~6 GB | ~3 GB |
| 256K (native max) | ~8 GB | ~4 GB |

KV is cheap enough that context length is mostly free here. Pick to match
R11 (96K) for apples-to-apples, or 65K conservative for first bring-up.

### Axis 5 — KV dtype

| KV dtype | Backend forced | KV memory | Quality cost |
|---|---|---|---|
| bf16 (default) | FA2 (auto) | 1× | None |
| fp8_per_token_head | **TRITON_ATTN** (potentially H17-affected, but Coder-Next is MoE — verify on bring-up) | 0.5× | Small (per vLLM warning) |
| fp8 static-scale | FA2 | 0.5× | Needs calibration scales (G14 territory) |

For Coder-Next specifically, since binding constraint is *expert offload bandwidth* not *KV memory*, **FP8 KV is a smaller lever than for dense models**. Keep bf16 for baseline; revisit if context needs to push past 96K.

### Axis 6 — Backend execution mode

| Mode | Cost | When to use |
|---|---|---|
| **cudagraphs FULL_AND_PIECEWISE** (default) | requires ~1.5 GB headroom for capture | First-pick once memory budget known |
| eager (`--enforce-eager`) | ~20-30% decode-perf hit | Initial bring-up to confirm fit, or if cudagraph profiling OOMs (G16 case) |

## Useful permutations to test

Pruning the 8 × 2 × 6 × 5 × 2 × 2 = 1920-point space down to discriminating
points:

| # | Quant | Runtime | Offload | Context | KV | Backend | Question answered |
|---|---|---|---|---|---|---|---|
| **G15.A** | AWQ-4bit | vLLM | 17 GB | 65K | bf16 | **cudagraphs** | **Initial fit + quality baseline (R11 apples-to-apples for everything but context)** |
| G15.A-fallback | AWQ-4bit | vLLM | 20 GB | 65K | bf16 | eager | Only if G15.A OOMs at cudagraph profiling — escalate offload, fall back to eager |
| G15.C | AWQ-4bit | vLLM | 13 GB | 65K | bf16 | cudagraphs | Does larger hot-expert cache help decode? |
| G15.D | AWQ-4bit | vLLM | 22 GB | 65K | bf16 | cudagraphs | Does smaller hot-expert cache cost more than expected? |
| G15.E | AWQ-4bit | vLLM | 17 GB | 96K | bf16 | cudagraphs | R11 apples-to-apples context |
| G15.F | AWQ-4bit | vLLM | 17 GB | 128K | fp8 | cudagraphs | Context push beyond production |
| **G15.G** | FP8 | vLLM | 55 GB | 65K | bf16 | eager | **Quality comparison: FP8 vs AWQ-4bit at higher offload cost** |
| G15.H | GGUF Q4_K_M | llama.cpp | layer-based | 65K | bf16 | n/a | External-runtime cross-check (matches compute-market.com benchmark) |
| G15.I | GGUF Q3_K_M | llama.cpp | minimal | 65K | bf16 | n/a | Smallest variant; tests if pure-GPU possible |
| G15.J | AWQ-4bit | vLLM-nightly | 17 GB | 65K | fp8 | cudagraphs | Combines G9 (nightly) with G15 — covers post-H17 paths |

### Initial test ordering (priority)

1. **G15.A** — initial fit + quality baseline with cudagraphs ON for R11 apples-to-apples. The G16 cudagraph-profiling OOM was specifically because of Qwen3.6-27B's multimodal vision tower (~5-10 GB unquantized); Coder-Next AWQ-4bit + 17 GB offload doesn't carry that weight. If empirically OOMs, fall back to G15.A-fallback (eager + 20 GB offload).
2. **G15.E** — push to 96K context for full R11 parity. Tests whether expert-offload + larger KV pool fits.
3. **G15.G** — only if A/E look promising. FP8 is more expensive to offload but may give cleaner quality.
4. **G15.H** — only if vLLM offload turns out unviable. Different-runtime escape hatch.

(G15.B was originally "cudagraphs recovery after eager baseline" — folded into G15.A since the eager-first call was a G16-specific reaction, not a general practice.)

### Dominated / skip

- AWQ-INT8 — strictly larger than FP8 at same bit-budget, skip
- GGUF Q5_K_M — more offload than Q4_K_M with marginal quality gain, skip
- GGUF Q6_K — same logic, skip
- NVFP4 — vLLM weight-loader bug (R6/R7) probably still bites — defer until next vLLM release
- SGLang variants — duplicate vLLM's role, skip
- Pure-GPU (offload=0) — won't fit at any usable quant
- 32K context — too conservative; we already have 96K-stable production

## Validation harness per test

Each row in the table above, when tested, gets:

1. Bring-up: container launches, `/health` 200 OK
2. VRAM measurement at idle and at peak (during prefill of 8K-token request)
3. `tools/perf-snapshot.sh` — TTFT, decode tok/s, 4× concurrent agg
4. `tools/polyglot-bench.sh 5 python` — n=5 polyglot (or n=10 if quality is on the bubble)
5. **Quality gate (kill criterion)**: polyglot ≥ R11 baseline (4/5 at n=5)
6. **Perf gate (production-swap criterion)**: decode within 50% of R11's 253 tok/s

Configs that pass both gates become production-swap candidates. Configs
that pass quality but fail perf become "wait for FA3 / vLLM nightly"
candidates. Configs that fail quality get FALSIFIED status.

## Open questions to resolve

1. **Does vLLM v0.20.2's `--cpu-offload-gb` actually use the MoE-expert-aware path?** The flag exists; the docs are ambiguous about whether it's the dumb dense-weight-streaming variant or the smart routed-expert variant. May need to read source or empirically test (decode rate is the tell — dumb variant would be sub-1 tok/s).

2. **Does the hybrid-attention model trigger TRITON_ATTN by default?** Our G16 experience showed Qwen3.6-27B does NOT (FA2 stayed). Confirm same for Coder-Next on bring-up; if TRITON_ATTN gets selected, re-check the H17 MoE-numerical-drift question.

3. **Does cudagraph profiling fit at all?** G16 OOM'd here. Coder-Next has bigger weights but smaller KV pool; profiling memory cost is similar though. Plan for eager-mode initial bring-up just in case.

4. **What's the actual expert hot-cache hit rate on this workload?** Determines real decode tok/s. Only measurable empirically.

## Empirical findings 2026-05-13

Three sub-attempts during initial G15.A bring-up (consolidated as R16 in
the matrix). All on `cyankiwi/Qwen3-Coder-Next-AWQ-4bit` at 65k context,
eager mode, FA2.

### Attempt 1: UVA backend, non-selective offload
```
--cpu-offload-gb=20
(no --cpu-offload-params)
```
**Decode: 0.20 tok/s.** vLLM offloaded the first 20 GB of weights that
loaded — *not* expert-specific. Every forward pass touched CPU-resident
non-expert weights → roughly the predicted "dumb streaming" rate of 20
GB / 2.8 GB/s ≈ 7 sec/token.

### Attempt 2: UVA backend, expert-targeted (Path A)
```
--cpu-offload-gb=20
--cpu-offload-params=experts
```
**Decode: 1.19 tok/s.** 6× improvement — confirms expert-targeting matters.
But still ~210× slower than R11 (253 tok/s). Bottleneck: UVA pages on
demand at page granularity; 10 experts × 48 layers = ~480 expert-access
events per token; with ~50% volume on CPU each fault is ~5 ms overhead +
data transfer. A polyglot run at this rate would take ~8 h, not feasible.

### Attempt 3: prefetch backend, expert-targeted (Path B)
```
--offload-backend=prefetch
--offload-group-size=4
--offload-num-in-group=2
--offload-prefetch-step=2
--offload-params=experts
```
**Load OK — runtime CRASH.** `AssertionError: CPU storage for
mlp.experts.w13_weight_g_idx is not pinned` at first inference step.
The prefetch offloader requires CUDA-pinned CPU memory for async H2D
copies, but AWQ-INT4's `g_idx` (group-index int32 tensor) fails to pin.

Workaround `VLLM_WEIGHT_OFFLOADING_DISABLE_PIN_MEMORY=1` bypasses the
assert but breaks fork-event sync at runtime — container crashed during
the first inference request (>5 min hang, 0 tokens). Conclusion:
**prefetch backend is not AWQ-compatible in v0.20.2.**

### Nightly verification (2026-05-13)

Pulled `vllm/vllm-openai:nightly` (version `0.20.2rc1.dev246+g28ee78af5`).
Compared offload modules byte-for-byte with installed v0.20.2:

| File | v0.20.2 md5 | Nightly md5 | Match? |
|---|---|---|---|
| `config/offload.py` | `b0c116488f9006884f27317a046f7164` | (same) | ✓ |
| `model_executor/offloader/prefetch.py` | `be7ff18ae7ef0e417aec5a5e5e09a393` | (same) | ✓ |
| `model_executor/offloader/uva.py` | `d7979457acc4dde91616b37e9886e81c` | (same) | ✓ |

**Conclusion**: nightly has no new offload paths. PR #37190 (the
MoE-aware `--moe-expert-cache-size` + LFRU cache + CPU-pinned experts)
is NOT merged. Greps for `CachedWeightProvider`, `MoEExpertCache`,
`LFRU`, `moe-expert-cache-size` all empty in both versions.

### Lock decision

G15 is **PARKED**:
- v0.20.2 / nightly UVA backend: 1.19 tok/s ceiling — not usable
- v0.20.2 / nightly prefetch backend: crashes on AWQ models
- Smart MoE path: blocked on upstream PR #37190 (open, verified label,
  ~980 LOC, CI passing, awaiting code-owner review as of 2026-05-11)

**Trigger to revisit**: PR #37190 merges OR equivalent path lands.
Watchlist entry in `model-config-matrix.md` as G17.

### Updates to the open-questions list above

1. ✅ Answered: vLLM 0.20.2's `--cpu-offload-gb` is **non-selective by default**. Adding `--cpu-offload-params=experts` enables expert-targeting but still uses page-fault UVA mechanism — too slow for TB4.
2. ✅ Answered: TRITON_ATTN does NOT auto-select for Qwen3-Coder-Next either. FA2 stays. Same as Qwen3.6-27B.
3. ✅ Answered: cudagraph profiling fits OK on this model (more headroom than Qwen3.6-27B's multimodal vision tower ate). We used `--enforce-eager` defensively but it wasn't required by memory pressure.
4. ❓ Not yet answered: hot-cache hit rate. Need PR #37190's smart path to measure meaningfully.
