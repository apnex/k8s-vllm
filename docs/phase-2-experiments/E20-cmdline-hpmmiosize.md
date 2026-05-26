# E20 — `pci=realloc=on,hpmmioprefsize=32G,hpmmiosize=256M`

**Status:** PENDING
**Phase:** 2.3
**Risk:** LOW
**Cost:** ~3 min editing + 1 reboot + post-test
**Reversibility:** revert grub + reboot
**Last updated:** 2026-05-26

## Hypothesis

`hpmmiosize=256M` parallel of `hpmmioprefsize` but for the **non-prefetchable** MMIO bridge window. BAR0 (MMIO config + registers) for the GPU is non-prefetchable, and although BAR0 is only ~16MB, the bridge non-prefetchable window allocation may interact with the prefetchable window allocation in unexpected ways. Hypothesis: pre-budgeting both prefetchable and non-prefetchable windows produces correct full allocation in cases where prefetchable-only hint is insufficient.

## Falsification gates

**PASS:** post-runtime-cable-cycle, BAR1=32G AND both bridge windows pre-budgeted.

**FAIL:** BAR1=256M; the non-prefetchable budget didn't unlock the prefetchable-budget gate.

## Prerequisites

- E19 completed (PASS or FAIL — informs whether this addition is needed)
- GRUB editable

## Method

Follow `_SECTION-3-CMDLINE-WORKFLOW.md`. Parameter combination:

```
pci=realloc=on,hpmmioprefsize=32G,hpmmiosize=256M
```

After reboot, two-phase test as E18/E19:

```bash
sudo /root/k8s-vllm/tools/get-pci-stats.sh --baseline E20-cold-control
# enter broken-BAR1 state per recipe
sudo /root/k8s-vllm/tools/get-pci-stats.sh --snapshot E20
sudo /root/k8s-vllm/tools/get-pci-stats.sh --diff E20
```

## Predicted PASS signature

```
Phase B: BAR1=32G after cable cycle (same as E19 PASS, just with extra non-pref budget)
```

## Predicted FAIL signature

```
Phase B: BAR1=256M (additional non-pref budget didn't help)
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| Boot allocation fails | budget too aggressive; PCI hole exhausted | revert |

## Actual result

**Status:** PENDING — fill in when run

**Date:**

**Phase A result:**

**Phase B result:**

**Conclusion:**

## Cross-references

- Linux source: `drivers/pci/setup-bus.c::pci_hp_bridge_mmio_size`
- E19 (prev — prefetchable variant)
- E21 (next — combined hpmemsize alternative)
