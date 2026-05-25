# Mission manifest

**Living document.** Single entry point for "what's the project, what's running, what's open, what's next."\
Last refresh: 2026-05-25.

---

## Mission

Operate a production-grade vLLM OpenAI-compatible inference server on an AORUS RTX 5090 eGPU over Thunderbolt 4 attached to a NUC 15 Pro+ host, deployed via k3s as a consumer of the [`apnex/nvidia-driver-injector`](https://github.com/apnex/nvidia-driver-injector) producer.\
Equal-weight goals: **reliability** (no hard locks, surprise removal handled, recovery autonomous) and **performance** (parity with closed-driver / WSL2 baselines on coding workloads).

---

## Current production state

| Layer | State |
|---|---|
| Hardware | AORUS RTX 5090 over TB4 → NUC 15 Pro+ (`obpc`) |
| Driver | `595.71.05-aorus.14` (patched build via injector container) |
| Runtime | k3s DaemonSet (`Path B`) — Path A docker-compose preserved as dev fallback |
| vLLM | `vllm/vllm-openai:v0.20.2` (R11-validated, locked) |
| Model | `cyankiwi/Qwen3-Coder-30B-A3B-Instruct-AWQ-4bit` @ 96k context |
| Service | `vip-vllm` @ `192.168.1.251:8000` via MetalLB `vllm-pool` |
| Observability | host-side systemd timers → `/var/log/vllm-soak/{metrics.csv,pods-*.txt}` |
| Soak window | 2026-05-24 → ~2026-06-07 (14-day, gates upstream PR work) |

---

## Active initiatives

Grouped by status. Numbered IDs match cross-references in commit messages and other docs.

### Dispatchable now

| # | Initiative | Status | Owner | Blocker | Detail |
|---|---|---|---|---|---|
| **M1** | TB / PCIe deep-dive research | ready | research subagent (Opus) | none | Why does TB auto-authorize fire at boot but not at runtime? What runtime hot-plug paths exist? Upstream patches for ReBAR-aware hot-plug? Output: `audit/tb-pcie/CONSOLIDATED.md` |
| **M2** | NVIDIA GPU Operator audit | plan written, awaiting 4 open-question sign-offs | 4 parallel research subagents + synthesis | 4 sign-off questions in `docs/gpu-operator-audit-plan.md` | Extract proven patterns for driver DaemonSet entrypoint, label/taint mgmt, controller logic, 5-year issue history. Synthesis informs D-1 / D-2 / D-4 design. |

### Conditional (trigger-based)

| # | Initiative | Trigger | Detail |
|---|---|---|---|
| **M3** | v0.21.1 cutover | upstream releases `vllm/vllm-openai:v0.21.1` (estimate 2026-05-31 to 2026-06-07) | 5-phase plan in `docs/v0.21.1-cutover-plan.md`. Potentially unblocks 7 parked threads + 2 new Tier S candidates. |
| **M4** | Heartbeat watchdog implementation | soak surfaces a `#42897`-class wedge | livenessProbe replacement based on `vllm:generation_tokens_total` flatline detection. Defer indefinitely if no wedge fires. |

### Hardening gaps (filed against `apnex/nvidia-driver-injector`)

| # | Gap | Severity | Status | Design discussion |
|---|---|---|---|---|
| **D-1** | Stale `nvidia.driver/state=ready` node label during driver-absent window | medium | open, design TBD | gated on M2 (mirror NVIDIA's label/taint conventions) |
| **D-2** | Injector enters liveness-probe-driven crashloop instead of documented clean-exit-wait pattern under k3s | medium | open, design TBD | gated on M2 |
| **D-3** | PCIe tunnel does not autonomously recover from chassis power-cycle; requires reboot with cable in place | high | open, design TBD | gated on M1 (research informs Option B vs Option E vs "document as known limit") |
| **D-4** | Injector failure modes are buried in logs (BAR1=256MB error took 10+ min to surface during 2026-05-25 test) | low-medium | open, design TBD | gated on M2 |

### Deferred (post-audit)

| # | Initiative | Trigger | Detail |
|---|---|---|---|
| **M5** | Injector code changes for D-1 / D-2 / D-3 / D-4 | M1 + M2 complete + design call made | Implementation phase. Code changes against injector repo, not this repo. |
| **M6** | Laguna-XS.2 model bench | any time (passes all v0.20.2 hard gates) | Single-variable swap against R11; ~45 min. Most useful BATCHED with M3's v0.21.1 cutover when 2 more Tier S candidates also become testable. |

### Post-soak (after 2026-06-07 window closes)

| # | Initiative | Trigger | Detail |
|---|---|---|---|
| **M7** | Injector patch promotion: `reviewed → approved` flip | clean 14-day soak | 11 intent files in injector repo flip status. Gates M8. |
| **M8** | NVIDIA upstream PRs: C1-C5 + E1 | M7 complete | Upstream contribution. Outside scope of this repo; tracked in injector repo. |

---

## Recently closed (last ~14 days, for traceability)

| Date | What | Where landed |
|---|---|---|
| 2026-05-22 | injector patch-intent schema + 11 catalog files | injector repo `main` |
| 2026-05-23 | injector v3 multi-lens triangulated improvement sweep | injector repo `main` |
| 2026-05-24 | k8s-vllm refactor (docker-compose → k3s, MetalLB VIP, v0.21.0 audit + skip) | this repo, `937533a` |
| 2026-05-24 | k3s substrate validation (perf + polyglot vs R11 baseline) | this repo, `3c420c1` |
| 2026-05-24 | soak observability stack | this repo, `dc178a6` |
| 2026-05-24 | model research (3-week window) + v0.21.1 cutover plan | this repo, `4373af1` |
| 2026-05-24 | injector diag container (`apnex/nvidia-driver-diag:1.0`) | injector repo `main` |
| 2026-05-24 | injector aorus.14 image cutover | injector repo + production |
| 2026-05-25 | reliability test — live GPU power-on after extended absence | this repo, `archive/power-on-test-20260525T005756Z/` + `docs/reliability-test-2026-05-25-gpu-power-on.md` |

---

## Cross-references (detailed plans + state)

**This repo (`apnex/k8s-vllm`):**

- [`docs/v0.21.1-cutover-plan.md`](./v0.21.1-cutover-plan.md) — M3 detailed plan
- [`docs/gpu-operator-audit-plan.md`](./gpu-operator-audit-plan.md) — M2 detailed plan
- [`docs/model-research-2026-05-24.md`](./model-research-2026-05-24.md) — Tier S candidate research
- [`docs/reliability-test-2026-05-25-gpu-power-on.md`](./reliability-test-2026-05-25-gpu-power-on.md) — D-1 / D-2 / D-3 / D-4 origin
- [`docs/perf-hypothesis-ledger.md`](./perf-hypothesis-ledger.md) — H-numbered perf hypotheses
- [`docs/model-config-matrix.md`](./model-config-matrix.md) — model × config result matrix (R-numbered runs)
- [`docs/soak-monitoring.md`](./soak-monitoring.md) — observability stack
- [`audit/v0.21.0/CONSOLIDATED.md`](../audit/v0.21.0/CONSOLIDATED.md) — v0.21.0 skip rationale

**Producer repo (`apnex/nvidia-driver-injector`):**

- driver patches (P1-P7 base, A1-A5 addon)
- patches intent + review catalogs (11 files, status: `reviewed`)
- production-migration plan (soak + cutover steps)
- diag companion container

**Fork (`apnex/vllm`):**

- read-only audit clone of `vllm-project/vllm`
- used by audit subagents (v0.21.0 audit, future v0.21.1 audit, future model researches)

---

## How to use this document

- **Looking for current production state?** Top table.
- **What's the next thing to do?** First row of "Dispatchable now" — if empty, look at "Conditional" triggers.
- **Tracking a specific concern?** Each initiative has an ID (M1-M8, D-1 to D-4) — grep commit messages and other docs.
- **Wondering if X is being worked on?** Either it's an active initiative above, or it's in "Recently closed," or it isn't tracked yet (file it).
- **Refresh policy:** update after each completed initiative or weekly, whichever is shorter.
