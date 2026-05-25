# G2 — Manifest patterns + label/taint management

**Date:** 2026-05-25
**Auditor:** subagent G2 (1 of 4 parallel)
**Source:** NVIDIA/gpu-operator @ v26.3.1 (HEAD 5a25fef4, pinned latest stable tag)

## TL;DR (3 bullets)

- **NVIDIA does NOT taint nodes** — the entire scheduling story is `nvidia.com/gpu.deploy.*` *labels* applied by the operator (`controllers/state_manager.go`) plus per-DaemonSet `nodeSelector` matching those labels. The `Resources` struct (`controllers/resource_manager.go:60`) declares a `Taint` field but no code path in v26.3.1 ever populates it. The only "taint"-shaped primitive in the upgrade flow is **`kubectl cordon`** (vendored via `k8s-operator-libs/pkg/upgrade/cordon_manager.go`), which sets `.spec.unschedulable=true`, not a `NoSchedule` taint.
- **Driver readiness is a multi-layer state machine**: (a) per-node label `nvidia.com/gpu.deploy.driver=true` gates the driver DS onto the node, (b) the driver container's `startupProbe` (`assets/state-driver/0500_daemonset.yaml:140`) writes `/run/nvidia/validations/.driver-ctr-ready` once `nvidia-smi` succeeds, (c) the `nvidia-operator-validator` DaemonSet writes `/run/nvidia/validations/driver-ready` as a host-FS signal, (d) downstream operands (device-plugin, GFD, dcgm-exporter, mig-manager) block their init container on `until [ -f /run/nvidia/validations/driver-ready ]`. There is **no** stand-alone `nvidia.com/gpu.driver.ready` node label — readiness is host-FS-based, not node-label-based.
- **Adoption recommendation for the injector** is narrow: copy two keys verbatim (`nvidia.com/gpu.deploy.driver=true` for the injector DaemonSet nodeSelector, and the canonical toleration `nvidia.com/gpu:NoSchedule`). Do **not** invent a `nvidia.com/gpu.driver.ready` label; NVIDIA does not have one. Our existing `nvidia.driver/state=ready` is in a **different label namespace** (`nvidia.driver/` vs `nvidia.com/gpu.`) and is therefore not a conflict — but it is also not a convention NVIDIA established. The "ecosystem consistency" goal is best served by aligning the *gating mechanism* (label-based nodeSelector with explicit toleration), not by stealing a key NVIDIA never published.

---

## Node labels — the canonical list NVIDIA applies

The operator both *consumes* labels written by NFD/GFD and *writes* its own labels. The authoritative list of operator-written labels lives in `controllers/state_manager.go:41-81` and the per-workload map at `controllers/state_manager.go:88-113`.

| Key | Example value | Who writes it | Lifecycle | Source ref |
|---|---|---|---|---|
| `nvidia.com/gpu.present` | `"true"` / `"false"` | gpu-operator controller (`labelGPUNodes`) | Set `true` when node has NFD pci-10de label; flipped to `"false"` if those NFD labels later disappear (e.g. card removal) | `controllers/state_manager.go:42, 552-563` |
| `nvidia.com/gpu.deploy.driver` | `"true"` | gpu-operator controller (`addGPUStateLabels`) | Added once `gpu.present=true` AND workload config is `container`; **driver DS nodeSelector targets this** | `state_manager.go:90`, `assets/state-driver/0500_daemonset.yaml:28` |
| `nvidia.com/gpu.deploy.gpu-feature-discovery` | `"true"` | gpu-operator controller | Same lifecycle as `deploy.driver`; GFD DS nodeSelector | `state_manager.go:91`, `assets/gpu-feature-discovery/0500_daemonset.yaml:21` |
| `nvidia.com/gpu.deploy.container-toolkit` | `"true"` | gpu-operator controller | Container workload mode only | `state_manager.go:92` |
| `nvidia.com/gpu.deploy.device-plugin` | `"true"` | gpu-operator controller | Container workload mode only; device-plugin DS nodeSelector | `state_manager.go:93`, `assets/state-device-plugin/0500_daemonset.yaml:20` |
| `nvidia.com/gpu.deploy.dcgm`, `…dcgm-exporter`, `…node-status-exporter`, `…operator-validator` | `"true"` | gpu-operator controller | Container workload mode (validator DS nodeSelector targets the latter) | `state_manager.go:94-97`, `assets/state-operator-validation/0500_daemonset.yaml:21` |
| `nvidia.com/gpu.deploy.sandbox-device-plugin`, `…sandbox-validator`, `…vfio-manager`, `…kata-manager`, `…cc-manager`, `…vgpu-manager`, `…vgpu-device-manager`, `…kata-sandbox-device-plugin` | `"true"` | gpu-operator controller | VM-passthrough / VM-vGPU / Kata workload modes (per-key matrix in source) | `state_manager.go:75,100-111,363` |
| `nvidia.com/gpu.deploy.mig-manager` | `"true"` | gpu-operator controller | Added when `nvidia.com/mig.capable=true` (A100/A30/H100 family) and container workload | `state_manager.go:46,421-425` |
| `nvidia.com/gpu.deploy.operands` | `"true"` (user-set, default absent) | **user** (admin) | When set to `"false"`, **all** `deploy.*` labels are removed from node — node-level operands kill-switch | `state_manager.go:44,317-323,397-401` |
| `nvidia.com/gpu.workload.config` | `container` / `vm-passthrough` / `vm-vgpu` | **user** (admin) | Switches the workload-config map applied by the operator | `state_manager.go:70-73,334-345` |
| `nvidia.com/mig.config` | `all-disabled` / user-defined | gpu-operator + user | Operator writes `all-disabled` when MIG Manager is enabled but no config exists | `state_manager.go:50-51,580-586` |
| `nvidia.com/mig.capable` | `"true"` | NFD/GFD | Read-only consumed; combined with product-string heuristic in `hasMIGCapableGPU` | `state_manager.go:48,286-306` |
| `nvidia.com/gpu.product` | e.g. `Tesla-T4`, `NVIDIA-A100-SXM4-80GB` | GFD | Read-only consumed | `state_manager.go:53` |
| `nvidia.com/vgpu.host-driver-version` | string | GFD | Used as vGPU-node detector | `state_manager.go:52,287-290` |
| `nvidia.com/cuda.driver.major` | string | GFD | Read by nodeinfo package | `internal/nodeinfo/attributes.go:40` |
| `nvidia.com/gpu-driver-upgrade-state` | `upgrade-required` / `cordon-required` / `drain-required` / `pod-restart-required` / `validation-required` / `uncordon-required` / `upgrade-done` / `upgrade-failed` | upgrade controller via `k8s-operator-libs` | Set per node during a rolling driver-DS upgrade; cleared when feature is disabled | `vendor/.../upgrade/consts.go:21,48-82`; `controllers/upgrade_controller.go:201-228` |
| `nvidia.com/gpu-driver-upgrade.skip` | `"true"` | **user** | Per-node skip switch read by upgrade lib | `vendor/.../upgrade/consts.go:23` |
| `nvidia.com/gpu-driver-upgrade-drain.skip` | `"true"` | **user** (pod label, not node) | Pod selector excluded from drain during upgrade | `controllers/upgrade_controller.go:66,UpgradeSkipDrainLabelSelector` |
| `nvidia.com/gdrcopy.capable` | `"true"` | NFD via NodeFeatureRule | Set when `gdrdrv` module is loaded on host | `deployments/.../templates/nodefeaturerules.yaml:8-15` |
| `nvidia.com/gds.capable` | `"true"` | NFD via NodeFeatureRule | Set when `nvidia_fs` module is loaded | `nodefeaturerules.yaml:16-23` |
| `nvidia.com/peermem.capable` | `"true"` | NFD via NodeFeatureRule | Set when `nvidia_peermem` module is loaded | `nodefeaturerules.yaml:24-31` |
| `nvidia.com/precompiled` | `"true"` / `"false"` | Helm template label on driver DS | Identifies whether DS uses pre-compiled vs build-on-load driver | `assets/state-driver/0500_daemonset.yaml:6,24` |
| `nvidia.com/gpu-driver-upgrade-enabled` (annotation, not label) | `"true"` | gpu-operator controller (`applyDriverAutoUpgradeAnnotation`) | Added to all GPU nodes when `driver.upgradePolicy.autoUpgrade=true` is set in ClusterPolicy | `state_manager.go:78, 462-517` |
| `feature.node.kubernetes.io/pci-10de.present` (+ `pci-0302_10de.present`, `pci-0300_10de.present`) | `"true"` | **NFD** | The signal the operator uses to detect "this is a GPU node" before writing `gpu.present` | `state_manager.go:115-119` |

**No `nvidia.com/gpu.driver.ready` label exists.** Driver readiness is signalled via the host-FS file `/run/nvidia/validations/driver-ready` (written by `nvidia-operator-validator`) and `/run/nvidia/validations/.driver-ctr-ready` (written by the driver container's `startupProbe`). Operand DS init containers gate on the file, not on a node label. See `assets/state-container-toolkit/0400_configmap.yaml:12`, `assets/state-device-plugin/0400_configmap.yaml:12`, `assets/state-mig-manager/0420_configmap.yaml:12`, and the validator preStop hook `assets/state-operator-validation/0500_daemonset.yaml:133-136` which deletes the `*-ready` files when validator stops.

---

## Node taints — the canonical list NVIDIA applies

**None.** This was the most surprising finding of the audit.

The `Resources` struct at `controllers/resource_manager.go:60` has a `Taint corev1.Taint` field, but it is never assigned in v26.3.1 — no asset YAML carries `kind: Taint`, no controller method sets `.Spec.Taints` on a `Node`, and `grep -rn 'Taint' controllers/` outside test files returns only that one struct field. Treat the field as dead code (likely a vestige of an earlier plan).

What the operator **does** do that scheduler-fences a node:

| Mechanism | When | What primitive | Source |
|---|---|---|---|
| `kubectl cordon` (sets `Node.Spec.Unschedulable=true`) | During a driver-DS upgrade, after entering `cordon-required` state | `drain.RunCordonOrUncordon(helper, node, true)` | `vendor/.../upgrade/cordon_manager.go:38-42` |
| `kubectl drain` | During driver upgrade, after entering `drain-required` state | k8s-drain library | `vendor/.../upgrade/drain_manager.go` (whole file) |
| Per-node label gate (`nvidia.com/gpu.deploy.*`) flipped to absent/false | When operator decides node should not run an operand | DS `nodeSelector` no longer matches → pod is evicted at next reconcile | `state_manager.go:431-460` (`removeGPUStateLabels`) |
| NFD-managed taint via NodeFeatureRule `.taints` block | **Optional**, off by default (`nfd.master.enableTaints=false`) | NFD applies whatever taint a NodeFeatureRule's `taints:` block declares | `deployments/gpu-operator/values.yaml:577`, NFD CRD `nfd-api-crds.yaml:730-755` |

There is an NFD-side feature where rules can declare `taints:` — but the bundled `nodefeaturerules.yaml` template ships **no taints** (only labels). The Helm value `nfd.master.enableTaints` defaults to `false`.

What every NVIDIA-owned DaemonSet **tolerates** (so cluster admins can taint GPU nodes themselves with `nvidia.com/gpu:NoSchedule` to keep non-GPU work off them):

```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
```

Every operand DS carries this exact toleration: driver (`assets/state-driver/0500_daemonset.yaml:29-32`), device-plugin (`assets/state-device-plugin/0500_daemonset.yaml:21-24`), GFD (`assets/gpu-feature-discovery/0500_daemonset.yaml:22-25`), validator (`assets/state-operator-validation/0500_daemonset.yaml:22-25`). The default chart applies the same toleration cluster-wide via `daemonsets.tolerations` at `deployments/gpu-operator/values.yaml:41-44`.

So `nvidia.com/gpu:NoSchedule` is **the canonical taint key** that NVIDIA assumes a cluster admin will apply if they want to fence GPU nodes — even though gpu-operator itself never sets it.

---

## Where the logic lives

| Concern | Component | Layer |
|---|---|---|
| `nvidia.com/gpu.present` set/cleared | `controllers/state_manager.go:labelGPUNodes()` | gpu-operator controller-runtime reconciler |
| `nvidia.com/gpu.deploy.*` map applied/removed | `controllers/state_manager.go:updateGPUStateLabels()` → `addGPUStateLabels()` / `removeGPUStateLabels()` | gpu-operator controller |
| Workload-config dispatch (container vs VM) | `controllers/state_manager.go:getWorkloadConfig()` reads user-set `nvidia.com/gpu.workload.config` | gpu-operator controller |
| Driver-DS upgrade state machine + cordon/drain | `vendor/github.com/NVIDIA/k8s-operator-libs/pkg/upgrade/*.go` invoked from `controllers/upgrade_controller.go` | shared NVIDIA upgrade library, embedded in the operator binary |
| GFD-style hardware labels (`gpu.product`, `gpu.memory`, `gpu.count`, `cuda.driver.major`, etc.) | `gpu-feature-discovery` binary inside the GFD DS pod | separate component (DS, talks to NFD master via local FS at `/etc/kubernetes/node-feature-discovery/features.d`) |
| `pci-10de.present` and other PCI presence labels | NFD worker pods | upstream NFD (vendored chart at `deployments/gpu-operator/charts/node-feature-discovery/`) |
| `gdrcopy/gds/peermem.capable` labels | NFD master applying `NodeFeatureRule` CR | NFD + CR shipped by the chart |
| Driver-container readiness file (`.driver-ctr-ready`) | `assets/state-driver/0400_configmap.yaml` `startup-probe.sh` script run by driver container's `startupProbe` | driver pod itself, via probe + lifecycle preStop |
| Validator readiness file (`driver-ready`, `toolkit-ready`, `plugin-ready`, `cuda-ready`, `mofed-ready`, …) | `cmd/nvidia-validator/main.go` writing under `/run/nvidia/validations/` | validator DS init containers |

The clear separation: **node-state labels are operator-controller-owned**, **readiness signals are filesystem-owned**. No single layer carries both.

---

## Probe configurations

### `nvidia-driver-ctr` (the kernel-module-loader container)

`assets/state-driver/0500_daemonset.yaml:140-149`:

```yaml
startupProbe:
  exec:
    command:
    - sh
    - /usr/local/bin/startup-probe.sh
  initialDelaySeconds: 60
  failureThreshold: 120
  successThreshold: 1
  periodSeconds: 10
  timeoutSeconds: 60
```

Time budget: 60s grace + 120 × 10s = **20 minutes** before kubelet declares startup failed. The script (`assets/state-driver/0400_configmap.yaml`) checks (i) `/sys/module/nvidia/refcnt` exists, (ii) `nvidia-smi` returns 0, then atomically writes `/run/nvidia/validations/.driver-ctr-ready`.

`lifecycle.preStop` deletes `/run/nvidia/validations/.driver-ctr-ready` (`0500_daemonset.yaml:150-153`) so consumers detect un-ready immediately on graceful pod stop.

**There is no `livenessProbe` and no `readinessProbe` on the driver container.** This is intentional — a kernel module is host state. Once loaded, restarting the pod won't unload or reload it. NVIDIA's stance is: trust the startup probe to gate the "go" signal; once started, don't liveness-restart (which would burn cycles for nothing and could mask real host kernel issues).

The defaults from the Helm chart confirm: `deployments/gpu-operator/values.yaml:138-144` shows `driver.startupProbe.{initialDelaySeconds:60, periodSeconds:10, timeoutSeconds:60, failureThreshold:120}` — no `livenessProbe` or `readinessProbe` keys defaulted at all.

### `nvidia-peermem-ctr` sidecar (driver DS) — **the one container that has a liveness probe**

`assets/state-driver/0500_daemonset.yaml:176-193`:

```yaml
startupProbe:
  exec: { command: [sh, -c, 'nvidia-driver probe_nvidia_peermem'] }
  initialDelaySeconds: 10
  failureThreshold: 120
  successThreshold: 1
  periodSeconds: 10
  timeoutSeconds: 10
livenessProbe:
  exec: { command: [sh, -c, 'nvidia-driver probe_nvidia_peermem'] }
  periodSeconds: 30
  initialDelaySeconds: 30
  failureThreshold: 1
  successThreshold: 1
  timeoutSeconds: 10
```

`failureThreshold: 1` is aggressive — one missed probe restarts the sidecar — but the rationale is documented inline: "takes care of loading nvidia_peermem whenever it gets dynamically unloaded during MOFED driver re-install/update" (`0500_daemonset.yaml:158`). The restart **re-runs `reload_nvidia_peermem`** which is the entire job of the container.

### `nvidia-fs-ctr` and `nvidia-gdrcopy-ctr` sidecars

Both have only a `startupProbe`, no liveness — pattern matches driver-ctr.

### `nvidia-operator-validator`

No probes on the main container — the init containers run the validators serially and the main container is `while true; do sleep 86400; done`. Readiness is signalled by the existence of `/run/nvidia/validations/<component>-ready` files written by `cmd/nvidia-validator/main.go:155-189`.

### Pattern summary

| Container | Startup | Liveness | Readiness |
|---|---|---|---|
| `nvidia-driver-ctr` | YES (script checks /sys/module + nvidia-smi) | NO | NO |
| `nvidia-peermem-ctr` | YES | YES (failureThreshold:1) | NO |
| `nvidia-fs-ctr`, `nvidia-gdrcopy-ctr` | YES | NO | NO |
| `nvidia-operator-validator` | NO | NO | NO (FS signal) |
| device-plugin, GFD, dcgm-exporter, mig-manager | mostly NO probes; gate via init container `until [ -f .../driver-ready ]` | varies | varies |

The dominant NVIDIA pattern is: **host-state containers do NOT use liveness probes** — they use startup probes plus filesystem-marker handshakes. Liveness is reserved for sidecars whose container restart actually performs a recovery action (peermem reload, etc.).

---

## Driver state machine in k8s terms

| Conceptual state | k8s primitive carrying it | How it's set | How it's cleared |
|---|---|---|---|
| "Node is a GPU node" | Label `nvidia.com/gpu.present=true` | Set by `labelGPUNodes()` after detecting NFD pci-10de label | Set to `"false"` if NFD labels disappear |
| "Operator wants driver on this node" | Label `nvidia.com/gpu.deploy.driver=true` | Set by `addGPUStateLabels()` in container workload mode | Removed if workload-config changes, or if `gpu.deploy.operands=false` |
| "Driver DS pod scheduled" | DaemonSet pod presence (driven by `nodeSelector: nvidia.com/gpu.deploy.driver=true`) | k8s scheduler | k8s scheduler when label is removed |
| "Driver still loading" | Pod is in `Ready=False` because `startupProbe` hasn't yet succeeded | startup probe script returns non-zero | startup probe writes `.driver-ctr-ready` and returns 0 |
| "Driver ready (kernel)" | File `/run/nvidia/validations/.driver-ctr-ready` exists | Probe script writes atomically | Pod `preStop` hook deletes it |
| "Driver ready (validated)" | File `/run/nvidia/validations/driver-ready` exists | `nvidia-validator` init container writes it after `chroot` checks | Validator pod `preStop` deletes `*-ready` files |
| "Driver broken / failed install" | Pod `Ready=False` for > 20 min (startupProbe failure threshold exhausted) → CrashLoopBackOff; downstream operands sit in init `wait-for /driver-ready` indefinitely | startup script returns 1 from `nvidia-smi` or `[ ! -f /sys/module/nvidia/refcnt ]` | Pod restarts and re-tries (no escalation to taint or label flip) |
| "Driver upgrade in flight" | Label `nvidia.com/gpu-driver-upgrade-state=<phase>` on the node | upgrade controller progresses through phases | Cleared at `upgrade-done` |
| "Node fenced for upgrade" | `Node.Spec.Unschedulable=true` (cordon) | `CordonManagerImpl.Cordon()` at `cordon-required` phase | `Uncordon()` at `uncordon-required` phase |

**Key gap relative to our D-1 concern:** NVIDIA's design does NOT clear `gpu.deploy.driver` when the driver crashloops. They rely on:
1. The downstream operand (device-plugin) staying blocked in `init` because `/run/nvidia/validations/driver-ready` never appears → no `nvidia.com/gpu` resource is registered on the node → kubelet doesn't advertise the resource → GPU-requesting pods don't get scheduled (because they request `nvidia.com/gpu: 1`).
2. So the *resource-not-advertised* path is the actual "no-schedule" fence, not a label or taint flip.

This is a defensible design only if every consumer requests `nvidia.com/gpu: <N>` in `resources.limits`. Workloads that gate purely on a `nodeSelector` (which is exactly what our injector consumer contract does, per `k8s/daemonset.yaml:11`) would bypass that fence — which is the D-1 risk.

---

## Multi-node rollout strategy

| DaemonSet | Strategy | Why |
|---|---|---|
| `nvidia-driver-daemonset` | **`type: OnDelete`** — hard-coded in `assets/state-driver/0500_daemonset.yaml:16-17` AND enforced in `controllers/object_controls.go:3814-3817` ("`// disallow setting RollingUpdate strategy with the driver container`") | A rolling driver-pod restart would race with in-flight CUDA workloads; the upgrade controller orchestrates the per-node sequence (cordon → drain → restart pod → validate → uncordon) explicitly via the `gpu-driver-upgrade-state` label machine. Letting the kubelet auto-roll would defeat the cordon/drain. |
| All other operands (device-plugin, GFD, dcgm, validator, mig-manager, etc.) | Default `RollingUpdate` with `maxUnavailable: 1` from `deployments/gpu-operator/values.yaml:47-52` | Standard k8s rolling DS update; these operands are stateless w.r.t. the kernel module |
| Operator controller deployment | Single replica, k8s `Recreate` strategy via the operator chart | Single-writer reconciliation |

The **driver upgrade orchestration is the headline mechanism**: instead of relying on the DaemonSet controller to roll, the gpu-operator's `UpgradeReconciler` (`controllers/upgrade_controller.go:82`) drives a per-node state machine. With `driver.upgradePolicy.autoUpgrade=true` (`values.yaml:151`, default), the configurable knobs are:
- `maxParallelUpgrades: 1` — at most one node at a time
- `maxUnavailable: 25%` — same as default DS rolling
- `drainSpec.podSelector: nvidia.com/gpu-driver-upgrade-drain.skip!=true` — auto-injected at `upgrade_controller.go:172-177`

So the answer to the rollout question is **`OnDelete` + custom controller-driven serial rollout**, not `RollingUpdate`. This is a deliberate departure from the standard k8s DS upgrade story.

---

## Comparison to our injector

Working from `/root/nvidia-driver-injector/k8s/daemonset.yaml` and `/root/nvidia-driver-injector/entrypoint.sh:61-105`.

| Concern | Injector today | NVIDIA gpu-operator | Aligned? |
|---|---|---|---|
| **Node label "this is a GPU node"** | none (relies on `tolerations: operator: Exists` to land on every node) | `nvidia.com/gpu.present=true` (controller-written from NFD signal) | ❌ different — our injector self-discovers at runtime per-node; operator front-loads via NFD |
| **Node label "operator wants driver here"** | none (nodeSelector empty) | `nvidia.com/gpu.deploy.driver=true` | ❌ different — we run-everywhere; they gate-everywhere |
| **Node label "driver is ready"** | `nvidia.driver/state=ready` (custom namespace) — set by entrypoint after `modprobe` succeeds | NONE on node labels; FS file `/run/nvidia/validations/driver-ready` | **divergent semantics** — we surface readiness as a node label; NVIDIA surfaces it as a host-FS file consumed by init containers in other DS pods |
| **Node label "driver version"** | `nvidia.driver/version=595.71.05-aorus.14` — set by entrypoint | None on node directly; `nvidia.com/cuda.driver.major` written by GFD; image tag on DS | ❌ different — closest analogue (`cuda.driver.major`) is much coarser |
| **Taint for "no driver"** | none | none (NVIDIA does NOT taint) | ✅ same (both rely on consumer-side gating) |
| **Toleration on driver pod** | `operator: Exists` (tolerates *everything*) | `key: nvidia.com/gpu, operator: Exists, effect: NoSchedule` (tolerates only the canonical GPU taint plus the per-DS-Helm-injected control-plane toleration) | ❌ wider — our DS tolerates more than necessary |
| **Driver-pod startup probe** | none | YES — 20 min budget, checks /sys/module + nvidia-smi, writes FS marker | ❌ we have no startup probe |
| **Driver-pod liveness probe** | YES — `[ -e /sys/module/nvidia/version ]`, 180s+60s×3 | NO on driver-ctr | ❌ **opposite philosophy** — this is precisely the D-2 issue |
| **Driver-pod readiness probe** | YES — `[ -e /sys/module/nvidia/version ]`, 120s+15s | NO on driver-ctr | ❌ opposite philosophy |
| **preStop hook on driver pod** | none | `rm -f /run/nvidia/validations/.driver-ctr-ready` | ❌ — equivalent in our world would be a `kubectl label nodes self nvidia.driver/state-` on graceful stop |
| **Rollout strategy** | `RollingUpdate, maxUnavailable: 1` (`daemonset.yaml:184-192`) | **`OnDelete`** for the driver DS, hard-coded + enforced by controller | ❌ different — but ours is single-node so the distinction is academic until N > 1 |
| **Service account / RBAC** | `nvidia-driver-injector` SA with `nodes: [get, patch]` | `nvidia-driver` SA with `nodes: [get, list, patch, update, watch]` plus pods, pods/eviction, daemonsets | similar (we have strictly less — fine because we don't drain) |

---

## Recommended adoption: exact key/value strings to copy verbatim

**Tier 1 (adopt verbatim):**

1. **DaemonSet nodeSelector** — gate the injector DS to nodes intended for a GPU driver:
   ```yaml
   nodeSelector:
     nvidia.com/gpu.deploy.driver: "true"
   ```
   THE canonical key for "cluster operator has decided this node should host a kernel-driver-installing DS". Admin sets it by hand; single-node k3s can keep `nodeSelector: {}` today, but standardising on the key removes divergence the moment a second node arrives.

2. **Toleration** — match exactly:
   ```yaml
   tolerations:
     - key: nvidia.com/gpu
       operator: Exists
       effect: NoSchedule
   ```
   The convention admins use to fence GPU nodes; every NVIDIA operand DS carries exactly this. Our current `operator: Exists` (no key) tolerates *all* taints — broader than the convention; tighten to canonical, optionally adding a control-plane toleration on multi-node.

**Tier 2 (do NOT adopt — these don't exist in NVIDIA's design):**

3. **No canonical `nvidia.com/gpu.driver.ready` node label exists in v26.3.1.** Don't invent one in the `nvidia.com/` namespace — that namespace is implicitly owned by NVIDIA/NFD/GFD output, squatting risks future collision. Keep our readiness signal in our own namespace (`nvidia.driver/state=ready`).

4. **No canonical node taint NVIDIA applies.** Don't add one without explicit user sign-off.

**Tier 3 (semantic alignment, different keys):**

5. **Probe philosophy.** NVIDIA's driver-ctr has **no livenessProbe**. The injector's current livenessProbe (`[ -e /sys/module/nvidia/version ]`, failureThreshold:3) is the direct cause of the D-2 crashloop pattern. The fix is NVIDIA's pattern: replace livenessProbe with **startupProbe** (one-shot, long budget), keep readinessProbe, gracefully exit-wait after irrecoverable error. The entrypoint already does `sleep infinity` post-modprobe — wire the probe to match.

6. **preStop hook.** When the driver pod is gracefully torn down, remove `nvidia.driver/state=ready` so consumers immediately observe the node as not-ready. Mirrors NVIDIA's `rm -f .../driver-ctr-ready` in intent. Our `uninstall` path (`entrypoint.sh:104-105`) already implements the label removal — wiring it to `lifecycle.preStop` would close the gap.

7. **Rollout strategy for multi-node future.** Switch driver DS to `updateStrategy: OnDelete` once N > 1, and orchestrate version bumps via `kubectl delete daemonset + kubectl apply` (already the documented path per `daemonset.yaml:184-189`) or a small wrapper mirroring the gpu-operator state machine (cordon → delete pod → wait ready → uncordon → next). For N=1 today, this is documentation, not code.

---

## Open questions / things I couldn't resolve

1. **Why is `Resources.Taint` (`controllers/resource_manager.go:60`) declared but unused?** Could be reserved feature, dead code, or used via reflection. Git-blame would clarify whether a "taint-via-asset-YAML" path was ever implemented or only sketched. Flags that "NVIDIA doesn't taint" might be a *current-version* statement rather than a *design-intent* statement.

2. **NFD `enableTaints` interaction.** Current `nodefeaturerules.yaml` declares no taints but the mechanism exists. If a future gpu-operator release flips `nfd.master.enableTaints: true` and adds a taint rule, our analysis needs update.

3. **`nvidia.com/gpu-driver-upgrade.driver-wait-for-safe-load` annotation** (`consts.go:30`) — exists for safe-load orchestration; didn't trace its full lifecycle in `safe_driver_load_manager.go`. Out of scope for D-1/D-2.

4. **NVIDIA's "no driver → no schedule" relies on `resources.limits["nvidia.com/gpu"]: 1` being universal in consumer pods.** Our consumer contract (`k8s/daemonset.yaml:11`) gates via `nodeSelector: nvidia.driver/state: ready`, not via resource requests — this is the exact divergence that makes D-1 a real bug for us but not for vanilla gpu-operator deployments. Worth confirming before assuming "mirror NVIDIA verbatim" closes D-1.

5. **Who sets `nvidia.com/gpu.deploy.driver`?** In gpu-operator it's the controller. If we adopt the key without a controller, options are: (a) admin sets manually pre-deploy (simplest, single-node-friendly), (b) the entrypoint self-sets (defeats the gate), (c) a tiny operator-shim. For N=1 today, (a) is lowest friction.
