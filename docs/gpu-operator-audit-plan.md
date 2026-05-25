# NVIDIA GPU Operator — deep audit plan

**Status:** planning phase, awaiting approval before execution.\
**Trigger:** reliability test 2026-05-25 surfaced 3 hardening gaps (D-1 stale node label, D-2 injector liveness-crashloop pattern, D-3 PCIe tunnel non-recovery after GPU power-cycle).\
**Goal:** extract proven patterns from NVIDIA's ~5-year-hardened driver-DaemonSet implementation rather than re-invent.\
**Companion plan:** TB/PCIe deep-dive (D-3 specifically) — separate effort, runs in parallel.\
**Cross-refs:** [`docs/reliability-test-2026-05-25-gpu-power-on.md`](./reliability-test-2026-05-25-gpu-power-on.md), upstream repo `https://github.com/NVIDIA/gpu-operator`.

---

## TL;DR

Four parallel Opus research subagents on a fresh local clone of `NVIDIA/gpu-operator`, each owning one audit dimension.\
Synthesis subagent merges the four reports into a single comparison-and-recommendations doc.\
~2-3 hours total Opus compute; ~1-2 days wall-clock with our scheduling.\
Produces concrete patch-ready recommendations for our injector, NOT a research paper.

---

## Why this matters

NVIDIA GPU Operator is the de facto k8s standard for driver lifecycle on GPU nodes.\
It has been running in production at thousands of sites for ~5 years.\
The patterns it uses for driver-DaemonSet entrypoint logic, node label management, probe configuration, taint application, and failure recovery represent battle-tested k8s-native solutions to exactly the class of problems we just surfaced.

Our `nvidia-driver-injector` solves a related but different problem (TB-attached eGPU on a single-node k3s) and has accumulated patches reactively as we hit issues.\
A structured comparison should surface (a) patterns we should copy, (b) gaps we have that they've already solved, and (c) the things that are genuinely ours to invent because they don't address eGPU at all.

---

## Scope

### In scope

- **`driver/`** subcomponent of gpu-operator — the actual driver-loading DaemonSet
- **Driver container Dockerfile + entrypoint** — build chain, runtime logic
- **Driver DaemonSet manifest patterns** — probes, tolerations, volume mounts, security context
- **`gpu-operator-validator/`** — health validation patterns
- **Node label / taint management** — which labels, when applied, who applies them
- **State machine / error handling** — how they distinguish "no GPU yet" from "GPU broken"
- **Multi-driver-version support** — if they handle cluster-wide version transitions
- **Recovery from GPU absence / arrival** — equivalent to our hotplug story
- **Issue/PR history mining** — what edge cases they've hit over 5 years

### Out of scope

- GFD (GPU Feature Discovery) beyond what touches labels we'd consume
- DCGM exporter (we have our own observability)
- MIG manager (no MIG on our hardware)
- vGPU manager (not our use case)
- Network operator (not GPU-adjacent)
- Sandbox / container toolkit (we install nvidia-container-toolkit separately)
- Multi-GPU coordination (single GPU)
- Multi-node scheduling (single-node k3s)
- Helm chart packaging mechanics (we use raw manifests)

---

## Phase 1 — Orient (one-shot, before subagent dispatch)

```bash
gh repo fork NVIDIA/gpu-operator --fork-name gpu-operator-audit --clone=false
cd /root && git clone --filter=blob:none https://github.com/apnex/gpu-operator-audit.git
```

Local clone serves as the audit-target. Read-only — never modify, never push.

One-time orientation pass (single-shot, no subagent — fast):

- Read top-level `README.md` + `CONTRIBUTING.md`
- Enumerate top-level dirs; produce a "this is where to look" map
- Identify the driver-DaemonSet Helm template path (likely `deployments/gpu-operator/templates/driver-*.yaml`)
- Identify the driver container source repo (likely `https://github.com/NVIDIA/driver-container-images` — separate from gpu-operator itself)
- Note tag/version: pin to most recent stable release; audit against that, not main

Output: short markdown blob with the "navigation map" that subagents reference.

---

## Phase 2 — Four parallel Opus subagents

### Subagent G1 — Driver container deep-dive

**Scope:** the driver container itself — what runs inside.

Files to read:
- Dockerfile(s) — base image, build chain
- `entrypoint.sh` or equivalent — full state machine
- `nvidia-driver` wrapper scripts
- driver validator binary / scripts

Questions to answer:
- How does the entrypoint detect "no GPU yet"? Loop-wait? Clean exit?
- How does it sequence: kernel build → module load → device materialise → persistence engage?
- What error handling does it have at each step?
- How does it react to GPU disappearing at runtime?
- What signals does it emit (logs / files / exit codes / probes)?
- What privs does it require? (`privileged: true`? specific capabilities?)
- What `/sys` and `/proc` paths does it touch?

Output: `audit/gpu-operator/G1-driver-container.md` (~2,500 words).

### Subagent G2 — Manifest patterns + node label/taint management

**Scope:** the k8s side — how the operator declares the driver DaemonSet and manages node state.

Files to read:
- Driver DaemonSet template (Helm)
- Driver pod spec (probes, security context, volume mounts, tolerations, nodeSelector)
- Node label/taint application logic (likely in operator controller code, `controllers/`)
- RBAC for label/taint operations
- CRDs touching driver / node state

Questions to answer:
- What labels does the operator apply, and at what lifecycle stages?
- Does it use taints? Which ones, with what effect (`NoSchedule` / `NoExecute`)?
- Where does taint application sit — driver pod, operator controller, GFD?
- What are the liveness vs readiness probe configurations?
- How does it handle the "driver still loading" vs "driver ready" vs "driver broken" states?
- What's the rollout strategy for driver version changes across the cluster?

Output: `audit/gpu-operator/G2-manifests-labels.md` (~2,500 words).

### Subagent G3 — Operator controller logic (failure recovery + reconciliation)

**Scope:** the Go-level controller — how it reconciles desired state vs actual state.

Files to read:
- `controllers/` — main reconciliation loops
- Status / phase tracking (how does the operator know if a driver pod is healthy?)
- Event emission (what does it emit to k8s events for human visibility?)
- Failure recovery paths (driver pod CrashLoopBackOff → what does the operator do?)

Questions to answer:
- Does the operator monitor the driver pod's state and take corrective action (vs. just kubelet's auto-restart)?
- Does it ever delete + recreate a driver pod (force-cycle past kubelet backoff)?
- How does it surface health to humans (`Status.Conditions`? Events? Metrics?)
- What's the equivalent of our "soak observability" pattern in their world?
- Do they have an explicit "degraded" state for partial failure?

Output: `audit/gpu-operator/G3-controller-recovery.md` (~2,500 words).

### Subagent G4 — Issue/PR history mining (5 years of edge cases)

**Scope:** GitHub issue tracker + closed PRs to extract historical lessons.

Approach:
- Pull all GitHub issues with labels `driver`, `bug`, `regression` from the last 3 years
- Sort by reaction count (most-impactful first)
- Group by theme (driver-load failures, label issues, probe issues, k8s-version compatibility, etc.)
- For each theme: pull the issue + the fix PR (if merged); summarise the lesson

Questions to answer:
- What classes of failure have hit gpu-operator users in production?
- What of those classes apply to us (single-node, eGPU, AWQ workload)?
- Which lessons are encoded in current code vs documentation vs neither?
- Are there any TB / hotplug / power-cycle issues in their history?
- What recurring patterns appear in their post-mortems?

Output: `audit/gpu-operator/G4-issue-history.md` (~3,000 words).

---

## Phase 3 — Synthesis

A fifth Opus subagent reads G1-G4 and produces the final deliverable.

**Brief:**

- Read G1, G2, G3, G4 fully
- Read our own `entrypoint.sh`, `k8s/deployment.yaml`, and the test doc `docs/reliability-test-2026-05-25-gpu-power-on.md`
- Produce a head-to-head comparison

**Output:** `audit/gpu-operator/CONSOLIDATED.md` with this structure:

```markdown
# GPU Operator audit — comparison + recommendations

## TL;DR (5 bullets — top recommendations)

## Comparison table — patterns we have vs. they have

| Concern | Our injector | GPU Operator | Should we adopt? |

## What we should adopt (ranked by leverage)
(per recommendation: rationale, code-touch surface, risk, leverage)

## What we deliberately do NOT adopt (and why)
(things that don't fit our eGPU / single-node / TB constraints)

## What we genuinely have to invent (they don't address it)
(eGPU hotplug, TB tunnel recovery, the D-3 problem class)

## Mapping to surfaced gaps
| Gap | What gpu-operator does | Our action |
| D-1 stale label | (their approach) | (what we'd do) |
| D-2 liveness-crashloop | (their approach) | (what we'd do) |
| D-3 PCIe non-recovery | (their approach — likely no equivalent) | (informed by separate TB research) |

## Concrete patch candidates for injector
(list of specific changes with one-line summaries — NOT detailed patches, just the candidate list for the design conversation that follows)

## Open questions
```

---

## Phase 4 — Design conversation (with user)

After synthesis lands, we have a real comparison doc.\
At that point:

1. User reviews `CONSOLIDATED.md`
2. User picks which recommendations to adopt
3. ONLY THEN do we touch any injector code

Per user direction this morning: *"I want to discuss hardening design before we commit to changes."* This plan honors that.

---

## Why four subagents and not one

Single-subagent scope would be too large:
- gpu-operator repo is ~50k lines of Go + Helm + shell
- Driver container subrepo is another ~5k lines
- 5 years of issues = thousands of closed tickets

Four parallel subagents fit each scope into a single context window with room for actual analysis.\
Synthesis subagent reads pre-digested reports rather than raw repo, which fits its scope cleanly.

---

## Hard rules for all subagents

- Read-only on the local gpu-operator clone (no modifications)
- Read-only on our k8s-vllm repo (the audit informs design; doesn't change code yet)
- All output to `audit/gpu-operator/` subdir
- No `gh repo fork` of the operator (already done in Phase 1)
- No execution of any operator code locally
- Cite source files with paths + line numbers where load-bearing
- Quote actual code where load-bearing (don't paraphrase critical state machines)

---

## Open questions to resolve before dispatch

1. **Pin to which gpu-operator version?** Latest stable, or whatever matches a specific k3s/k8s version compatibility window we care about? My lean: latest stable (their most-current best practices).
2. **Should G4 (issue mining) cover only the operator repo, or also `nvidia-container-toolkit` and `driver-container-images`?** My lean: just operator repo, narrowly scoped.
3. **Should we time-box G4 to the last 2 years instead of 3?** 5-year history may include patterns no longer relevant (older k8s versions, older operator architectures). My lean: 2-3 year window.
4. **Output language:** strict markdown reports, or include a JSON appendix per subagent for machine-readable comparison? My lean: markdown only — humans (you and me) are the readers.

---

## Estimated cost

- Phase 1 (orient): ~10 min synchronous
- Phase 2 (4 parallel subagents): ~45 min wall-clock (run concurrently)
- Phase 3 (synthesis): ~30 min
- Phase 4 (design conversation): bounded by your availability

Total Opus compute: ~3-4 hours.\
Total wall-clock with our scheduling: 1-2 days including review.\
Outputs are durable repo artifacts (`audit/gpu-operator/`) we keep for future reference.
