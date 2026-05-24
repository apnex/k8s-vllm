# vLLM v0.21.0 — consolidated audit + recommendation

**Date:** 2026-05-24\
**Author:** main agent, consolidating 5 parallel Opus subagent audits (A-E)\
**Subject:** Should we pin our k3s manifests to `vllm/vllm-openai:v0.21.0`, hold on `v0.20.2`, or wait for `v0.21.1`?\
**Fork:** `apnex/vllm` (clone at `/root/vllm`)

---

## TL;DR

**Recommendation: pin k3s manifests to `v0.20.2` (known-good); wait for `v0.21.1` final; skip `v0.21.0` entirely.**

Three corroborated findings drive this:

1. **`v0.21.1rc0` is already tagged** (169 commits past v0.21.0, 12 formal cherry-picks). A patch release is in the rc cycle — historically ~1-2 weeks to final at vLLM's cadence. The fact that there *is* an rc means maintainers consider v0.21.0 worth patching.
2. **Two fixes in v0.21.1rc0 hit our exact path:** PR #42292 (Qwen3CoderTool required-tool-choice fix) and PR #42434 (revert of buggy Core routing-replay engine change). Neither is in v0.21.0.
3. **v0.21.0 has confirmed RTX 5090 startup hang + sustained-traffic engine hang** (issues #42987, #42897). #42987 has a one-line workaround; #42897 is unresolved. Both reproduce on our exact hardware class (Blackwell sm_120).

The k3s substrate refactor (Path A → Path B) is the priority and is orthogonal to the version bump. Ship the refactor on v0.20.2 (already validated R11 production); flip to v0.21.1 in a separate, audited cutover when it stabilises.

---

## Per-auditor risk scores

| Auditor | Scope | Score | Lens |
|---|---:|---:|---|
| A — Release notes | Official surface | 2/5 | Low risk — environment cheap, no AWQ/parser breaking changes called out |
| B — Post-release issues | 185 issues, 9 days | 3.5/5 | Real-world early-adopter signal: SM120 hangs + parser bugs |
| C — 30-day bug themes | 301 bug-labeled | 3/5 | Streaming parser refactor introduced systemic bugs |
| D — Code diff v0.20.2..v0.21.0 | 396 commits, 1096 files | 3/5 | Sampler default flip + tool-parser refactor have real semantic content |
| E — PR landscape | v0.21.1rc0 + 30d merges | 2/5 | Hotfix set has no AWQ-on-Blackwell-dense fixes (good); 2 PRs in rc0 directly relevant |
| **Composite** | | **~2.7/5** | **Moderate — staged adoption, not drop-in** |

The lower scores (A, E) come from official-surface auditors. The higher scores (B, C, D) come from auditors who looked at actual user bugs and code diff. The bug-side evidence is more discriminating.

---

## Corroborated findings (≥2 auditors concur)

### 1. Streaming tool-call parsers are broken across families [B+C+D+E]

v0.21.0's `DelegatingParser.parse_delta` refactor (PR #41876) consolidated streaming logic across parsers and introduced regressions in every family parser we'd plausibly use: `qwen3_coder`, `qwen3_xml`, `gemma4`, `kimi_k2`, `glm47_moe`, `granite4`, `deepseekv4`.

**Specific bugs hitting our `--enable-auto-tool-choice --tool-call-parser <family>` path:**
- #42696 — Gemma4: multi-tool delta mis-attribution at concurrency ≥500; strict-client field re-emission
- #43221 — Qwen3: `</think><tool_call>` in same delta truncates reasoning content
- #43238 — qwen3_xml: `ast.literal_eval` fails on JSON booleans/null → complex arrays silently string-encoded
- #42747 — `tool_choice="none"` ignored in streaming (any parser)
- #43436 — Qwen parsers broken with MTP and/or `--stream-interval > 1`

**Code-side root cause [D]:** `Qwen3CoderToolParser.supports_required_and_named = False` reroutes required tool_choice away from the legacy JSON-grammar path; the inline `extract_tool_call_required_streaming` helper was deleted; structural-tag enforcement is a new opt-in env var (`VLLM_ENFORCE_STRICT_TOOL_CALLING`).

**Fix status [E]:** PR #42292 (Qwen3CoderTool required-tool-choice fix) is in **v0.21.1rc0**, NOT in v0.21.0. PRs for #42696 (Gemma4 rewrite) and #43221 (DelegatingParser merge fix) are not yet merged.

**Verdict:** material risk to any production deployment of v0.21.0 using `--enable-auto-tool-choice` with a streaming client. v0.21.1 fixes the most relevant one for us; more in flight.

### 2. RTX 5090 / sm_120 startup hang [B+C]

Issue #42987: `_dummy_sampler_run` uses `top_k = vocab_size - 1` (151,935 for Qwen2.5-3B). Both Triton and FlashInfer top-k mask kernels hang silently on SM120 — `cuLaunchKernel` dispatched, host blocks in `cudaEventSynchronize` forever. No error, no timeout (>9 hours observed before SIGTERM).

- Reproduces on **bare-metal RTX 5090** on v0.20.1; reporter states "likely 0.21.x too."
- One-line workaround exists (monkey-patch `top_k = 50` in profiling run; profiling memory footprint is top_k-independent).
- PR awaiting hardware verification; not in v0.21.0, not in v0.21.1rc0 cherry-pick set [E].

**Our exposure:** our exact hardware. Almost certainly hits us on first launch of v0.21.0 unless we apply mitigation.

### 3. RTX 5090 sustained-traffic engine hang [B+C]

Issue #42897: after hours of sustained chat-completion traffic at concurrency >1, EngineCore wedges on `cuEventSynchronize`. HTTP `/health` still returns 200; `Avg prompt throughput` log line stops; engine never recovers. Reproduced on three vLLM builds (0.21.0 + 2 nightlies). Same hardware class as ours. Reporter's flags: `--enable-auto-tool-choice --reasoning-parser qwen3 --tool-call-parser qwen3_coder` — heavy overlap with our planned config.

Closed by reporter as "not actionable from stack trace alone." Root cause unresolved. Reporter built a journal-heartbeat watcher (83s after last throughput log → restart).

**Our exposure:** real for our k3s DaemonSet pattern. If we ship, build a token-output-rate watchdog independent of `/health` (Phase 2).

### 4. Three silent default-env-var flips [A+D]

| Env var | v0.20.2 | v0.21.0 | Impact on us |
|---|---|---|---|
| `VLLM_USE_FLASHINFER_SAMPLER` | None (opt-in) | True | Sampler path silently changes for stochastic decode on sm_120; falls back to native sampler with `warning_once` if FlashInfer rejects sm_120 |
| `VLLM_ENABLE_PREGRAD_PASSES` | False | True | +~1s cold compile |
| `VLLM_USE_RAY_V2_EXECUTOR_BACKEND` | 0 | 1 | None (no Ray) |

Plus the new `--fingerprint-mode=full` default adds `system_fingerprint` field to all responses — Pydantic-strict clients may need updating.

**Mitigation if we ship:** explicitly set `VLLM_USE_FLASHINFER_SAMPLER=0` + `--fingerprint-mode=none` in container env until soaked.

### 5. v0.21.1rc0 already tagged with 12 cherry-picks [E + local git verify]

`git tag` in `/root/vllm` confirms `v0.21.1rc0` exists. E enumerated the 169 commits + 12 formal cherry-picks (milestone #29). Audit A missed it because it queried `releases` (publish-time) rather than `tags`; rc0 is tagged but not yet formally released. **A's conclusion that "no v0.21.1rc0 exists" was wrong; E + local verification are authoritative.**

Cherry-pick set distribution:
- DSv4 / Blackwell MLA correctness (3) — not us
- Build/CI hardening (4) — not us
- Quant new formats (3 — NVFP4, FP8, W8A8) — not us (we're AWQ)
- KV/disagg (2) — not us
- **AWQ-Marlin / sm_120-dense: ZERO cherry-picks** — our path is treated as the stable reference (good signal)

The 169-commit window also includes:
- PR #42292 (Qwen3CoderTool required-tool-choice fix) — **directly relevant**
- PR #42434 — **revert** of Core "routing replay with device cache and async D2H pipeline" (#39917). v0.21.0 shipped the buggy variant.
- PR #41215 (sm_120 family detection for FP8 CUTLASS) — sign sm_120 detection was recently broken in some path

### 6. PR #37190 (MoE expert offload) is effectively dead [E]

- State: open, draft=false, mergeable_state=dirty, needs-rebase
- No maintainer review in 8+ weeks; explicit `@mgoin` tag on 2026-04-07 unanswered
- MoE Refactor wave (5 merged PRs since) reshaped the `experts/` directory under it
- Open algorithmic concern (tkj666's prefill-overflow correctness) unresolved in code
- Targets `main`, not v0.21.x — would land in v0.22 at earliest

**Verdict:** confirms our existing memory (`feedback_vllm_moe_offload_blocked_on_pr_37190`). Stay on Qwen3-Coder 30B-A3B-AWQ dense. Re-poll quarterly; treat as dead if no maintainer touch by 2026-09-01.

---

## What is NOT a concern for us

- **AWQ kernel changes** — D found zero in our path. Only `awq_marlin.py` import-path updates (refactor, no behaviour change).
- **Qwen3 / Llama3 / Gemma3 model loaders** — D found minimal compile-decorator schema tweaks only. Gemma3 no longer hard-fails on non-`gelu_pytorch_tanh` activation (relaxation).
- **MoE/MLA/NVFP4/MXFP4 paths** — entire cluster of v0.21.0 bug themes (Themes 5-8 in C) miss us because we run dense AWQ-4bit.
- **cu13/cu129/cu128 wheel matrix [C, Theme 2]** — we use prebuilt Docker image, which is the only path that "just works."
- **NIXL 1.x bump** — single-GPU non-disaggregated.
- **Transformers v4 deprecation** — prebuilt image already ships v5.
- **C++20 build requirement** — prebuilt image only.

---

## Three viable paths

### Path 1 — Hold on v0.20.2, wait for v0.21.1 final (RECOMMENDED)

- Pin k3s manifests to `vllm/vllm-openai:v0.20.2` (R11 production-validated since 2026-05-10)
- Ship the substrate refactor (Path A → Path B / docker-compose → k3s DaemonSet) on known-good
- When v0.21.1 final ships (estimate 2026-05-31 to 2026-06-07 based on v0.20.x cadence: rc0 → final was 5-7 days), re-audit deltas vs v0.21.0 (small — should be just the 12 cherry-picks + 4 reverts)
- Staged cutover: smoke-test v0.21.1 with mitigations in a parallel pod, then flip

**Pros:** zero version-bump risk on the refactor; substrate and version changes stay separable; v0.21.1 absorbs the parser + Core revert fixes that directly hit us.\
**Cons:** stay on v0.20.2 for ~1-2 weeks longer.

### Path 2 — Ship v0.21.0 with mitigations

- Pin manifests to `vllm/vllm-openai:v0.21.0`
- Set `VLLM_USE_FLASHINFER_SAMPLER=0` + `--fingerprint-mode=none` in container env
- Apply #42987 mitigation (`top_k=50` patch or `--enforce-eager` baseline)
- Build heartbeat watchdog before production cutover (#42897 risk)
- Avoid AWQ-MLA model families (GLM-4.7-AWQ, DeepSeek-V4-AWQ, Kimi-AWQ) — #43263 crash on long prefill
- Set `--stream-interval 1` if hitting streaming-parser bugs
- Accept that Qwen3CoderTool `tool_choice="required"` may be quirky until v0.21.1

**Pros:** bleeding-edge features (Gemma4-AWQ 9.5× KV cache headroom, attention sync elimination, OOM-safe model load).\
**Cons:** carries ~5 mitigations to track; the version-bump risk piggybacks on the substrate refactor; first launch may hang silently.

### Path 3 — Stay on v0.20.2 indefinitely

- Ship refactor on v0.20.2; don't plan a v0.21.x cutover at all
- Revisit at v0.22 (~Aug 2026) or when triggered by a specific feature need

**Pros:** maximum stability.\
**Cons:** misses incremental fixes; falls behind upstream support window; v0.20.2 carries #41306 MoE perf regression (irrelevant to us — we're dense) and #42591 `/v2/embed` API-key bypass (security, but we don't expose `/v2/embed`).

---

## Recommendation

**Path 1.** Specifically:

1. **Now**: pin k3s manifests to `vllm/vllm-openai:v0.20.2`. Ship the k3s refactor. Soak.
2. **Watch**: poll `gh api repos/vllm-project/vllm/releases/tags/v0.21.1` and `gh api repos/vllm-project/vllm/tags` weekly. Likely lands within 14 days.
3. **When v0.21.1 ships**: spawn a small audit-update agent (delta vs v0.21.0; expect ≤30 PRs to review) + smoke-test in staging container, then plan cutover.
4. **PR #37190**: declared effectively dead per E's analysis. Re-poll 2026-08-24 (quarterly) or earlier if label set changes.
5. **Production hardening (orthogonal)**: build the token-output-rate heartbeat watchdog regardless of v0.21.x version — #42897 class hazards exist independent of release.

---

## Open follow-ups (not blocking the decision)

- **Audit A error noted**: A claimed "no v0.21.1rc0 exists" because it queried `releases` API (publish-time, formal). E + local git verified `v0.21.1rc0` IS tagged. Methodology note for future audits: check `git tag` + `gh api tags` not just `gh api releases`.
- **Cross-checks D suggested**: FlashInfer 0.6.8.post1 sm_120 sampler quality A/B; xgrammar 0.2.0 grammar compatibility with our tool-call payloads. Both are smoke-tests we'd run during the v0.21.1 staging cutover anyway.
- **Watchdog spec**: heartbeat = "tokens emitted in last N seconds across all in-flight requests" via metrics scrape; kubelet `restartPolicy: Always` + livenessProbe with `failureThreshold` ≈ 83 / probe-interval.

---

## Sources

All five audit deliverables in this directory:

- [`A-release-notes.md`](A-release-notes.md) — 3,082 words; risk 2/5
- [`B-post-release-issues.md`](B-post-release-issues.md) — 4,070 words; risk 3.5/5
- [`C-bug-themes.md`](C-bug-themes.md) — 4,261 words; risk 3/5
- [`D-code-diff.md`](D-code-diff.md) — 3,970 words; risk 3/5
- [`E-pr-landscape.md`](E-pr-landscape.md) — ~3,500 words; risk 2/5

Fork: https://github.com/apnex/vllm (clone at `/root/vllm`)
