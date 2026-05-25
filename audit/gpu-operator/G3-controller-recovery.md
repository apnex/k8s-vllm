# G3 — Operator controller logic + failure recovery

**Date:** 2026-05-25
**Auditor:** subagent G3 (1 of 4 parallel)
**Source:** NVIDIA/gpu-operator @ `v26.3.1` (commit `5a25fef4`)

## TL;DR (3 bullets)

- **The operator does NOT actively recover crashing driver pods.** It reads `DaemonSet.Status` aggregates (`NumberUnavailable`, `NumberAvailable`) and converts that into a coarse `Ready` / `NotReady` / `Disabled` enum on the CRD — but never inspects `ContainerStatus.RestartCount`, `Waiting.Reason`, `Terminated.ExitCode`, or `LastTerminationState`. The only code path that *deletes* a driver pod is the optional, opt-in `upgrade-controller`, and even then only during an explicit driver upgrade — never as a CrashLoopBackOff recovery action.
- **Human-visible health is minimal: a single `Status.State` enum + two mutually-exclusive Conditions (`Ready`/`Error`).** There are zero `Status.Conditions` of type `Degraded` or `Progressing`, and the operator emits **zero Kubernetes Events** in steady-state (the EventRecorder is only wired into the upgrade lib's drain/cordon path). Failures are observable only through pod logs and a small set of operator-level Prometheus metrics that count *reconciliations*, not driver-pod failure modes.
- **Implication for D-2 / D-4:** adding a controller above our injector DaemonSet would *not* materially improve recovery if we copied gpu-operator's design — the upstream's controller is a thin reflector of DaemonSet status, not a state machine that intervenes in crashing pods. The patterns worth borrowing are narrow (drift correction for the GPU-presence label, a small Prometheus counter set), but the loudness/recovery gap we want to fix is something the upstream operator has too. Building our own minimal recovery loop with `RestartCount`-aware force-cycling and an explicit `Degraded` condition would actually be a *step ahead* of upstream, not a step toward parity.

## Does the operator actively reconcile driver pods?

**Yes for topology / drift; no for crash recovery.**

The `ClusterPolicyReconciler.Reconcile()` loop (`controllers/clusterpolicy_controller.go:93-227`) drives a fixed list of "state" steps (`step()` at `controllers/state_manager.go:1051-1089`) which each check-or-create one operand (driver DS, container-toolkit DS, device-plugin DS, dcgm DS, etc.). Readiness aggregation is done by `isDaemonSetReady()` (`controllers/object_controls.go:3922-3998`):

```go
func isDaemonSetReady(name string, n ClusterPolicyController) gpuv1.State {
    ...
    if ds.Status.DesiredNumberScheduled == 0 {
        return gpuv1.Ready                               // line 3933
    }
    if ds.Status.NumberUnavailable != 0 {
        n.logger.Info("daemonset not ready", "name", name)
        return gpuv1.NotReady                            // line 3938
    }
    ...
```

For DaemonSets configured with `OnDelete` strategy, it walks owned pods and checks `pod.Status.Phase == "Running"` and `ContainerStatus.Ready` (`object_controls.go:3969-3993`). **That is the entire pod-level inspection in the controller.** The reconciler then either marks the CR `Ready` (full success), `NotReady` (something's not converged — requeue in 5s, `clusterpolicy_controller.go:184`), or sets an `Error` condition (state-machine step failed).

What the controller does NOT do:

- Never reads `ContainerStatus.RestartCount`.
- Never inspects `ContainerStatus.State.Waiting.Reason` (i.e. cannot distinguish `ImagePullBackOff` from `CrashLoopBackOff` from `CreateContainerError`).
- Never reads `ContainerStatus.LastTerminationState.Terminated.ExitCode` or `Reason`.
- Never reads pod events (no `Event` watch is registered in `SetupWithManager`).
- Never deletes a driver pod for any failure reason. The only `Delete()` calls in `internal/state/driver.go:211` and `:240` exist to remove **stale DaemonSets whose `nodeSelector` no longer matches any node** — i.e. topology drift, not crash recovery.

The grep is decisive:

```
$ grep -rn "CrashLoopBackOff\|RestartCount" controllers/ internal/
# zero hits in controllers/, zero in internal/
```

The only `RestartCount > 10` check anywhere in the project is inside the vendored upgrade library (`vendor/github.com/NVIDIA/k8s-operator-libs/pkg/upgrade/common_manager.go:638`), and even there the response is to *label the node `UpgradeStateFailed`* — not to delete the pod.

## Force-cycling behavior

**There is none in the steady-state path.** No code in `controllers/` or `internal/` deletes pods. The two `Delete()` sites in `internal/state/driver.go` delete entire DaemonSets when the node selector no longer matches (per the comment at `:218-229`, this fixes issue #1368 where the controller looped creating-then-deleting a DS).

The upgrade controller (`controllers/upgrade_controller.go`) opts into pod deletion via `WithPodDeletionEnabled(gpuPodSpecFilter)` (`cmd/gpu-operator/main.go:177`), but:

1. It is only active when `clusterPolicy.Spec.Driver.UpgradePolicy.AutoUpgrade == true` (line 114).
2. It is gated on an explicit driver-version change (the upgrade library's `SchedulePodsRestart` path drains the node, then deletes the driver pod so the new image rolls out).
3. The `isDriverPodFailing()` check (vendored at `common_manager.go:636-648`) — the only `RestartCount`-aware logic in the project — moves the node to `UpgradeStateFailed` state but does NOT itself delete the failing pod or attempt recovery. It just stops the upgrade for that node and waits for human intervention.

So: **the operator never force-cycles a driver pod purely because it is unhealthy.** It relies entirely on kubelet's exponential-backoff restart loop. Our injector is in the same regime.

## Health surfacing (conditions / events / metrics / logs)

### `Status.Conditions`

The CRD `Status` carries `Conditions []metav1.Condition` (`api/nvidia/v1/clusterpolicy_types.go:1962`), but only **two** condition Types are ever set, and they are mutually exclusive (one True ↔ the other False):

`internal/conditions/conditions.go:24-28`:
```go
const (
    Ready = "Ready"
    Error = "Error"
)
```

`internal/conditions/clusterpolicy.go:60-99` shows the toggling logic: setting `Ready=True` forces `Error=False` (with `Reason=Ready`); setting `Error=True` forces `Ready=False` (with `Reason=Error`). No third state exists.

Condition `Reason` strings are richer (`internal/conditions/consts.go`):
- `Reconciled` — happy path.
- `ReconcileFailed` — generic catch-all.
- `OperandNotReady` — generic operand fail.
- `DriverNotReady` — driver DS pods not ready.
- `NFDLabelsMissing` — NFD setup incomplete.
- `NoGPUNodes` — no GPU node found.
- `NodeStatusExporterNotReady` — listed in const but I found no producer for it.

For the `NVIDIADriver` CR, only `ConflictingNodeSelector` is added on top (`internal/conditions/nvidiadriver.go:36`).

This means the consumer (Prometheus alert, human kubectl) sees the *category* of failure but never the *specific* failure mode. "Driver not ready" doesn't tell you whether modprobe failed, the image is pulling, the firmware is missing, or the kernel module hit a runtime BUG.

### `Status.State`

A single `State string` enum: `ready` / `notReady` / `ignored` / `disabled` (`api/nvidia/v1/clusterpolicy_types.go:1943-1952`; identical set for NVIDIADriver at `api/nvidia/v1alpha1/nvidiadriver_types.go:479-487`). This is what `kubectl get clusterpolicy` displays in its `Status` column (`+kubebuilder:printcolumn` at `:1970`).

### Kubernetes Events

```
$ grep -rn "GetEventRecorderFor\|recorder\.Event" controllers/ internal/
# zero hits
```

The operator's own controllers register no `EventRecorder` and emit zero Kubernetes Events. The only `EventRecorder` instantiation in the codebase is `cmd/gpu-operator/main.go:170` and is handed *only* to the vendored upgrade library:

```go
clusterUpgradeStateManager, err := upgrade.NewClusterUpgradeStateManager(
    upgradeLogger,
    mgr.GetConfig(),
    // nolint:staticcheck
    // TODO: update k8s-operator-libs to leverage events.EventRecorder instead
    mgr.GetEventRecorderFor("nvidia-gpu-operator"),
    upgrade.StateOptions{},
)
```

The `TODO` comment is telling — they want to migrate to a newer EventRecorder API but haven't. And the existing events fire only during cordon/drain/upgrade lifecycle moves (see `vendor/.../drain_manager.go:106-130`, `node_upgrade_state_provider.go:87-211`). **A driver pod in CrashLoopBackOff at steady state produces no Event from the operator.**

### Prometheus metrics

`controllers/operator_metrics.go` registers ~17 gauges/counters. The relevant subset:

```go
reconciliationLastSuccess    // ts of last successful reconcile
reconciliationStatus         // {-2,-1,0,1} = err / no CP / not-ready / ready
reconciliationTotal          // counter
reconciliationFailed         // counter
reconciliationHasNFDLabels   // 0/1
gpuNodesTotal                // gauge of GPU nodes labelled
upgradesInProgress/Done/Failed/Available/Pending  // node counts
```

Notice what's missing: **no `driver_pod_restart_count`, no `driver_pod_failure_mode`, no `driver_pod_crashloop_seconds`**. The metrics measure *operator activity*, not *operand health*. A driver pod that has been crashing for 30 minutes shows up only as `reconciliation_status == 0` (not-ready) — exactly the same value you'd see for "just created, still pulling image."

### Logs

Standard structured `logr` logs from the controller. No structured failure-classification — failure modes show up as message strings to be grepped.

## Built-in observability

For "a driver pod has been crashing for N minutes" the operator gives you, in priority order:

1. `Status.Conditions` will show `Type=Ready, Status=False, Reason=DriverNotReady, Message="Waiting for driver pod to be ready"` (`controllers/nvidiadriver_controller.go:208-210`). The Message is generic — no restart count, no last termination reason, no first-fail timestamp.
2. `Status.State == "notReady"` (boolean).
3. Prometheus: `gpu_operator_reconciliation_status == 0` (boolean) and `gpu_operator_reconciliation_failed_total` ticking. Neither attributable to *which* pod or *which* failure.
4. Operator log spam — same `"daemonset not ready"` line every 5s (the requeue cadence at `clusterpolicy_controller.go:184`).
5. The operator emits no `Event`s for this, so `kubectl describe` shows nothing operator-sourced. You'd see kubelet events (`BackOff`, `Started`, `Killing`) on the pod itself, but those are kubelet's, not the operator's.

Compared to our injector's soak observability (per-rerun structured progress markers + ledger) this is a step *down*. The operator gives you "is it ready right now?" with no temporal context whatsoever.

## Degraded state modeling

**Binary.** The model is:

```
ready | notReady | ignored | disabled
```

There is no `degraded`, no `partial`, no `available-but-impaired`. The `Conditions` array is constrained to `Ready` XOR `Error` (mutually exclusive — see the toggling code at `internal/conditions/clusterpolicy.go:67-98`).

Concretely: a cluster where the driver loads but `nvidia-smi -L` hangs would, in this operator's model, report `ready` (because the DaemonSet's `NumberReady == DesiredNumberScheduled`, the only signal it consumes). The operator has no notion of "loaded but not functionally usable." This is the same blind spot we have on our injector — the difference is the operator's `Status.State` field gives users a *false* sense of richness they don't have.

For context, the OpenShift `ClusterOperator` pattern (visible in `vendor/github.com/openshift/api/config/v1/types_cluster_operator.go:179`) uses a richer `Available`/`Progressing`/`Degraded`/`Upgradeable` four-condition model. The gpu-operator does not adopt it even though it ships with OCP-aware code paths.

## Drift correction discipline

**Decent for labels; absent for pods.**

The clusterpolicy controller's `labelGPUNodes()` (`controllers/state_manager.go:519-622`) re-asserts node labels on every reconciliation:

- If a node has the NFD GPU label but is missing the operator's `nvidia.com/gpu.present=true` label, it adds it (lines 550-557).
- If a node has the common GPU label but no longer has GPUs per NFD, it flips it to `false` and removes all GPU-state labels (lines 558-569).
- For MIG-capable GPUs without a MIG config label, it sets one (lines 580-587).

This is true reconciliation discipline — if anything (a human, a node restart, another controller) wipes those labels, the operator restores them on the next reconcile. Reconciliation is triggered by Node-Update events that filter for label changes (`clusterpolicy_controller.go:279-316`), so drift correction is fast (no need to wait for the periodic requeue).

DaemonSet drift: the controllers use server-side apply / patch semantics via `object_controls.go`'s create-or-update helpers (not shown in this audit but visible by inspection — `client.Patch` calls with `MergeFrom`). DaemonSet field modifications outside the operator's owned fields will be tolerated; modifications to owned fields will be reverted on next reconcile.

Pod-level drift correction does **not** exist (pods are owned by the DaemonSet controller, not by gpu-operator).

## Failure mode taxonomy

**Effectively absent.** The operator distinguishes failures at one granularity: "which state-machine step failed" (e.g. `state-driver` vs `state-container-toolkit` vs `state-dcgm`), surfaced via:

```go
// controllers/clusterpolicy_controller.go:154
fmt.Sprintf("Failed to reconcile %s: %s",
    clusterPolicyCtrl.stateNames[clusterPolicyCtrl.idx], statusError.Error())
```

But within a step, all failures collapse to `OperandNotReady` / `DriverNotReady` / `ReconcileFailed`. The operator cannot tell:

- driver build failed (DKMS/precompiled image issue) vs
- modprobe failed (kernel mismatch, missing symbols) vs
- GPU not present (PCI enumeration issue) vs
- GSP firmware mismatch (file not found, version skew) vs
- nvidia-smi hangs (driver loaded but RM stuck) vs
- container image pull failed.

All five present identically as `Status.State=notReady` + `Conditions=[Ready=False, Error=True, Reason=DriverNotReady]`. The user has to read pod logs to diagnose.

The validator pod (`assets/state-operator-validation/0500_daemonset.yaml`) runs a sequence of init-containers that each check one preflight (driver, toolkit, cuda, plugin, mofed); these init-containers' failure surfaces as a *pod-not-ready* but the operator does not introspect *which* validator init-container blocked — only that the overall validator DS is not ready. The validator pod's logs/exit codes are the only place failure-mode information lives, and they require `kubectl logs nvidia-operator-validator -c <container>` to retrieve.

## D-2 implications (architectural)

D-2 = injector liveness-crashloop hardening (currently we rely on kubelet's exponential backoff with no override).

**Adding a controller-level state machine modeled after gpu-operator's would not solve D-2.** Gpu-operator has exactly the architecture (Reconcile loop watching DaemonSet status, requeue every 5s when not ready) and exactly the same blind spot: kubelet does all the actual restart work, the controller just observes.

What *would* solve D-2 is a controller with three properties gpu-operator lacks:

1. **`RestartCount`-aware force-cycle.** When `ContainerStatus.RestartCount` exceeds threshold *and* the pod has been in `Waiting{Reason=CrashLoopBackOff}` for >N seconds, *delete the pod* to escape kubelet's exponential backoff (which can grow to 5m between attempts and is a brittle waiting game for hardware-recoverable failures). The deletion bypasses backoff because the new pod is a fresh sandbox.
2. **Cooldown / circuit-breaker.** Track per-pod delete attempts in an annotation; refuse to force-cycle more than N times in M minutes; flip to `Degraded` condition and stop intervening so a human can step in. Gpu-operator's `UpgradeStateFailed` node label is the spiritual ancestor of this idea — but they only apply it during upgrades.
3. **Pre-recovery hardware probe.** Before force-cycling, run our existing `usr/local/sbin/` helpers (bridge-link-cap, m-recover) — these address the *cause*, where the pod restart only addresses the *symptom*. Gpu-operator has nothing analogous because their operand is purely a userspace driver-build problem.

Architecture sketch for our single-node case:

- A `InjectorRecovery` controller (in-cluster, deployed as a separate Deployment OR running in-process inside an `injector-operator` binary).
- Watches our injector DaemonSet's pods (not the DS — kubelet aggregation is too lossy).
- State machine per pod: `Healthy` → `Crashing` (RestartCount delta in last 5min > 1) → `ForceCycling` (we just deleted) → `Cooldown` → back to `Healthy` or escalate to `Degraded`.
- Emits Events (`Recovery`, `ForceCycled`, `Degraded`, `RecoveryGaveUp`) and sets `Status.Conditions` on a new lightweight CRD (or on a ConfigMap if we want to avoid CRD overhead).
- Runs the bridge-link-cap / m-recover probes between attempts.

For a single-node deployment, this could be ~300-500 LOC of Go using controller-runtime, much smaller than gpu-operator (~15k LOC). The complexity gpu-operator carries is for multi-tenancy, OpenShift integration, sandbox/kata/vgpu support — none of which we need.

**Alternative considered:** instead of a custom controller, could we configure kubelet's restart-policy or use a sidecar? No — restart-policy is fixed for DaemonSets and kubelet's backoff isn't tunable per-pod. A sidecar runs in the same pod and shares its restart fate. A separate "watcher" Pod that calls the k8s API to delete the injector pod is essentially a controller without controller-runtime — the proper shape is a controller.

## D-4 implications (loudness patterns)

D-4 = buried failure modes (right now a CrashLoop pod is visible only by `kubectl get pods`, no distinguishing signal between failure kinds).

Gpu-operator's loudness patterns are:

- One `Status.Condition` change per state-machine transition (low-frequency, coarse-grained).
- Five Prometheus metrics that count *reconciliations*, not *failure kinds*.
- Zero per-failure-mode Events.
- Zero distinct exit codes.
- No structured logging schema — failure cause lives in a `Message` string.

**Anti-patterns to avoid copying:**

- The `Ready`/`Error` two-condition mutex. A binary toggle loses information. Use the OpenShift four-condition pattern (`Available`, `Progressing`, `Degraded`, `Upgradeable`) or our own enumeration.
- The single `Message` string for the failure cause. Use either a `Reason` enum (which gpu-operator partly does with consts.go) or structured fields.
- Reliance on `kubectl get pod` for failure visibility. Emit Events with distinct `Reason` values per failure mode.

**Patterns worth adopting:**

- The condition-Reason enum approach (`internal/conditions/consts.go`) — these are stable identifiers that alerts and humans can pattern-match. Lift this idea and create our own enum: `KernelModuleLoadFailed`, `GSPFirmwareMismatch`, `PCIEEnumerationFailed`, `BridgeLinkDegraded`, `WPR2Stuck`, `DMARFault`, etc. Each must be detectable from observable signals (container exit code, last-termination message, journald grep).
- The reconciliation-status Prometheus gauge — promote to a per-failure-mode counter (`injector_failure_mode_total{mode="kernel_module_load"}`). Then a single PromQL query gives the top failure modes by frequency.

**Loudness recommendation for D-4:**

1. **Structured exit codes.** Define an enum in our injector entrypoint (e.g. exit 10 = kernel module load fail; 11 = GSP firmware missing; 12 = PCIe enumeration; 13 = WPR2 stuck; 14 = nvidia-smi hang; 15 = container runtime probe failed). Each kubelet `BackOff` event will then carry this code in `lastState.terminated.exitCode` and become greppable.
2. **First-failure journald marker.** Have the entrypoint write a `/dev/kmsg` line on each failure mode (`INJECTOR_FAIL: mode=gsp_firmware_missing ver=595.71.05`). `dmesg` becomes a permanent record even across pod replacements.
3. **A small in-controller event emitter** (~50 LOC). On first observation of a failure mode (delta detection from previous reconcile), emit a typed Event (`Reason=KernelModuleLoadFailed`, `Type=Warning`). Subsequent identical failures don't re-emit (Event deduplication).
4. **Per-failure-mode Prometheus counter.** Single new metric `injector_failure_mode_total{mode="..."}` that the controller increments based on exit-code observation.

## Recommended patterns to consider adopting

1. **`labelGPUNodes` style reconciliation for our common-presence label.** If we ever label nodes (e.g. for vLLM placement), do it from a reconciliation loop that re-asserts, not a one-shot. Gpu-operator's drift correction here is solid (`controllers/state_manager.go:519-622`).
2. **Condition-Reason consts.** Adopt the `internal/conditions/consts.go` pattern — keep machine-readable Reason strings in a small enumeration file, separate from the human-readable Message strings.
3. **5-second requeue on not-ready.** The `RequeueAfter: time.Second * 5` (`clusterpolicy_controller.go:184`) is a reasonable cadence — short enough that humans see fast convergence, long enough to avoid hammering the apiserver.
4. **DaemonSet-stale cleanup.** Their `cleanupStaleDriverDaemonsets()` (`internal/state/driver.go:186-250`) is a thoughtful design: delete a DS only when (a) it's no longer in the desired manifest *or* (b) its desired-count is zero AND no nodes match its selector. The `#3` clause exists because of a bug they had (#1368) where they entered a create/delete loop. We should keep this in mind if we ever add multi-DS topologies.
5. **Singleton enforcement via `Ignored` state.** Their pattern of marking duplicate CRs as `Ignored` (`clusterpolicy_controller.go:117-122`) is cleaner than failing — extra instances are visible but don't disrupt the active one.

**Patterns NOT to adopt:**

- The two-condition mutex (`Ready` XOR `Error`).
- Reliance on `DaemonSet.Status` aggregates as the sole readiness signal.
- Zero EventRecorder use in steady state.
- Single state-machine instance shared across all reconciliations (`var clusterPolicyCtrl ClusterPolicyController` at `clusterpolicy_controller.go:56` — a package-level singleton) — modern controller idiom is to keep state in the reconciler struct.

## Open questions / things I couldn't resolve

- **Does the validator emit failure-mode metadata via its DS labels or annotations?** I read the validator DaemonSet manifest (`assets/state-operator-validation/0500_daemonset.yaml`) and noted six init-containers, but the validator's actual *binary* source is not in this repo — it's pulled from `nvcr.io` as an opaque image. So I can't tell whether it writes per-init-container exit-code or status into the pod's annotations, which would be the right place to surface failure-mode info to the operator.
- **The `NodeStatusExporterNotReady` condition Reason has no producer.** Defined in `internal/conditions/consts.go:29` but `grep -rn NodeStatusExporterNotReady --include='*.go'` shows only the const declaration. Likely a vestigial constant from a planned but unimplemented feature.
- **Whether `WithValidationEnabled` materially changes behaviour at steady-state.** It is set in `cmd/gpu-operator/main.go:177` for the upgrade lib, but the upgrade lib's `IsValidationEnabled()` branch (visible in `vendor/.../common_manager.go:489`) seems to gate only the upgrade-progress transitions, not steady-state recovery. I did not trace the full validation-pod lifecycle.
- **Is there an OpenShift-specific recovery path I missed?** Gpu-operator has heavy OCP code in `controllers/state_manager.go` (`ocpEnsureNamespaceMonitoring`, `ocpDriverToolkit`). I did not inspect whether OCP's `ClusterOperator` integration (which uses the richer `Available`/`Progressing`/`Degraded` condition vocabulary) hooks back into a recovery path. Likely not — these look like reporting-only integrations — but worth verifying if we ever target OCP.
