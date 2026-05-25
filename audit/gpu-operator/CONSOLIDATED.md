# M2 — NVIDIA GPU Operator audit, consolidated

**Date:** 2026-05-25
**Source reports:** G1 (driver container), G2 (manifests+labels), G3 (controller logic), G4 (issue history)
**Sister research:** M1 (TB/PCIe deep-dive) — see `audit/tb-pcie/CONSOLIDATED.md`
**Trigger:** `docs/reliability-test-2026-05-25-gpu-power-on.md` (4 hardening gaps: D-1, D-2, D-3, D-4)
**Subject of comparison:** `github.com/apnex/nvidia-driver-injector` (entrypoint.sh + k8s/daemonset.yaml) vs `NVIDIA/gpu-operator v26.3.1` + `NVIDIA/gpu-driver-container 25.01.21` + `NVIDIA/k8s-driver-manager` (HEAD `9c55180`).

---

## TL;DR — five highest-leverage takeaways

1. **Delete the injector's `livenessProbe`.** NVIDIA removed exactly this anti-pattern from GDS/GDRCopy sidecars in PR #1317 ("the livenessProbes timeout due to long response times of the `lsmod` commands which have led to undesirable restarts of the container leaving the driver daemonset in a bad state"). The driver container itself has never had one in the window G4 audited. Our `[ -e /sys/module/nvidia/version ]` liveness is the structural twin of the probe NVIDIA retired, and is the direct cause of gap **D-2**. (G1 §"Runtime GPU absence handling", G4 Theme 1, G2 §"Probe configurations")
2. **Adopt a startupProbe with a 20-minute budget** (`initialDelaySeconds:60, periodSeconds:10, timeoutSeconds:60, failureThreshold:120`) as the *only* probe on the driver container, plus a `lifecycle.preStop` hook that runs `cmd_unlabel_node` (we already have the verb). This pair is NVIDIA's canonical pattern and our existing `uninstall` subcommand already does most of the work — we just need to wire it as preStop and keep liveness deleted. (G1 §"Recommended patterns", G2 §"Tier 3").
3. **Split the entrypoint into an init container ("k8s-driver-manager"-style) + a main "driver" container** OR — for a smaller incremental change — add a sidecar/CronJob *reaper* that owns label state during the driver-absent window. The headline architectural finding from G1 is that NVIDIA's reliability comes from the init container, not from the driver container itself. We don't need to copy the full 10-label upgrade dance, but the *shape* — one Pod, one process owns mutation, one process owns kernel — is the lesson. (G1 §"State machine", G3 §"D-2 implications").
4. **Use a host-filesystem readiness file (`/run/nvidia/injector/state`) as the canonical "is the driver up" oracle, not just a node label.** Atomic-write via `tmp+mv`, removed by preStop. NVIDIA's `/run/nvidia/validations/.driver-ctr-ready` is consumed by four separate Pods — for us the consumer is currently only a node label, but a file gives us (a) downstream consumers a stat-able signal, (b) a place to encode failure-mode metadata as structured fields, (c) the "loud signal" lever for **D-4**. (G1 §"Signals emitted", G2 §"Where the logic lives").
5. **Ship a `must-gather.sh`-style debug bundler + structured exit-codes for the entrypoint.** G4's strongest D-4 precedent is k8s-driver-manager PR #166 which rewrote opaque log lines into actionable recovery guidance, and `hack/must-gather.sh` is the canonical "give us details" tool NVIDIA links from every issue. Both are zero-architectural-risk additions that yield disproportionate operator UX returns. (G4 §"Failure-mode-clarity issues")

---

## Comparison table — patterns we have vs they have

| Concern | Our injector today | NVIDIA gpu-operator | Verdict |
|---|---|---|---|
| **Driver container state machine** | Single `entrypoint.sh` does PCI gate → BAR1 verify → build → modprobe → bind → perms → engage-persistence → sleep infinity. 7 phases, all inline, single TU. | Two cooperating containers in one Pod: `k8s-driver-manager` (init, k8s-aware) + `nvidia-driver init` (main, "boring half"). Init owns labels/cordon/drain/idempotency-digest; main owns modprobe. Sequencing is `set -eu`+`\|\| exit 1`; retry granularity is the whole Pod. | **Adapt** — split conceptually even if we stay one-container; at minimum extract a `pre.sh` and `load.sh` so we can later promote `pre.sh` to an init container. |
| **State machine work the entrypoint already does** | Has a real subcommand dispatcher (`load`/`uninstall`/`purge`), explicit safety gates (fuser, refcount), per-step `fail()` with actionable messages. | Single `init()` function, no subcommands, no operator-grade error messages. Recovery actions live in the separate `k8s-driver-manager` Go binary. | **We are ahead here.** Our error messages already exceed NVIDIA's (per G4's k8s-driver-manager PR #166 lament). Don't regress this in any refactor. |
| **Probe configuration: liveness** | `[ -e /sys/module/nvidia/version ]`, 180s+60s×3 (~5 min to detect, then restart) | **NONE on driver container.** Removed from sidecars in PR #1317. Pattern: probes never punish kernel-module owners with restart. Liveness only on DCGM exporter (PR #2175) where restart is safe. | **Adopt NVIDIA's pattern — drop it.** This is the #1 D-2 fix. |
| **Probe configuration: readiness** | `[ -e /sys/module/nvidia/version ]`, 120s+15s | **NONE on driver container.** Readiness is FS-file-based (`/run/nvidia/validations/.driver-ctr-ready`) consumed by other pods' init containers. | **Adapt** — keep our readiness probe (kubelet `Ready` count is useful), but back it with the FS file rather than sysfs, so it matches the source-of-truth used by external consumers (validator-style pods if we ever add them). |
| **Probe configuration: startup** | **NONE** | YES — 20 min budget (`initialDelaySeconds:60, failureThreshold:120, periodSeconds:10, timeoutSeconds:60`), exec script checks `/sys/module/nvidia/refcnt` + `nvidia-smi`, writes the FS marker. | **Adopt verbatim** — exact numeric values + script shape. |
| **Probe fault-tolerance idiom** | N/A (probes are dumb checks) | `probe_nvidia_peermem` returns 0 when MOFED is absent ("skipping probe to avoid container restarts"). Probes do NOT fail when their precondition is absent. | **Adopt the idiom** — if we ever add a probe that depends on TB tunnel or PCIe enum, it must return 0 when those are absent, not 1. The PCI gate already exits cleanly (`exec sleep infinity`) which is the same philosophy applied to the entrypoint; extend it to probes. |
| **Node labels — namespace** | `nvidia.driver/state=ready`, `nvidia.driver/version=…` (our own namespace) | `nvidia.com/gpu.present`, `nvidia.com/gpu.deploy.<10 components>`, `nvidia.com/gpu.workload.config`, `nvidia.com/gpu-driver-upgrade-state` (+ ~6 more). All `nvidia.com/` — owned by NVIDIA/NFD/GFD. **NO `nvidia.com/gpu.driver.ready` label exists.** | **Keep our namespace; do NOT squat `nvidia.com/`.** G2's tier-2 explicit recommendation. Our semantics (label = currently-working) diverge from NVIDIA's (label = aspirational). |
| **Node labels — semantic** | "Currently working" — set after a successful load, removed on uninstall. Stale during driver-absent window (D-1). | "Operator desires this" — set by controller from CR + NFD signal, NOT cleared on driver crash. NVIDIA's design intentionally lets the resource-not-advertised path (`nvidia.com/gpu` resource missing from kubelet) act as the schedule fence — see #1391 "working as intended". | **Inverted.** Our model is observational; NVIDIA's is aspirational. We cannot mirror NVIDIA's pattern because our consumer contract uses `nodeSelector`, not `resources.limits[nvidia.com/gpu]`. The fix for D-1 must come from US, not by copying upstream. |
| **Node label drift — who reconciles?** | Pod sets on success, removes on `cmd_unlabel_node`. No re-reconciliation if something else mutates the label. | `labelGPUNodes()` re-asserts every reconciliation (5s requeue on not-ready); Node-Update events with label-filter trigger immediate convergence. PATCH semantics (PR #1873) to survive concurrent writes. | **Adopt PATCH semantics** when we move to (or add) a reconciler. We already use `kubectl label --overwrite` which is closer to PATCH than UPDATE, but a controller would need explicit `client.Patch` with `MergeFrom`. |
| **Node taints — what NVIDIA applies** | None | **None.** Surprise finding. They define `nvidia.com/gpu:NoSchedule` as the *convention* admins use, and every operand DS *tolerates* it, but the operator never sets it. | **Same — adopt.** Add the canonical `nvidia.com/gpu:NoSchedule` toleration (we currently tolerate `operator: Exists` which is overly broad). Don't auto-apply a taint. |
| **Pod placement — which DS lands on which node** | `nodeSelector: {}` + `tolerations: operator: Exists` (universal). PCI gate inside container → `sleep infinity` exit if no GPU. | `nodeSelector: nvidia.com/gpu.deploy.driver=true` (canonical, controller-managed). Operator front-loads the decision; the pod assumes the world is correct. | **Adopt the key, manually for now.** G2 tier-1: even for single-node, standardise on `nvidia.com/gpu.deploy.driver=true` so a future N>1 doesn't require a schema change. Manual `kubectl label nodes <self> nvidia.com/gpu.deploy.driver=true` until we have a controller. |
| **Failure surfacing — exit codes** | `fail()` always `exit 1`; PCI-absent gracefully `exec sleep infinity` so pod doesn't crashloop on a GPU-less node | All paths `exit 1`. No distinguishing codes. | **We can do better than NVIDIA here.** G3 §"D-4 implications" recommends structured exit codes (10=module-load, 11=GSP-fw, 12=PCI, 13=WPR2, 14=nvidia-smi hang, 15=runtime probe). Each kubelet `BackOff` event then carries the code in `lastState.terminated.exitCode` and becomes greppable. |
| **Failure surfacing — events** | None (kubelet emits its own BackOff/Started/Killing) | **Zero from the operator** in steady state (only the vendored upgrade lib emits events during cordon/drain). G3's grep is decisive: "zero hits" on `recorder.Event` in controllers/. | **Beat upstream.** A tiny in-controller event emitter (~50 LOC, per G3) would put us ahead. Defer until we add a controller; meanwhile use `/dev/kmsg` writes as a journald-resident signal so failures survive pod replacement. |
| **Failure surfacing — readiness file** | None | `/run/nvidia/validations/.driver-ctr-ready` written atomically via `tmp+mv`, removed by preStop, consumed by 4+ pods. Contents encode feature flags (`GDRCOPY_ENABLED` etc.) that validator parses. | **Adopt** — write `/run/nvidia/injector/state` with `phase=`, `last_error=`, `version=` fields. Mirror their atomic-write idiom. |
| **Failure surfacing — debug bundle** | None | `hack/must-gather.sh` (~12 KB), linked from every issue, captures operator logs, DS pod logs, CR YAML, node descriptions, configs. PRs add coverage incrementally (#2097, #1454). | **Adopt — high leverage / low risk.** Our analog bundles `dmesg \| grep -iE 'nvidia\|pcieport\|thunderbolt'`, `lspci -vvv` on bridge + GPU, sysfs PCIe state, `boltctl list`, `journalctl -k`, last K lines of container logs, modinfo, version+digest of patched modules. |
| **Failure surfacing — Prometheus metrics** | None | 17 gauges/counters. ALL measure operator activity, not operand health. No `driver_pod_restart_count`, no `driver_pod_failure_mode`. | **Beat upstream when we add metrics.** Per G3's recommendation: `injector_failure_mode_total{mode="..."}` and `injector_phase_duration_seconds{phase="..."}` from day one. |
| **Crash recovery — operator-level** | None (kubelet's exponential backoff) | None (kubelet's exponential backoff). G3 was decisive: zero `RestartCount` checks anywhere in `controllers/`. The "operator state machine" is a status-reflector, not an interventionist. | **Inverted opportunity.** A small `RestartCount`-aware force-cycler (~300-500 LOC controller per G3) would put us ahead of upstream. Defer; documented as a candidate, not a Sub-Cycle 5 item. |
| **Crash recovery — hardware probes** | `usr/local/sbin/` ships bridge-link-cap, m-recover (patch A1+A2), engage-persistence. These are *one-shot or systemd-timer*, not driven by container restart events. | None. NVIDIA's operand is purely a userspace build problem; they have nothing analogous because they don't have eGPU semantics. | **We are ahead.** Don't lose this — any reorg of the entrypoint must keep the bridge-link-cap and m-recover paths reachable. |
| **Crash recovery — held-modules-block-restart** | `cmd_uninstall` refuses when `fuser` reports holders; `purge` is the explicit teardown. | Same fundamental problem (G4 #2166 "Driver Pod Restart Causes Init:CrashLoopBackOff When GPU Workloads Are Running"). NVIDIA's answer: "use the upgrade controller, not pod restart." | **Same — keep our safety gates.** Our `fuser` + refcount checks in `cmd_uninstall` are the right pattern. |
| **DKMS handling** | Memory note: vanilla `nvidia.ko.xz` collision. No proactive purge in the container. | Active purge in precompiled image: `apt-get purge -y nvidia-dkms-${DRIVER_BRANCH}-server nvidia-kernel-source-${DRIVER_BRANCH}-server` (G1 §"DKMS handling"). | **Adopt as init-time assertion** — entrypoint should `find /lib/modules/${KVER}/extra/ /lib/modules/${KVER}/updates/dkms/ -name 'nvidia*.ko*'` and either fail loudly or purge with explicit `WARN`. Our memory note documents the trap; the container should detect it. |
| **Kernel-update hook** | apply.sh installs cmdline + modprobe.d at host bring-up; no DKMS-style postinst hook. | `_write_kernel_update_hook` creates `/run/kernel/postinst.d/update-nvidia-driver` that `nsenter`s into the running container and `nvidia-driver update --kernel ${NEW_KVER}`. ERR traps to `exit 0` so apt transaction succeeds. | **Consider** — would let a Fedora `kernel-core` update auto-rebuild without operator action. Risk: if rebuild fails, container is wedged at old-kernel; would still need next reboot. Probably defer until we hit it operationally. |
| **Rollout strategy** | `RollingUpdate, maxUnavailable: 1` | **`OnDelete`** — hard-coded *and* enforced in controller code (rejects RollingUpdate). They drive per-node sequencing via `gpu-driver-upgrade-state` label state machine. | **Adopt OnDelete + document the manual sequence** (`kubectl delete daemonset + apply`). Already the documented path per our daemonset.yaml comment. Single-node makes it academic today, but standardising removes a future trap. |
| **RBAC scope** | `get, patch` on `nodes` (we don't drain or cordon) | `get, list, patch, update, watch` on `nodes`; `get, list, delete, eviction` on `pods`; `daemonsets get, list` | **Stay narrow.** Our scope is appropriately bounded. If we add a reaper or controller, expand only as needed. |
| **Idempotency** | PCI gate skips load if `lsmod` already shows nvidia (the `load_module` "already loaded — skipping" branch). | `DRIVER_CONFIG_DIGEST` env-var hash vs on-disk digest decides "skip uninstall" (G1 §"Recommended patterns" item 7). Recently narrowed to install-relevant fields only (PR #2147 — over-broad digest was the bug). | **Consider for a future reorg.** Encode "what the loaded driver should look like" as a digest (version + module options + patch set fingerprint), persist on disk, only mutate kernel if digest changed. Would defuse a class of "spurious reload after pod restart" scenarios. |

---

## What we should adopt (ranked by leverage)

### Rank 1 — Drop the livenessProbe; add a startupProbe; wire preStop

**Rationale.** G4's strongest single finding is that NVIDIA explicitly retired exactly our pattern (PR #1317) with explicit reasoning that matches our D-2 symptom. G1 confirms the architectural philosophy: kernel-module owners must not be punished with restarts because the recovery action (restart) is harmful (held modules → rmmod fails → crashloop). G2 documents the exact replacement parameters (`initialDelaySeconds:60, periodSeconds:10, timeoutSeconds:60, failureThreshold:120` = 20-min budget). Our `cmd_unlabel_node` already exists; lifecycle.preStop just calls it.

**Code-touch surface.**
- `k8s/daemonset.yaml`: delete the `livenessProbe` block; replace with `startupProbe` of the same shape but matching NVIDIA's parameters; add `lifecycle.preStop.exec.command` running `/entrypoint.sh unlabel-only` (a new minor subcommand that is `cmd_unlabel_node` without rmmod).
- `entrypoint.sh`: small new subcommand `unlabel-only` or inline the preStop logic.
- Keep the `readinessProbe` for kubelet `Ready` count.

**Risk.** Low. We're aligning with upstream-validated pattern. Main risk: the entrypoint's `sleep infinity` line at the end of `load` becomes the steady-state — if it ever exits unexpectedly the pod will not restart cleanly. Mitigation: a periodic `nvidia-smi` sanity check could go in a `readinessProbe` *with* the precondition-absent-returns-0 idiom from `probe_nvidia_peermem`.

**Leverage.** Addresses **D-2** directly. Also indirectly fixes D-1 (because removing liveness means we stop having a "pod restarts → label stale" cycle; the label is stale only between a true `uninstall` and the next `load`, which is the lifecycle.preStop window).

### Rank 2 — Add a readiness-file oracle (`/run/nvidia/injector/state`)

**Rationale.** G1 §"Signals emitted" + G2 §"Where the logic lives" agree: NVIDIA's reliability multiplier is a filesystem marker, not a node label. The file is stat-able by anything on the host, can encode structured state, survives the apiserver being unreachable, and the atomic-write idiom (`tmp+mv`) means consumers never see a half-written value. The label remains for k8s-native consumers; the file is the source of truth for everyone else.

**Code-touch surface.**
- `entrypoint.sh`: after each phase, write `/run/nvidia/injector/state` with `phase=<name>` and `last_error=…` if appropriate. Use `tmp+mv`.
- `entrypoint.sh`: `cmd_unlabel_node` also `rm -f` the file.
- `k8s/daemonset.yaml`: bind-mount `/run/nvidia` from the host (already implicit via privileged + /dev mount, but make it explicit).
- Document the file format in `docs/consumer-contract.md`.

**Risk.** Low. Additive only; doesn't replace anything.

**Leverage.** Addresses **D-4** (failure modes now have a stat-able home with structured fields). Lays groundwork for a future controller to consume.

### Rank 3 — Structured exit codes + `/dev/kmsg` first-failure markers

**Rationale.** G3 §"D-4 implications" and G4 §"Failure-mode-clarity issues" converge: a single `exit 1` is information-poor. Distinct exit codes per failure mode make kubelet `lastState.terminated.exitCode` greppable. A `/dev/kmsg` write on first observation puts the failure in `dmesg` where it survives pod replacement and is captured by every observability stack on the planet.

**Code-touch surface.**
- `entrypoint.sh`: replace single `fail()` with `fail_with_code <code> <message>`. Define an enum file `entrypoint-exit-codes.sh` sourced at top.
- `entrypoint.sh`: on each distinct failure mode, write `printf 'INJECTOR_FAIL: mode=%s ver=%s\n' "$mode" "$VERSION" > /dev/kmsg` before `exit`.
- Update G1-style table in `docs/consumer-contract.md` mapping code → failure → recovery guidance.

**Risk.** Low. Pure additive; existing `exit 1` callers can be migrated incrementally.

**Leverage.** Addresses **D-4** in a way that doesn't depend on any controller — every existing log scraper, every kubectl describe, every dmesg grep becomes a usable diagnostic interface.

### Rank 4 — Adopt canonical labels/toleration for future N>1; rewrite our toleration to be specific

**Rationale.** G2's tier-1 finding: the *gating mechanism* (nodeSelector matching a canonical key + canonical toleration) is what aligns us to the ecosystem, not stealing label keys NVIDIA never defined. Our current `operator: Exists` (no key) tolerates *all* taints, which is wider than the NVIDIA convention.

**Code-touch surface.**
- `k8s/daemonset.yaml`:
  ```yaml
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
    # Plus a control-plane toleration if/when we add non-control-plane nodes
  nodeSelector:
    nvidia.com/gpu.deploy.driver: "true"  # operator sets manually on single-node
  ```
- `scripts/apply.sh`: add a step that runs `kubectl label node $(hostname) nvidia.com/gpu.deploy.driver=true --overwrite` when k3s is detected.
- `docs/consumer-contract.md`: document this is an *added* gate (we still emit our own `nvidia.driver/state=ready` label for downstream consumers; the new key just gates *us*).

**Risk.** Low; single-node makes it academic but removes a future trap. Watch: if the user removes the label, our DS stops scheduling — surfaces as `0 pods scheduled` instead of crashloop, which is louder.

**Leverage.** No direct gap mapping; ecosystem alignment + future-proofing. The G2 §"Recommended adoption" tier-1 list.

### Rank 5 — Ship a `must-gather.sh` analog

**Rationale.** G4's lowest-cost / highest-leverage D-4 finding. Validated under hostile production conditions. We have all the data sources already; we just need to bundle them.

**Code-touch surface.**
- New `scripts/must-gather.sh` that captures: `dmesg | grep -iE 'nvidia|pcieport|thunderbolt|aer'`, `lspci -vvv` on bridge+GPU BDFs, `cat /sys/bus/pci/devices/${EGPU_BDF}/*` (selected files), `boltctl list -a`, `journalctl -k --since '-2 hour'`, last 500 lines of `kubectl logs ds/nvidia-driver-injector -n kube-system`, `kubectl get nodes -o yaml`, `kubectl get pods -A -o wide`, `modinfo nvidia`, `cat /etc/modprobe.d/nvidia-driver-injector.conf`, `cat /proc/cmdline`, our patch-version digest. Tarballs to `/tmp/injector-must-gather-$(date +%s).tar.gz`.
- Reference from `docs/troubleshooting.md` (which may need to be created) and from every `fail()` message that the user is likely to see.

**Risk.** Trivial.

**Leverage.** Addresses **D-4** — every issue report can include a single artifact instead of N back-and-forth requests for "can you also send …".

### Rank 6 (deferred but listed) — Init container split

**Rationale.** G1 §"State machine" is unambiguous that this is the *architectural* lesson. The current `entrypoint.sh` is monolithic; the long-term shape is `pre.sh` (idempotency check, label-pause, DKMS-collision-purge, drain consumer GPU pods if any) + `load.sh` (build + modprobe + perms + engage). The split allows preStop on the main container to be terse while the pre-flight is rich.

**Code-touch surface.** Significant — split `entrypoint.sh` into two scripts, refactor `k8s/daemonset.yaml` to have `initContainers:` + `containers:`, update Dockerfile to copy both.

**Risk.** Medium — refactor risk in a load-bearing component. Worth doing in its own sub-cycle, not bundled with the probe fix.

**Leverage.** Indirectly addresses D-1, D-2, D-4 by giving us a clean place to put state-management without polluting the modprobe path.

---

## What we deliberately do NOT adopt (and why)

1. **`nvidia.com/gpu.driver.ready` label.** Does not exist in v26.3.1. G2 §"Tier 2" explicit: NVIDIA squats the `nvidia.com/` namespace, inventing keys there risks future collision. Keep `nvidia.driver/state=ready` in our own namespace.

2. **The 10-component `nvidia.com/gpu.deploy.<component>=paused-for-driver-upgrade` label pause dance.** Useful for NVIDIA's multi-operand topology (validator, toolkit, device-plugin, GFD, DCGM, MIG-manager, sandbox-plugin, vGPU-manager, kata-manager, cc-manager). We have one operand (vLLM). Single-label state suffices.

3. **`Ready`/`Error` two-condition mutex.** G3 §"Degraded state modeling" — binary toggle loses information, NVIDIA's known weakness. If we add Status.Conditions, use the OpenShift four-condition pattern (`Available`/`Progressing`/`Degraded`/`Upgradeable`) or our own enumeration.

4. **`DaemonSet.Status` aggregates as the sole readiness signal.** G3 calls this out as a NVIDIA anti-pattern — a coarse aggregate that loses per-pod failure-mode information. We already inspect pod state in detail when needed; don't regress to upstream's coarseness.

5. **Reliance on `resources.limits["nvidia.com/gpu"]: 1` as the schedule fence.** This is NVIDIA's implicit assumption that makes their no-label-cleanup design work. Our consumer contract uses `nodeSelector`, not GPU resource requests — which is the exact divergence that makes D-1 a real bug for us but not for NVIDIA. Don't pretend we can copy their semantics; design for our own.

6. **DKMS-style postinst hook with nsenter.** G1 documents this works for NVIDIA but the ERR-trap-to-exit-0 means apt succeeds while container is wedged — a footgun. We already document "reboot after kernel update" operationally. Defer.

7. **DCGM-exporter-style aggressive liveness on the driver container.** PR #2175 added liveness *only* to a userspace component (the metrics scraper). Don't generalize that to kernel-module owners; the same PR that demonstrates upstream knows when liveness is appropriate also demonstrates they keep it off the driver.

8. **Anything matching `Resources.Taint` (`controllers/resource_manager.go:60`).** G2 confirmed it's dead code in v26.3.1. Don't taint nodes from the injector.

---

## What we genuinely have to invent (no upstream precedent)

### D-3 — runtime PCIe-tunnel non-recovery from chassis power-cycle

**Deferred to M1.** G4 §"TB / eGPU / hotplug issues" explicitly: zero issues mention `thunderbolt`, `TB3`, `TB4`, `external GPU`, `eGPU`. NVIDIA's controller assumes monotonic node-to-GPU mapping. Nothing to adopt. M1's `CONSOLIDATED.md` proposes Option B (in-container watcher) + Option F (operational doc) as the path. Listed here only for completeness.

### Per-failure-mode metrics + events with stable Reason enum

G3 §"D-4 implications" + Theme 1: NVIDIA has neither a per-failure-mode counter nor distinct event Reasons. We could ship `injector_failure_mode_total{mode="..."}` from day one and emit typed Events on first observation. No precedent to copy; we get to define the schema.

### `RestartCount`-aware force-cycler

G3 §"D-2 implications" is explicit: a controller that watches our DS's pods, detects "stuck in CrashLoopBackOff for >N min with RestartCount delta", and **deletes the pod** to bypass kubelet's 5-min exponential backoff cap would be a step *ahead* of upstream. Combined with a cooldown / circuit-breaker that flips to `Degraded` after K attempts. Sized at ~300-500 LOC controller-runtime in G3.

### Hardware-recovery probes between attempts

Our `usr/local/sbin/bridge-link-cap` and m-recover (patch A1+A2) are already hardware-aware recovery. Wiring them into a force-cycler's between-attempts step is novel — NVIDIA has nothing analogous because their operand isn't hardware-recovery-aware.

---

## Mapping to surfaced gaps

| Gap | What gpu-operator does | Direct lesson | Recommended injector action | Priority |
|---|---|---|---|---|
| **D-1** stale node label `nvidia.driver/state=ready` during driver-absent window | Refuses to clean up labels on uninstall (#1391 "working as intended"). Their fence is resource-not-advertised + label-as-aspiration. | NVIDIA's pattern doesn't apply — we use `nodeSelector` not `resources.limits[nvidia.com/gpu]`. We have to clean up ourselves. The `lifecycle.preStop` + drop-liveness combo from Rank 1 narrows the window from "indefinite while liveness loops" to "while the user manually `kubectl delete`s". For the absent-host-driver case (the actual D-1 timeline), a tiny reaper Pod or a `RestartCount`-aware sidecar that calls `kubectl label nodes ... nvidia.driver/state=degraded` after N seconds of pod-not-ready is the right shape. | (a) Rank 1 first (closes the lifecycle.preStop hole); (b) reaper/controller for the absent-host-driver case, sized in Rank 6 deferred bucket. | **High** |
| **D-2** liveness-crashloop | PR #1317 deleted the equivalent probe. Driver container has *no* liveness, only 20-min startupProbe. | Delete our liveness; adopt 20-min startupProbe verbatim; wire preStop. | Rank 1. | **High — top priority** |
| **D-3** PCIe non-recovery | (defer to M1) | (defer to M1) | (defer to M1 — Option B in-container watcher + Option F doc per M1 §"Recommendation") | **High but in M1's domain** |
| **D-4** buried failure modes | Has FS-marker pattern, has must-gather.sh, has stable Reason consts. Lacks per-failure metrics, lacks distinct exit codes, lacks structured events in steady state. | Adopt their good patterns (FS marker, must-gather), beat them on their weak ones (exit codes, /dev/kmsg, future per-mode metrics). | Ranks 2, 3, 5. | **Medium-high** |

---

## Concrete patch candidates for injector

(One-line summaries for the design conversation. Detailed patches come after the user picks.)

1. **PC-1 — Replace livenessProbe with startupProbe in injector DaemonSet** (G2 + G4 PR #1317; addresses D-2). Drop the liveness block in `k8s/daemonset.yaml`, replace with NVIDIA-canonical `startupProbe` (60s+10s×120, ~20 min budget). Low risk. Highest leverage.

2. **PC-2 — Add `lifecycle.preStop` hook that unlabels the node** (G1 §"Recommended patterns" item 2; addresses D-1's "graceful stop" lane). Wire `cmd_unlabel_node` (already exists in entrypoint.sh) to preStop. Low risk. Narrows D-1 window.

3. **PC-3 — Add FS readiness oracle `/run/nvidia/injector/state` with atomic write** (G1 + G2; addresses D-4). Structured fields: `phase=`, `last_error=`, `version=`, `loaded_at=`. Mirrors NVIDIA's `tmp+mv` idiom. Low risk, additive.

4. **PC-4 — Structured exit codes + `/dev/kmsg` first-failure markers** (G3 + G4; addresses D-4). New `entrypoint-exit-codes.sh` enum sourced by entrypoint; every `fail()` callsite gains a code; first observation writes a kmsg line. Low risk. Operator-UX win.

5. **PC-5 — Ship `scripts/must-gather.sh`** (G4 §"Failure-mode-clarity issues"; addresses D-4). Bundles dmesg+lspci+sysfs+boltctl+kubectl-logs+modinfo+digest. Low risk, trivial. Cited from every fail() message.

6. **PC-6 — Adopt canonical `nvidia.com/gpu:NoSchedule` toleration; consume `nvidia.com/gpu.deploy.driver=true` nodeSelector** (G2 §"Tier 1"; ecosystem alignment, no direct gap). Tightens our toleration from "everything" to canonical. `apply.sh` sets the label on k3s detection. Low risk.

7. **PC-7 — DKMS-collision pre-flight assertion** (G1 §"DKMS handling"; addresses our memory-noted trap). Entrypoint asserts no `nvidia*.ko*` exists under `/lib/modules/${KVER}/extra/` or `/updates/dkms/` from a non-injector source; either fail loudly or purge with `WARN`. Low risk.

8. **PC-8 — Init-container split (defer, sub-cycle 5+)** (G1 §"State machine"; sets the stage for D-1 reaper + future controller). Split entrypoint into `pre.sh` (init container) and `load.sh` (main container). Medium risk, refactor scope. Hold until probe + FS-marker land.

9. **PC-9 — In-cluster reaper or `RestartCount`-aware controller (defer to design call)** (G3 §"D-2 implications"; closes D-1 fully + adds bypass for kubelet 5-min backoff). ~300-500 LOC controller-runtime, OR a much smaller CronJob/sidecar that polls and `kubectl label nodes ... nvidia.driver/state=degraded` after N seconds pod-not-ready. The CronJob path is two orders of magnitude smaller. Medium-low risk for CronJob; medium for controller.

10. **PC-10 — Switch DaemonSet `updateStrategy` to `OnDelete`** (G2 §"Multi-node rollout"; addresses a future N>1 footgun). Single-node makes it academic; standardising now means the documented `kubectl delete daemonset + apply` upgrade path is enforced. Low risk.

11. **PC-11 — Probe fault-tolerance idiom for any future probe** (G1 + G4 PR #1317; documentation only today). If we add any new probe, it must return 0 when its precondition is absent. NVIDIA's `probe_nvidia_peermem` is the reference implementation. Zero risk.

12. **PC-12 — Per-failure-mode Prometheus counter (defer)** (G3 §"D-4 implications"). `injector_failure_mode_total{mode="..."}`, `injector_phase_duration_seconds{phase="..."}`. Requires we either expose a metrics endpoint from a sidecar or have a controller scrape FS state. Defer until we have a controller. Medium risk (new dependency surface).

---

## Recommended design conversation topics for the user

These are the calls only the user can make. Each has a proposed lean based on the audit synthesis above.

**Q1. Probe philosophy — drop liveness entirely, or replace with a safer one?**
*Proposed lean:* drop entirely (PC-1). NVIDIA's PR #1317 evidence is dispositive. Add structured readiness via FS marker (PC-3) for richer signal without restart consequences.

**Q2. D-1 reaper approach — preStop only, or preStop + CronJob/controller?**
*Proposed lean:* preStop (PC-2) now closes the graceful-stop lane. For the absent-host-driver lane (the actual test scenario), start with a small **CronJob** that watches DS pod status and labels accordingly — ~50 lines of bash, deployable as a single manifest, deletable when we ship a real controller. Promote to controller (PC-9) only if we hit operational pain.

**Q3. Init container split now, or after probe/FS-marker land?**
*Proposed lean:* after. PC-1, PC-2, PC-3, PC-4, PC-5 are all surgical and low-risk; the init split (PC-8) is a refactor that benefits from those landing first.

**Q4. Adopt the canonical NVIDIA toleration/nodeSelector for future-proofing?**
*Proposed lean:* yes (PC-6). Tightens our toleration scope, gives a future N>1 a clean migration. apply.sh sets the label on k3s detection so single-node UX doesn't change.

**Q5. Exit-code enum + /dev/kmsg writes — adopt now?**
*Proposed lean:* yes (PC-4). High leverage, low risk, plays well with kubelet's `lastState.terminated.exitCode` and every observability stack.

**Q6. must-gather.sh — adopt now?**
*Proposed lean:* yes (PC-5). NVIDIA's most-load-bearing operator-UX tool. We have all the inputs already.

**Q7. OnDelete update strategy now, or wait for N>1?**
*Proposed lean:* now (PC-10). The documentation already says "delete + apply"; the manifest should enforce it. Standardising eliminates a future trap.

**Q8. Do we want any new controller code, or stay manifest-only?**
*Proposed lean:* manifest-only for sub-cycle 5. Defer the controller (PC-9, PC-12) to a later sub-cycle when the FS marker (PC-3) is consumable. A CronJob bash reaper is the bridge.

**Q9. Should D-1 be addressed by changing the label *semantics*, not just adding cleanup?**
*Proposed lean:* keep observational semantics (label = currently-working) but make it *eventually consistent* via the FS marker + reaper. Aspirational semantics (NVIDIA's choice) would require us to redesign the consumer contract; not worth it for one consumer (vLLM).

---

## Open questions / things the audit couldn't resolve

1. **v26.3.0 "don't reinstall driver on container restart" feature** — G4 saw it cited in three closing comments (#2166, #2433, k8s-driver-manager #166) but the corresponding PR wasn't located. Description matches exactly what we'd want for D-2 (probes restart container; driver stays loaded). Worth tracking when it lands — could supersede some of our adoption picks.

2. **Whether NVIDIA's `lifecycle.preStop` runs cleanly during kubelet eviction** (vs only `docker stop`-class). If the host is hard-rebooted, preStop doesn't fire — so PC-2 closes the graceful lane only. The reaper (PC-9) is the hard-reboot answer.

3. **Whether the FS-marker pattern survives container image upgrades.** The file lives under `/run` which is tmpfs on most distros — survives container restarts within a boot, but cleared at reboot (correct). We need to verify this matches our expected semantics; if we want survival-across-reboots, file goes under `/var/lib/nvidia-injector/` instead.

4. **Does NVIDIA's startupProbe-only design tolerate a TB-tunnel-vanishes mid-workload scenario?** G1's §"Runtime GPU absence handling" says "Short answer: there is none" — they assume traditional PCIe. Our injector does *not* face the same constant — TB chassis power-cycle is a real scenario. The probe pattern is still right (don't punish kernel-module owners with restarts) but the policy gap (what *does* respond?) is ours to fill, likely via PC-3 + reaper + the M1 watcher.

5. **`lifecycle/stale` bias in our G4 issue sample.** G4 flagged that issues close at 120 days no-activity; some "fixed" patterns we'd want to study may have just timed out. Re-check #705 ("driver re-installed every reboot") periodically — if it ever moves, the persist-driver-root design might inform our DKMS-collision pre-flight (PC-7).

6. **Whether `must-gather.sh`'s contents change with operator version.** G4 noted PRs incrementally add coverage (#2097, #1454). We'd want a similar living document — every time we add an observability surface, it goes in must-gather. Worth a checklist in `docs/` rather than a one-shot script.

7. **Whether our existing `usr/local/sbin/bridge-link-cap` and m-recover (A1+A2) should be invoked from the entrypoint, or remain host-systemd-owned.** Currently they're host services. NVIDIA has nothing equivalent. Folding them into the container's preflight would let an init-container-split (PC-8) run them in the pod context; keeping them on the host means they fire before the container starts. Probably the latter remains correct — they're recovery primitives, not application logic.

8. **Whether to ship a tiny `NVIDIADriver`-style CRD now or stay manifest-only.** G3 calls out that adding a CRD would let us carry `Status.Conditions`, `Status.Conditions[].Reason` from a stable enum, and structured per-failure-mode info. But it adds a controller dependency. Probably defer until PC-9's controller question is decided; manifest + FS marker is a fine bridge.

9. **The `nvidia.com/gpu-driver-upgrade-enabled` annotation pattern.** Not in our scope, but if we ever add multi-version coexistence, this is the precedent. Out of scope for sub-cycle 5.

---

## Cross-cutting note on superseded patches

The Rank 1 probe + preStop design interacts with the "close-path mitigated 2026-05-08" finding (patch 0029). 0029 made nvidia-smi safe; it does NOT make liveness-probe-driven restarts safe — those still fail because of held modules, exactly per G4 #2166. The two are complementary: 0029 lets nvidia-smi run inside the container; PR #1317-style probe removal prevents the restart loop.
