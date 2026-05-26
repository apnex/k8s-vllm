# E04 — udevadm trigger

**Status:** PENDING
**Phase:** 2.1
**Risk:** LOW
**Cost:** ~3 min
**Reversibility:** auto
**Last updated:** 2026-05-26

## Hypothesis

`udevadm trigger` re-fires udev events for matching devices, causing userspace re-binding and possibly re-running driver attach paths. It does NOT touch PCI config space or trigger bridge re-enumeration. Hypothesis: udevadm trigger is **insufficient** to recover BAR1 because the failure is at PCI enumeration level (bridge windows already constrained), not at udev/driver-attach level.

This is a **negative-control experiment**: confirms udev is not the failure layer.

## Falsification gates

**PASS:** BAR1=32G post-trigger. Would be surprising; suggests udev path somehow influences bridge windows.

**FAIL:** BAR1=256M post-trigger. **Expected outcome.** udev re-attached driver; PCI state unchanged.

**INCONCLUSIVE:** udev hangs; driver re-attach fails.

## Prerequisites

- Cluster in "broken-BAR1" state per `_STARTING-STATE-RECIPE.md`
- udevadm available (systemd-based system)

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/k8s-vllm/tools/get-pci-stats.sh --baseline E04
```

### Step 2 — Drain workload

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 3 — Try udevadm trigger variants

#### Variant A — full PCI re-trigger

```bash
sudo udevadm trigger --subsystem-match=pci --action=add
sleep 3
sudo udevadm settle --timeout=30
```

#### Variant B — change action (less disruptive)

```bash
sudo udevadm trigger --subsystem-match=pci --action=change
sleep 3
sudo udevadm settle --timeout=30
```

#### Variant C — remove then add (more aggressive)

```bash
sudo udevadm trigger --subsystem-match=pci --action=remove
sleep 2
sudo udevadm trigger --subsystem-match=pci --action=add
sleep 5
sudo udevadm settle --timeout=30
```

#### Variant D — thunderbolt subsystem specifically

```bash
sudo udevadm trigger --subsystem-match=thunderbolt --action=change
sleep 3
sudo udevadm settle --timeout=30
```

### Step 4 — Post-experiment state capture + diff

```bash
sudo /root/k8s-vllm/tools/get-pci-stats.sh --snapshot E04
sudo /root/k8s-vllm/tools/get-pci-stats.sh --diff E04
```

### Step 5 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
BAR1: 256M → 32G                  ← unexpected
(would require udev to invoke a re-enumeration we don't currently know about)
```

## Predicted FAIL signature (expected)

```
BAR1: 256M → 256M
Bridge windows: unchanged
Driver: re-attached (no functional change)
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| udev queue fills up | `udevadm settle` times out | `sudo systemctl restart systemd-udevd` |
| Variant C removes device but doesn't re-add | `lspci -s 0000:03:00.0` empty | `echo 1 | sudo tee /sys/bus/pci/rescan` (transitions to E11 territory) |

## Actual result

**Status:** PENDING — fill in when run

**Date:**

**Per-variant results:**

| Variant | Status | Diff highlights |
|---|---|---|
| A — pci/add | | |
| B — pci/change | | |
| C — pci/remove+add | | |
| D — thunderbolt/change | | |

**Conclusion:**

## Cross-references

- systemd-udevd(8), udevadm(8)
- Used to refresh udev rule state for `/dev/nvidia*` permissions historically
