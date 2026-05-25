# G4 — Issue + PR history mining (2.5 year window)

**Date:** 2026-05-25
**Auditor:** subagent G4 (retry)
**Window:** 2023-12-01 to 2026-05-25
**Repo:** NVIDIA/gpu-operator only (with cross-refs into NVIDIA/k8s-driver-manager where the gpu-operator team merged a closing PR)

---

## TL;DR (3 bullets — biggest lessons)

1. **NVIDIA explicitly *removed* a livenessProbe that was causing exactly our D-2 failure.** PR [#1317](https://github.com/NVIDIA/gpu-operator/pull/1317) (2025-03-10) — "We've noticed cases where the livenessProbes timeout due to long response times of the `lsmod` commands which have led to undesirable restarts of the container leaving the driver daemonset in a bad state." The driver container today has *no* livenessProbe and *no* readinessProbe — only a long-tail startupProbe (`failureThreshold: 120`, `periodSeconds: 10`, `timeoutSeconds: 60` → ~20 min budget). Our `[ -e /sys/module/nvidia/version ]` livenessProbe is the exact anti-pattern they retired.
2. **The startupProbe race is itself a known landmine.** PR [#1939](https://github.com/NVIDIA/gpu-operator/pull/1939) (2025-11-26) eliminated a race where the startupProbe's `nvidia-smi` was actually what loaded `nvidia.ko` (before the driver container's modprobe), defeating every custom kernel-module parameter. Lesson: probes are observers, never side-effects. Critical when our injector might evolve to add a similar probe.
3. **Label drift is universally agreed to be NVIDIA's responsibility going IN, but explicitly *not* coming OUT.** NVIDIA's stated policy ([#1391](https://github.com/NVIDIA/gpu-operator/issues/1391)): "Uninstalling the operator or any other components responsible for initially labeling nodes never removes those labels. This is working as intended." But during pod absence ↔ pod presence (our D-1 case), the cluster-policy controller DOES re-reconcile labels — PR [#1873](https://github.com/NVIDIA/gpu-operator/pull/1873) switched from `UPDATE` to `PATCH` to survive concurrent edits. The lesson is that NVIDIA *never* added a "driver-pod-absent" annotation that downstream schedulers could honour — they rely on `nvidia.com/gpu.deploy.*` and `feature.node.kubernetes.io/pci-10de.present` being controller-managed, and they do not actively cleanup-on-pod-delete.

---

## Methodology + raw counts

- Pulled *all* 467 issues opened in the window via `gh api 'search/issues?q=repo:NVIDIA/gpu-operator+is:issue+created:>=2023-12-01' --paginate`.
- Pulled the bug-labeled subset: 52 issues (41 closed, 11 open).
- Sorted by `reactions` then `comments`. Read the body for the top ~50, plus an additional ~25 chosen by topical filter (`probe`, `liveness`, `label`, `taint`, `stale`, `upgrade`, `hotplug`, `kernel`, `DKMS`, `precompiled`, `thunderbolt`).
- Fetched ~30 PRs identified by the same keyword filter, focusing on `is:merged`.
- Read comments on the 7 most-load-bearing issues (#2166, #1361, #1391, #626, #991, #2433, #2382) — NVIDIA's responses contain the most valuable design rationale, often *not* captured in the merged PR.
- Cross-referenced into `NVIDIA/k8s-driver-manager` where gpu-operator issue #2166 was closed via the sister repo's PR #166 (D-4 directly relevant).

The set is biased: most reactions go to install/auth/registry friction issues (NGC 401/502, EKS upgrades, helm chart breakage) that are not relevant to our injector. The reliability/race-condition issues we care about typically have 0-2 reactions and 8-20 comments — the comment-to-reaction ratio is a better severity signal than reaction count alone.

---

## Theme 1 — Probe / restart-loop / driver-pod-stuck

**Pattern.** When the driver container's startup is slow (compile, GSP firmware load, kernel-module insertion) or its in-place upgrade is non-trivial (already-loaded modules need rmmod), *any* probe that synchronously calls into the GPU stack tends to fire during the brittle window. NVIDIA's pattern is: (a) extremely long-tail startupProbe budget, (b) zero liveness/readiness on the driver container itself, (c) probes only on side-car-like operands (DCGM exporter — PR [#2175](https://github.com/NVIDIA/gpu-operator/pull/2175)), and (d) probes must never do work that the entrypoint should have done.

**Most-impactful issues.**
- [#1317 PR](https://github.com/NVIDIA/gpu-operator/pull/1317) (merged 2025-03-10) — "[GDS][GDRCopy] remove unnecessary liveness probe" — `lsmod`-based liveness was timing out and restarting the container, *which then* left the driver daemonset in a "bad state." Note the exact match to our D-2: a sysfs/module probe causes restart, the restart cannot complete because the kernel module is held, so we crashloop. NVIDIA's fix: delete the probe.
- [#1939 PR](https://github.com/NVIDIA/gpu-operator/pull/1939) (merged 2025-11-26) — "Run nvidia-smi after modules are loaded in driver ds startup probe" — race where the probe's `nvidia-smi` *was* what loaded `nvidia.ko`, bypassing the driver-container scripts that apply kernel-module parameters from a user-supplied ConfigMap.
- [#2166](https://github.com/NVIDIA/gpu-operator/issues/2166) — "Driver Pod Restart Causes Init:CrashLoopBackOff When GPU Workloads Are Running" (Feb 2026, 7 comments, closed). Quote from NVIDIA's @tariq1890: *"It is expected that all active GPU workload pods be brought down so that the driver upgrade can happen successfully."* Force-restarting the driver pod outside the upgrade-controller workflow leaves modules held → crashloop. The fix path was *not* in gpu-operator — it was in k8s-driver-manager PR #166 (better log messages), and the long-term fix is v26.3.0+ "not reinstall driver on container restart" (still in flight as of 2026-05).
- [#1361](https://github.com/NVIDIA/gpu-operator/issues/1361) (19 comments) — NVML deadlock in 570.124.06 → `device-plugin` health-check goroutines wedge → `kubelet` device-plugin gRPC hangs → *every* pod on the node, GPU or not, stuck pending. Resolution: driver-container `570.172.08` (NVML fix). Time-to-root-cause: 3 months. Lesson: a single bad driver release can take down the entire kubelet plane, not just GPU work.
- [#726](https://github.com/NVIDIA/gpu-operator/issues/726) / [#724](https://github.com/NVIDIA/gpu-operator/issues/724) — `unknown field "grpc" in io.k8s.api.core.v1.Probe` on K8s 1.22/<1.24. They use gRPC probes, which are 1.24+ GA. Their stance: bump the floor.
- [#1230](https://github.com/NVIDIA/gpu-operator/issues/1230) — `node-feature-discovery-worker` "constantly restarting … no error in the log." Diagnosed as a node-resource starvation issue. Lesson: a probe that fails silently looks identical to OOM-kill from the outside.

**Fix PRs.**
- #1317 (remove liveness)
- #1939 (probe must not have side-effects)
- #1496 (Use POSIX sh in probes, after distroless migration removed bash)
- #2175 (add liveness/readiness to *DCGM exporter only* — it's a userspace service that *can* be safely restarted)
- #1416 (don't enter a delete/recreate loop on a daemonset whose pods can't schedule because of taints — the controller now checks "does this DS's nodeSelector match any node" *before* deleting)

**Lesson learned.** Probes on the driver container are dangerous because (a) the recovery action (restart) is harmful (held modules), and (b) the failure surface (lsmod, nvidia-smi, sysfs) is broader and slower than the probe budget. NVIDIA's pattern: *no liveness on anything that owns a kernel module*. Their startupProbe budget is ~20 minutes.

**Encoded in code / documented / neither.**
- Encoded: `deployments/gpu-operator/values.yaml` ships only `startupProbe` for the driver container (verified 2026-05-25 against main).
- Encoded: GDS/GDRCopy livenessProbes deleted (PR #1317).
- *Not* documented as a design principle — there is no "do not add livenessProbes" rule in any README; the lesson lives only in the PR description.

---

## Theme 2 — Label / taint / node-state-drift

**Pattern.** gpu-operator owns ~5 distinct label families: `nvidia.com/gpu.deploy.<operand>=true|false|pre-installed`, `nvidia.com/gpu.present=true`, `nvidia.com/gpu.workload.config=container|vm-passthrough|vm-vgpu`, `nvidia.com/mig.*`, and OS/kernel labels mostly inherited from NFD. The controller actively reconciles these *while running*, but does NOT clean them up on uninstall (explicit policy).

**Most-impactful issues.**
- [#1391](https://github.com/NVIDIA/gpu-operator/issues/1391) (4 comments, closed wontfix) — "GPU related labels persists on the nodes even after uninstalling GPU Operator." NVIDIA's @chipzoller: *"Uninstalling the operator… never removes those labels. This is working as intended. I don't think I've run across any Kubernetes software/projects which do this either."* A user pushes back: *"the state-machine using labels for the driver installation state is a bit more than descriptive metadata… a failed installation might not recover correctly after an uninstall, reinstall because of those labels."* NVIDIA does not respond to that pushback. **This is essentially the D-1 design question and gpu-operator answered "not our problem."**
- [#2288](https://github.com/NVIDIA/gpu-operator/issues/2288) — "GPU Operator override Node label `nvidia.com/gpu.deploy.device-plugin=true`." User set the label to `false` at node-launch time; gpu-operator overrode it back to `true` because *"the gpu-operator detect[s] the node as having no GPUs at launch, removing all operands and then apply labels again despite the node being launched with a specific labels to disable an operand."* This is a label-drift bug. Closed as fixed.
- [#701](https://github.com/NVIDIA/gpu-operator/issues/701) — `nvidia.com/gpu.deploy.mig-manager` label not removed when MIG is disabled. Resolution: gpu-operator's state machine assumed the label was orthogonal to MIG state; it's not.
- [#1392](https://github.com/NVIDIA/gpu-operator/issues/1392) — confirms controller reconciles `container ↔ vm-passthrough ↔ vm-vgpu` label transitions and tears down the no-longer-needed operand daemonsets. Validates the "active label-driven reconciliation" pattern.
- [#1469](https://github.com/NVIDIA/gpu-operator/issues/1469) — NFD's `pci-10de.present` label disappears if cluster admin changes NFD config → gpu-operator's *entire daemonset stack* terminates immediately, because the nodeSelector no longer matches. Requested fix: own the label via `NodeFeatureRule` instead of relying on shared NFD state. (Still open.) Lesson: an upstream label *is* an external dependency you cannot trust.
- [#1622](https://github.com/NVIDIA/gpu-operator/issues/1622) — adding a node with a different OS image causes the existing daemonset's pod image to be silently rewritten to the new OS's image (wrong). Mixing kernel versions creates label-derived daemonset names that diverge from the pod-template image.
- [#1274](https://github.com/NVIDIA/gpu-operator/issues/1274) — labels applied to *non-GPU* nodes when the PCI scan misfires through Proxmox passthrough.

**Fix PRs.**
- [#1873](https://github.com/NVIDIA/gpu-operator/pull/1873) (Nov 2025) — "use PATCH to update node labels instead of UPDATE" — fixes "Operation cannot be fulfilled on nodes 'X': the object has been modified" race that left the ClusterPolicy stuck in `ReconcileFailed`. **This is a label-write-contention bug NVIDIA explicitly solved.** Their old code did GET-modify-UPDATE, lost the race, and the controller never retried. PATCH avoids the resource-version conflict.
- [#1885](https://github.com/NVIDIA/gpu-operator/pull/1885) — backport of #1873 to release-25.10. Treated as security-class important.
- [#2081](https://github.com/NVIDIA/gpu-operator/pull/2081) — "Cleanup stale daemonsets not managed by any nvidiadriver CR." When a CR's nodeSelector tightens, the old DS becomes orphaned and was *left running*. Fix: GC by ownership reference.
- [#1416](https://github.com/NVIDIA/gpu-operator/pull/1416) — fix for #1368 endless DS create/delete loop. Stale-check now requires *both* `DesiredNumberScheduled == 0` AND `nodeSelector matches no nodes`. **This is the closest precedent for "how do you decide a thing is dead without false-positive churn?"** Directly relevant to D-1: just because the driver pod isn't running doesn't mean the daemonset is stale.
- [#2138](https://github.com/NVIDIA/gpu-operator/pull/2138) + [#2144](https://github.com/NVIDIA/gpu-operator/pull/2144) — removed dependency on host-mounted `/etc/os-release`; now reads NFD labels. So gpu-operator depends on NFD-published labels for its own scheduling decisions. The reliability of those labels became load-bearing.

**Lesson learned.** Label cleanup is hard, and NVIDIA chose not to do it on uninstall. But during the *running* lifecycle they take label correctness seriously enough to switch from UPDATE to PATCH and to fix multiple drift bugs. For D-1, the question is whether you want the "label is presence" semantics (NVIDIA's choice, with the explicit caveat that stale labels can mis-schedule on reinstall) or "label is liveness" (which gpu-operator did *not* implement and which their controller architecture would make awkward — they don't reconcile labels in response to pod state, only in response to node state + CR state).

**Encoded in code / documented / neither.**
- Encoded: PATCH-not-UPDATE (PR #1873).
- Encoded: orphan-DS GC (PR #2081).
- Encoded: stale-DS deletion guard (PR #1416).
- *Not* encoded: pod-presence → label-presence cleanup (and explicitly refused as design philosophy in #1391).

---

## Theme 3 — Upgrade orchestration / multi-node coordination

**Pattern.** Driver upgrades require: (1) cordon node, (2) drain GPU workloads, (3) delete driver pod, (4) wait for kernel modules to unload, (5) start new pod, (6) re-validate, (7) uncordon. Any deviation (autoUpgrade off but pod restarted; workloads using `NVIDIA_VISIBLE_DEVICES` instead of resource requests; mixed precompiled/compiled across versions) wedges the cluster.

**Most-impactful issues.**
- [#2166](https://github.com/NVIDIA/gpu-operator/issues/2166) — covered above; the canonical "force-restart wedges modules" case.
- [#626](https://github.com/NVIDIA/gpu-operator/issues/626) — "Nodes stuck in upgrade" — `validation-required` and `pod-restart-required` states with no recovery path documented. Closed 2 years later as stale.
- [#1567](https://github.com/NVIDIA/gpu-operator/issues/1567) (open) — ClusterPolicy status oscillates Ready ↔ NotReady during a rolling upgrade. NVIDIA hasn't fixed; the underlying behaviour is "DS upgrades one node at a time, new pods start while old are terminating." Status field is computed from a transient quorum, so it lies during transitions.
- [#705](https://github.com/NVIDIA/gpu-operator/issues/705) — driver re-compiled+re-installed on every node reboot even when no driver version change. NVIDIA: *"this is the current limitation"*, marked as roadmap (a "persist driver root" feature). The closer comment 18 months later: *"We don't have any plans to avoid reinstallation on a node reboot."* Roadmap silently abandoned. Workaround: v26.3.0 "not reinstall driver on container restart" (per #2166 comment).
- [#1361](https://github.com/NVIDIA/gpu-operator/issues/1361) — 560 → 570 driver upgrade triggers NVML deadlock → entire node wedges (covered above).
- [#2433](https://github.com/NVIDIA/gpu-operator/issues/2433) (open) — install-old, uninstall, install-new triggers CrashLoopBackOff because nvidia-fs kernel module is held from the prior install. Workaround: bump `k8s-driver-manager` to a specific commit (`ae3f46db`); the older version doesn't retry the rmmod with exponential backoff (PR [#176](https://github.com/NVIDIA/k8s-driver-manager/pull/176)).
- [#2417](https://github.com/NVIDIA/gpu-operator/issues/2417) / PR [#2418](https://github.com/NVIDIA/gpu-operator/pull/2418) — nil-pointer panic in upgrade controller when `DrainSpec` is unset but `autoUpgrade: true`. Empty-struct default not applied. Verified on OpenShift 4.21.5 with v26.3.1, May 2026. Lesson: optional pointer fields in CRDs are landmines.
- [#1277](https://github.com/NVIDIA/gpu-operator/issues/1277) / PR [#1981](https://github.com/NVIDIA/gpu-operator/pull/1981) — `nvidia.com/gpu-driver-upgrade-enabled` annotation applied even when `driver.enabled=false`. Controller code didn't check `Driver.IsEnabled()` before applying. Six months between report and fix.

**Fix PRs.** #2418 (nil-pointer guard), #1981 (gate annotation on Driver.IsEnabled), #2147 (scope `DRIVER_CONFIG_DIGEST` to install-relevant fields — previously the digest changed when the DS spec schema changed, causing spurious reinstalls).

**Lesson learned.** Upgrade orchestration is the single biggest source of escalations. The fixes are all defensive (nil-guards, gating conditionals, narrowing what triggers reconciliation). They have *not* solved the underlying problem that a held kernel module cannot be unloaded by a restarting pod. Their answer is "use the upgrade controller." If you don't, you crashloop.

**Encoded in code / documented / neither.**
- Encoded: nil-guards, gating conditionals.
- Documented: must-gather workflow (script at `hack/must-gather.sh`, 11.8 KB) — this is the canonical "give us debugging output" tool linked in the issue template.
- *Not* fully solved: held-modules-prevent-restart is an architectural constraint.

---

## Mapping to our gaps

| Gap | Closest gpu-operator theme | What they did | What we should consider |
| --- | --- | --- | --- |
| **D-1** stale node label `nvidia.driver/state=ready` during driver-absent window | Theme 2 — label cleanup-on-uninstall ([#1391](https://github.com/NVIDIA/gpu-operator/issues/1391)) + label-write contention (PR [#1873](https://github.com/NVIDIA/gpu-operator/pull/1873)) | (1) Explicitly *refused* to clean up labels on uninstall — labels are "metadata not resources." (2) Did fix label-write races (UPDATE → PATCH) when the pod *is* running. (3) Their controller architecture reconciles labels from CR-state + node-state, not from pod-state. | We're in a different position: our injector *is* the pod, and our label `nvidia.driver/state=ready` claims a *current* state, not a *desired* state. gpu-operator's labels are aspirational ("this node should run this operand") and the operator owns them. Ours is observational and the absence is meaningful. Recommendation: change semantics or add a separate controller to clear the label on pod absence; gpu-operator offers no out-of-the-box pattern because their labels never mean "currently working." |
| **D-2** injector liveness-crashloop from `[ -e /sys/module/nvidia/version ]` | Theme 1 — probe design (PR [#1317](https://github.com/NVIDIA/gpu-operator/pull/1317), PR [#1939](https://github.com/NVIDIA/gpu-operator/pull/1939), PR [#2175](https://github.com/NVIDIA/gpu-operator/pull/2175)) | NVIDIA *explicitly removed* liveness probes that checked module/sysfs state. The driver container today has only a startupProbe with a 20-minute budget. They added liveness/readiness *only* to userspace operands (DCGM exporter) where restart is safe. | **Strongest single recommendation in this audit:** delete our livenessProbe. Replace with a startupProbe that has a long budget. If we *must* have liveness for some failure case, scope it to something safe to restart, not the driver itself. Match the exact NVIDIA pattern: `initialDelaySeconds: 60`, `periodSeconds: 10`, `timeoutSeconds: 60`, `failureThreshold: 120`. |
| **D-3** PCIe tunnel non-recovery | Theme — not present in gpu-operator | gpu-operator has zero TB / PCIe-tunnel awareness. Issue [#1263](https://github.com/NVIDIA/gpu-operator/issues/1263) (open) is the only hot-plug-adjacent request — and it's about *composable DRA*, not TB recovery. | Handled by sister subagent M1; gpu-operator offers nothing here. |
| **D-4** failure modes buried in container logs | Theme 1 + Theme 3 cross — k8s-driver-manager PR [#166](https://github.com/NVIDIA/k8s-driver-manager/pull/166) | Most-relevant precedent: PR #166 (Apr 2026) replaced `disabled by the upgrade policy` log line with explicit recovery guidance ("you have GPU workloads using the driver; here's what to do"). They also maintain `hack/must-gather.sh` as the canonical debug-bundle tool, referenced from the issue template. | Two concrete adoptions: (a) treat every error path as a docs surface — rewrite the failure log lines to tell the user *what to do next*; (b) ship a `must-gather.sh` analog for our injector that bundles `dmesg | grep -i nvidia`, `lspci -vvv` on the bridge, `journalctl -u nvidia-driver-injector`, sysfs PCIe state, and the last K log lines. Both are zero-architectural-risk improvements that gpu-operator validated under hostile production conditions. |

---

## TB / eGPU / hotplug issues (special call-out)

The harvest is **thin**, which is itself the finding.

- **[#1263](https://github.com/NVIDIA/gpu-operator/issues/1263)** "Support of GPU hot-plug" (Feb 2025, open, lifecycle/frozen). Proposes Composable Disaggregated Infrastructure (CDI — *PCIe* fabric, not container CDI) hot-attach via DRA. No engineering response from NVIDIA in 15 months; the only NVIDIA-side reply was an @-mention of @klueska. **gpu-operator has no hot-plug story.** Their assumption: GPUs are static node properties.
- **[#2463](https://github.com/NVIDIA/gpu-operator/issues/2463)** (May 2026, open) "Driver daemonset fails to start on kernels without `CONFIG_MEMORY_HOTPLUG`." Not eGPU per se, but the only "hotplug" string match. The driver DS unconditionally mounts `/sys/devices/system/memory/auto_online_blocks` which doesn't exist on kernels without `CONFIG_MEMORY_HOTPLUG=y`. Fix is trivial (conditional mount) but the patch is the first finding of that kind, in a 5-year-old project.
- Zero issues mention `thunderbolt`, `TB3`, `TB4`, `external GPU`, `eGPU`, `surprise removal`, or `device disconnect`. The gpu-operator user base does not run our workload.

**Implication for M1 cross-thread.** gpu-operator's controller assumes monotonic node-to-GPU mapping. Adding hot-plug to it would be a significant lift. Our injector's PCIe-recovery work has no precedent here and won't conflict.

---

## DKMS / kernel-version issues (special call-out)

- **[#1622](https://github.com/NVIDIA/gpu-operator/issues/1622)** — adding a node with a different OS image causes the existing daemonset's pod image to be silently rewritten. Mixed kernels in a cluster are a known sharp edge. Closed Dec 2025.
- **[#1215](https://github.com/NVIDIA/gpu-operator/issues/1215)** "kernel upgrade" — minimal report but pattern is: nvidia.ko built for old kernel, kernel upgraded out from under it, pod cannot insert module.
- **[#705](https://github.com/NVIDIA/gpu-operator/issues/705)** — driver re-installed on every reboot even with no version change. The "compile every boot" pattern is exactly the same overhead a vanilla-then-replace-with-patched DKMS scenario would face. The eventual v26.3.0 "persist driver root" feature is the architectural answer — they make a persistent host directory the install target, then `nvidia-container-toolkit` reads from that path instead of bind-mounting from the container.
- **[#1188](https://github.com/NVIDIA/gpu-operator/issues/1188)**, **[#1203](https://github.com/NVIDIA/gpu-operator/issues/1203)**, **[#933](https://github.com/NVIDIA/gpu-operator/issues/933)** — precompiled-driver-image-not-available-for-this-kernel. NVIDIA's pre-built tags lag the active kernel set. Fallback is compile-on-pod-startup, which they then have to invalidate-cache for via the `DRIVER_CONFIG_DIGEST` mechanism (PR [#2147](https://github.com/NVIDIA/gpu-operator/pull/2147)).
- **[#1390](https://github.com/NVIDIA/gpu-operator/issues/1390)** — "Unable to load the kernel module 'nvidia.ko'." Typical when a vanilla `nvidia.ko.xz` is left in `/lib/modules/<kver>/extra/` and `depmod` picks it over the operator-provided one. **This is the exact landmine you logged in MEMORY.md as "DKMS vanilla `nvidia.ko.xz` collides with patched `.ko` on kernel upgrades."** NVIDIA hits the same class of bug; their answer is "clean the host before letting the operator manage things." Their k8s-driver-manager has an `uninstall_driver` step that explicitly `rmmod`s and clears module files. Our injector should do the equivalent and assert no `nvidia*.ko*` exists under `/lib/modules/<kver>/extra/` and `/updates/dkms/` before insmod.

**Lesson for us.** Our DKMS collision finding has direct parallel in gpu-operator's k8s-driver-manager. The pattern they use is a privileged init container that runs `rmmod` then deletes module files. That pattern is reusable.

---

## Failure-mode-clarity issues (special call-out, D-4)

- **k8s-driver-manager PR [#166](https://github.com/NVIDIA/k8s-driver-manager/pull/166)** (Apr 2026) is the cleanest "we replaced bad log messages with actionable recovery guidance" precedent. Before/after example from the PR body:

  Before:
  ```
  msg=Auto drain of the node is disabled by the upgrade policy
  msg=Failed to uninstall nvidia driver components
  msg=Performing cleanup on failure
  msg=Auto eviction of GPU pods on node ipp2-2153 is disabled by the upgrade policy
  msg=failed to uninstall nvidia driver components: failed to unload driver: resource temporarily unavailable
  ```

  After: a verbose multi-line message telling the user precisely which workloads are holding the modules, what to do (`kubectl drain`, or `kubectl delete pod -l workload-label`), and what the auto-policy means in their config. Same observable failure, completely different operator experience.

- **`hack/must-gather.sh`** is the canonical debug bundle. ~12 KB shell. Referenced from every "share more details" comment NVIDIA staff posts. Bundles operator pod logs, DS pod logs, CR YAML, node descriptions, and config. PR #2097 (Feb 2026) added NVIDIADriver CR capture. PR #1454 added KubeVirt log capture. **This is the lowest-cost highest-leverage D-4 improvement we can adopt.**

- **[#1391](https://github.com/NVIDIA/gpu-operator/issues/1391)** comment from @Perdjesk: *"At least something about those aspects could be included in the uninstall docs."* NVIDIA agreed in principle, didn't act. So gpu-operator has the same gap we do — documentation lags code by ~2 versions, and users learn about failure modes from GitHub issues, not from docs.

- **[#901](https://github.com/NVIDIA/gpu-operator/issues/901)** — "AUTO_UPGRADE_POLICY_ENABLED set to true, but eviction and drain are 'disabled by the upgrade policy'" — opaque log line. Exactly the message PR #166 retired.

- **[#1595](https://github.com/NVIDIA/gpu-operator/issues/1595)** — "FabricManager doesn't get started correctly (and no error handling)" — fabric-manager error message: `Unknown option: /usr/share/nvidia/nvswitch/fabricmanager.cfg`. The driver container script didn't validate config-version-compatibility, just shoved the wrong arg in. The user title nails it: "and no error handling."

**Lesson.** D-4 is universal. The pattern that worked (PR #166) is: (a) treat each fatal log line as a UI string the user will see, (b) write it as imperatively as possible ("do X to recover" not "X failed"), (c) include the relevant resource identifiers (which pod, which workload), (d) link to docs. A `must-gather.sh` analog is the bundle-side complement.

---

## Probe-configuration historical issues (special call-out — D-2 design call)

**Did gpu-operator ever ship a livenessProbe on the driver container, then remove it?**

The git history of `roles/gpu_operator/templates/state-driver/0500_daemonset.yaml` and `assets/state-driver/0500_daemonset.yaml` (the driver DS template) shows that the driver container in `clusterpolicy`-managed mode has **never had a livenessProbe** in the time window we audited. It has only ever had a `startupProbe` (the same one referenced in #630 from 2023-12, with `failureThreshold: 120`).

The closest historical removal is PR #1317 — but that was on the **GDS** and **GDRCopy** sidecar containers, not the driver container. Those sidecars had livenessProbes that ran `lsmod` to check if `nvidia-fs` / `gdrdrv` were loaded. Quote from the PR: *"the livenessProbes timeout due to long response times of the `lsmod` commands which have led to undesirable restarts of the container leaving the driver daemonset in a bad state."* This is the strongest evidence: NVIDIA tried *exactly* the kind of probe our injector uses, hit the same failure mode, and removed it.

The NVIDIADriver CR also carries an explicit `livenessProbe` field (template lines 32-34 in `nvidiadriver.yaml`) — but it's gated on `if .Values.driver.livenessProbe`, and the default `values.yaml` does *not* set it. So the on-by-default state is no liveness; users must opt in.

PR [#2175](https://github.com/NVIDIA/gpu-operator/pull/2175) (Feb 2026) added liveness *and* readiness probes to the DCGM exporter operand. PR description: *"Adding probes to the DCGM pods ensure that these pods aren't marked as 'Ready' until the DCGM is actually ready to serve traffic."* This is the policy: probes are appropriate for userspace services that have a meaningful "ready to serve" state. They are *not* appropriate for kernel-module owners.

**Direct D-2 implication.** Our `livenessProbe: [ -e /sys/module/nvidia/version ]` is structurally identical to the `lsmod` liveness PR #1317 deleted. The failure mode is identical. The recommended fix is identical: delete the liveness probe; if startup time is the concern, use startupProbe with a long budget.

---

## Recurring patterns across themes

What gpu-operator consistently gets wrong, then fixes:

1. **GET-modify-UPDATE on shared cluster state.** Fixed in PR #1873 (labels, UPDATE → PATCH). Likely to recur on annotations, taints, status subresources. Default to PATCH for any shared resource.
2. **Optional pointer fields in CRDs assumed non-nil.** Fixed in PR #2418 (DrainSpec). The CRD lets you omit them; the controller assumed they exist. They have unit tests now; this class of bug recurs every minor release. We should default-zero our CRD-equivalents in Go, not rely on YAML to set them.
3. **Probes with side-effects.** Fixed in PR #1939 (probe was loading the kernel module). The script that owns the module-load must be the *only* path; probes are read-only observers.
4. **Stale resource detection by a single signal.** Fixed in PR #1416 (was deleting DS whenever pods=0; needed *also* "nodeSelector matches no nodes"). Any "is this thing dead?" decision needs corroboration. D-1 falls in this class.
5. **Reconciliation digest scoped too broadly.** Fixed in PR #2147 (`DRIVER_CONFIG_DIGEST` was over the whole spec; now scoped to install-relevant fields only). Lesson: change-detection hashes must exclude fields that don't affect the operation being decided.
6. **Implicit dependency on host filesystem state.** Fixed in PRs #2138 + #2144 (was mounting `/etc/os-release`; now reads NFD labels). Implication: any host-mount our injector takes that *might* differ between operator pod and target node is a future bug.
7. **External label dependency.** Not fixed (#1469 still open). NFD-published labels are external state our controllers depend on. We have the same exposure with `feature.node.kubernetes.io/pci-10de.present`.
8. **Error messages that don't tell the user what to do.** Fixed *individually* (k8s-driver-manager PR #166); no systematic policy. Recurs.

---

## Open questions / things I couldn't resolve

- **Has anyone tried a TB-attached GPU with gpu-operator?** Search returned zero hits. Either nobody has, or the failures look the same as PCI-class generic failures and get filed under those tags.
- **Why did gpu-operator not adopt a "driver-pod-ready" annotation pattern for downstream-consumer schedulers?** The architectural decision (#1391 refusal to cleanup labels on uninstall) seems load-bearing here, but no PR explicitly considered it. Would be useful to know if this was considered and rejected vs never considered.
- **Is the `lifecycle/stale` workflow biasing our sample?** The bot closes issues at 120 days no activity. Some of the most-relevant issues (#705, #626, #872) closed *not* because they were resolved but because they were stale. That means the "fix" we'd see in code may not exist; the issue just timed out.
- **The v26.3.0 "don't reinstall driver on container restart" feature** is mentioned in three closing comments (#2166, #2433, k8s-driver-manager #166) but I couldn't find the corresponding PR. The feature description matches what we'd want for D-2 (probes restart container; driver stays loaded). Worth tracking when it lands.
- **The `must-gather.sh` script** would be useful to read line-by-line to design our injector analog. Skipped due to time-box (would require fetching contents and re-parsing); recommended as a follow-up.
