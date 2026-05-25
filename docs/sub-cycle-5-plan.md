# Sub-cycle 5 implementation plan — injector hardening + device plugin adoption

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 8 approved hardening patches from the 2026-05-25 NVIDIA gpu-operator audit + adopt the NVIDIA device plugin as the GPU resource-advertisement mechanism, eliminating D-1 (stale node label) by design.

**Architecture:** Producer (`apnex/nvidia-driver-injector`) gains structured failure surfaces (exit code enum, PC-3 readiness file, active heartbeat, DKMS pre-flight, must-gather, OnDelete strategy, startupProbe). Consumer (`apnex/k8s-vllm`) gains the NVIDIA k8s-device-plugin DaemonSet (gated by PC-3 file via initContainer) and migrates vLLM scheduling from custom label to `resources.limits[nvidia.com/gpu]: 1`.

**Tech Stack:** bash (entrypoint + tools), kubernetes manifests (yaml), shellcheck for static analysis, kubectl for validation, NVIDIA k8s-device-plugin v0.17.4.

---

## Cross-references

- **Audit:** `audit/gpu-operator/CONSOLIDATED.md` — patch candidates + design discussion
- **Mission:** `docs/mission-manifest.md` — gap D-1 closes via this plan
- **Origin:** `docs/reliability-test-2026-05-25-gpu-power-on.md` — surfaced the 4 gaps; D-1 was elevated to architectural change here
- **Test result:** device plugin validation passed on our patched 595.71.05-aorus.14 driver (NVML compatibility confirmed empirically 2026-05-25 04:39 UTC)

## Repos affected

- **Producer (driver layer):** `apnex/nvidia-driver-injector` — local clone at `/root/nvidia-driver-injector/`
- **Consumer (workload + deployment):** `apnex/k8s-vllm` — local clone at `/root/k8s-vllm/` (this repo)

PC-3 file path is a contract between the two: `/run/nvidia/injector/state` — written by producer, read by consumer.

## Pre-flight: clean up the experimental plugin deployment

The device plugin was deployed for validation testing (kubectl patched in-place, not version-controlled). Roll it back before the plan begins so the formal manifest in `apnex/k8s-vllm/k8s/device-plugin.yaml` is the source of truth.

### Task 0: Roll back experimental device plugin

**Files:**
- N/A (cluster state change only)

- [ ] **Step 1: Verify the experimental plugin is currently running**

Run:
```bash
kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset
kubectl get node obpc -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

Expected: DS shows `1/1 READY`, allocatable shows `1`.

- [ ] **Step 2: Delete the experimental DS**

Run:
```bash
kubectl delete daemonset -n kube-system nvidia-device-plugin-daemonset
```

Expected: `daemonset.apps "nvidia-device-plugin-daemonset" deleted`.

- [ ] **Step 3: Confirm the resource is no longer advertised**

Run:
```bash
sleep 5
kubectl get node obpc -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

Expected: empty output (resource removed when plugin gone).

- [ ] **Step 4: No commit (cluster state only — version-controlled deployment lands in Phase 3)**

---

## Phase 1 — Foundation patches (parallel-safe in `apnex/nvidia-driver-injector`)

These patches are independent and can each land as their own commit. They land in the producer repo. Order within Phase 1 doesn't matter; do them sequentially for clean commit history.

### Task 1: PC-7 — DKMS pre-flight scrub in entrypoint

**Files:**
- Modify: `/root/nvidia-driver-injector/entrypoint.sh` (add pre-flight block near top of `cmd_install`)

- [ ] **Step 1: Read current entrypoint to locate cmd_install function**

Run:
```bash
grep -n 'cmd_install\|^### ' /root/nvidia-driver-injector/entrypoint.sh | head -20
```

Expected: shows function header and section markers; note the line number where `cmd_install` starts.

- [ ] **Step 2: Insert DKMS scrub before the kernel build step**

In `entrypoint.sh`, immediately after the `[nvidia-driver-injector] PCI gate ✓` log line in `cmd_install`, add:

```bash
# --- PC-7: DKMS pre-flight scrub ---
# Fedora's kernel-core update auto-builds vanilla nvidia*.ko.xz via DKMS.
# depmod prefers compressed over uncompressed, so a stale DKMS artifact
# would shadow our patched build. Remove before our build/load sequence.
# See feedback_dkms_vanilla_vs_patched_module_collision (project memory).
log "PC-7: scanning for DKMS-built vanilla nvidia artifacts"
KMOD_DIR="/lib/modules/$(uname -r)/extra"
DKMS_ARTIFACTS=$(find "$KMOD_DIR" -maxdepth 1 -name 'nvidia*.ko.xz' 2>/dev/null || true)
if [ -n "$DKMS_ARTIFACTS" ]; then
    log "PC-7: scrubbing DKMS artifacts to prevent vanilla shadowing:"
    echo "$DKMS_ARTIFACTS" | sed 's/^/  /'
    echo "$DKMS_ARTIFACTS" | xargs rm -f
    depmod -a "$(uname -r)"
    log "PC-7: scrub complete"
else
    log "PC-7: no DKMS artifacts found (clean)"
fi
```

(Replace `log` with whatever the entrypoint's existing log helper is — likely `echo "[nvidia-driver-injector] ..."` or similar. Read the existing logging convention first and match it.)

- [ ] **Step 3: Run shellcheck on entrypoint**

Run:
```bash
shellcheck /root/nvidia-driver-injector/entrypoint.sh
```

Expected: no new errors introduced. (Pre-existing warnings are not blockers; report any NEW errors and fix before proceeding.)

- [ ] **Step 4: Test the scrub block does no harm when no DKMS artifacts present**

Run:
```bash
ls /lib/modules/$(uname -r)/extra/nvidia*.ko.xz 2>&1 | head -3 || echo "(none — scrub is no-op)"
bash -n /root/nvidia-driver-injector/entrypoint.sh
echo "exit=$?"
```

Expected: scrub block won't fire (no .ko.xz files); `bash -n` syntax check returns 0.

- [ ] **Step 5: Commit**

```bash
cd /root/nvidia-driver-injector
git add entrypoint.sh
git commit -m "feat(entrypoint): PC-7 DKMS pre-flight scrub

Scan for DKMS-built vanilla nvidia*.ko.xz at entrypoint start and
remove before our build/load sequence. depmod prefers compressed
over uncompressed, so a stale DKMS artifact would shadow our patched
build and silently load vanilla nvidia instead.

Known landmine documented in project memory
feedback_dkms_vanilla_vs_patched_module_collision; encoded in code
so it can't be forgotten on the next Fedora kernel upgrade.

Mirrors NVIDIA k8s-driver-manager's rmmod+module-file-deletion
init-container pattern (per G4 audit, gpu-operator issue #1390)."
```

### Task 2: PC-4 — Exit code enum + `/dev/kmsg` markers

**Files:**
- Modify: `/root/nvidia-driver-injector/entrypoint.sh` (add enum + replace `fail()` calls)

- [ ] **Step 1: Read existing fail() invocations to enumerate failure sites**

Run:
```bash
grep -nE 'fail\(|^fail\(|"FAIL' /root/nvidia-driver-injector/entrypoint.sh | head -20
```

Expected: list of all fail-call sites. Note each one; you'll need a distinct exit code per logical failure class.

- [ ] **Step 2: Add the exit code enum near the top of entrypoint.sh (after `set -euo pipefail`)**

Add this block after the shell options are set:

```bash
# --- PC-4: structured exit codes ---
# CONTRACT: exit code values are STABLE. Never reuse a number across
# versions. Adding a new failure mode means adding a new number.
# Consumers (kubelet's lastState.terminated.exitCode, must-gather.sh,
# monitoring) treat these as a stable enum.
readonly EXIT_OK=0
readonly EXIT_NO_GPU=10              # PCI gate found no NVIDIA device
readonly EXIT_BAR1_TOO_SMALL=11      # device present but BAR1 < 32 GiB
readonly EXIT_KERNEL_BUILD_MISSING=20 # /lib/modules/$(uname -r)/build absent
readonly EXIT_MODPROBE_FAILED=30     # modprobe nvidia returned non-zero
readonly EXIT_GSP_FW_LOAD=31         # nvidia-smi reports firmware error
readonly EXIT_PERSISTENCE_FAILED=40  # nvidia-smi -pm 1 returned non-zero
readonly EXIT_DEVICE_MISSING=50      # /dev/nvidia* didn't materialise in time
readonly EXIT_DKMS_SCRUB_FAILED=60   # PC-7 scrub couldn't remove .ko.xz
readonly EXIT_UNKNOWN=99             # catch-all for not-yet-enumerated cases

# fail() — replaces bare `exit 1` calls.
# Emits structured exit code AND writes a /dev/kmsg marker so the failure
# survives the container restart and is visible via dmesg/journalctl -k.
fail() {
    local code="$1"; shift
    local msg="$*"
    echo "[nvidia-driver-injector] FAIL ($code): $msg" >&2
    # /dev/kmsg is rate-limited; <3> is KERN_ERR priority.
    echo "<3>nvidia-driver-injector FAIL code=$code: $msg" > /dev/kmsg 2>/dev/null || true
    exit "$code"
}
```

- [ ] **Step 3: Replace every existing fail-site with a code-tagged fail() call**

For each line identified in Step 1, replace the existing pattern (typically `echo "FAIL: ..." >&2; exit 1`) with `fail $EXIT_<APPROPRIATE> "<msg>"`. Mapping:

| Existing failure | New call |
|---|---|
| "no GPU matching ... found on PCI" | `fail $EXIT_NO_GPU "no GPU matching 10de:* found on PCI bus"` |
| "BAR1 too small" | `fail $EXIT_BAR1_TOO_SMALL "BAR1 too small: $bar1_bytes bytes (need ≥ 34359738368)"` |
| "kernel build dir missing" | `fail $EXIT_KERNEL_BUILD_MISSING "kernel build dir absent: $KMOD_BUILD_DIR"` |
| modprobe failure | `fail $EXIT_MODPROBE_FAILED "modprobe nvidia exit=$rc"` |
| GSP firmware error | `fail $EXIT_GSP_FW_LOAD "GSP firmware load failed: $err"` |
| persistence engagement | `fail $EXIT_PERSISTENCE_FAILED "nvidia-smi -pm 1 exit=$rc"` |
| /dev/nvidia* missing | `fail $EXIT_DEVICE_MISSING "/dev/nvidia* did not materialise within ${WAIT_S}s"` |
| (PC-7 from Task 1) scrub fail | `fail $EXIT_DKMS_SCRUB_FAILED "could not remove DKMS artifact: $f"` |

Add the PC-7 scrub failure path to Task 1's block: if `rm -f` returns non-zero, call `fail $EXIT_DKMS_SCRUB_FAILED ...`.

- [ ] **Step 4: Run shellcheck**

Run:
```bash
shellcheck /root/nvidia-driver-injector/entrypoint.sh
```

Expected: no new errors.

- [ ] **Step 5: Smoke-test the fail function in isolation**

Run:
```bash
bash -c "
source /root/nvidia-driver-injector/entrypoint.sh 2>/dev/null || true
fail 99 'smoke test'
" 2>&1 | tail -3
echo "exit=$?"
```

Expected: stderr line `[nvidia-driver-injector] FAIL (99): smoke test`, exit code 99.

(`source` may fail if entrypoint has side-effects on shebang; if so, copy `fail` definition into a tmp file and test there. Mark this step DONE if you've manually verified the fail function exits with the right code via inspection.)

- [ ] **Step 6: Commit**

```bash
cd /root/nvidia-driver-injector
git add entrypoint.sh
git commit -m "feat(entrypoint): PC-4 structured exit codes + /dev/kmsg markers

Define a stable exit-code enum for the injector entrypoint. Each
failure mode gets a distinct code so kubelet's
lastState.terminated.exitCode carries meaning and consumers
(must-gather.sh, monitoring, humans) can act on it without parsing
logs.

Codes are CONTRACT: never reuse a number across versions. Adding a
new failure mode means adding a new number.

fail() helper also writes /dev/kmsg with KERN_ERR priority so the
first-failure marker survives container restart and is visible via
dmesg / journalctl -k / any host-level log scraper.

Replaces ad-hoc 'exit 1' calls throughout cmd_install. Sets up the
substrate that PC-5 must-gather.sh consumes."
```

### Task 3: PC-1 — Drop livenessProbe, add startupProbe in DaemonSet

**Files:**
- Modify: `/root/nvidia-driver-injector/k8s/daemonset.yaml`

- [ ] **Step 1: Read current probe configuration**

Run:
```bash
grep -B1 -A6 -E 'livenessProbe:|readinessProbe:|startupProbe:' /root/nvidia-driver-injector/k8s/daemonset.yaml
```

Expected: shows the existing `livenessProbe` block (executing `[ -e /sys/module/nvidia/version ]` per audit findings). Note exact indentation level.

- [ ] **Step 2: Replace livenessProbe block with startupProbe**

Delete the existing `livenessProbe:` block and replace with:

```yaml
        # PC-1: startupProbe ONLY (no livenessProbe).
        # NVIDIA gpu-operator PR #1317 explicitly retired lsmod-based
        # livenessProbes because they cause undesirable container restarts
        # that leave the driver daemonset in a bad state. Match their
        # pattern: gate startup, then trust the FS readiness oracle
        # (PC-3 /run/nvidia/injector/state) for runtime state.
        startupProbe:
          exec:
            command:
              - /bin/sh
              - -c
              - '[ -f /run/nvidia/injector/state ] && grep -q ''"phase":"ready"'' /run/nvidia/injector/state'
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          # 120 × 10s = 1200s = 20 min budget for cold modprobe + init.
          # Matches NVIDIA driver container's startupProbe budget.
          failureThreshold: 120
```

If a `readinessProbe` exists, leave it in place (it's not load-bearing for D-2; only liveness was the harm).

- [ ] **Step 3: Validate the YAML still parses**

Run:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('/root/nvidia-driver-injector/k8s/daemonset.yaml')))"
echo "exit=$?"
```

Expected: exit 0.

- [ ] **Step 4: Run kubectl client-side dry-run**

Run:
```bash
kubectl apply --dry-run=client -f /root/nvidia-driver-injector/k8s/daemonset.yaml 2>&1 | tail -5
```

Expected: `daemonset.apps/nvidia-driver-injector configured (dry run)` or similar success.

- [ ] **Step 5: Commit**

```bash
cd /root/nvidia-driver-injector
git add k8s/daemonset.yaml
git commit -m "feat(k8s): PC-1 drop livenessProbe; add startupProbe gated on PC-3 file

NVIDIA gpu-operator PR #1317 explicitly retired the structurally
identical pattern (lsmod-based livenessProbe) with this rationale:
'livenessProbes timeout due to long response times of the lsmod
commands which have led to undesirable restarts of the container
leaving the driver daemonset in a bad state.'

Confirmed empirically in the 2026-05-25 reliability test: our
livenessProbe '[ -e /sys/module/nvidia/version ]' is the direct
cause of the D-2 crashloop pattern observed during driver-absent
windows.

Replace with a startupProbe matching NVIDIA's driver-container
pattern (~20-min cold start budget) that polls PC-3 file. After
startup, no probe-driven restart — runtime state is signalled via
the PC-3 active-heartbeat file (next commit)."
```

### Task 4: PC-6a — Tighten toleration

**Files:**
- Modify: `/root/nvidia-driver-injector/k8s/daemonset.yaml`

- [ ] **Step 1: Read current tolerations**

Run:
```bash
grep -B1 -A6 'tolerations:' /root/nvidia-driver-injector/k8s/daemonset.yaml
```

Expected: shows current toleration block. Likely `operator: Exists` with no key (overly broad).

- [ ] **Step 2: Replace with NVIDIA-canonical toleration**

Replace the existing tolerations block with:

```yaml
      # PC-6a: NVIDIA-canonical toleration. Every NVIDIA operand pod in
      # gpu-operator uses exactly this toleration (G2 audit). Tighter
      # than 'operator: Exists' (which tolerates ALL taints) — accepts
      # only the canonical nvidia.com/gpu:NoSchedule taint admins use
      # to fence GPU nodes.
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
```

- [ ] **Step 3: Validate YAML + dry-run**

Run:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('/root/nvidia-driver-injector/k8s/daemonset.yaml')))" && \
kubectl apply --dry-run=client -f /root/nvidia-driver-injector/k8s/daemonset.yaml 2>&1 | tail -3
```

Expected: parses + dry-run succeeds.

- [ ] **Step 4: Commit**

```bash
cd /root/nvidia-driver-injector
git add k8s/daemonset.yaml
git commit -m "feat(k8s): PC-6a tighten toleration to NVIDIA-canonical pattern

Replace 'operator: Exists' (tolerates ALL taints) with the canonical
NVIDIA toleration 'key: nvidia.com/gpu, operator: Exists, effect:
NoSchedule' that every gpu-operator operand pod uses (per G2 audit
of NVIDIA/gpu-operator @ v26.3.1).

For single-node today this is documentation-into-manifest. For
future N>1 it preserves admin ability to taint nodes with other
keys without our injector bypassing them."
```

### Task 5: PC-10 — `updateStrategy: OnDelete`

**Files:**
- Modify: `/root/nvidia-driver-injector/k8s/daemonset.yaml`

- [ ] **Step 1: Check whether updateStrategy is currently set**

Run:
```bash
grep -A3 'updateStrategy:' /root/nvidia-driver-injector/k8s/daemonset.yaml || echo "(not set — defaults to RollingUpdate)"
```

Expected: either an explicit block or absent (defaults).

- [ ] **Step 2: Add or replace updateStrategy block**

Within the DaemonSet `spec:` (NOT under `template:`), add or replace:

```yaml
  # PC-10: OnDelete prevents auto-replace of injector pods on DS manifest
  # changes. Driver reloads must be deliberate (admin runs kubectl delete
  # pod), not a side effect of editing an env var. NVIDIA gpu-operator
  # uses this exact strategy for its driver DS (G2 audit:
  # assets/state-driver/0500_daemonset.yaml + controllers/object_controls.go).
  updateStrategy:
    type: OnDelete
```

- [ ] **Step 3: Validate YAML + dry-run**

Run:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('/root/nvidia-driver-injector/k8s/daemonset.yaml')))" && \
kubectl apply --dry-run=client -f /root/nvidia-driver-injector/k8s/daemonset.yaml 2>&1 | tail -3
```

Expected: parses + dry-run succeeds.

- [ ] **Step 4: Commit**

```bash
cd /root/nvidia-driver-injector
git add k8s/daemonset.yaml
git commit -m "feat(k8s): PC-10 updateStrategy: OnDelete

Mirror NVIDIA gpu-operator's driver DS strategy (G2 audit of
assets/state-driver/0500_daemonset.yaml AND enforced in
controllers/object_controls.go:3814-3817). kubelet stops auto-
replacing pods on DS manifest changes; admin runs 'kubectl delete
pod' explicitly to roll a new driver version.

For N=1 today: codifies what we already do operationally
('delete pod manually to roll driver updates'). For future N>1:
prevents accidental cluster-wide simultaneous driver reload from
a single DS edit."
```

### Task 6: PC-5 — Ship `must-gather.sh`

**Files:**
- Create: `/root/nvidia-driver-injector/tools/must-gather.sh`

- [ ] **Step 1: Create the must-gather script**

Write to `/root/nvidia-driver-injector/tools/must-gather.sh`:

```bash
#!/usr/bin/env bash
# must-gather.sh — single-command diagnostic bundle for the nvidia-driver-injector.
#
# Run as root on the host. Produces a tar.gz under /tmp that operators
# can attach to bug reports. Mirrors NVIDIA gpu-operator's hack/must-gather.sh
# pattern (referenced from every "share more details" issue comment per
# G4 audit).
#
# Usage:
#   sudo /root/nvidia-driver-injector/tools/must-gather.sh
#
# Output: /tmp/nvidia-injector-must-gather-<UTC-ts>.tar.gz

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root (need /sys/kernel access)" >&2
    exit 1
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
workdir="/tmp/nvidia-injector-must-gather-${ts}"
mkdir -p "$workdir"

log() { echo "[must-gather] $*"; }

log "collecting to $workdir"

# Host state
log "host kernel + cmdline"
uname -r > "$workdir/uname-r.txt"
cat /proc/cmdline > "$workdir/cmdline.txt"

log "dmesg (full + filtered)"
dmesg > "$workdir/dmesg-full.txt" 2>&1 || true
dmesg 2>/dev/null | grep -iE 'nvidia|pcie|thunderbolt|aer|xid|gsp' > "$workdir/dmesg-relevant.txt" || true

log "journalctl current boot"
journalctl -k -b > "$workdir/journalctl-kernel.txt" 2>&1 || true
journalctl -u nvidia-driver-injector-bridge-link-cap.service > "$workdir/journalctl-bridge-link-cap.txt" 2>&1 || true
journalctl -u 'vllm-soak-*' > "$workdir/journalctl-vllm-soak.txt" 2>&1 || true

log "PCI topology"
lspci -nn > "$workdir/lspci-all.txt" 2>&1 || true
lspci -vvv > "$workdir/lspci-vvv.txt" 2>&1 || true
lspci -t -nn > "$workdir/lspci-tree.txt" 2>&1 || true

log "thunderbolt state"
boltctl list > "$workdir/boltctl.txt" 2>&1 || true
for d in /sys/bus/thunderbolt/devices/*/; do
    if [ -f "$d/unique_id" ]; then
        name=$(basename "$d")
        {
            echo "--- $name ---"
            for f in unique_id vendor_name device_name authorized; do
                printf '%s=%s\n' "$f" "$(cat "$d/$f" 2>/dev/null || echo '(absent)')"
            done
        } >> "$workdir/thunderbolt-sysfs.txt"
    fi
done

log "nvidia module + devices"
cat /sys/module/nvidia/version > "$workdir/nvidia-version.txt" 2>&1 || echo "(driver not loaded)" > "$workdir/nvidia-version.txt"
ls -la /dev/nvidia* > "$workdir/dev-nvidia.txt" 2>&1 || echo "(no /dev/nvidia*)" > "$workdir/dev-nvidia.txt"
ls -la /lib/modules/$(uname -r)/extra/nvidia* > "$workdir/modules-extra.txt" 2>&1 || true

log "nvidia-smi if available"
nvidia-smi -q > "$workdir/nvidia-smi-q.txt" 2>&1 || echo "(nvidia-smi failed)" > "$workdir/nvidia-smi-q.txt"
nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,temperature.gpu,power.draw --format=csv > "$workdir/nvidia-smi-csv.txt" 2>&1 || true

log "PC-3 readiness file (the canonical injector state)"
cat /run/nvidia/injector/state > "$workdir/pc3-state.json" 2>&1 || echo "(file absent — injector may not have completed startup)" > "$workdir/pc3-state.json"

log "kubernetes state"
if command -v kubectl >/dev/null 2>&1; then
    kubectl get pods -A -o wide > "$workdir/k8s-pods-all.txt" 2>&1 || true
    kubectl get nodes -o yaml > "$workdir/k8s-nodes.yaml" 2>&1 || true
    kubectl get events -A --sort-by=.lastTimestamp > "$workdir/k8s-events.txt" 2>&1 || true
    kubectl logs -n kube-system -l app=nvidia-driver-injector --tail=200 > "$workdir/k8s-injector-logs.txt" 2>&1 || true
    kubectl logs -n kube-system -l name=nvidia-device-plugin-ds --tail=200 > "$workdir/k8s-device-plugin-logs.txt" 2>&1 || true
    kubectl logs -n vllm -l app=vllm --tail=200 > "$workdir/k8s-vllm-logs.txt" 2>&1 || true
else
    echo "(kubectl not available)" > "$workdir/k8s-skipped.txt"
fi

log "soak observability snapshot"
ls -la /var/log/vllm-soak/ > "$workdir/soak-dir-listing.txt" 2>&1 || true
cp /var/log/vllm-soak/metrics.csv "$workdir/soak-metrics.csv" 2>/dev/null || true
ls -t /var/log/vllm-soak/pods-*.txt 2>/dev/null | head -3 | xargs -I{} cp {} "$workdir/" 2>/dev/null || true

log "tar"
out="/tmp/nvidia-injector-must-gather-${ts}.tar.gz"
tar -czf "$out" -C /tmp "$(basename "$workdir")"
rm -rf "$workdir"

log "done: $out ($(stat -c %s "$out") bytes)"
log "attach this file to issues; share via: cp $out <destination>"
```

- [ ] **Step 2: Make executable**

Run:
```bash
chmod +x /root/nvidia-driver-injector/tools/must-gather.sh
```

- [ ] **Step 3: Run shellcheck**

Run:
```bash
shellcheck /root/nvidia-driver-injector/tools/must-gather.sh
```

Expected: no errors.

- [ ] **Step 4: Smoke test (actually run it)**

Run:
```bash
sudo /root/nvidia-driver-injector/tools/must-gather.sh
```

Expected: log lines for each collection step, ends with `done: /tmp/nvidia-injector-must-gather-<ts>.tar.gz`. Tar exists and is non-empty.

- [ ] **Step 5: Verify tar contents**

Run:
```bash
tar -tzf /tmp/nvidia-injector-must-gather-*.tar.gz | head -30
```

Expected: shows the bundled files (dmesg-relevant.txt, lspci-all.txt, k8s-pods-all.txt, etc.).

- [ ] **Step 6: Commit**

```bash
cd /root/nvidia-driver-injector
git add tools/must-gather.sh
git commit -m "feat(tools): PC-5 ship must-gather.sh

Single-command diagnostic bundle for operators reporting issues.
Mirrors NVIDIA gpu-operator's hack/must-gather.sh (referenced from
every 'share more details' issue comment per G4 audit of the gpu-
operator issue tracker).

Collects: host kernel state, full + filtered dmesg, journalctl
(kernel + bridge-link-cap + vllm-soak), full PCI topology, TB
state via boltctl + sysfs, nvidia module + device state, nvidia-smi
output, PC-3 readiness file, kubectl get for nodes/pods/events/logs
in kube-system + vllm namespaces, soak observability snapshot.

Outputs a single tar.gz under /tmp that operators can attach to
issues without typing 20 separate commands. Will pick up PC-3 file
once that lands; until then logs '(file absent)' transparently."
```

---

## Phase 2 — PC-3 readiness file machinery (depends on Phase 1 PC-4 enum)

This is the substrate that the device plugin gates on. Must land before Phase 3.

### Task 7: PC-3 — Add state file write helper + phase enum

**Files:**
- Modify: `/root/nvidia-driver-injector/entrypoint.sh`

- [ ] **Step 1: Add state-file helper near top of entrypoint, after the exit code enum**

Add this block after the `EXIT_*` constants:

```bash
# --- PC-3: readiness file as state machine ---
# Mirrors NVIDIA's /run/nvidia/validations/.driver-ctr-ready pattern
# (G1 audit). Consumed by the device plugin's initContainer for
# startup ordering AND by must-gather.sh for diagnostic data.
#
# Written atomically via tmp+mv. Removed in cmd_uninstall and via
# preStop hook.
readonly STATE_DIR=/run/nvidia/injector
readonly STATE_FILE="${STATE_DIR}/state"

# write_state <phase> [last_error_code] [last_error_msg]
# Phase enum: starting, scrubbing_dkms, kernel_build, modprobe,
#             materializing_devs, engaging_persistence, ready,
#             degraded, failed
write_state() {
    local phase="$1"
    local err_code="${2:-0}"
    local err_msg="${3:-}"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$STATE_DIR"
    local tmp="${STATE_FILE}.tmp.$$"
    # Driver version + PCI + BAR1 best-effort; OK to be empty in early phases.
    local driver_ver bar1_gib gpu_pci
    driver_ver=$(cat /sys/module/nvidia/version 2>/dev/null || echo "")
    gpu_pci=$(lspci -d 10de: 2>/dev/null | awk '{print $1; exit}')
    if [ -n "$gpu_pci" ]; then
        local bar1_bytes
        bar1_bytes=$(awk 'NR==2 {print strtonum("0x" $2) - strtonum("0x" $1) + 1}' \
            "/sys/bus/pci/devices/0000:${gpu_pci}/resource" 2>/dev/null || echo 0)
        bar1_gib=$((bar1_bytes / 1024 / 1024 / 1024))
    else
        bar1_gib=0
    fi
    # Build JSON with jq if available, fallback to printf
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg phase "$phase" \
            --arg ts "$now" \
            --arg ver "$driver_ver" \
            --arg pci "$gpu_pci" \
            --argjson bar1 "$bar1_gib" \
            --argjson code "$err_code" \
            --arg msg "$err_msg" \
            '{phase:$phase, last_checked:$ts, driver_version:$ver,
              gpu_pci:$pci, bar1_size_gib:$bar1,
              last_error_code:$code, last_error:$msg}' > "$tmp"
    else
        printf '{"phase":"%s","last_checked":"%s","driver_version":"%s","gpu_pci":"%s","bar1_size_gib":%d,"last_error_code":%d,"last_error":"%s"}\n' \
            "$phase" "$now" "$driver_ver" "$gpu_pci" "$bar1_gib" "$err_code" "$err_msg" > "$tmp"
    fi
    mv -f "$tmp" "$STATE_FILE"
}

remove_state() {
    rm -f "$STATE_FILE"
}
```

- [ ] **Step 2: Sprinkle write_state calls at each phase boundary in cmd_install**

After each existing log line marking a phase transition, add `write_state <phase>`:

```bash
# Near top of cmd_install:
write_state "starting"

# After PC-7 scrub block:
write_state "scrubbing_dkms"  # before the scrub
# ... existing scrub code ...

# After kernel build step:
write_state "kernel_build"
# ... existing kernel build code ...

# Just before modprobe nvidia:
write_state "modprobe"
# ... existing modprobe code ...

# After modprobe success, before waiting for /dev/nvidia*:
write_state "materializing_devs"
# ... existing device-wait code ...

# Before nvidia-smi -pm 1:
write_state "engaging_persistence"
# ... existing persistence code ...

# After all of cmd_install completes successfully:
write_state "ready"
log "PC-3: state=ready written to $STATE_FILE"
```

Update `fail()` to ALSO write `failed` state before exiting:

```bash
fail() {
    local code="$1"; shift
    local msg="$*"
    echo "[nvidia-driver-injector] FAIL ($code): $msg" >&2
    echo "<3>nvidia-driver-injector FAIL code=$code: $msg" > /dev/kmsg 2>/dev/null || true
    write_state "failed" "$code" "$msg" || true  # best-effort; ignore if dir absent
    exit "$code"
}
```

- [ ] **Step 3: Wire remove_state into cmd_uninstall**

In `cmd_uninstall`, after stopping/unloading:

```bash
remove_state
```

- [ ] **Step 4: Add active heartbeat to the idle loop**

Replace the current idle-loop tail of `cmd_install` (typically `sleep infinity` or `wait`) with:

```bash
# --- PC-3 active heartbeat (composite design) ---
# Re-verify driver state every HEARTBEAT_INTERVAL seconds. Update file
# timestamp + write phase=degraded if anything's wrong. This is more
# active than NVIDIA's "sleep infinity" pattern — appropriate for our
# eGPU/TB reality where GPUs can disappear at runtime.
readonly HEARTBEAT_INTERVAL=30
log "PC-3: entering active heartbeat loop (interval=${HEARTBEAT_INTERVAL}s)"
while :; do
    sleep "$HEARTBEAT_INTERVAL"
    if [ ! -f /sys/module/nvidia/version ]; then
        write_state "degraded" 30 "nvidia module unloaded mid-run"
        continue
    fi
    if [ ! -e /dev/nvidia0 ]; then
        write_state "degraded" 50 "/dev/nvidia0 disappeared"
        continue
    fi
    # All checks pass; refresh ready state (updates last_checked timestamp)
    write_state "ready"
done
```

- [ ] **Step 5: Update DaemonSet manifest to mount PC-3 state dir from host**

Modify `/root/nvidia-driver-injector/k8s/daemonset.yaml` — under `spec.template.spec`, add to `volumes:`:

```yaml
        - name: pc3-state
          hostPath:
            path: /run/nvidia/injector
            type: DirectoryOrCreate
```

And under the container's `volumeMounts:`:

```yaml
            - name: pc3-state
              mountPath: /run/nvidia/injector
```

Also add a preStop lifecycle hook to the container:

```yaml
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - 'rm -f /run/nvidia/injector/state'
```

- [ ] **Step 6: Validate manifest + shellcheck**

Run:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('/root/nvidia-driver-injector/k8s/daemonset.yaml')))"
shellcheck /root/nvidia-driver-injector/entrypoint.sh
kubectl apply --dry-run=client -f /root/nvidia-driver-injector/k8s/daemonset.yaml 2>&1 | tail -3
```

Expected: YAML parses; shellcheck clean; dry-run succeeds.

- [ ] **Step 7: Commit**

```bash
cd /root/nvidia-driver-injector
git add entrypoint.sh k8s/daemonset.yaml
git commit -m "feat(entrypoint+k8s): PC-3 readiness file with active heartbeat

Add /run/nvidia/injector/state as the canonical readiness signal.
Mirrors NVIDIA gpu-operator's /run/nvidia/validations/.driver-ctr-
ready pattern (G1 audit) but extends with our project's reliability
needs:

- Atomic tmp+mv writes
- Phase enum: starting → scrubbing_dkms → kernel_build → modprobe →
  materializing_devs → engaging_persistence → ready (or degraded/failed)
- Active heartbeat loop replaces NVIDIA's 'sleep infinity' — re-
  verifies driver + devices every 30s, writes phase=degraded if state
  changes. Appropriate for our eGPU/TB reality where GPUs can vanish
  at runtime (per MISSION-1 Sub-mission C).
- Removed by preStop hook on intentional shutdown
- Lives on tmpfs (/run) — cleared on host reboot (correct semantics)

DaemonSet mounts /run/nvidia/injector via hostPath so the file is
visible to other containers (next commit: device plugin's
initContainer reads this file for startup ordering).

fail() now also writes phase=failed + last_error_code + last_error
before exiting — must-gather.sh picks up the rich diagnostic info."
```

---

## Phase 3 — Device plugin DaemonSet (in `apnex/k8s-vllm`)

The device plugin lives in the CONSUMER repo (this one), not the producer. It's a workload-side concern.

### Task 8: Create device plugin manifest

**Files:**
- Create: `/root/k8s-vllm/k8s/device-plugin.yaml`

- [ ] **Step 1: Write the device plugin DS manifest**

Write to `/root/k8s-vllm/k8s/device-plugin.yaml`:

```yaml
# NVIDIA k8s-device-plugin v0.17.4 — advertises nvidia.com/gpu as a
# kubelet resource so workloads can schedule via resources.limits.
# Eliminates the D-1 stale-label gap by design: when NVML returns
# 0 GPUs, plugin advertises 0, scheduler stops scheduling.
#
# Patched from upstream
# https://github.com/NVIDIA/k8s-device-plugin/blob/v0.17.4/deployments/static/nvidia-device-plugin.yml
# with:
#   - runtimeClassName: nvidia (our runtime contract)
#   - NVIDIA_VISIBLE_DEVICES=all + NVIDIA_DRIVER_CAPABILITIES env
#   - initContainer that waits for the injector's PC-3 ready signal
#     before starting NVML probe (avoids 'No devices found' crashloop)
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
  labels:
    app.kubernetes.io/name: nvidia-device-plugin
    app.kubernetes.io/version: "0.17.4"
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      priorityClassName: system-node-critical
      runtimeClassName: nvidia
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
        - key: CriticalAddonsOnly
          operator: Exists
      initContainers:
        # Gate startup on the injector's PC-3 readiness file. Without this,
        # the plugin can race ahead of the injector and fail NVML probe with
        # 'No devices found. Waiting indefinitely.'
        - name: wait-for-driver
          image: alpine:3.20
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              STATE=/run/nvidia/injector/state
              echo "wait-for-driver: polling for $STATE phase=ready (timeout 600s)"
              t=0
              while [ "$t" -lt 600 ]; do
                if [ -f "$STATE" ] && grep -q '"phase":"ready"' "$STATE" 2>/dev/null; then
                  echo "wait-for-driver: PC-3 ready — proceeding"
                  exit 0
                fi
                sleep 2
                t=$((t + 2))
              done
              echo "wait-for-driver: TIMEOUT — PC-3 never reached ready in 600s" >&2
              exit 1
          volumeMounts:
            - name: pc3-state
              mountPath: /run/nvidia/injector
              readOnly: true
      containers:
        - name: nvidia-device-plugin-ctr
          image: nvcr.io/nvidia/k8s-device-plugin:v0.17.4
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "compute,utility"
            - name: FAIL_ON_INIT_ERROR
              value: "false"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
        - name: pc3-state
          hostPath:
            path: /run/nvidia/injector
            type: DirectoryOrCreate
```

- [ ] **Step 2: Validate the YAML**

Run:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('/root/k8s-vllm/k8s/device-plugin.yaml')))"
kubectl apply --dry-run=client -f /root/k8s-vllm/k8s/device-plugin.yaml 2>&1 | tail -3
```

Expected: parses + dry-run succeeds.

- [ ] **Step 3: Commit**

```bash
cd /root/k8s-vllm
git add k8s/device-plugin.yaml
git commit -m "feat(k8s): adopt NVIDIA k8s-device-plugin v0.17.4

Replaces the custom nvidia.driver/state=ready label contract with
the canonical NVIDIA pattern: device plugin probes NVML, advertises
nvidia.com/gpu to kubelet, scheduler is GPU-aware. Eliminates D-1
(stale node label) by design — when NVML returns 0 GPUs, plugin
advertises 0, scheduler auto-stops scheduling GPU pods.

Patched from upstream static manifest with:
- runtimeClassName: nvidia (our runtime contract — required for
  the plugin's container to see /dev/nvidia*)
- NVIDIA_VISIBLE_DEVICES=all + DRIVER_CAPABILITIES (else 'auto'
  strategy fails on our setup; empirically validated 2026-05-25)
- initContainer that waits for the injector's PC-3 ready signal
  before starting NVML probe (avoids 'No devices found' crashloop
  when plugin starts before injector finishes modprobe)
- FAIL_ON_INIT_ERROR=false so transient NVML hiccups don't
  permanently kill the plugin pod
- Drop-all capabilities + no priv-escalation security context

NVML compatibility with our patched 595.71.05-aorus.14 driver was
validated empirically before this commit (see audit log)."
```

---

## Phase 4 — vLLM consumer migration

### Task 9: Migrate vLLM deployment to `nvidia.com/gpu` resource

**Files:**
- Modify: `/root/k8s-vllm/k8s/deployment.yaml`

- [ ] **Step 1: Read current vLLM deployment**

Run:
```bash
grep -nE 'nodeSelector:|resources:|nvidia' /root/k8s-vllm/k8s/deployment.yaml
```

Expected: shows the current `nodeSelector: nvidia.driver/state=ready` and absent `resources.limits[nvidia.com/gpu]`.

- [ ] **Step 2: Remove the custom nodeSelector**

In `/root/k8s-vllm/k8s/deployment.yaml`, find and remove the block:

```yaml
      nodeSelector:
        nvidia.driver/state: ready
```

(Keep `runtimeClassName: nvidia` — that's still required for device injection via the runtime path.)

- [ ] **Step 3: Add `nvidia.com/gpu` resource request to the container**

In the vLLM container spec, add (or merge into existing `resources:` block):

```yaml
          resources:
            limits:
              nvidia.com/gpu: 1
            requests:
              nvidia.com/gpu: 1
```

- [ ] **Step 4: Validate**

Run:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('/root/k8s-vllm/k8s/deployment.yaml')))"
kubectl apply --dry-run=client -f /root/k8s-vllm/k8s/deployment.yaml 2>&1 | tail -3
```

Expected: parses + dry-run succeeds.

- [ ] **Step 5: Commit**

```bash
cd /root/k8s-vllm
git add k8s/deployment.yaml
git commit -m "feat(k8s): migrate vLLM scheduling to nvidia.com/gpu resource

Replace 'nodeSelector: nvidia.driver/state=ready' with
'resources.limits[nvidia.com/gpu]: 1'. With the device plugin
advertising the resource based on actual NVML state, the scheduler
is GPU-aware: pods only schedule when a working GPU is available
AND auto-stop scheduling when NVML reports 0 GPUs (e.g., when our
injector fails or the TB tunnel breaks).

This eliminates the D-1 stale-label problem class — there is no
longer a label that can lie about driver state. The plugin's NVML
probe is the runtime truth.

runtimeClassName: nvidia retained — device injection still happens
via the runtime path; only the SCHEDULING gate changed."
```

---

## Phase 5 — Soak resumption + validation

This phase is operational, not code-writing. Run on the live cluster.

### Task 10: Roll out the new injector image + manifests

**Files:**
- N/A (operational)

- [ ] **Step 1: Build the new injector image**

Run:
```bash
cd /root/nvidia-driver-injector
docker build -t apnex/nvidia-driver-injector:595.71.05-aorus.15 .
```

Expected: image built; tag noted for the rollout.

- [ ] **Step 2: Import to k3s containerd**

Run:
```bash
docker save apnex/nvidia-driver-injector:595.71.05-aorus.15 | sudo k3s ctr images import -
```

Expected: import successful.

- [ ] **Step 3: Update injector DS image tag, apply**

Edit `/root/nvidia-driver-injector/k8s/daemonset.yaml`: bump the image tag to `595.71.05-aorus.15`. Then:

```bash
kubectl apply -f /root/nvidia-driver-injector/k8s/daemonset.yaml
```

Expected: `daemonset.apps/nvidia-driver-injector configured` (NOT auto-replaced because PC-10 OnDelete).

- [ ] **Step 4: Manually delete the injector pod to roll the new image (OnDelete strategy)**

Run:
```bash
kubectl delete pod -n kube-system -l app=nvidia-driver-injector
```

Wait for new pod to be `1/1 Ready`:
```bash
kubectl wait -n kube-system --for=condition=Ready --timeout=300s pod -l app=nvidia-driver-injector
```

Expected: new pod Ready within 5 min (cold modprobe + persistence + PC-3 ready).

- [ ] **Step 5: Verify PC-3 file is being written + heartbeat is active**

Run:
```bash
cat /run/nvidia/injector/state
sleep 35
cat /run/nvidia/injector/state
```

Expected: file exists with `phase: ready`; `last_checked` timestamp updates between the two reads.

- [ ] **Step 6: Apply the device plugin manifest**

Run:
```bash
kubectl apply -f /root/k8s-vllm/k8s/device-plugin.yaml
kubectl rollout status -n kube-system daemonset/nvidia-device-plugin-daemonset --timeout=120s
```

Expected: plugin Ready (initContainer passes immediately because PC-3 already at ready).

- [ ] **Step 7: Verify nvidia.com/gpu is advertised**

Run:
```bash
kubectl get node obpc -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

Expected: `1`.

- [ ] **Step 8: Apply the migrated vLLM deployment**

Run:
```bash
kubectl apply -f /root/k8s-vllm/k8s/deployment.yaml
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

Expected: vLLM pod reaches Ready after cold-load (~5-15 min from HF cache).

- [ ] **Step 9: Smoke-test VIP**

Run:
```bash
curl -s --max-time 10 http://192.168.1.251:8000/v1/models | python3 -m json.tool
```

Expected: JSON response with `qwen3-coder-30b-a3b` (or whatever VLLM_MODEL is currently set to).

- [ ] **Step 10: Verify must-gather works against new state**

Run:
```bash
sudo /root/nvidia-driver-injector/tools/must-gather.sh
ls -lh /tmp/nvidia-injector-must-gather-*.tar.gz | tail -1
tar -tzf /tmp/nvidia-injector-must-gather-*.tar.gz | grep -E 'pc3-state|device-plugin' | head -5
```

Expected: tar created; contains `pc3-state.json` (with phase=ready content) AND `k8s-device-plugin-logs.txt`.

- [ ] **Step 11: Reset the soak observability counter (the 14-day window restarts from this cutover)**

Update `docs/mission-manifest.md` "Soak window" field to the new start date. Commit + push:

```bash
cd /root/k8s-vllm
# (manually edit the date in mission-manifest.md)
git add docs/mission-manifest.md
git commit -m "docs(manifest): reset 14-day soak window to sub-cycle 5 cutover date"
```

---

## Phase 6 — Push everything

### Task 11: Push both repos

**Files:**
- N/A (git operation)

- [ ] **Step 1: Push injector repo**

Run:
```bash
cd /root/nvidia-driver-injector
git log --oneline -10  # verify all sub-cycle 5 commits present
git push origin main
```

Expected: ~7 new commits pushed (PC-7, PC-4, PC-1, PC-6a, PC-10, PC-5, PC-3).

- [ ] **Step 2: Push k8s-vllm repo**

Run:
```bash
cd /root/k8s-vllm
git log --oneline -5
git push origin main
```

Expected: 2-3 new commits pushed (device plugin, vLLM migration, soak reset).

---

## Acceptance criteria

Sub-cycle 5 is complete when ALL of:

- ✅ Injector pod runs new image (`595.71.05-aorus.15`), Ready 1/1
- ✅ PC-3 file exists at `/run/nvidia/injector/state` with `phase: ready` and `last_checked` updating every ~30s
- ✅ Device plugin DS Ready 1/1, advertises `nvidia.com/gpu: 1` to kubelet
- ✅ vLLM pod Ready 1/1, scheduled via `resources.limits[nvidia.com/gpu]: 1`
- ✅ No `nvidia.driver/state=ready` nodeSelector in vLLM deployment
- ✅ VIP `http://192.168.1.251:8000/v1/models` returns JSON
- ✅ `tools/must-gather.sh` runs cleanly and bundles PC-3 file + plugin logs
- ✅ Soak observability continues writing metrics (timer is independent of these changes)

## Rollback plan

If any acceptance criterion fails:

1. **Injector regression** — bump image tag back to `595.71.05-aorus.14`, `kubectl delete pod -l app=nvidia-driver-injector` (OnDelete; new pod uses old image)
2. **Device plugin regression** — `kubectl delete -f /root/k8s-vllm/k8s/device-plugin.yaml`; vLLM will be stuck Pending until consumer manifest also rolled back
3. **vLLM regression** — revert the vLLM deployment YAML to use `nodeSelector: nvidia.driver/state=ready` (the OLD label) + drop the `nvidia.com/gpu` resource request; re-apply. The OLD label still exists on the node (from current operational state) until we remove it, so this rollback works.

Full rollback is a single commit revert in each repo + re-apply. The state is recoverable.

## What's NOT in this plan

- **PC-8 init container split** — deferred to sub-cycle 6 (per Q3 design call)
- **MISSION-1 work** (hot-plug + hot-power + unexpected disconnect resilience) — separate track per `docs/mission-egpu-hot-plug-hot-power.md`
- **v0.21.1 cutover** — separate plan at `docs/v0.21.1-cutover-plan.md`; gated on upstream release
- **Laguna-XS.2 bench** — separate when soak allows
- **Heartbeat watchdog for `#42897` wedge class** — Phase 2 of mission, deferred until soak surfaces a wedge

---

## Self-review (per writing-plans skill)

**Spec coverage:**

| Decision | Plan task |
|---|---|
| PC-1 probe | Task 3 |
| PC-3 file + heartbeat | Task 7 |
| PC-4 exit codes + kmsg | Task 2 |
| PC-5 must-gather | Task 6 |
| PC-6a toleration | Task 4 |
| PC-7 DKMS scrub | Task 1 |
| PC-10 OnDelete | Task 5 |
| Device plugin adoption | Task 8 |
| vLLM consumer migration | Task 9 |
| Operational rollout | Task 10 |
| Push | Task 11 |
| Pre-flight cleanup | Task 0 |

All 9 design decisions have an explicit task. PC-3 dependency chain is correct (Phase 2 depends on Phase 1's PC-4 enum; Phase 3 depends on Phase 2).

**Placeholder scan:** All steps have concrete code, exact commands, expected outputs. No "TBD," no "add appropriate error handling." Reviewed and clean.

**Type consistency:** PC-3 file path is `/run/nvidia/injector/state` in every task (entrypoint write, daemonset mount, device-plugin initContainer read, must-gather scoop). Exit code constants are `EXIT_*` in every reference. Phase enum values match across `write_state` calls and the initContainer's `grep` pattern.
