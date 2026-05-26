# E18 — `pci=realloc=on` alone

**Status:** PENDING
**Phase:** 2.3
**Risk:** LOW
**Cost:** ~3 min editing + 1 reboot + post-test
**Reversibility:** revert grub + reboot
**Last updated:** 2026-05-26

## Hypothesis

The kernel cmdline `pci=realloc=on` enables `pci_realloc_enable=PCI_REALLOC_ENABLE` in `drivers/pci/pci.c`, which causes the PCI subsystem to re-attempt resource assignment when initial allocation fails. Hypothesis: enabling realloc-on may cause the PCI core to widen bridge windows when downstream BAR sizes exceed the budget — potentially fixing the broken-BAR1 issue at boot, and possibly also when triggered via remove+rescan.

**Note from LF forum discussion** (audit/tb-pcie/CONSOLIDATED.md Q3): `pci=realloc=on` alone has been **tested by users** and reported insufficient. This experiment **confirms locally** so we have a documented baseline.

## Falsification gates

**PASS:** post-reboot-with-cmdline AND post-runtime-cable-cycle, BAR1=32G.

**FAIL:** post-runtime-cable-cycle, BAR1=256M (same as without cmdline). LF forum corroboration confirmed.

**INCONCLUSIVE:** boot-time allocation breaks unexpectedly with cmdline present.

## Prerequisites

- Working production baseline (BAR1=32G via cold-plug)
- GRUB editable

## Method

Follow `_SECTION-3-CMDLINE-WORKFLOW.md`. Specific parameter to ADD to `GRUB_CMDLINE_LINUX`:

```
pci=realloc=on
```

After reboot:

### Phase A — Cold-plug control

Verify BAR1=32G is still achievable at boot with the new cmdline (control test):

```bash
sudo /root/k8s-vllm/tools/get-pci-stats.sh --baseline E18-cold-control
grep 'size=32G' /var/log/mission-1-archaeology/E18-cold-control.baseline.txt
# Expected: PASS — cmdline shouldn't break cold-plug
```

### Phase B — Runtime cable cycle test

```bash
# 1. Enter broken-BAR1 state via cable cycle (per _STARTING-STATE-RECIPE.md)
# 2. Capture E18 snapshot
sudo /root/k8s-vllm/tools/get-pci-stats.sh --snapshot E18
sudo /root/k8s-vllm/tools/get-pci-stats.sh --diff E18
```

## Predicted PASS signature

```
Phase A (cold control): BAR1=32G (unchanged from baseline)
Phase B (runtime cycle): BAR1: 256M → 32G after cable cycle
                        → cmdline made hotplug allocation succeed
```

## Predicted FAIL signature (likely per LF forum)

```
Phase A: BAR1=32G (control passes)
Phase B: BAR1=256M after cable cycle (same as without cmdline)
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Phase A breaks (boot allocation fails) | BAR1=64M at boot | revert cmdline; reboot; document INCONCLUSIVE |
| Phase B AER cascade | dmesg shows AER storm post-cable-cycle | reboot; this surfaces a different failure mode than the matrix targets |

## Actual result

**Status:** PENDING — fill in when run

**Date:**

**Phase A result:**

**Phase B result:**

**Conclusion:**

## Cross-references

- Linux source: `drivers/pci/pci.c::pci_realloc_setup`
- `Documentation/admin-guide/kernel-parameters.txt` pci=realloc
- LF forum thread: linked from audit/tb-pcie/CONSOLIDATED.md Q3
- E19 (next iteration adds hpmmioprefsize)
