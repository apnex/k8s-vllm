# Model research — 3-week window 2026-05-03 → 2026-05-24

**Date:** 2026-05-24
**Method:** Opus subagent research via HuggingFace API + vLLM PR scan + targeted web search
**Hardware target:** single RTX 5090 (32 GB), TB4-tunneled PCIe, vLLM v0.20.2 (v0.21.1 cutover target)
**Workload target:** coding via OpenCode agent (polyglot-class) at ≥96k context, AWQ-4bit preferred

## TL;DR (5 names worth testing, ranked)

1. **`cyankiwi/Laguna-XS.2-AWQ-INT4`** — 33B / 3B-active MoE, SWE-bench Verified 68.2%, SWE-bench Multilingual 62.4%, native Apache 2.0, **architecturally near-isomorphic to R11** (MoE, ~30B class, 3B active) with explicit "agentic coding + long-horizon work" framing. Tool-call parser is custom (`poolside_v1`) and ships in vLLM PR #41129 (merged 2026-04-28, in v0.20.2). **Lowest-risk swap of R11.** Caveat: base model released 2026-04-28/29 (outside window by 4 days); AWQ-4bit by cyankiwi created 2026-05-02 and last-mod 2026-05-13, which IS in window — that quant artefact is the new fact.
2. **`tencent/Hy-MT2-30B-A3B-FP8`** — 30B / 3B-active MoE, **architectural twin of R11 (Qwen3-Coder-30B-A3B)**, native FP8 ships from Tencent (2026-05-18). **Cautionary:** model is translation-specialised (33 languages, 4096-token default). Almost certainly NOT a coding upgrade, but cheap to test as a "MoE-30B-A3B that's NOT Qwen3-Coder" baseline. Include here only because the architectural similarity is unique among new-in-window releases.
3. **`Jackrong/Qwopus3.6-35B-A3B-v1`** — 35B/3B-active MoE distilled from Claude Opus reasoning traces onto a Qwen3.6 MoE base, released 2026-05-06. Hybrid Gated DeltaNet linear + standard attention (novel-ish), 256 experts, 262K native context, Apache 2.0. **Only GGUF and base BF16 ship today — no AWQ.** Tier B only; flagged for tracking when QuantTrio / cyankiwi quantises it.
4. **`Jackrong/Qwopus3.6-27B-v2-FP8`** — 27B dense Qwen3.6-27B base with Trace Inversion reasoning distillation, FP8 in-window (2026-05-23). Card cites SWE-bench Verified 75.25% (vendor-reported, controlled-202 slice). **Hard-gate blocker: model card explicitly states "Required Version: vLLM 0.21.0".** Roll-forward target after v0.21.1 cutover. **R15-style retry vehicle** (different distillation pipeline than the abliterated/pristine variants of Qwen3.6-27B).
5. **`cyankiwi/GLM-4.7-Flash-REAP-23B-A3B-AWQ-4bit`** — REAP-pruned variant (Cerebras Router-weighted Expert Activation Pruning, 25% expert pruning from GLM-4.7-Flash 30B-A3B to 23B-A3B), AWQ-4bit, 202K context, MIT license. Base GLM-4.7-Flash AWQ predates window; the **REAP variant + GLM-4.7 tool-parser fix (PR #31220 merged 2026-05-21)** are the in-window novelties. Listed Tier S because REAP is a novel deployment-time architectural intervention worth understanding even if final quality lags R11.

**Most surprising novel callout:** `ByteDance-Seed/Cola-DLM` — a hierarchical **continuous-latent diffusion language model** (Flow Matching prior over text VAE latents instead of next-token prediction). Released 2026-05-15, Apache 2.0, paper [arXiv:2605.06548](https://arxiv.org/abs/2605.06548). Not a near-term deployment candidate (research checkpoint, no vLLM path) but it's an actual architecture departure, not a transformer reshuffle.

## Methodology + sources

Triangulated three data streams; cross-checked the unions.

- **HuggingFace API** — direct REST endpoint queries:
  - `GET /api/models?sort=trendingScore&direction=-1&limit=100&filter=text-generation` — filtered client-side for `createdAt >= 2026-05-03`. Found: Hy-MT2 family (Tencent, 2026-05-11), HRM-Text-1B (2026-05-17), Ring-2.6-1T (inclusionAI, 2026-05-14), Cola-DLM (ByteDance-Seed, 2026-05-15), Qwopus3.6-35B-A3B-v1 (Jackrong, 2026-05-06), GoLongRL-30B-A3B (Kwai-Klear, 2026-05-19), Carbon-{500M,3B,8B} (HuggingFaceBio, scientific), SR2AM-v1.0-30B (sailing-lab, 2026-05-19), Marlin-2B (NemoStation, 2026-05-13).
  - `GET /api/models?author=cyankiwi&sort=lastModified&direction=-1` — to detect AWQ-4bit drops by the publisher we already use for R11. **Most-recent in-window:** `cyankiwi/Laguna-XS.2-AWQ-INT4` (created 2026-05-02, last-mod 2026-05-13). Most "May 2026 last-mod" entries are housekeeping re-mods of older artefacts, not new uploads.
  - `GET /api/models?author=QuantTrio` — cross-check; no new in-window AWQ uploads from QuantTrio (last upload `GLM-4.7-AWQ` re-mod 2026-05-18, but artefact dates from 2025-12-24).
  - `GET /api/models?search=<name>` for each candidate, to enumerate quantization availability per model. Confirmed Hy-MT2-30B-A3B has FP8 + GGUF + MLX but NO AWQ as of 2026-05-24.
- **vLLM GitHub PR scan**:
  - `gh api 'search/issues?q=repo:vllm-project/vllm+is:pr+is:merged+merged:2026-05-03..2026-05-24+label:new-model'` — 14 hits including PR #41254 (MiniCPM-V 4.6, 2026-05-12), #41745 (Gemma4 MTP spec-decode, 2026-05-06), #42078 (Cohere Eagle + MoE fix, 2026-05-09), #42654 (OpenVLA, 2026-05-19), #42705 (InternS2 Preview, 2026-05-15), #43004 (DeepSeek V4 refactor, 2026-05-19), #41826 (peagle speculators, 2026-05-12).
  - `gh api 'search/issues?q=repo:vllm-project/vllm+is:pr+is:merged+merged:2026-05-03..2026-05-24+label:model'` — 14 hits, dominated by non-arch fixes; the model-relevant ones overlap above.
  - Per-model lookups: `Hunyuan` (PR #40681 Hy3 preview merged 2026-04-23; no Hy-MT2-specific PR in window — Hy-MT2 uses `HunYuanMoEV1` arch class already merged), `GLM-4.7` (PR #31220 tool-call parser fix merged 2026-05-21, PR #35576 MLA+NVFP4/INT4 crash fix merged 2026-05-24, PR #39660 GLM-4.7-FP8 prefill perf merged 2026-05-12), `Laguna/poolside` (PR #41129 model impl merged 2026-04-28, PR #41880 DFlash speculator merged 2026-05-07), `Ring/inclusionAI` (PR #35102 for Ring 2.5 merged 2026-02-26 — Ring 2.6-1T uses same arch class, no in-window PR needed).
  - vLLM release timing: v0.20.0 (2026-04-27), v0.20.1 (2026-05-04), **v0.20.2 (2026-05-08)**, **v0.21.0 (2026-05-15, skipped per audit)**.
- **Targeted web search** (WebSearch tool) — used for cross-confirmation of release dates and benchmark numbers, then dereferenced primary sources via WebFetch where possible. Queries used:
  - `qwen 3.7 release May 2026` → API-only, no open weights yet
  - `DeepSeek V4 release date 2026` → API/HF on **2026-04-24**, in pre-window
  - `Mistral Magistral Devstral release May 2026` → Devstral-Small-2507 and Magistral-Small-2506 are 2025-06/07 artefacts; Mistral Medium 3.5 was 2026-04-30
  - `Kimi K3 Moonshot release 2026` → not released as of 2026-05-24; K2.6 is April
  - `MiniMax M3 release May 2026` → M3.0 released **2026-04-02**, pre-window
  - `Zyphra ZAYA1 release` → ZAYA1-8B released **2026-05-06**, in-window
  - `GLM-4.7 ZhipuAI release` → GLM-4.7 base model is **2026-04-03**, pre-window
  - `Tencent Hunyuan MT2 release` → **2026-05-21**, in-window
  - `Sapient HRM-Text release` → **2026-05-18**, in-window
  - `inclusionAI Ring-2.6-1T` → **2026-05-08/14**, in-window
  - `ByteDance Cola-DLM` → arXiv paper **2026-05-07**, weights ~2026-05-15
  - `SubQ subquadratic 12M context` → **2026-05-05**, **closed-weights / API only**
  - `Llama 4 / Gemma 4 May 2026` → both April; pre-window
- **r/LocalLLaMA**: site-restricted query returned no hits this iteration (search filter rejected the `site:` prefix). Not a critical signal — primary sources covered the major releases.

## Tier S — pass all hard gates + competitively differentiated

### S1. cyankiwi/Laguna-XS.2-AWQ-INT4

| Field | Value |
|---|---|
| **HF repo** | [`cyankiwi/Laguna-XS.2-AWQ-INT4`](https://huggingface.co/cyankiwi/Laguna-XS.2-AWQ-INT4) |
| **Base model** | [`poolside/Laguna-XS.2`](https://huggingface.co/poolside/Laguna-XS.2) |
| **Architecture** | MoE 30+ layers / sliding-window attn (10 global + 30 SWA layers, 512-tok window) + FP8 KV-cache native; **256 experts + 1 shared**; per-head gating |
| **Params total / active** | 33B / 3B |
| **Context** | 131,072 tokens native (matches our R11 96k production, with 35% headroom) |
| **Quant available** | AWQ-INT4 (cyankiwi, 2026-05-02; in-window last-mod 2026-05-13), FP8 (poolside, 2026-04-23), NVFP4 (poolside, 2026-04-23), INT4 (poolside, 2026-04-23) |
| **vLLM support** | Architecture support in vLLM PR [#41129](https://github.com/vllm-project/vllm/pull/41129) merged **2026-04-28 → IN v0.20.2** ✓. DFlash speculator support in PR [#41880](https://github.com/vllm-project/vllm/pull/41880) merged 2026-05-07 (also in v0.20.2). |
| **Headline benchmarks** | SWE-bench Verified **68.2%**, SWE-bench Multilingual 62.4%, SWE-bench Pro 44.5%, Terminal-Bench 2.0 30.1% (model card, [poolside.ai/blog/introducing-laguna-xs2-m1](https://poolside.ai/blog/introducing-laguna-xs2-m1)) |
| **License** | Apache 2.0 |
| **Tool-call format** | `--tool-call-parser poolside_v1 --reasoning-parser poolside_v1 --enable-auto-tool-choice` (parser ships in vLLM PR #41129) |
| **VRAM @ 96k est.** | AWQ-4bit weights ~17 GB (33B × 0.5 byte/param) + KV ≈ 5–7 GB at 96k with FP8 KV (the model bakes FP8 KV scales) + ~3 GB workspace = **~25–27 GB** — fits cleanly inside the 30.7 GB budget of R11 |
| **Why test** | Closest like-for-like swap of R11. Same MoE-30-class with 3B active, same AWQ-4bit, native FP8 KV (escapes our H17 triton-MoE bug because Laguna uses SWA+global stacking, not MLA), 68.2% SWE-bench-Verified is a credible upgrade over Qwen3-Coder's unattributed comparable. **Quality-vs-quality A/B is finally possible without an architecture variable. Highest-information run on the candidate list.** |

### S2. tencent/Hy-MT2-30B-A3B-FP8

| Field | Value |
|---|---|
| **HF repo** | [`tencent/Hy-MT2-30B-A3B-FP8`](https://huggingface.co/tencent/Hy-MT2-30B-A3B-FP8) |
| **Base model** | [`tencent/Hy-MT2-30B-A3B`](https://huggingface.co/tencent/Hy-MT2-30B-A3B) (Tencent Hunyuan, 2026-05-21 announcement) |
| **Architecture** | MoE (HunYuanMoEV1 in vLLM); active param count not stated explicitly but "30B-A3B" naming convention implies ~3B active. Hunyuan-class attention (not MLA). |
| **Params total / active** | 30B / 3B (estimated from naming convention) |
| **Context** | **4,096 tokens default** (per model card inference params) — but this is the translation harness setting; arch likely supports more. **Verify before deploying for OpenCode 96k workloads.** |
| **Quant available** | FP8 (Tencent first-party, 2026-05-18), GGUF 4-bit (community, 2026-05-22), MLX 4/8-bit (2026-05-22). **No AWQ as of 2026-05-24.** |
| **vLLM support** | Uses `HunYuanMoEV1` arch class already in vLLM (since PR #40681 merged 2026-04-23). Card says `vllm serve tencent/Hy-MT2-30B-A3B --tensor-parallel-size 1` works. **Should work on v0.20.2.** |
| **Headline benchmarks** | "Outperforms DeepSeek-V4-Pro and Kimi K2.6 in fast-thinking mode" (translation tasks — not directly comparable to coding) ([model card](https://huggingface.co/tencent/Hy-MT2-30B-A3B)). **No published coding scores.** |
| **License** | Not explicit on the model card (HF page lacks license-tag) — verify before commercial use |
| **Tool-call format** | Translation-focused model; tool-calling support not documented on card |
| **VRAM @ 96k est.** | FP8 weights ~30 GB (30B × 1 byte). Tight on 32 GB GPU. At 96k context might OOM. |
| **Why test** | **Honest framing:** this is unlikely to beat R11 on coding because it's a translation specialisation. Listed in Tier S only because (a) it is the only NEW-IN-WINDOW MoE in the exact 30B/3B-A3B class — making it the structural-twin control for R11; (b) FP8 native (vs our AWQ-4bit) lets us test the FP8 vs INT4 axis on identical compute geometry; (c) if Hunyuan's MoE routing differs meaningfully from Qwen3-Coder's, even a translation-pretrained model could surprise on agentic coding tasks (low prior, but a cheap-to-test experiment). **Do NOT promote to production candidate without coding-bench evidence.** |

### S3. cyankiwi/GLM-4.7-Flash-REAP-23B-A3B-AWQ-4bit

| Field | Value |
|---|---|
| **HF repo** | [`cyankiwi/GLM-4.7-Flash-REAP-23B-A3B-AWQ-4bit`](https://huggingface.co/cyankiwi/GLM-4.7-Flash-REAP-23B-A3B-AWQ-4bit) |
| **Base model** | `cerebras/GLM-4.7-Flash-REAP-23B-A3B` (REAP-pruned from `zai-org/GLM-4.7-Flash` 30B-A3B → 23B-A3B by removing 16 of 64 experts) |
| **Architecture** | GLM-4.7 MoE family. **MLA attention** (Multi-head Latent Attention — flag for AWQ+MLA long-prefill crash hazard, vLLM issue #43263). REAP = Router-weighted Expert Activation Pruning (one-shot, no fine-tune). |
| **Params total / active** | 23B / 3B (after 25% expert-pruning from 30B/3B) |
| **Context** | 202,752 tokens |
| **Quant available** | AWQ-4bit (cyankiwi, in-window last-mod), AWQ-8bit also exists |
| **vLLM support** | Card claims "Fully compatible with vanilla vLLM" — but **GLM-4.7 tool-call parser was buggy until PR #31220 merged 2026-05-21** (post-v0.20.2). Tool calling broken until v0.21.1 cutover. **MLA-related crash for INT4 fixed in PR #35576 merged 2026-05-24** (also post-v0.20.2). |
| **Headline benchmarks** | Parent GLM-4.7-Flash scores (model card): SWE-bench Verified 59.2%, GPQA-Diamond 75.2%, AIME 25 91.6%, LCB v6 64.0%. REAP variant inherits with some degradation expected; Cerebras claims minimal generative-task loss vs. expert-merging baselines. |
| **License** | MIT |
| **Tool-call format** | `--tool-call-parser glm47 --reasoning-parser glm45 --enable-auto-tool-choice` |
| **VRAM @ 96k est.** | AWQ-4bit 23B ≈ 12 GB + KV at 96k (MLA = ~28 KB/tok dense after compression, smaller than MHA) ≈ 3 GB + 3 GB workspace = **~18 GB** — substantial headroom, room to push past 96k context |
| **Why test** | (a) **REAP** is a genuine deployment-time architectural intervention (saliency-criterion pruning that preserves router control); validating REAP on our stack gives us a tool for future MoE-shrinking. (b) 18 GB load leaves 14 GB headroom — could let us hit 200k+ context. (c) GLM-4.7 family is the top open-weights coding model in 2026-Q2 per multiple reviews. **Caveat: hard-gate marginal until v0.21.1 cutover** lifts the tool-parser + AWQ+MLA crash blocks. Run as Tier S on v0.21.1, NOT on v0.20.2 today. |

## Tier A — pass hard gates, less differentiated or unproven

### A1. inclusionAI/Ring-2.6-1T

| Field | Value |
|---|---|
| **HF repo** | [`inclusionAI/Ring-2.6-1T`](https://huggingface.co/inclusionAI/Ring-2.6-1T) |
| **Released** | 2026-05-08 (announced) / 2026-05-14 (HF created_at) |
| **Params** | 1 Trillion total. Active params not stated on card, but Ring-2.5 family was ~50B active. |
| **Context** | 128K native, 256K via YaRN |
| **License** | MIT |
| **vLLM** | Card includes `vllm serve` example; uses `Ring` arch class (Ring 2.5 support landed in PR #35102, merged 2026-02-26, so present in v0.20.2) |
| **Tier A reason** | **Hard-gate fail: VRAM.** Even at AWQ-4bit, ~500 GB weights alone. Listed for awareness of Ant Group's flagship; not deployable on 32 GB. |
| **Smaller variants** | None as of 2026-05-24 (only `inferencerlabs/Ring-2.6-1T-MLX-3.7bit-INF` exists, still ~430 GB). Watch for community shrunk variants. |

### A2. cyankiwi/Laguna-XS.2-AWQ-INT4 — already promoted to Tier S; the FP8 variant `poolside/Laguna-XS.2-FP8` belongs here

The FP8 variant occupies an awkward slot: cleaner inference (no AWQ dequant overhead, native FP8 KV) but ~33 GB weights at FP8 vs ~17 GB at AWQ-4bit. On a 32 GB 5090 at 96k context, FP8 doesn't leave KV headroom; AWQ-4bit does. **Recommendation: prefer S1 AWQ-INT4 path, leave FP8 as a "what-if-we-had-48GB" comparison only.**

### A3. Jackrong/Qwopus3.6-35B-A3B-v1 (Tier A, not S, because no AWQ yet)

35B/3B-A3B MoE (Qwen3.6-35B-A3B base), Claude-Opus-distilled reasoning, hybrid Gated DeltaNet linear + standard attention, 256 experts, 262K context, Apache 2.0. Available today as: base BF16 (70 GB), GGUF (out-of-scope), FP8 of the 27B sibling but **NOT** the 35B-A3B sibling, no AWQ. **Promote to Tier S when QuantTrio or cyankiwi quantises** — Jackrong's MoE merges have historically been brittle (model card warns about 9% LoRA on MoE causing weight-merge failures), so wait for a clean third-party quant.

## Tier B — borderline (one hard gate marginal)

### B1. Jackrong/Qwopus3.6-27B-v2-FP8

27B Qwen3.6-27B base (DENSE — not MoE), Claude-Opus + Trace-Inversion distillation, FP8 native scales, 2026-05-23 release. **Hard-gate blocker: model card explicitly requires vLLM 0.21.0** (`Required Version: vLLM 0.21.0 (validated)`). Roll-forward to v0.21.1 unblocks it. SWE-bench Verified 75.25% (vendor-reported, controlled-202 slice). VRAM at 28.5 GiB at unspecified context per card — tight on 32 GB. **This is the R15 (Qwen3.6-27B) retest vehicle** — same parent arch, different distillation. Worth running ONCE v0.21.1 lands.

### B2. ZAYA1-8B (Zyphra)

8.4B total / 760M active MoE (MoE++ architecture with **Compressed Convolutional Attention** — 8× KV-cache compression vs standard attention). Trained on AMD MI300X. Apache 2.0. HMMT'25 89.6 > Claude 4.5 Sonnet (math). **Coding scores not headlined** — model is math-reasoning-positioned. At 8B total it's well under VRAM budget but **active-params 760M** means inference is fast; for our coding workload, dense compute matters less than data-mixture quality. Not a primary candidate but worth a 1-hour smoke test to validate the CCA architecture before considering it a building block.

### B3. tencent/Hy-MT2-7B(-FP8)

The 7B dense variant of the Hy-MT2 family. FP8 quant published 2026-05-12. Translation-focused. Useful only as a "small model for fast paths" if our project ever revisits the H9 dual-model question — currently OUT OF SCOPE per project memory (vllm-only host, no Ollama, no second-model serving).

## Novel-architecture callouts (informational; may or may not pass hard gates)

The user explicitly asked to surface these even when they don't deploy on our stack today.

### N1. ByteDance-Seed/Cola-DLM — Continuous Latent Diffusion LM

**The standout architectural departure of the window.** Cola DLM is a hierarchical **continuous-latent diffusion language model**. Pipeline:

1. Text VAE encodes input → continuous latent sequence
2. Block-causal Diffusion Transformer (DiT) does **Flow Matching** prior transport over the latent sequence (NOT next-token autoregression)
3. VAE decoder maps latents back to tokens

References: arXiv [2605.06548](https://arxiv.org/abs/2605.06548) (paper 2026-05-07), HF repo [`ByteDance-Seed/Cola-DLM`](https://huggingface.co/ByteDance-Seed/Cola-DLM) (weights 2026-05-15), GitHub [ByteDance-Seed/Cola-DLM](https://github.com/ByteDance-Seed/Cola-DLM), project page [hongcanguo.github.io/Cola-DLM](https://hongcanguo.github.io/Cola-DLM/). Apache 2.0.

**vLLM compatibility:** None as of 2026-05-24. The architecture has no `vllm/model_executor/models/` class. Inference is via a custom OAI-compatible endpoint shipped in the repo. This is a research checkpoint, not a production-ready model.

**Why it matters:** Discrete diffusion LMs (Mercury, LLaDA, SubQ-class) are competing with autoregressive models. Cola-DLM is **continuous-latent** — closer to image-diffusion's latent-space paradigm. If this architecture lands consistent quality at scale, it would obsolete a meaningful chunk of vLLM's KV-cache + speculative-decode complexity. **Track the next 6 months of Cola-DLM follow-up papers.**

### N2. sapientinc/HRM-Text-1B — Hierarchical Reasoning Model

**Brain-inspired non-transformer architecture.** Two transformer modules H (high-level/slow) and L (low-level/fast) run in nested recurrence: outer H-cycle wraps inner L-cycle, and the L-stack runs ~3× per H-step. Effectively **unbounded compute depth at bounded params** (1B). Trained on ~40B tokens (~1000× less than typical pretraining). Cost-to-pretrain ~$1000 per the press release.

References: HF [`sapientinc/HRM-Text-1B`](https://huggingface.co/sapientinc/HRM-Text-1B), paper [arXiv:2506.21734](https://arxiv.org/pdf/2506.21734) (Hierarchical Reasoning Model), GitHub [sapientinc/HRM-Text](https://github.com/sapientinc/HRM-Text), press [PR Newswire 2026-05-18](https://www.prnewswire.com/news-releases/sapient-intelligence-launches-hrm-text-challenging-the-llm-monopoly-with-a-brain-inspired-foundation-model-trained-on-up-to-1000x-fewer-tokens-302774638.html). Apache 2.0.

Benchmarks (independent April 2026 verification cited on card): MATH 56.2%, ARC-Challenge 81.9%, DROP 82.2%, MMLU 60.7%. **Coding scores absent — model not coding-tuned.**

**vLLM compatibility:** Requires `transformers >= 5.9.0` with `hrm_text` model class. Card claims `vllm serve sapientinc/HRM-Text-1B` works, but vLLM's main branch does not have an `HRMTextForCausalLM` arch class as of 2026-05-24. **Almost certainly broken on v0.20.2** — would fall back to a generic transformers wrapper, losing the recurrence advantage.

**Caveat:** model requires `token_type_ids` for correct inference (PrefixLM training objective). Standard chat-completion APIs strip this. Card warns: *"Omitting this falls back to pure causal attention and gives noticeably worse logits."* — non-trivial integration barrier.

**Why it matters:** if recurrent-latent models can match transformer quality at 1000× less training cost, the open-model economics flip. For us specifically, HRM-Text is a strong "small model for cheap probes" candidate IF coding finetune appears.

### N3. SubQ (Subquadratic Labs) — Sparse Sliding Attention at 12M context

**Sub-quadratic frontier LLM.** Custom SSA (sparse sliding attention) architecture, linear scaling with context. Claims 95.0% RULER 128K, 65.9% MRCR v2 @ 1M, **81.8% SWE-Bench Verified** (vendor-reported).

References: [Subquadratic launch announcement 2026-05-05](https://siliconangle.com/2026/05/05/subquadratic-launches-29m-bring-12m-token-context-windows-ai/), [DataCamp explainer](https://www.datacamp.com/blog/subq-ai-explained), [Hacker News thread 48023079](https://news.ycombinator.com/item?id=48023079).

**Hard-gate fail:** closed weights, API-only. Cannot deploy on our hardware. Listed because **81.8% SWE-bench Verified vendor-reported is the highest coding number we've seen from any model in the window** — if SubQ ever opens weights it would be a major event.

### N4. Tencent Hy-MT2 — "fast-thinking" multilingual translation MoE

Architecturally the Hunyuan-MoE-V1 class is not novel by itself, but the **fast-thinking training paradigm** is interesting: Tencent claims the 7B and 30B-A3B variants beat DeepSeek-V4-Pro and Kimi K2.6 on translation tasks WITHOUT extended chain-of-thought (the "fast" path), via a curriculum that bakes the reasoning into single-pass inference. Worth understanding the methodology even if the model itself is translation-specialised.

### N5. inclusionAI Ring-2.6-1T — async-RL-trained trillion MoE

Architecture is conventional but the **training procedure** is the novelty: asynchronous RL with the IcePop algorithm at trillion-parameter scale, plus an "adjustable Reasoning Effort" mechanism with `high` and `xhigh` modes. The reasoning-effort dial is a deployment-time control novelty. Not deployable here (1T params), but the async-RL+IcePop methodology will likely cascade to smaller models within 6-12 months.

### N6. Zyphra ZAYA1 — Compressed Convolutional Attention (CCA)

CCA achieves **8× KV-cache compression** vs standard attention. ZAYA1-8B (8.4B / 760M active MoE) is the smallest production carrier. If CCA generalises, the H5 (context-pushing) lever in our roadmap changes shape — CCA does for attention what MLA does for KV but with a different mechanism. **Worth a smoke test for arch validation,** not for coding deployment (Zyphra is math-positioned, not code).

### N7. Cerebras GLM-4.7-Flash-REAP-23B-A3B — REAP expert pruning

Promoted into Tier S above. Adding here for the novelty index: **REAP (Router-weighted Expert Activation Pruning)** is a one-shot saliency-based MoE pruning method that explicitly preserves the router's independent control over surviving experts. Unlike expert-merging (which causes "functional subspace collapse" on generative tasks), REAP claims minimal generative-quality loss. **The first MoE-shrinking technique we'd seriously test in production.** Paper not yet on arXiv at the time of this writing; technique disclosed in the model card.

### N8. Poolside Laguna XS.2 — sliding window + global hybrid + per-head gating + native FP8 KV

Laguna's architecture innovations (10 global + 30 sliding window with **per-head gating** and SWA window=512) are a quiet but real attention-pattern departure that bake KV-savings into the architecture without compressing KV explicitly (the way MLA does). Per-head gating is the novel piece — gates which heads participate per token, not just which experts. Treated as Tier S because of the engineering — not just the benchmarks.

## Updated comparison table (extends model-config-matrix.md schema)

| # | Date | Model | Quant | Config (proposed) | Expected VRAM @ 96k | Polyglot reported | Coding bench | License | vLLM v0.20.2? | Tier | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| C1 | 2026-05-02 (quant; base 2026-04-28) | poolside/Laguna-XS.2 via cyankiwi AWQ-4bit | AWQ-INT4 | FA2 / FP8-KV (native scales) / 96k / `--tool-call-parser poolside_v1` | ~25–27 GB | — (no run) | SWE-Verified 68.2%, SWE-Multi 62.4%, T-Bench 30.1% | Apache 2.0 | ✓ (PR #41129 merged 2026-04-28, in v0.20.2) | **S** | Direct R11 swap. Native FP8 KV scales escape H17 triton-MoE bug. Best candidate. |
| C2 | 2026-05-18 (FP8 quant; base 2026-05-21 announce / 2026-05-11 HF) | tencent/Hy-MT2-30B-A3B-FP8 | FP8 | FA2 / bf16-kv / 96k | ~30 GB tight | — | translation-specialised; no coding bench published | unclear | ✓ (HunYuanMoEV1 in vLLM since #40681) | **S** (control) | NOT a primary; structural-twin of R11 for FP8-vs-INT4 axis isolation. **Verify license + max_context before deploy.** |
| C3 | 2026-05-25 (quant); base 2026-04-22 | cyankiwi/GLM-4.7-Flash-REAP-23B-A3B-AWQ-4bit | AWQ-INT4 | FA2 / bf16-kv / 96k / `--tool-call-parser glm47 --reasoning-parser glm45` | ~18 GB | — | parent SWE-V 59.2%, LCB-v6 64.0% (pre-REAP); REAP claims minimal generative drop | MIT | ⚠ tool parser broken till PR #31220 (merged 2026-05-21, in v0.21.0+ not v0.20.2); AWQ+MLA crash hazard till PR #35576 (merged 2026-05-24) | **S** (after v0.21.1 cutover) | Novel REAP arch lever. Run after R-cutover only. |
| C4 | 2026-05-06 | Jackrong/Qwopus3.6-35B-A3B-v1 | base BF16 only | — | OOM at BF16 (~70 GB) | — | "SWE-bench testing underway" | Apache 2.0 | unknown (MoE arch new) | **A** | Promote to S when QuantTrio AWQs it. Novel arch tag = Gated DeltaNet hybrid. |
| C5 | 2026-05-23 | Jackrong/Qwopus3.6-27B-v2-FP8 | FP8 | FA2 / bf16-kv / 96k | ~28.5 GB (per card) tight | — | SWE-V 75.25% (vendor, 202-slice) | Apache 2.0 | ✗ (card states vLLM 0.21.0 required) | **B** | R15-style retest with different distillation. Roll-forward to v0.21.1. |
| C6 | 2026-05-08 | inclusionAI/Ring-2.6-1T | base BF16 only | — | massive OOM | — | n/a | MIT | ✓ (Ring arch in vLLM since #35102) | **A** | Hardware-OOM for awareness only. |
| C7 | 2026-05-06 | Zyphra/ZAYA1-8B | base BF16 | — | ~16 GB | — | HMMT'25 89.6 (math); no coding scores | Apache 2.0 | unknown (custom MoE++ arch) | **B** | Novel CCA arch worth validating; not a coding candidate. |
| N1 | 2026-05-15 | ByteDance-Seed/Cola-DLM | — | — | — | — | n/a | Apache 2.0 | ✗ (no vLLM arch class) | **NOVEL** | Continuous-latent diffusion LM. Research only. |
| N2 | 2026-05-17 | sapientinc/HRM-Text-1B | base BF16 | — | ~2 GB | — | MATH 56.2%, MMLU 60.7% | Apache 2.0 | ✗ (no `HRMTextForCausalLM` in vLLM) | **NOVEL** | Hierarchical recurrent reasoning model. token_type_ids required. |
| N3 | 2026-05-05 | Subquadratic SubQ | closed | — | — | — | SWE-V 81.8% (vendor) | proprietary | ✗ (closed weights) | **NOVEL** | API-only; cannot deploy. Track. |
| N4 | 2026-05-08 | inclusionAI Ring-2.6-1T (also a novel arch callout for async-RL methodology) | — | — | OOM | — | n/a | MIT | ✓ (Ring arch present) | **NOVEL** | Async RL + IcePop + Reasoning Effort dial. |

## Open questions / red flags

Per-candidate items to verify before any test fires.

### C1 (Laguna-XS.2-AWQ)
- **Verify** the AWQ-4bit checkpoint's FP8 KV scales (the base model bakes them, but does the AWQ requant preserve them?). Test by checking config.json for `kv_cache_scheme` and `kv_scale` tensors in safetensors.
- **Verify** `poolside_v1` tool parser handles the OpenCode tool-call format (it's a coding-positioned model, parser should be coding-aware, but confirm against an actual agent run).
- **Verify** SWA boundaries: with 512-tok sliding window in 30 of 40 layers, very-long prefill behaviour at 96k could differ from R11. Run the H18 needle-in-haystack probe equivalent.
- **Risk:** poolside is a 5-week-old open-weights effort; the engineering polish vs. Qwen3-Coder (battle-tested for 6+ months in our matrix) is unknown.

### C2 (Hy-MT2-30B-A3B-FP8)
- **Verify max_position_embeddings** on the actual config.json — the 4096 quoted on the card may be the translation harness default, not the architectural cap.
- **Verify license tag** — the HF page lacks a license badge.
- **Verify** FP8 weights fit at 96k context — at 30 GB weights + KV, may need gpu-mem 0.93+ and could OOM at our 96k target.
- **Expect quality regression** on coding tasks vs R11. Run only as a controlled comparison, not a production swap.

### C3 (GLM-4.7-Flash-REAP-23B-A3B-AWQ)
- **Blocked on v0.21.1 cutover** for tool calling (PR #31220, merged 2026-05-21) and MLA+AWQ crash safety (PR #35576, merged 2026-05-24). Do NOT test on v0.20.2.
- **Verify** REAP doesn't disproportionately hurt coding-track experts (REAP's saliency criterion mixes router gate values + expert activation norms — coding experts may be high-norm but low-frequency, and pruning could over-remove them).
- **Risk** of AWQ+MLA long-prefill crash (vLLM issue #43263 in our project memory) — recommended workaround was "FP8 or unquantised only on our stack" for AWQ+MLA. PR #35576 may or may not fully close that issue; verify on a small prefill before scaling.

### C4 (Qwopus3.6-35B-A3B-v1)
- **Blocked on AWQ availability.** Watch QuantTrio and cyankiwi.
- The model card itself warns "**9% LoRA configuration is risky** for this MoE due to potential training instability and weight merging conflicts" and "Common Error: `ModuleNotFoundError: Could not import module 'Qwen3_5MoeForConditionalGeneration'`" — base weights may not load cleanly even before quantisation.

### C5 (Qwopus3.6-27B-v2-FP8)
- **Blocked on v0.21.1 cutover.** Model card states "Required Version: vLLM 0.21.0 (validated)".
- 28.5 GB weight memory is tight on a 32 GB GPU; the 96k context goal may require eager mode (which crippled R15). Test at 32k first.
- SWE-V 75.25% is vendor-reported on a "controlled-202 slice" — almost certainly NOT comparable to standard SWE-bench Verified (n=500). Discount accordingly.

### General red flags
- **AWQ+MLA long-prefill crash** (project-memory issue #43263) still applies to any new MLA-using AWQ model (GLM-4.7 family, DeepSeek-V4 family, Kimi). Workaround: FP8 or unquantised. Affected here: C3.
- **MoE expert offload (PR #37190) still dead** as of 2026-05-24. Any model that would require expert-offload to fit (e.g., a hypothetical Laguna-M.1 quant, DeepSeek-V4-Flash) is DOA on our hardware.
- **Tool-call parser availability is not symmetric across models.** v0.20.2 has `mistral`, `hermes`, `llama3_json`, `pythonic` parsers + Qwen3-specific. `poolside_v1` ships in PR #41129 (in v0.20.2). `glm47` parser is BROKEN until PR #31220 (in v0.21.0). Hunyuan tool parsing has open bugs (PR #38103 unmerged).

## What was NOT a new release in the window (sanity check)

Triangulation evidence — these are things I looked at and then rejected as not in window:

- **Qwen3.7** (Alibaba flagship, 2026-05-20 announce) — closed weights, API-only Max/Plus variants. No open weights yet. Not deployable.
- **Qwen3.6-{27B, 35B-A3B}** — **2026-04-16/22**, pre-window (already in our matrix as R15).
- **Qwen3-Coder-Next** — **2026-02-03 base; 2026-04-28 most recent** — already in our matrix as R16 (parked pending PR #37190).
- **Gemma 4** (E2B/E4B/26B-A4B-MoE/31B-Dense) — **2026-04-02**, pre-window. Already in our matrix as R6/R7 (failed-load on 31B-Dense).
- **Llama 4 Scout / Maverick** — **2026-04-05**, pre-window.
- **DeepSeek V4 Pro (1.6T) / Flash (284B)** — **2026-04-24**, pre-window. In-window only the vLLM **refactor** PR #43004 (closed 2026-05-19) — refactor, not new model. Flash AT 284B exceeds VRAM by 9× even at AWQ-4bit; Pro at 1.6T is hopeless. Not deployable regardless.
- **MiniMax M3** — **2026-04-02**, pre-window.
- **GLM-4.7 base** (358B) — **2026-04-03**, pre-window. (The REAP variant in C3 is what's new-ish.)
- **GLM-4.7-Flash** (30B-A3B) — **2026-04-21**, pre-window. The cyankiwi AWQ-4bit is from 2026-01-19. NOT new in window — only PR #31220 (tool-parser fix) and PR #35576 (MLA+AWQ crash fix) are in window.
- **Mistral Medium 3.5** — **2026-04-30**, pre-window by 3 days; also 128B dense doesn't fit.
- **Devstral-Small-2507 / Devstral-Medium-2507** — **2025-07** base, 11 months old. The AWQ quants are from 2025-07. NOT in window. (53.6% SWE-Verified per Mistral's card — below our R11 anyway.)
- **Magistral-Small-2506** — **2025-06** base. NOT in window. (LiveCodeBench-v5 55.84% — below R11 effective performance.)
- **Nemotron 3 Nano Omni** — **2026-04-28/29**, just outside window. 30B/3B-A3B; if AWQ quant appears in window it'd be a credible structural-twin of R11. None visible as of 2026-05-24.
- **MiniCPM-V 4.6** (vLLM PR #41254 merged 2026-05-12) — vision-language model, not text-only; not a coding candidate.
- **InternS2 Preview** (vLLM PR #42705 merged 2026-05-15) — 36B/3B-A3B MoE multimodal, **scientific specialisation** (not coding). Listed in Tier B-equivalent only because of architectural family; not a primary candidate.
- **OpenVLA** (vLLM PR #42654 merged 2026-05-19) — vision-language-action model for robotics, not a coding LLM.
- **Qianfan-OCR** (vLLM PR #40136 merged 2026-05-05) — OCR-specialised, not a coding LLM.
- **HuggingFaceBio Carbon-{500M,3B,8B}** (HF 2026-05-12/17) — biology-specialised, not coding.
- **Hunyuan-MT2-1.8B, -7B** — too small, training-specialised for translation; the 30B-A3B sibling is the only one in our class.
- **Kimi K3** — not released as of 2026-05-24 (rumoured Q3 2026; K2.6 was April).

---

**Companion files:** [`model-config-matrix.md`](./model-config-matrix.md) (existing tested-configs matrix), [`perf-hypothesis-ledger.md`](./perf-hypothesis-ledger.md) (hypothesis ledger explaining the H-test discipline these candidates would slot into).

**Recommended next action:** test S1 (Laguna-XS.2-AWQ-INT4) FIRST. It's the only candidate in the window that (a) passes every hard gate today on v0.20.2, (b) is architecturally close enough to R11 that a polyglot bench result will be cleanly comparable (one variable: weights + training mix; same MoE-30/3B-A3B, same AWQ-4bit, same FA2-eligible attention), and (c) has third-party-published SWE-bench numbers that suggest a real upgrade rather than a sideways move. C3 (GLM-4.7-Flash-REAP) is the second-best, but gated on v0.21.1 cutover. Hold C2/C4/C5 for now.
