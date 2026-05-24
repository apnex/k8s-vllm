# Audit E — PR landscape

**Date:** 2026-05-24
**Auditor:** subagent E (5-of-5 parallel)
**Scope:** map the PR ecosystem around v0.21.0 — what merged for v0.21.1rc0, what's open against the v0.21 cherry-pick line, what's been reverted, what's merged into our stack's surface area in the last 30 days, and the live status of PR #37190 (MoE expert offload).

---

## TL;DR (3 bullets)

- **v0.21.1rc0 is a real hotfix release, not a polish pass.** 169 commits sit between `v0.21.0` and `v0.21.1rc0`, and the cherry-pick milestone (#29 "v0.21.0 cherry picks") has already absorbed 12 PRs — the contents are concentrated in MoE refactor cleanups, DSv4 / Blackwell MLA bugs, quantization (NVFP4 / FP8 / Marlin / Quark / MXFP4), KV-cache offloading, and CI fixes. None of the 12 cherry-picks are AWQ-Marlin core or sm_120 dense path. That is a clear "v0.21.0.0 has known sharp edges, but they're not on our path" signal.
- **The reverts pattern is small (3 in v0.21.1rc0, 4 more on `main` post-rc0) and one of them — `Revert "[Core] Replace routing replay with device cache and async D2H pipeline"` (#42434) — is a non-trivial Core revert touching the engine routing path.** That's the only "watch this carefully" revert for us; the rest are docs, build packaging, or compile patches.
- **PR #37190 (MoE expert offload, the historic blocker for the 80B-A3B variant) is still alive but degraded:** open, draft=false, `mergeable_state=dirty`, `needs-rebase` label, only 1 inline reviewer comment + 1 bot comment, no NVIDIA / vLLM-core reviewer, milestone=null, last author push **2026-05-24** (today). It is being maintained by a community contributor pair (e1n00r + caiovicentino) with independent multi-model validation, but it has been **drifting against `main` for ~10 weeks** and no maintainer has put it on a release track. **Our take: do not ride it for v0.21.0 production; stay on Qwen3-Coder 30B-A3B-AWQ as we are; revisit if a maintainer review or `ready` label appears.**

---

## v0.21.1rc0 — what's in it?

`git log --oneline v0.21.0..v0.21.1rc0` returned **169 commits**. Below is the curated subset relevant to our stack (AWQ-4bit, prebuilt image, Blackwell sm_120, OpenAI server, tool-call parsers) plus the 12 PRs that were formally cherry-picked into milestone #29 "v0.21.0 cherry picks" (the canonical v0.21.x hotfix queue).

### Cherry-pick milestone #29 (formal v0.21.x backports — all 12)

| Commit (in v0.21.1rc0) | PR #   | Title                                                                                       | Area              |
| ---------------------- | ------ | ------------------------------------------------------------------------------------------- | ----------------- |
| a8c13d283              | #42464 | Patch `SlidingWindowSpec.real_page_size_bytes` for nvfp4 kv                                 | quant / kv-cache  |
| 140dc2ec3              | #42438 | [Bugfix] Install nvidia-cutlass-dsl[cu13] extra on CUDA 13 platforms                        | build             |
| 07534b878              | #42364 | [PD] Bump NIXL connector dependency to 1.x                                                  | disagg / kv       |
| 8c4fc4202              | #42357 | [CI] Inline build artifact annotations in release pipeline                                  | CI                |
| e1c8776e9              | #42355 | [CI] Move DockerHub and PyPI publish steps to end of release pipeline                       | CI                |
| 53181384e              | #42287 | [Bugfix] Fix DSV4 swiglu_limit on marlin backend                                            | quant / DSv4      |
| dd6b3a5ef              | #42153 | [Perf] Use 2D-grid to eliminate divmod in W8W8 group quant                                  | perf (W8A8)       |
| f8848b2f2              | #41986 | [Bugfix] Add swiglu limits to deepgemm fp8 methods                                          | quant (FP8)       |
| a8887c208              | #41946 | [Bugfix][ROCm][DSV4][Perf] Add aiter mhc support                                            | ROCm / DSv4       |
| 0d2732dd9              | #41778 | [MLA Attention Backend] Add TOKENSPEED_MLA backend for DSR1/Kimi K25 prefill+decode (Blackwell) | Blackwell attn |
| d077622d6              | #41516 | [Build] Build bundled DeepGEMM `_C` per-Python so the wheel imports on every CPython         | build             |
| ebeb09d82              | #40900 | [KV Transfer] Add MooncakeStoreConnector for KV cache offloading via Mooncake               | kv-offload        |

**Interpretation of the cherry-pick set (this is the strongest "what really hurt in v0.21.0" signal):**

- **DSv4 / MLA dominates** (3 of 12): swiglu_limit on marlin, aiter mhc on ROCm, the new TOKENSPEED_MLA Blackwell backend. v0.21.0 shipped DeepSeek-V4 support and clearly under-tested the Marlin and ROCm MLA paths.
- **Build/CI is over-represented** (4 of 12): cu13 cutlass-dsl install, DeepGEMM ABI portability, two release-pipeline ordering fixes. v0.21.0's release pipeline emitted broken artifacts and the team is hardening it for v0.21.1.
- **Quantization sharp edges around new formats** (3 of 12): nvfp4 KV cache sliding-window page sizing, deepgemm FP8 swiglu limits, W8A8 perf. **None of these touch AWQ-Marlin** — AWQ on Blackwell sm_120 inherits zero hotfixes from this set, which is consistent with "AWQ-Marlin is the boring, mature path." That is good news for our config.
- **KV / disagg** (2 of 12): NIXL 1.x bump, Mooncake connector. Disaggregated-prefill territory, not single-host single-GPU territory.

### Other notable items in v0.21.1rc0 that did NOT cherry-pick but touch our surface

| Commit    | PR #   | Title                                                                                       | Why it matters to us                          |
| --------- | ------ | ------------------------------------------------------------------------------------------- | --------------------------------------------- |
| 0f69128a3 | #42454 | [Bugfix] Handle real-world gpt-oss tool call output in Harmony parsing                       | tool-call parser stability                    |
| 665f9c425 | #42128 | [Bugfix] Fix Gemma4ToolParser streaming float corruption                                     | tool-parser correctness pattern               |
| 56434e865 | #42660 | [Bugfix] Fix incorrect chat template format for Qwen3.5                                      | Qwen family chat templates                    |
| bf610c2f5 | #41674 | [Bugfix] Fix inverted condition causing thinking_token_budget to be silently ignored         | OpenAI-server feature regression              |
| 873910d60 | #42116 | [Frontend] add support for thinking_token_budget in completions                              | OpenAI-server feature                         |
| 920bf3ec8 | #42292 | [Bugifx][Qwen3CoderTool] Restore supports_required_and_named for required tool_choice         | Qwen3-Coder tool_choice — **directly ours**   |
| f6e868fbd | #42470 | [CI] Use uv with Python 3.12 for PyPI wheel upload                                          | build/release plumbing                        |
| ca60a4e84 | #42521 | [Fix] Weight loading for qwen3_5 using runai_streamer                                       | Qwen3.5 weight loading                        |
| ca7e4546d | #42104 | [CI] set max transformers version for skywork model                                          | transformers pin pressure                     |
| 92def124b | #42151 | [MM][Perf][CG] Support ViT full CUDA graph for Qwen3.5                                       | Qwen3.5 perf                                  |
| 6427603ae | #42334 | [MoE Refactor] Move remaining experts classes to experts directory                          | active refactor — destabilises MoE area       |
| 8c79ad658 | #42434 | **Revert** "[Core] Replace routing replay with device cache and async D2H pipeline" (#39917) | core engine routing path was unstable        |

**Bottom-line interpretation:** v0.21.0 went out with a mix of (a) DSv4 / Blackwell MLA correctness gaps that are getting fast hotfixes, (b) noisy release-pipeline plumbing, and (c) a fairly active tool-parser bugfix stream where vendors (gpt-oss / Gemma4 / Qwen3-Coder / Qwen3.5) are converging on common shapes. **Our specific surface — AWQ-4bit on Blackwell sm_120, OpenAI server, Qwen3-Coder tool-call parser — picks up two relevant fixes** (#42292 for Qwen3CoderTool required-tool-choice, #42454 for Harmony parsing edge cases) without inheriting any of the dangerous DSv4 / NIXL plumbing. The PR #42292 hit in particular is a real "the parser had a quietly broken code path in v0.21.0" fix.

---

## Open PRs targeting v0.21.x / release-blockers

Direct queries by milestone and label:

```
milestone:v0.21.1   → 0 open PRs
milestone:v0.22     → 0 open PRs
label:release-blocker → 0 open PRs
```

The vLLM project **does not use the milestone-attached PR or `release-blocker` label workflow** for v0.21.x. Instead, the v0.21.x cherry-pick line is curated by attaching PRs to milestone #29 ("v0.21.0 cherry picks") **after they merge to main**, not as forward-targeted open PRs. So "what's gating v0.21.1" is not directly visible through GitHub queries — it's curated implicitly by the release manager from the post-rc0 commit stream.

What this means: **the absence of a release-blocker queue is not "nothing is blocking v0.21.1"; it's "we don't expose blocking via labels."** The 4 reverts that landed after rc0 (see next section) are the closest thing to "release-blocker signal" the project produces.

Proxy queues for active community attention:

- `label:needs-rebase` (10 most-recently-touched): #42992 (kv_offload DSV4-flash crash), #42095 (FlexAttention layout), #43518 (FP8 SSM cache, WIP), **#37190 (MoE offload — ours)**, #40424 (Nemotron reasoning), #43319 (DSV4 MTP draft BF16), #43476 (unified comm), #11714 (LoRA lm_head), #40915 (Qwen3 XML tool parser redesign), #40783 (Qwen3 reasoning parser fixes).
- `label:ready` (top of queue, most-recently-touched): #39177 (ROCm AITER MoE), #41947 (Marlin MoE TP padding NVFP4 H100), #43162 (DSV4 q-pad fusion), #42959 (kv_offload sliding-window stale blocks), #43385 (DSV4 MTP ROCm), and several more. **None hit our AWQ / Blackwell-dense / OpenAI-server path directly.**
- `label:ready-run-all-tests`: dominated by Model Runner V2 migration work (#42665, #42667, #35558, #43458) and torch.compile work — interesting forward signal for v0.22 but irrelevant for v0.21.0 production.

---

## Recent reverts (last 30 days)

Reverts that landed in `v0.21.0..v0.21.1rc0`:

| Commit    | PR #            | Title                                                                                       | Reason / risk                                                                                                                                                                              |
| --------- | --------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 8c79ad658 | #42434          | Revert "[Core] Replace routing replay with device cache and async D2H pipeline" (#39917)    | **The one to watch.** Reverts a Core engine change (device cache + async D2H pipeline). Commit body has only a sign-off, no explanation. The original PR #39917 was a perf/correctness rework of routing replay; its revert lands in v0.21.1rc0 — meaning **v0.21.0 shipped the buggy variant**. v0.21.0.0 users running multi-stream / async-overlap workloads should expect surprises until they're on v0.21.1. |
| 0a9362d6a | #41512          | Revert "[Build] Make bundled DeepGEMM wheel portable across Python versions"               | Wheel-packaging regression. Replaced by #41516 (per-Python C build) which IS in the cherry-pick set. Bookkeeping, not user-visible.                                                       |
| 62ba7516e | #41618          | Revert "[Doc] Fix RTD build: pytorch.org/docs/stable/objects.inv returns 404"               | Docs build only. Irrelevant.                                                                                                                                                               |

Reverts that landed on `main` AFTER v0.21.1rc0 (so will roll into v0.21.1 final or v0.22):

| Commit    | PR #   | Title                                                                                       | Reason / risk                                                                                                                              |
| --------- | ------ | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| 10d264a2b | #43492 | Revert "[Misc] add humming to dependencies"                                                 | Humming is a new quantization kernel dep added in #42540. Reverted, likely circular-dep or install-time breakage. Not in our path.        |
| 85959567c | #43188 | [ci] Revert model executor test back to L4                                                  | CI infra rollback. Not in our path.                                                                                                       |
| 1ac10f159 | #42913 | Revert "[torch.compile] Add patch for fullgraph compilation" (#42686)                       | torch.compile fullgraph patch was incorrect. We don't run torch.compile fullgraph in our production config. Not in our path.              |
| 953754253 | #42923 | Revert checkpoint specific workaround in Transformers modelling backend                     | Transformers backend cleanup. Not in our path.                                                                                            |

**Flag for the consolidator:** the **#42434 Core routing-replay revert** is the single revert that affects engine execution semantics. v0.21.0 has it; v0.21.1rc0 does not. This is one of the strongest arguments for **waiting for v0.21.1 final rather than pinning v0.21.0** if our workload involves heavy parallel decoding / scheduling stress. For our current single-model AWQ workload it likely doesn't bite, but it's a real correctness change.

---

## PR #37190 status update — MoE expert CPU offload

This is the PR we've been blocked on since 2026-05-13 (memory: `feedback_vllm_moe_offload_blocked_on_pr_37190.md`).

**State snapshot (queried 2026-05-24):**

- **state**: `open` (NOT closed, NOT merged)
- **draft**: `false`
- **mergeable**: `false`
- **mergeable_state**: `dirty` (has conflicts with `main`)
- **base**: `main` (NOT a v0.21.x branch)
- **head**: `e1n00r:feature/moe-expert-lru-cache` (community fork)
- **head_sha**: `1ad1e999ada2dcbe068cd929550c0808b85117dc`
- **created**: 2026-03-16
- **last update**: 2026-05-24T08:50 (today)
- **changed_files**: 14, additions=955, deletions=47
- **comments**: 43 conversation, 1 inline review comment (gemini-code-assist bot only)
- **reviews**: 2 (one COMMENTED from `alvinttang` 2026-03-16, one COMMENTED from `gemini-code-assist[bot]` 2026-03-16). **Zero formal APPROVE; zero formal CHANGES_REQUESTED.**
- **labels**: `documentation`, `performance`, `frontend`, `needs-rebase`, `ci/build`, `verified`
- **milestone**: `null` (not assigned to any release)
- **CI checks on head SHA**: only `Summary`, `Meta Internal-Only Changes Check`, `DCO` are present and `success`. **The full test pipeline has not been triggered on this head** — likely because there is no `ready` label.

**Last 10 comments digest (with my reading between the lines):**

1. **2026-04-02 e1n00r (author):** thanks caiovicentino for Nemotron validation; incorporated kernel-init fix as co-authored commit. *Sign: the patchset is co-maintained, not solo.*
2. **2026-04-02 caiovicentino:** suggests LFRU eviction policy; describes layers 18-23 deep-layer starvation pattern under LRU. *Sign: this is the kind of subtle "real workloads expose it" insight only an actual user generates.*
3. **2026-04-02 caiovicentino:** measured LFRU = +5.2% tok/s vs LRU on Nemotron-Cascade-2-30B-A3B (RTX PRO 6000 Blackwell). Cache=8, 15.6→16.4 tok/s, hit-rate 13.5%→30.2%. *Real numbers, on Blackwell.*
4. **2026-04-02 caiovicentino:** posts HuggingFace model card with full benchmarks + charts (`caiovicentino1/Nemotron-Cascade-2-30B-A3B-PolarQuant-Q5`).
5. **2026-04-03 caiovicentino:** independent validation on **Gemma 4 26B-A4B-it** (128 experts × top-8, 30 layers) — confirms the cache works on a structurally different MoE.
6. **2026-04-03 e1n00r:** confirms they have LFRU + 6 other policies implemented in their `tinyserve` repo; deep-layer starvation eliminated.
7. **2026-04-07 e1n00r:** **explicit ask** to maintainer `@mgoin` to add `ready` label to trigger CI; states all pre-commit checks pass. *This is the moment that should have unblocked merge — and it didn't.*
8. **2026-04-07 mergify[bot]:** merge conflict, please rebase.
9. **2026-04-07 caiovicentino:** rebased on top of `70406eb1d` (2026-04-07 main); confirmed end-to-end with CompressedTensors INT4 MoE on Qwopus-MoE-35B-A3B-INT4-CT, RTX PRO 6000 Blackwell 102 GB. **Measured `--moe-expert-cache-size 8` numbers on a real Blackwell.**
10. **2026-04-07 caiovicentino:** benchmark charts + PPL 6.56 on WikiText-2 (matches BF16). *Substantive correctness + perf data — the kind of thing a maintainer should respond to.*
11. **2026-04-09 tkj666:** identifies real algorithmic gap — when cache overflows during *prefill*, current code keeps the suffix of unique-sorted expert IDs (i.e., highest IDs), which is *arbitrary*, not access-order. **This is a legitimate technical concern.**
12. **2026-04-09 caiovicentino:** acknowledges the gap and explains the design rationale (during prefill there's no LRU history yet). *Conversation continues but no commits resolve it.*

**The "alvinttang" review** is substantive: identifies thread-safety in `ExpertLRUCache.prepare()` as fine *today* under vLLM's single-threaded forward pass, but flags it for future disaggregated prefill/decode. This is exactly the kind of forward-compat concern that would need maintainer triage — and there is no maintainer in the review thread.

**Branch staleness:** head SHA last updated 2026-05-24 (today), but `needs-rebase` is still attached and `mergeable_state` is `dirty` → today's push didn't include a rebase, just commits on a stale base. The PR has been **rebased at least once** (April 7 to commit 70406eb1d) but **the project has moved ~6 weeks of main forward since the last successful rebase**, including the MoE Refactor wave (#41055, #42334, #41979, #42334, #42566, #42483 — many of which restructure the exact `fused_moe/experts/` directory the PR touches). A clean rebase will be increasingly painful.

**Our take: do NOT ride PR #37190 for production on v0.21.0.**

Concrete reasons:

1. **No maintainer review.** Two community comments (one being a bot). `mgoin` was explicitly tagged on 2026-04-07; six weeks of silence followed.
2. **`needs-rebase` against a Refactor wave.** The MoE Refactor PRs (#41055, #41979, #42334, #42483, #42566) have moved the `experts/` directory under #37190's feet. A `verified` label is present but the head SHA's CI hasn't been re-run since the last push — it would almost certainly fail on the merge conflict surface alone.
3. **An open algorithmic concern (tkj666's prefill-overflow correctness) was raised on 2026-04-09 and was not closed in code.** Even if a maintainer picked it up today, that's a real change to the patch's semantics.
4. **The PR targets `main`, not v0.21.x.** Even on the most optimistic timeline, it would land in v0.22 at earliest. v0.21.0 production cannot wait for that.
5. **We have a working alternative.** The 30B-A3B-AWQ fits on our 32 GB 5090 already (per the existing investigation memo). Switching to the 80B-A3B variant is a "nice-to-have" not a "blocker for shipping vLLM 0.21.0."

**Recommended action:** mark PR #37190 as "watch but don't depend" in the dossier. Re-poll once a quarter or when its label set changes (specifically: `ready`, `approved`, or any maintainer review). If it doesn't get a maintainer touch by 2026-09-01, treat it as effectively dead and pivot to llama.cpp for the 80B-A3B variant if/when we need it.

---

## Recently merged PRs touching our stack (last 30 days)

### Quantization (label:quantization, merged ≥ 2026-04-24)

| #     | Title                                                                                       | Merged     |
| ----- | ------------------------------------------------------------------------------------------- | ---------- |
| 43148 | [Deprecation] Mark env vars covered by --moe-backend / --linear-backend                     | 2026-05-21 |
| 42782 | [Bugfix] Respect explicit --kv-cache-dtype over checkpoint kv_cache_scheme                  | 2026-05-16 |
| 42540 | [Misc] add humming to dependencies (subsequently reverted in #43492)                        | 2026-05-19 |
| 41965 | [Compressed Tensors] Allow configs with non-explicit ignores                                | 2026-05-07 |
| 41664 | [MXFP4] Support for linear layers + compressed-tensors integration                          | 2026-05-12 |
| 41630 | [NVFP4][fix] Fix `layer.weight` -> `w13` typo in NVFP4 MOE emulation kernel preparation     | 2026-05-04 |
| 41566 | [Quantization] Rework quantization_config to use QuantKey and allow for activation override | 2026-05-13 |
| 40033 | [NVFP4][Hopper/AMD Instinct] Add Triton kernels for NVFP4 dequantization and QDQ emulation  | 2026-04-30 |
| 39538 | [Kernel][UX] Add `--linear-backend` arg for linear kernel selection                         | 2026-05-16 |
| 35859 | [Quark] Support loading Quark NVFP4 checkpoints in vLLM                                     | 2026-05-13 |
| 34556 | [Quantization] add humming quantization kernel                                              | 2026-04-24 |

**Read:** activity is concentrated in NVFP4 / MXFP4 / Quark / Compressed-Tensors, not AWQ. AWQ-Marlin is treated as a stable backend. The new `--moe-backend` / `--linear-backend` CLI selectors (#39538, #43148) are worth knowing about but don't affect default behaviour.

### AWQ-specific (title contains "AWQ")

| #     | Title                                                                                       | Merged     |
| ----- | ------------------------------------------------------------------------------------------- | ---------- |
| 43296 | [CI] Fix `test_awq_load[gemma4-moe-*]` failure                                              | 2026-05-22 |
| 42483 | Refactor AWQ Marlin MoE onto modular WNA16 oracle                                           | 2026-05-18 |
| 42339 | [5/n] Migrate CUTLASS MLA, hadamard, awq, allspark and DSV3 fused a gemm to torch stable ABI | 2026-05-13 |

**Read:** **#42483 (AWQ Marlin MoE refactor onto the WNA16 oracle) is the only AWQ-substantive merge in 30 days** and it lands BEFORE v0.21.1rc0 (so it's in both v0.21.0 and v0.21.1rc0). For our dense Qwen3-Coder-30B-A3B-AWQ (or any non-MoE AWQ-Marlin path), this is neutral. The torch-stable-ABI migration (#42339) is plumbing.

### Blackwell / sm_120

| #     | Title                                                                                       | Merged     |
| ----- | ------------------------------------------------------------------------------------------- | ---------- |
| 40717 | [GDN] Enable FI Blackwell GDN prefill kernel                                                | 2026-05-20 |
| 41326 | Faster per-token fp8 group quant packed kernel for blackwell                                | 2026-05-01 |
| 41778 | [MLA Attention Backend] Add TOKENSPEED_MLA backend for DSR1/Kimi K25 prefill+decode on Blackwell | 2026-05-14 |
| 40082 | Integrate flashinfer b12x MoE and FP4 GEMM kernels for SM120/121                            | 2026-05-20 |
| 41215 | [Bugfix] Use enable_sm120_family for per-tensor FP8 CUTLASS kernels on SM12.1               | 2026-05-20 |

**Read:** **#41215 is directly ours** — fixes an sm120-family detection bug in per-tensor FP8 CUTLASS kernels. It's in v0.21.1rc0 (commit window) but I should flag it as a known sm_120 detection correction. **#40082 (flashinfer b12x MoE+FP4 for SM120/121)** is the kind of upstream-Blackwell-perf merge that's slowly building out v0.22's Blackwell story. None of these are AWQ-specific.

### Attention (last 30 days, MoE/Blackwell-adjacent only)

| #     | Title                                                                                       | Merged     |
| ----- | ------------------------------------------------------------------------------------------- | ---------- |
| 41052 | [Attention] Sync FA with upstream                                                           | 2026-05-13 |
| 41744 | [Attention] Minor refactor: layer takes ownership of the MLA prefill backend                | 2026-05-05 |
| 42555 | [Attention] Remove deprecated MLA prefill arguments                                         | 2026-05-14 |
| 40815 | [Attention] Move FA3→FA4 upgrade into get_flash_attn_version()                              | 2026-05-05 |
| 42121 | [Attention][Cleanup] Remove tree attention                                                  | 2026-05-09 |
| 42650 | [Bugfix] Source num_qo_heads from Attention layers in Flashinfer/Triton metadata builders   | 2026-05-22 |

**Read:** mostly MLA cleanup / FA upstream sync. **#41052 (FA upstream sync)** is the largest "behavioural change risk" item — FA kernel updates can shift numerics. Worth a regression spot-check post-upgrade.

### Tool-calling (the parser fleet)

22 PRs merged with `label:tool-calling` in 30 days. The ones that hit our stack:

| #     | Title                                                                                       | Merged     |
| ----- | ------------------------------------------------------------------------------------------- | ---------- |
| 42292 | [Bugifx][Qwen3CoderTool] Restore supports_required_and_named for required tool_choice       | 2026-05-12 |
| 42454 | [Bugfix] Handle real-world gpt-oss tool call output in Harmony parsing                       | 2026-05-13 |
| 42570 | [Refactor] Use shared utils in hermes tool parser                                           | 2026-05-14 |
| 42128 | [Bugfix] Fix Gemma4ToolParser streaming float corruption                                     | 2026-05-14 |
| 41876 | [Refactor] Consolidate required/named tool_choice streaming into DelegatingParser           | 2026-05-07 |
| 40894 | feat: update xgrammar==0.2.0 to use structural tags for strict tool calling + reasoning      | 2026-05-04 |

**Read:** **#42292 is directly ours** (Qwen3CoderTool, required tool_choice) and it's in v0.21.1rc0. **#41876 (DelegatingParser refactor) is structural** — it consolidated required/named tool_choice streaming across parsers; the v0.21.0 release is the first to ship this refactor, and #42292 is exactly the kind of follow-up regression the refactor produced. The pattern says "the tool-parser refactor in v0.21.0 had real bugs; one was caught for v0.21.1; expect more."

### Frontend / OpenAI server

29 PRs merged. The relevant ones for our config:

| #     | Title                                                                                       | Merged     |
| ----- | ------------------------------------------------------------------------------------------- | ---------- |
| 43414 | [Bugfix][Frontend] Fix input_audio parsing when uuid is present                             | 2026-05-23 |
| 43260 | [Frontend] Add truncation side to OpenAI endpoints                                          | 2026-05-22 |
| 43051 | [Bugfix] Auto-raise max_num_batched_tokens for prefix-LM multimodal models                  | 2026-05-23 |
| 42664 | [Frontend] Normalize reasoning_content to reasoning for client compatibility                | 2026-05-21 |
| 42329 | [Bugfix][Frontend] Default max_tokens server-side on /inference/v1/generate                 | 2026-05-13 |
| 42272 | [Frontend] Responses API supports chat_template_kwargs                                      | 2026-05-11 |
| 41800 | [Bugfix] Account for truncate_prompt_tokens when computing max_tokens                       | 2026-05-06 |

**Read:** mostly low-risk fixes and additions. **#42664 (reasoning_content normalization)** changes a response field name in some paths — clients pinning to `reasoning_content` could see breakage; clients reading `reasoning` only get a fix. Worth a smoke-test for any of our downstream consumers.

### Docker / build

| #     | Title                                                                                       | Merged     |
| ----- | ------------------------------------------------------------------------------------------- | ---------- |
| 43378 | [CI] Fix dockerfile dependency graph failure for pre-commit                                 | 2026-05-22 |
| 40453 | Update Dockerfile.rocm for AINIC & Thor NIC                                                 | 2026-05-14 |
| 39855 | [Bugfix] Install libcublas-dev in Dockerfile for FlashInfer CuTe DSL JIT                    | 2026-04-27 |

**Read:** **#39855 (libcublas-dev install)** matters for any CUDA-13 / FlashInfer-CuTe-DSL JIT path. The v0.21.0 prebuilt image picks this up.

### Weight loading

| #     | Title                                                                                       | Merged     |
| ----- | ------------------------------------------------------------------------------------------- | ---------- |
| 43213 | [Model] Fix MiniCPM-V 4.6 vit_merger qkv weight loading                                     | 2026-05-22 |
| 42521 | [Fix] Weight loading for qwen3_5 using runai_streamer                                       | 2026-05-14 |
| 42830 | Fix: Propagate pinned model revisions into Ultravox secondary weight loading                | 2026-05-16 |
| 42716 | Fix Weight loading for Qwen3.5-MTP and Qwen3-VL using runai_streamer                        | 2026-05-17 |
| 42244 | Avoid silent weights corruption when loading Nemotron Nano VL with reusable-buffer loaders  | 2026-05-11 |

**Read:** runai_streamer / reusable-buffer loaders had **silent-corruption bugs** that took multiple PRs to fix. **If we are using `--load-format=runai_streamer`, this is a flag area.** Our default config uses HF safetensors loading, so this is neutral — but worth knowing.

---

## Themes from PR activity (where is the codebase churning?)

Ranked by 30-day merge volume in areas that intersect our concerns:

1. **MoE / FusedMoE refactor.** At least 8 PRs (40735, 41046, 41055, 41299, 41979, 42334, 42483, 42566, 42680). This is a *running* refactor of the experts directory, which is exactly the surface PR #37190 patches. It is the strongest single explanation for why #37190 can't get merged — the target keeps moving.
2. **DSv4 / DeepSeek-V4 stabilization.** v0.21.0 shipped DSv4 and v0.21.1rc0 backports 3 DSv4 fixes (Marlin swiglu, ROCm aiter mhc, TOKENSPEED_MLA Blackwell). Several more DSv4 fixes are in the rc0 commit window but not cherry-picked (#42320, #42342, #42258, #42444, #43319). **Implication: DSv4 is the most-actively-debugged area; non-DSv4 users get incidental wins from related infrastructure fixes.**
3. **Tool-parser hygiene.** ~22 PRs in 30 days, mix of refactors (DelegatingParser, shared coerce_to_schema_type, hermes shared utils) and per-vendor bugfixes (Qwen3Coder, Gemma4, gpt-oss/Harmony, GLM, Mistral, DSV32/V4, Apertus). **Pattern: vLLM is consolidating parser infrastructure and the refactors are catching real bugs.**
4. **Quantization plumbing.** New `--linear-backend` / `--moe-backend` selectors, QuantKey rework, NVFP4/MXFP4/Quark expansion. AWQ is treated as the stable reference — no architectural change, only the Marlin-MoE refactor.
5. **Release pipeline hardening.** 4 CI/release PRs cherry-picked. v0.21.0's release pipeline was visibly flaky; v0.21.1 will be cleaner.
6. **KV-cache offloading + disaggregation.** Heavy investment (NIXL 1.x, Mooncake, OffloadingSpec, SimpleCPUOffloadBackend). Not in our path.
7. **Blackwell sm_120 fixes are small but real.** #41215 (FP8 CUTLASS family detection) and #40082 (flashinfer SM120/121). Pattern: sm_120 is *supported but not the perf priority*. Hopper/B200 gets more love.
8. **Model Runner V2 migration.** Active but firewalled behind labels and PR queues; not impacting v0.21.0 production yet. v0.22 territory.

---

## Risk score for our use case: **2/5** (low-moderate)

Justification:

- The v0.21.0 → v0.21.1rc0 hotfix set has **zero AWQ-Marlin-on-dense-Blackwell** fixes, which means the path we depend on is not flagged as broken. (+)
- **#42292 (Qwen3CoderTool required-tool-choice fix)** is in v0.21.1rc0, not v0.21.0 — so if we use `tool_choice="required"` with the Qwen3Coder parser, we want v0.21.1, not v0.21.0. (-)
- **#42434 (revert of Core routing-replay)** means v0.21.0 has a Core engine path that v0.21.1 reverts. For single-stream single-model inference (us today), unlikely to bite. For concurrent / async-overlap (us tomorrow if we add more clients), real risk. (-)
- **#41215 (sm_120 family detection fix for FP8 CUTLASS)** lands in our window — we are AWQ not FP8, so neutral for us today, but it's a sign the sm_120 detection logic was recently broken in some path. (~)
- **PR #37190 remains stuck.** Our memo's "stay on 30B-A3B-AWQ" decision is fully validated. (~ - it's not a risk, it's a known constraint.)
- **Reverts are small (3 in v0.21.1rc0, 4 post-rc0) and only one — #42434 — has real engine semantics.** That is a healthy signal. The project is not papering over breakage. (+)
- **The tool-parser refactor in v0.21.0 produced real downstream bugs (#42292, #42454, #42128, #41991, #42026).** Our config does use tool parsers. **Recommend running the prebuilt v0.21.1rc0 image rather than v0.21.0**, or alternatively pin to v0.21.0 and accept the Qwen3CoderTool required-tool-choice limitation. (-)

Net: 2/5. v0.21.0 is shippable for our config; v0.21.1 will be moderately better, primarily on tool-parser and DSv4-adjacent stability. The headline risks (PR #37190 stuck, MoE refactor in flight) do not affect our chosen 30B-A3B-AWQ baseline.

---

## Open questions for consolidation

1. **Wait for v0.21.1 final vs ship v0.21.0 prebuilt now?** My PR-landscape view says v0.21.1 brings (a) Qwen3CoderTool required-tool-choice fix (#42292), (b) Core routing-replay revert (#42434), (c) a clean release pipeline. None are deal-breakers for v0.21.0, but if our tool-call config includes `tool_choice="required"` on Qwen3Coder, **v0.21.1 is genuinely better**. Worth a 1-2 week wait if v0.21.1 final is on a normal cadence.
2. **Does any other auditor (A: release notes, B: post-v0.21.0 issues, C: regression themes, D: code-diff) corroborate the Core routing-replay (#42434) concern?** If B or C have user-reported regressions tied to #39917 / routing-replay / async D2H, the wait-for-v0.21.1 argument firms up. If not, v0.21.0 is fine for our config.
3. **Are we using `--load-format=runai_streamer` anywhere in the test path?** If yes, we want v0.21.1 (multiple silent-corruption fixes). If no (default HF safetensors), neutral.
4. **What is the trigger to re-poll PR #37190?** I recommend: poll once a quarter or when its label set changes (`ready` / `approved` / any maintainer review). If silent through 2026-09-01, treat as dead and pivot to llama.cpp for the 80B-A3B variant.
5. **The MoE Refactor wave (#41055, #42334, #41979, #42483, #42566) reshaped `fused_moe/experts/`.** Our config doesn't use MoE today, but if we later add an AWQ MoE model, **we'd be hitting code that landed for the first time in v0.21.0**, which the cherry-pick set tells us is still being stabilized (#42566, #43296 in v0.21.1rc0). Defer MoE-AWQ experiments to v0.21.1 or later.
6. **vLLM v0.22 signal:** Model Runner V2 migration, `--linear-backend` / `--moe-backend` consolidation, `claude-code-assisted` PRs entering the repo. Not actionable for us at v0.21.0 audit time, but the v0.22 release will be substantial.
