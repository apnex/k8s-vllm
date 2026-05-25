# G1 — Driver container deep-dive

**Date:** 2026-05-25
**Auditor:** subagent G1 (1 of 4 parallel)
**Source:**
- `NVIDIA/gpu-operator @ v26.3.1` (latest stable) — local clone at `/root/gpu-operator-audit/`
- `NVIDIA/gpu-driver-container @ 25.01.21` (latest tag on the canonical Ubuntu/RHEL driver-image repo) — local clone at `/root/gpu-driver-container/`
- `NVIDIA/k8s-driver-manager @ main` (no semver tags on this repo, HEAD `9c55180`) — local clone at `/root/k8s-driver-manager/`

## TL;DR

- **The driver container itself does almost no state-machine work.** It is a one-shot "install + load + sleep forever" script. All of the *interesting* k8s-aware reliability work (cordon, drain, label-pause, pod eviction) lives in a **separate init container — `k8s-driver-manager`** — that runs **before** the driver container starts. The driver container's job is reduced to: build/install modules, modprobe, `nvidia-persistenced`, `sleep infinity`. That separation is itself the headline architectural pattern.
- **Readiness is signalled by a single file: `/run/nvidia/validations/.driver-ctr-ready`.** The startupProbe `startup-probe.sh` writes that file atomically (`mv $TMP $READY_FILE`) once `lsmod` shows `nvidia` and `nvidia-smi` succeeds. The `preStop` lifecycle hook **removes** the file. The downstream `nvidia-operator-validator` blocks on this file (`stat`) and the existence of the file gates the device-plugin/toolkit pods via node-label pauses. This is the "loud signal" we don't currently emit.
- **No liveness probe on the driver container at all** — only a startupProbe. Once startup passes, the container has *no* health re-check; if `nvidia-smi` later wedges, the pod is *not* restarted. The decision NVIDIA made here is "don't fight upstream symptoms with restarts" — restarts are reserved for explicit upgrade flow via `k8s-driver-manager`. The only liveness probe in the entire DaemonSet is on the `nvidia-peermem-ctr` side-container (and even that one is GPU-absence-tolerant — it returns 0 if MOFED isn't ready).

## State machine (the headline finding)

The "state machine" is split across two cooperating processes that run in strict sequence inside the same Pod:

1. **`k8s-driver-manager` init container** (image: `nvcr.io/nvidia/cloud-native/k8s-driver-manager`, command `driver-manager uninstall_driver`) — runs to completion **before** the driver container starts. It's the k8s-aware orchestrator.
2. **`nvidia-driver-ctr` main container** (the image from `gpu-driver-container`, command `nvidia-driver init`) — runs the install + modprobe + sleep.

### `k8s-driver-manager` (init) — the state orchestrator

From `/root/k8s-driver-manager/cmd/driver-manager/main.go:269-411`:

```go
func (dm *DriverManager) uninstallDriver() error {
    // 1. Bail if host already has a driver
    if dm.isHostDriver() { ... return ... }

    // 2. Snapshot current operand labels into dm.components
    dm.fetchCurrentLabels()
    dm.fetchAutoUpgradeAnnotation()

    // 3. **Label-pause every GPU operator component on this node** (validator, toolkit,
    //    device-plugin, GFD, DCGM, MIG, sandbox, vGPU) by rewriting their
    //    `nvidia.com/gpu.deploy.<component>` labels to `paused-for-driver-upgrade`
    //    and then **wait for those pods to actually terminate** before touching the driver.
    dm.evictAllGPUOperatorComponents()  // → calls waitForPodsToTerminate()

    // 4. Idempotency short-circuit: if existing modules match desired version+config
    //    (compared via DRIVER_CONFIG_DIGEST env var vs file on disk),
    //    SKIP uninstall, just unmount stale rootfs + remove stale PID file, re-enable labels, exit.
    if dm.shouldSkipUninstall() {
        dm.unmountRootfs()
        dm.removePIDFile()
        dm.rescheduleGPUOperatorComponents()
        return nil
    }

    // 5. Cordon → drain (optional, env-flag gated) → cleanupDriver (rmmod)
    if dm.isGPUPodEvictionEnabled() {
        dm.kubeClient.CordonNode(...)
        dm.nvDrainNode()  // selectively evicts pods with nvidia.com/gpu in resources
        ...
    }
    if dm.isDriverLoaded() {
        dm.cleanupDriver()    // rmmod
    }
    dm.unbindVfioPCI()
    if dm.isGPUDirectRDMAEnabled() { dm.waitForMofedDriver() }

    // 6. Uncordon + restore operand labels (re-enable component pods on this node)
    dm.kubeClient.UncordonNode(...)
    dm.rescheduleGPUOperatorComponents()

    if dm.isNouveauLoaded() { dm.unloadNouveau() }
    return nil
}
```

The label-pause set is enumerated explicitly at `main.go:534-549` — 10 distinct `nvidia.com/gpu.deploy.<component>` labels are flipped from `true` → `paused-for-driver-upgrade`. The flip-back logic at `main.go:892-903` is symmetric:

```go
func (dm *DriverManager) maybeSetTrue(currentValue string) string {
    switch currentValue {
    case "false": return "false"
    case pausedStr: return "true"
    default:
        re := regexp.MustCompile(pausedStr + "_?")
        result := re.ReplaceAllString(currentValue, "")
        return strings.Trim(result, "_")
    }
}
```

The label value `paused-for-driver-upgrade` (constant `pausedStr` at `main.go:47`) is the only piece of state. It's intentionally human-readable so an operator looking at `kubectl get node -o yaml` immediately knows *why* the device-plugin isn't scheduling.

### `nvidia-driver init` (main container) — the boring half

From `/root/gpu-driver-container/ubuntu24.04/nvidia-driver:469-509`:

```bash
init() {
    if [ "${DRIVER_TYPE}" = "vgpu" ]; then _find_vgpu_driver_version || exit 1; fi

    echo -e "\n========== NVIDIA Software Installer ==========\n"
    exec 3> ${PID_FILE}
    if ! flock -n 3; then
        echo "An instance of the NVIDIA driver is already running, aborting"
        exit 1
    fi
    echo $$ >&3

    trap "echo 'Caught signal'; exit 1" HUP INT QUIT PIPE TERM
    trap "_shutdown" EXIT

    _unload_driver || exit 1
    _unmount_rootfs
    _update_ca_certificates
    _update_package_cache
    _resolve_kernel_version || exit 1
    _install_prerequisites
    _link_ofa_kernel
    _install_driver
    _load_driver || exit 1
    _mount_rootfs
    _write_kernel_update_hook

    echo "Done, now waiting for signal"
    sleep infinity &
    trap "echo 'Caught signal'; _shutdown && { kill $!; exit 0; }" HUP INT QUIT PIPE TERM
    trap - EXIT
    while true; do wait $! || continue; done
    exit 0
}
```

Notable: there is **no loop-wait for GPU presence**. The script either (a) succeeds and goes to `sleep infinity` (which becomes the container's steady state) or (b) fails any of `_resolve_kernel_version | _install_driver | _load_driver` and `exit 1`s — kubelet then restarts the Pod per its standard backoff policy. There is no "GPU not yet enumerated, retry in N seconds" pattern — NVIDIA assumes traditional PCIe where the GPU is present at boot.

The `flock` on the PID file at `nvidia-driver:477-482` is the one piece of in-script reliability — guarantees that if for some reason two driver scripts are running on the same node they don't trample each other.

## Sequencing + error handling per step

| # | Step (from `init()`) | Code line | Success path | Failure path | Observable signal |
|---|---|---|---|---|---|
| 1 | `flock` PID file | `nvidia-driver:477-482` | proceeds | `exit 1` immediately with stderr `"An instance of the NVIDIA driver is already running, aborting"` | exit code 1, log line, no `.driver-ctr-ready` |
| 2 | `_unload_driver` (rmmod any previously loaded modules) | `:262-346` | proceeds | `exit 1` (e.g. driver in use, `refcnt > deps`) — logs `lsmod \| grep nvidia` + `"Could not unload NVIDIA driver kernel modules, driver is in use"` | stderr + exit 1 |
| 3 | `_unmount_rootfs` | `:394-399` | proceeds | (no failure path; `umount -l -R` is best-effort) | none |
| 4 | `_resolve_kernel_version` | `:47-61` | sets `KERNEL_VERSION` (e.g. `6.8.0-44-generic`) | `exit 1` + `"Could not resolve Linux kernel version"` | stderr + exit 1 |
| 5 | `_install_prerequisites` (apt-get install kernel-headers + kernel-modules) | `:64-91` | unpacks headers/builtin files under `/lib/modules/<KVER>` | `set -eu` aborts on apt failure | non-zero exit, last apt error visible |
| 6 | `_install_driver` (`sh NVIDIA-Linux-...run --silent`) | `:349-382` | nvidia-installer compiles + signs + installs `.ko` files | `set -eu` aborts on installer non-zero | installer log to stdout |
| 7 | `_load_driver` (`modprobe nvidia / nvidia-uvm / nvidia-modeset`) | `:194-259` | modules loaded, persistenced started | `exit 1` (script-level `\|\| exit 1`); kernel `modprobe` errors visible because of `set -o xtrace` | xtrace output + exit 1 |
| 8 | `_mount_rootfs` (rbind `/` → `/run/nvidia/driver`) | `:385-391` | host can see driver files via `/run/nvidia/driver` | `set -eu` aborts | none beyond stderr |
| 9 | `_write_kernel_update_hook` | `:402-420` | writes `/run/kernel/postinst.d/update-nvidia-driver` for auto-rebuild on kernel update | no-op if hook dir missing | none |
| 10 | `sleep infinity` | `:504-507` | container stays Running | (only signal-handler exits) | container Running |
| 11 | startupProbe (separately, by kubelet) | `0400_configmap.yaml:10-41` | writes `/run/nvidia/validations/.driver-ctr-ready` | startupProbe returns 1, kubelet keeps trying for `failureThreshold:120 × periodSeconds:10s` = 20 min before killing | file present/absent + probe exit code |

The error handling per step is uniformly *crash-loud-and-exit-1* via `set -eu` + explicit `|| exit 1`. There is no per-step retry; the retry granularity is the whole Pod (kubelet restart). The implicit assumption is "if step 5 fails, retrying step 5 won't help — something is structurally wrong, restart from step 0".

The pre-step "is the world ready for me?" work is done by `k8s-driver-manager` in the init container. The driver container itself simply assumes the world has been prepared.

## Runtime GPU absence handling

**Short answer: there is none.** NVIDIA assumes the GPU is present at boot and stays present. Two observations:

1. The startupProbe (`startup-probe.sh:19-27`) checks `/sys/module/nvidia/refcnt` and runs `nvidia-smi` *once* at startup. Once it passes, kubelet stops calling it. There is **no livenessProbe** on `nvidia-driver-ctr` (verified at `assets/state-driver/0500_daemonset.yaml:140-153` — only `startupProbe` and `lifecycle.preStop`).

2. The script enters `sleep infinity` (`nvidia-driver:504`) and *never* re-checks anything. If the GPU vanishes (theoretically: traditional PCIe surprise-remove, AER fatal, or simulated hot-unplug), the container keeps running, modules stay loaded with stale device state, the readiness file stays present, and the device-plugin keeps advertising the resource. The first thing that would notice is a *user workload* hitting EIO on a CUDA call.

3. The single liveness probe in the DaemonSet is on the `nvidia-peermem-ctr` side-container (`0500_daemonset.yaml:185-193`), and the probe (`nvidia-driver probe_nvidia_peermem`, defined at `nvidia-driver:541-551`) is explicitly designed to be **fault-tolerant**:

```bash
probe_nvidia_peermem() {
    if lsmod | grep mlx5_core > /dev/null 2>&1; then
        if [ ! -f /sys/module/nvidia_peermem/refcnt ]; then
            echo "nvidia-peermem module is not loaded"
            return 1
        fi
    else
        echo "MOFED drivers are not ready, skipping probe to avoid container restarts..."
    fi
    return 0
}
```

The comment `"skipping probe to avoid container restarts"` makes the design philosophy explicit: probes that punish absence-of-prerequisite with restarts are anti-patterns. This is directly relevant to our D-2 gap.

The `lifecycle.preStop` hook at `0500_daemonset.yaml:150-153` is the only runtime feedback path:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "rm -f /run/nvidia/validations/.driver-ctr-ready"]
```

When kubelet terminates the Pod (for any reason — drain, upgrade, eviction), this hook *removes* the readiness file *first*, so downstream validators/device-plugins observe "driver gone" via file-stat well before the actual `_shutdown`/`rmmod` happens. This is the "no-stale-state" pattern.

## Signals emitted (logs / files / exit codes / probes)

| Signal type | Where | When | Consumer |
|---|---|---|---|
| Stdout/stderr log lines | container log | continuously during install; `"Done, now waiting for signal"` at end | `kubectl logs`, log aggregators |
| `/run/nvidia/nvidia-driver.pid` | host-mounted | written under `flock` at `nvidia-driver:477-482` | other invocations of `nvidia-driver`; kernel-update hook (`_write_kernel_update_hook:402-420`) reads it to `nsenter` into the running script |
| `/run/nvidia/validations/.driver-ctr-ready` | host-mounted | written atomically by startupProbe (`tmp + mv` at configmap:33-41); removed by preStop hook | `nvidia-operator-validator` (which `stat`s it — see `cmd/nvidia-validator/main.go:698-709`); `nvidia-peermem-ctr` (`reload_nvidia_peermem` at `nvidia-driver:512-527`); `nvidia-fs-ctr` and `nvidia-gdrcopy-ctr` use `until lsmod \| grep nvidia` instead |
| Probe exit code | startupProbe | every 10s for first 20 min after pod start | kubelet — promotes pod to Ready, lets readinessGate-aware controllers schedule |
| Exit code 1 | container exit | any failure in `init()` | kubelet → restart per backoff |
| Node labels `nvidia.com/gpu.deploy.<component>` | `k8s-driver-manager` mutates them on the Node object | on uninstall start (pause), on uninstall end (re-enable) | every operand DaemonSet's `nodeSelector` — pause causes pods to be evicted, re-enable schedules them back |
| `/run/kernel/postinst.d/update-nvidia-driver` | host-mounted | `_write_kernel_update_hook:402-420` | `apt` kernel-image postinst on host triggers `nvidia-driver update --kernel ${NEW_KVER}` via `nsenter` |

The atomic-write-via-tmp pattern in the startupProbe is small but important — `mkdir -p` + `echo ... > $TMP_FILE` + `mv "$TMP_FILE" "$READY_FILE"`. Validators never see a half-written file.

There are **no explicit k8s Events** emitted by either the driver container or the driver-manager. State changes are logged to stdout only.

## Privs / capabilities / sysfs touches

From `assets/state-driver/0500_daemonset.yaml`:

- `hostPID: true` (`:46`) — required so `nvidia-persistenced` (started inside container) can see and signal host processes that hold GPU refs
- `securityContext: { privileged: true }` (`:107`, also init container `:91`) — required for `modprobe`, `rmmod`, `mount --rbind /`, writing `/sys/module/firmware_class/parameters/path`
- `seLinuxOptions: { level: "s0" }` (`:108-109`) — explicit SELinux level (matters on RHEL/OpenShift)
- `serviceAccountName: nvidia-driver` (`:46`) — with a ClusterRole that grants `nodes` get/list/patch, `pods` get/list/delete/eviction, `daemonsets` get/list (used by validator to detect operator-managed driver)
- `priorityClassName: system-node-critical` (`:45`) — pod is not preemptible

Volume mounts (`:110-139`):
- `run-nvidia` → `/run/nvidia` (Bidirectional propagation) — the rbind target
- `var-log`, `dev-log` — log + syslog plumbing
- `host-os-release` → `/host-etc/os-release` (RO) — used to pick driver flavor
- `mlnx-ofed-usr-src`, `run-mellanox-drivers` (HostToContainer) — MOFED interop
- `sysfs-memory-online` → `/sys/devices/system/memory/auto_online_blocks` — for memory hot-plug
- `firmware-search-path` → `/sys/module/firmware_class/parameters/path` — written in `_load_driver:213` to point firmware loader at the in-container firmware
- `nv-firmware` → `/lib/firmware` (host) backed by `/run/nvidia/driver/lib/firmware` — makes container-shipped firmware visible to host kernel
- `driver-startup-probe-script` (ConfigMap) → `/usr/local/bin/startup-probe.sh` — externalised probe script (so it can be updated without rebuilding the driver image)

The init `k8s-driver-manager` adds: `host-root` (`/` RO HostToContainer), `host-sys` (`/sys`).

The script touches these host sysfs paths directly:
- `/sys/module/nvidia/refcnt`, `/sys/module/nvidia_uvm/refcnt`, `/sys/module/nvidia_modeset/refcnt`, `/sys/module/nvidia_peermem/refcnt`, `/sys/module/nvidia_drm/refcnt` — for rmmod refcount checks
- `/sys/module/firmware_class/parameters/path` — write for firmware search
- `/sys/bus/pci/devices/*/vendor` — read for Mellanox detection (`_mellanox_devices_present:128-139`)

## Driver build strategy (precompiled vs build-at-start)

NVIDIA ships **both** strategies in parallel, gated by an operator-level toggle `usePrecompiled` and a DaemonSet label `nvidia.com/precompiled: "true"|"false"`:

1. **Build-at-start (default)** — `ubuntu24.04/Dockerfile`:
   - Ships the `NVIDIA-Linux-<arch>-<DRIVER_VERSION>.run` installer
   - At container start, `_install_prerequisites` does `apt-get install linux-headers-${KERNEL_VERSION}` + dpkg-extracts `linux-image-${KERNEL_VERSION}` to populate `/lib/modules/<KVER>` (`nvidia-driver:64-91`)
   - Then `_install_driver` runs the `.run` installer with `--silent --no-drm --no-nouveau-check` etc. (`:349-382`)
   - Tradeoff: large image (CUDA base + installer), slow start (kernel-headers apt + compile), but works on any kernel that has packages available in apt

2. **Precompiled** — `ubuntu24.04/precompiled/Dockerfile`:
   - Image is built for **one specific kernel** (`ARG KERNEL_VERSION=6.8.0-44-generic` at `precompiled/Dockerfile:10`)
   - Installs `linux-modules-nvidia-${DRIVER_BRANCH}-server-${KERNEL_VERSION}` + Canonical-signed `linux-signatures-nvidia-${KERNEL_VERSION}` at **build time**
   - At start, `_install_driver` in `precompiled/nvidia-driver:236-260` just `apt-get install`s the pre-staged packages
   - Tradeoff: one image per kernel version (operator picks the right one via node-label `feature.node.kubernetes.io/kernel-version.full`), but boot is ~30s instead of ~5min, and no apt access needed at runtime

The operator picks the variant via `internal/state/driver.go:81` (`precompiledSpec`) and renders different DaemonSets accordingly. The label `nvidia.com/precompiled: "false"` on the DaemonSet pod template is the marker.

**This is directly analogous to our injector's "extract from `.run` at container start" pattern** — we're on the build-at-start side of the fence. The precompiled approach is what NVIDIA's distribution images (UBI driver images for OpenShift) use; the per-kernel build is gated on the operator knowing the cluster's kernel set in advance.

## DKMS handling

NVIDIA's design **explicitly excludes DKMS** from both image variants:
- Build-at-start uses the `.run` installer with `--no-rpms` (`:372`) — installs into `/lib/modules/<KVER>/kernel/drivers/video/` directly, doesn't register with DKMS
- Precompiled uses `linux-modules-nvidia-<DRIVER_BRANCH>-server-<KVER>` which is a **discrete pre-signed `.ko` package from Canonical**, also not DKMS

The precompiled `_install_driver` (`precompiled/nvidia-driver:236-260`) goes further and *actively uninstalls* DKMS:

```bash
apt-get purge -y \
    libnvidia-egl-wayland1 \
    nvidia-dkms-${DRIVER_BRANCH}-server \
    nvidia-kernel-source-${DRIVER_BRANCH}-server \
    xserver-xorg-video-nvidia-${DRIVER_BRANCH}-server
```

`nvidia-dkms-${DRIVER_BRANCH}-server` is the package that would normally trigger DKMS auto-build on kernel updates. NVIDIA purges it explicitly to prevent it from racing against the container-shipped modules — *the same class of bug we documented in `feedback_dkms_vanilla_vs_patched_module_collision`*.

The build-at-start variant sidesteps DKMS differently: by extracting the kernel headers into the container's *own* `/lib/modules` (`:70-91`) and running the installer there, the resulting `.ko` files live inside the container's mount namespace. The rbind at `_mount_rootfs:385-391` then exposes them to the host. There's no DKMS metadata anywhere on the host; the host kernel's modprobe finds the modules via the `/run/nvidia/driver` rbind because of the `_write_kernel_update_hook`.

The kernel-update hook (`nvidia-driver:402-420`) is the in-driver equivalent of DKMS:

```bash
cat > ${KERNEL_UPDATE_HOOK} <<'EOF'
#!/bin/bash
set -eu
trap 'echo "ERROR: Failed to update the NVIDIA driver" >&2; exit 0' ERR

NVIDIA_DRIVER_PID=$(< /run/nvidia/nvidia-driver.pid)
export "$(grep -z DRIVER_VERSION /proc/${NVIDIA_DRIVER_PID}/environ)"
nsenter -t "${NVIDIA_DRIVER_PID}" -m -- nvidia-driver update --kernel "$1"
EOF
```

This script is invoked by `apt`'s kernel-image postinst, finds the still-running driver container via its PID file, and `nsenter`s into the container's mount namespace to rebuild for the new kernel. The container keeps running across the rebuild. **The `trap '...; exit 0' ERR` is deliberate** — even if the rebuild fails, the apt transaction succeeds (avoids bricking the host's package state).

## Comparison to our injector (per gap)

### D-1 — label management during driver-absent window

**NVIDIA's approach:** the `k8s-driver-manager` init container *proactively* rewrites 10 distinct `nvidia.com/gpu.deploy.<component>` labels from `true` → `paused-for-driver-upgrade` **before** unloading the driver, and **waits for the dependent operand pods to actually terminate** (`waitForPodsToTerminate` at `main.go:581-654`). Re-enables symmetrically on the way out. The label state machine is durable on the Node object — survives Pod restart of the driver itself.

**Our injector:** node carries a single label that gets stale because no init container exists to mutate it. Workload pods see a "GPU present" label while the driver pod is mid-restart.

**Pattern to consider:** add an `initContainers` pre-step that updates a node label (e.g. `vllm.apnex/gpu.deploy: paused-for-driver-restart`) and a corresponding postStop or steady-state phase that flips it back. The label-value-as-explanation pattern (`paused-for-driver-upgrade` is human-readable) is worth copying — `kubectl get node -o yaml` immediately tells an operator *why* nothing is scheduling.

### D-2 — liveness-probe-crashloop instead of clean-exit-wait

**NVIDIA's approach:** **no livenessProbe on the driver container at all.** Only a startupProbe with a 20-minute budget (`failureThreshold:120 × periodSeconds:10s`). After startup passes, the container is *trusted* to remain alive (it's just a `sleep infinity`). Restarts are reserved for the explicit upgrade flow driven by the operator-side controller, not by probe failure. The one liveness probe in the entire DaemonSet (on the peermem side-container) is explicitly designed to **return 0 when the prerequisite is absent** with the comment "skipping probe to avoid container restarts".

**Our injector:** liveness probe runs `nvidia-smi`; when the GPU is gone the probe fails, kubelet restarts the container, the container fails to find the GPU during start, crashloop.

**Pattern to consider:** drop the runtime livenessProbe; rely on startupProbe only, with a long failureThreshold. If runtime GPU-absence detection is needed, do it in a *separate* small probe pod that emits events/metrics but doesn't restart the driver. Critically — encode the "skipping probe to avoid container restarts" pattern: if a precondition (TB tunnel present, eGPU PCIe device enumerated) is *known absent*, the probe should return success, not failure. That's what NVIDIA does for peermem when MOFED is absent.

### D-4 — failure modes buried in container logs

**NVIDIA's approach:** the readiness signal is a **file path**, not a log line. `/run/nvidia/validations/.driver-ctr-ready` is the canonical "is the driver up" oracle, consumed by 4+ separate pods. The file's *content* even encodes feature flags (`GDRCOPY_ENABLED`, `GDS_ENABLED`, `GPU_DIRECT_RDMA_ENABLED`) which the validator parses to decide what sub-validations to run (`cmd/nvidia-validator/main.go:842-878`). The preStop hook deletes the file to give downstream consumers a *positive* signal that the driver is going away. Atomic-write via `tmp + mv` is used so consumers never see a partial file.

**Our injector:** failures only surface in container logs.

**Pattern to consider:** mirror the file-based readiness signal — write a structured `/run/nvidia/injector/status` file with `phase=` and `last_error=` fields, atomically. Have a preStop hook that removes it. This gives consumers (validator pods, monitoring) something to stat. Optionally: emit k8s Events on phase transitions (NVIDIA doesn't, but they have the operator-side controller as a fallback observer — we don't).

## Recommended patterns to consider adopting

1. **Two-container split** — extract a `k8s-driver-manager` style init container that owns all k8s state mutations (labels, cordon, drain). The driver container itself stays dumb. This is *the* architectural lesson.
2. **Atomic file as readiness oracle** — `/run/nvidia/validations/.driver-ctr-ready` written via `tmp + mv`, removed in preStop. Single point of truth.
3. **No livenessProbe on the driver container.** Use only a generous startupProbe (NVIDIA uses 20 min failureThreshold budget). Don't punish the container for transient downstream failures via restart.
4. **Probe fault-tolerance** — when implementing any probe, if the precondition for the check is absent, return success not failure (see `probe_nvidia_peermem`).
5. **Label-value-as-explanation** — `paused-for-driver-upgrade` is deliberately human-readable. An operator reading node spec immediately sees *why* things are paused.
6. **PID file + `flock`** for single-instance guarantee — cheap, robust, defeats double-modprobe races.
7. **DRIVER_CONFIG_DIGEST idempotency** (`main.go:670-695`) — env-var hash vs on-disk digest decides "skip uninstall". Encode spec into a digest, store on disk, only mutate world if digest changed. Could apply to "did the patch series change?" — if not, no rmmod.
8. **Kernel-update hook with `nsenter`** — DKMS without DKMS. Survives apt kernel-image updates while keeping container running.
9. **Active DKMS purge** in precompiled image — analogous to our memory note about `/lib/modules/<KVER>/extra/nvidia*.ko.xz` collision; NVIDIA bakes the cleanup into the image rather than as a runbook step.
10. **Symmetric label restore on every exit path** — `cleanupOnFailure` (`main.go:943-961`) *always* calls `rescheduleGPUOperatorComponents` even after failed uninstall. Never leave the cluster in a "paused" state without a restore attempt.

## Open questions / things I couldn't resolve

- **Precompiled-image kernel-version selection.** Saw the `nvidia.com/precompiled` label and `precompiledSpec` (`internal/state/driver.go:81`), but didn't trace the controller logic that produces N DaemonSets per kernel version. Likely near line 246 (TODO about cleanup on toggle).
- **Driver-container metrics.** `cmd/nvidia-validator/metrics.go` (321 lines) exists but the driver container itself appears to emit nothing structured beyond logs and the readiness file — metrics flow from DCGM-exporter post-validation.
- **20-minute startupProbe vs `OnDelete` update strategy.** DaemonSet uses `updateStrategy: type: OnDelete` (`0500_daemonset.yaml:18-19`); didn't trace whether the operator controller respects the startup budget on rolling restarts.
- **Stale apt cache + kernel-update hook.** Hook traps ERR and exits 0 (so apt succeeds), but container wedges at old-kernel modules. No recovery code visible — relies on next reboot triggering normal `init()`.
- **No equivalent of our `engage-persistence` flow.** NVIDIA starts `nvidia-persistenced --persistence-mode` (`:235`) but does nothing analogous to our 41W-idle-trap mitigation (`nvidia-smi -pm 1`). Either `--persistence-mode` is enough on data-center GPUs, or the lazy-bringup is Blackwell-eGPU-specific.
- **No watchdog for "driver loaded but `nvidia-smi` hangs."** No live check after the one-shot startupProbe. This is exactly the close-path bug class our patch 0029 mitigated, and validates the project policy that Q-watchdog stays Addon-class (not upstreamable): NVIDIA's design philosophy is to not have a watchdog at this layer.
