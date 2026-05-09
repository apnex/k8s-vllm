# vLLM perf hypothesis ledger

> **Living document.**
> Tracks every open hypothesis about how to push our vLLM stack
> for higher quality + higher throughput on heavy software-engineering
> workloads via OpenCode.
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

1. Aider Polyglot subset (30 problems across Python / JS / Rust / Go / C++ / Java).
   See [`tools/aider-polyglot-bench.sh`](../tools/aider-polyglot-bench.sh).
2. OpenCode hand-crafted suite — 5 representative tasks, scored 1–5.
3. Tool-call retry count on the suite (target: 0 per task).

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

### H1 — Qwen3-Coder-30B-A3B beats Gemma 4 26B-A4B for SWE quality at ~same decode speed

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-09 |
| Motivation | Qwen3-Coder is code-pretrained + RLHF'd specifically for SWE; Gemma 4 is general-purpose. Both are MoE with ~3-4B active params, so decode speed should land in the same bucket. Quality on Aider Polyglot for Qwen3-Coder-30B-A3B reportedly leads dense 70B models. |
| Quality gate | Aider Polyglot subset pass-rate must beat current Gemma 4 baseline by ≥ +5 percentage points to be declared a quality win. |
| Test plan | Pull `cyankiwi/Qwen3-Coder-30B-A3B-Instruct-AWQ-4bit`. Swap `VLLM_MODEL`, restart, run perf-snapshot.sh + Aider subset. Compare against frozen Gemma 4 baseline. n=3 on Aider subset to control for sampling variance. |
| Measurement | Aider Polyglot pass-rate (%); decode tok/s ×3; concurrent-4 decode tok/s; OpenCode tool-retry count on hand-crafted suite. |
| If proven | Switch default `VLLM_MODEL` to Qwen3-Coder; lock as Phase 1 baseline. |
| If falsified | Stay on Gemma 4; explore other code-tuned models (Magistral-Small, Mistral-Small-3.2-24B). |

### H2 — n-gram speculative decoding gives 1.3–1.8× decode with zero quality loss

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-09 |
| Motivation | Code is highly repetitive (variable names, brackets, common patterns). vLLM's `--speculative-config '{"method": "ngram", "num_speculative_tokens": 5, "prompt_lookup_max": 4}'` predicts repeated text from the prompt itself — no draft model needed. Acceptance rate on code is typically 40–60%. Free 1.3–1.8× decode. |
| Quality gate | Speculative decoding must produce identical outputs to non-speculative for greedy temp=0 runs (verifies acceptance logic correctness). |
| Test plan | Add `--speculative-config '...'` to compose. n=3 perf snapshots before/after with seeded prompts. Diff outputs at temp=0. |
| Measurement | Decode tok/s; speculative-acceptance-rate (logged by vLLM); identical-output verification. |
| If proven | Add to default compose; keep flag on permanently. |
| If falsified | Drop; revisit if a code-tuned draft model emerges (H8). |

### H3 — FP8 KV cache halves KV memory → enables 65k context or 2× concurrent sub-agents

| Field | Value |
|---|---|
| Status | **OPEN** |
| Stated | 2026-05-09 |
| Motivation | `--kv-cache-dtype=fp8` halves KV memory at minimal quality loss (NVIDIA's published FP8-KV results show <0.5% accuracy delta on standard benchmarks). On Blackwell, FP8 has native tensor-core support — may even be faster than bf16 KV. Frees ~7 GB VRAM at 32k context, which can be spent on bigger context OR more concurrent sequences. |
| Quality gate | Aider Polyglot subset within −2pp of bf16 baseline. Long-context fidelity test: insert known fact at token ~20000, ask at end-of-context — must retrieve correctly. |
| Test plan | Add `--kv-cache-dtype=fp8` to compose. Run quality gate. Then push max-model-len to 65536 OR `--max-num-seqs` higher; measure concurrent-4 throughput. |
| Measurement | Aider pass-rate; long-context retrieval correctness (n=5); concurrent throughput delta. |
| If proven | Add to default; consider H5 (bigger context) on top. |
| If falsified | Stay on bf16 KV; consider INT8 if bf16 budget too tight. |

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

### H5 — Bump `max_model_len` to 65k–128k with FP8 KV — full repo context viable

| Field | Value |
|---|---|
| Status | **OPEN** (blocked by H3) |
| Stated | 2026-05-09 |
| Motivation | Real codebases routinely hit 50k+ tokens for whole-file reads. 32k context forces OpenCode to chunk / RAG, losing accuracy on whole-codebase reasoning. Native context for Gemma 4 / Qwen3-Coder is 128k. With FP8 KV (H3), 65k feasible. |
| Quality gate | Long-context fidelity (n=5 inserted-fact retrievals at token ~50000). Aider subset still passes. |
| Test plan | Set `--max-model-len=65536`; measure VRAM headroom; run regression suite. |
| Measurement | VRAM at idle + at 60k-context request; long-context retrieval correctness; throughput at long context. |
| If proven | Lock 65k or 128k as default. |
| If falsified | Keep 32k; investigate prefix caching (H6) instead. |

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
| Status | **DEFERRED** |
| Stated | 2026-05-09 |
| Motivation | OpenCode supports per-agent model assignment. Light agents (file-list, ripgrep-summary) don't need 30B-class quality. Run 26B MoE on vLLM for build/plan, run a 1–4B model on Ollama for fast tool-summary sub-agents. Memory carve-out tricky — both need GPU. |
| Quality gate | OpenCode's overall task success rate stays flat. |
| Test plan | TBD; needs OpenCode multi-agent config investigation. |

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

---

## Resolved hypotheses

(empty — first pass, 2026-05-09)

---

## Phase plan

| Phase | Hypotheses | Goal |
|---|---|---|
| **Phase 1 — Lock the base model** | H1 | Decide Qwen3-Coder-30B-A3B vs Gemma 4 26B-A4B |
| **Phase 2 — Free wins** | H2, H3, H6 | Speculative + FP8 KV + prefix-cache verification |
| **Phase 3 — Quality / context** | H5, H7 | Bigger context + FP8 weights |
| **Phase 4 — Concurrency** | H4 | Tune for OpenCode sub-agent fan-out |
| **Phase 5 — Speculative-with-draft** | H8 | Last-mile decode speedup |
| **Phase 6 — Multi-model** | H9 | Heavy + light split for agentic workflows |
| **Phase 7 — Cold-load** | H11–H13 | Inherited from perf-roadmap |
