# MISSION-1 Phase 2 — Software-path archaeology matrix

**Purpose:** Exhaustively enumerate untested userspace + kernel mechanisms that might restore BAR1=32GB / bridge window=32GB+ on a TB-attached eGPU at runtime, without host reboot.

**Question we're answering:** Does **any** software-only path exist that triggers fresh PCIe bridge window allocation matching the device's actual ReBAR request? (H10 in `docs/mission-egpu-hot-plug-hot-power.md` — currently OPEN.)

**Status of H1 (cable replug → 32GB)**: FALSIFIED 2026-05-25 by E7. This doc is the follow-up.

**Pre-existing experiment registry**: `docs/mission-egpu-hot-plug-hot-power.md#empirical-experiments-queued` (E1-E9). This matrix extends to E10-E18.

---

## Stats script (tooling prerequisite — section 4 of this doc)

Every experiment uses `tools/get-pci-stats.sh` for before/after state capture. Capture+diff is the unit of evidence; subjective "looks the same" doesn't count.

---

## Section 1 — No-reboot, no-setup experiments

**These run sequentially on the live cluster between vLLM drains.** Each is reversible by reboot if it goes wrong. Run from the broken-BAR1 starting state (i.e., after some prior cycle that left bridge=288M/BAR1=256M); if a test recovers BAR1=32GB, we have a winner.

| # | Experiment | Hypothesis | Cost | Risk | Reversibility |
|---|---|---|---|---|---|
| **E10** | `echo 0 > /sys/bus/pci/slots/<N>/power; sleep 2; echo 1 > /sys/bus/pci/slots/<N>/power` (pciehp slot power cycle — different from `remove`/`rescan`) | Slot power-cycle path forces full pciehp re-enumeration including bridge window reallocation | 2 min | LOW | Auto on `echo 1` |
| **E11** | Remove the **root port** (`0000:00:07.0`) + rescan from `0000:00` parent | Removing at the root port level lets the kernel reallocate windows for the entire TB subtree from scratch (we only went as high as `02:00.0` in prior tests) | 5 min | MEDIUM | May need reboot if root port doesn't come back |
| **E12** | `echo 1 > /sys/bus/pci/devices/0000:04:00.0/remove; echo 1 > /sys/bus/pci/devices/0000:04:00.1/remove; echo 1 > /sys/bus/pci/rescan` (remove both GPU functions explicitly, not just the bridge subtree) | Per-function removal followed by global rescan may take a different allocation path than bridge-level removal | 3 min | LOW | Auto on rescan |
| **E13** | `echo 1 > /sys/bus/pci/devices/0000:04:00.0/reset` (PCIe function-level reset) | FLR may trigger BAR re-negotiation through the bridge | 1 min | LOW | Auto |
| **E14** | `cat /sys/bus/pci/devices/0000:04:00.0/reset_method` → write alternative methods (`pm`, `bus`, `flr`, etc.) then trigger reset | Different reset methods exercise different kernel code paths | 5 min × N methods | LOW | Auto |
| **E15** | `echo 0 > /sys/bus/pci/devices/0000:04:00.0/d3cold_allowed` then re-enable; cycle device through D3cold | D-state transitions force certain re-init code paths in pcieport | 5 min | MEDIUM | Auto |
| **E16** | `udevadm trigger --subsystem-match=pci --action=remove` then `--action=add` for the GPU device | udev-driven re-trigger may invoke different kernel paths than direct sysfs writes | 3 min | LOW | Auto |
| **E17** | debugfs scan: `find /sys/kernel/debug/pci/ -writable -type f` — enumerate and document every writable debugfs entry; try toggling each (where semantics are obvious) | Kernel may expose realloc / bridge-resize triggers under debugfs that aren't in the public sysfs API | 30 min (survey + targeted prods) | MEDIUM (debugfs writes can hang the kernel) | Reboot may be needed for some |
| **E18** | Exhaustive sysfs surface enumeration: `find /sys/bus/pci/devices/ /sys/bus/thunderbolt/ -writable -type f` — for each, document what writes do (mostly from kernel source) and identify "this could plausibly trigger reallocation" candidates | Some writable sysfs file does what we want; we just haven't found it | 1-2 hr survey + targeted prods | LOW (most writes are no-op or rejected) | Per-file |

**Total Section 1 budget:** ~3-4 hours wall-clock if run sequentially. Each individual test cheap.

---

## Section 2 — No-reboot, requires `setpci` (medium risk)

Direct PCI config-space writes. The kernel may or may not honor externally-modified register values; this is the "is the kernel's bridge-window-sizing decision *consultative* or *authoritative*?" question.

| # | Experiment | Hypothesis | Cost | Risk | Reversibility |
|---|---|---|---|---|---|
| **E19** | `setpci -s 0000:03:00.0 PREF_MEMORY_BASE=...` + `PREF_MEMORY_LIMIT=...` — directly widen the bridge's prefetchable memory window to 32GB | Bridge windows are config-space registers; rewriting them may be honored by the kernel's PCI subsystem on next enumeration | 30 min (per-bridge math) | **HIGH** (mis-written bridge windows can hang the bus) | Reboot |
| **E20** | `setpci -s 0000:04:00.0 <RBAR_CONTROL>=15` (write to the device's Resizable BAR Control register to request 32GB explicitly) | Device-side ReBAR negotiation may complete if we ask for 32G after the bridge window is widened | 1 hr | **HIGH** | Reboot |
| **E21** | `setpci` combined: widen bridge windows (E19) + trigger device-side reset (E13) + check BAR1 | E19+E13 chain may complete the negotiation cycle | 2 hr | **HIGH** | Reboot |

**Total Section 2 budget:** ~half day; HIGH risk — only attempt after Section 1 fully exhausted and only with a deliberate plan to reboot if needed.

---

## Section 3 — Reboot-required (cmdline tuning)

Each iteration requires a host reboot. Methodology: edit GRUB cmdline, reboot, capture stats, observe. ~3 min per iteration.

| # | Experiment | Hypothesis | Cost | Risk | Reversibility |
|---|---|---|---|---|---|
| **E22** | Add `pci=realloc=on` to cmdline | Even though LF forum says it doesn't help alone, validate on our specific hardware | 3 min | LOW | Edit cmdline + reboot |
| **E23** | `pci=realloc=on hpmmioprefsize=32G` | Combine LF forum's "didn't help alone" with explicit 32G hint for prefetchable memory | 3 min | LOW | Edit + reboot |
| **E24** | `pci=realloc=on hpmmioprefsize=32G hpmmiosize=256M` | Add the non-prefetchable hint too — LF forum tested without this | 3 min | LOW | Edit + reboot |
| **E25** | `pci=realloc=on hpmemsize=33G` (combined budget hint) | Alternative form of the budget hint | 3 min | LOW | Edit + reboot |
| **E26** | `pci=realloc=on hpmmioprefsize=32G pcie_aspm=off` | Test interaction with ASPM disabled (we have `pcie_aspm.policy=performance`; trying full off) | 3 min | LOW | Edit + reboot |
| **E27** | Cold-boot WITH device powered off, then power on at runtime — repeat each cmdline above | Test whether cmdline hints take effect on runtime hotplug after the cmdline was set at boot | 10 min each | LOW | Edit + reboot + physical |
| **E28** | `pci=resource_alignment=NN@<bridge>` variations (our current `35@0000:03:00.0` is one specific value; try others or remove) | Alignment hint at a different size may shape allocation differently | 3 min each | LOW | Edit + reboot |

**Total Section 3 budget:** ~1 day; each iteration is cheap but multiple reboots accumulate.

---

## Section 4 — Custom kernel build (last resort)

| # | Experiment | Hypothesis | Cost | Risk | Reversibility |
|---|---|---|---|---|---|
| **E29** | Cherry-pick Miroshnichenko "movable BARs" v9 (Dec 2020, 26 patches) onto current kernel 7.0.x; build; install; test | The proposed mechanism explicitly addresses our class of problem; even though the series stalled in mainline review, it may work in practice | 1-2 days (build + iteration) | MEDIUM | Pin original kernel; boot back |
| **E30** | Write a minimal custom kernel module that exposes `/sys/.../trigger_bridge_resize` and triggers `pci_resize_resource` + bridge reallocation under our control | If the API exists internally but isn't exposed to userspace, we can expose it | 1-3 days | MEDIUM | Module unload |
| **E31** | Patch `drivers/pci/setup-bus.c` `__assign_resources_sorted` to retry with larger windows when initial allocation < device's ReBAR cap | Direct surgical fix at the location the LF forum identified | 3-5 days | HIGH (changes core PCI behavior) | Pin original kernel |

**Total Section 4 budget:** ~1-2 weeks if pursued; gates the broader upstream contribution work.

---

## Recommended evaluation order

Prioritised by **information-per-cost** + **least-invasive first** + **dependency**:

### Phase 2.1 — Quick wins (Section 1 — ~3-4 hours total)

1. **E10** (slot power-cycle) — highest "different code path" probability among sysfs-only tests
2. **E11** (remove root port + rescan) — never tested at this level; high-info
3. **E13** (FLR reset) — cheap; FLR is a different code path than remove/rescan
4. **E14** (reset_method permutations) — extends E13
5. **E15** (D3cold transitions) — different init path
6. **E16** (udevadm trigger) — different event source
7. **E12** (per-function remove) — variant of what we've tried but different selector

### Phase 2.2 — Survey (Section 1 — half day)

8. **E18** (full sysfs surface enumeration) — produces a matrix of candidates; informs whether any other writes exist
9. **E17** (debugfs survey) — kernel-internal API surface

### Phase 2.3 — Cmdline tuning (Section 3 — half day; needs reboot per iter)

10. **E22** (`pci=realloc=on` alone) — establishes baseline
11. **E23** (`+hpmmioprefsize=32G`) — the most-likely-to-work combo
12. **E24-E25** (variants if E23 partial)
13. **E26** (ASPM interaction if E23 still partial)
14. **E27** (cmdline + cold-boot-off path) — test how cmdline hints flow into hotplug allocation
15. **E28** (resource_alignment variants)

### Phase 2.4 — setpci (Section 2 — half day; HIGH risk)

16. **E19** (bridge window widen via setpci)
17. **E20** (device RBAR control register)
18. **E21** (combined E19+E13)

### Phase 2.5 — Kernel work (Section 4 — last resort, 1-2 weeks)

19. **E29** (Miroshnichenko patches)
20. **E30** (custom module)
21. **E31** (direct PCI core patch)

---

## Exit criteria

The archaeology completes when ONE of:

- **(a) A working software-only trigger is found.** E10-E28 all run at least once; at least one produced BAR1=32GB after a runtime cycle. → Integrate into Option B in-container watcher; Sub-mission A closes.
- **(b) Exhaustively proven that no software-only trigger exists.** All E10-E28 produce the same 256MB outcome. → Phase 3 upstream work (E29-E31) becomes the only path; we have a published, citation-ready bug report.
- **(c) Partial success — a path works some of the time / on some kernels.** → Document the working envelope; ship Option B with the documented limitation.

---

## Operational protocol per experiment

1. Capture **before** state: `tools/get-pci-stats.sh --baseline <experiment-id>`
2. Run the experiment per its row above
3. Capture **after** state: `tools/get-pci-stats.sh --snapshot <experiment-id>`
4. Diff: `tools/get-pci-stats.sh --diff <experiment-id>`
5. Record outcome in this doc's "Results" section (added when run begins)
6. If the experiment broke the cluster, reboot to recover before proceeding

Drain-first protocol from MISSION-1 mission doc applies — no experiment runs while vLLM is actively serving CUDA compute.

---

## Cross-references

- Mission: `docs/mission-egpu-hot-plug-hot-power.md` (especially H10 + experiment list)
- M1 research: `audit/tb-pcie/CONSOLIDATED.md` (Q1-Q6 + LF forum analysis)
- E7 result (H1 falsified): `archive/cable-replug-test-E7-20260525T084717Z/post-test-finding.txt`
- Stats script: `tools/get-pci-stats.sh`
