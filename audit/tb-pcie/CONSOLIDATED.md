# M1 — TB / PCIe deep-dive

**Date:** 2026-05-25
**Trigger:** reliability test 2026-05-25 power-on findings (`docs/reliability-test-2026-05-25-gpu-power-on.md`, archive `archive/power-on-test-20260525T005756Z/`)
**Cross-refs:** `docs/reliability-test-2026-05-25-gpu-power-on.md`, `docs/mission-manifest.md` (M1 row)
**Scope:** answer Q1-Q6 — TB auto-authorize asymmetry boot vs runtime, runtime bridge-window reallocation gap, upstream ReBAR-hotplug patch state, eGPU ecosystem practice, Option-E viability, design recommendation for `apnex/nvidia-driver-injector` gap D-3.

---

## TL;DR (3 bullets)

- **TB asymmetry is real and is a userspace boltd policy artefact, not a kernel asymmetry.** The kernel exposes every newly-observed downstream switch with `authorized=0` and emits a `KOBJ_ADD` uevent at both boot and runtime; the only kernel-internal "auto-approve" applies to the host router (route==0). Whether the device then gets authorized depends entirely on whether `boltd` is running and reaches the device's stored entry. A chassis power-cycle without cable unplug fails because the TB cable stays electrically present, the upstream router (1:0) is never re-enumerated, and the downstream device-add event lands on a stored UUID — but in our captured timeline the auto-authorize path did not fire and the device sat at `authorized=0`. Most likely cause is one of two known race conditions in boltd's handling of repeated quick add/attach cycles plus the documented re-enrollment Bz#1770579 class. Manual `boltctl authorize <uuid>` succeeds because it bypasses the racy add-handler entirely.
- **Runtime bridge-window resize is a deliberately-absent kernel feature.** `pci_assign_unassigned_root_bus_resources()` uses pre-sized hints (`pci_hotplug_mmio_pref_size`) committed at first enumeration; once siblings have been assigned addresses *contiguous* with the populated bridge's window, the window cannot grow without releasing and re-laying-out the entire subtree, which would require all drivers under it to checkpoint+rebind (the macOS "PCIe pause" capability). The closest in-tree attempt — Sergei Miroshnichenko's "PCI: Allow BAR movement during boot and hotplug" series — reached v9 (26 patches, Dec 2020) and stalled with Bjorn Helgaas requesting clearer bug-report citations; it was never merged. The 2025-2026 Ilpo Järvinen "PCI: Resizable BAR improvements" series targeted at Linux 6.19/7.0 is a refactor, NOT a hotplug-aware enumerator — by the maintainer's own statement.
- **Recommendation: Option B (in-container watcher) + Option F (operational doc), with Option E held as a 12-24-month upstream play, not a near-term unblock.** Option E is technically tractable as a *thunderbolt* subsystem patch (kick a re-authorize on stored devices when an `authmode`-eligible device-add fires and `iommu_dma_protection==1`), but the user-facing problem (runtime BAR1=256MB) is the *bridge window* gap, and that gap has resisted 5+ years of upstream effort. The injector should ship a 50-line watcher that detects `TB connected + authorized=0 + stored` and issues `boltctl authorize`, AND we should document "cable must be plugged at boot for full BAR1" as a hard prerequisite. Treat runtime power-cycle as "expect to reboot".

---

## Q1 — Why does TB auto-authorize fire at boot but not at runtime?

### The kernel side is *symmetric* — boot and runtime go through the same code path

The Linux thunderbolt driver does not have a "boot path" and a "runtime path" with different authorize semantics. Both go through `tb_scan_port()` → `tb_switch_add()`. The only thing that differs is **uevent suppression**.

From `drivers/thunderbolt/tb.c` (current master, via WebFetch):

```c
if (!tcm->hotplug_active) {
    dev_set_uevent_suppress(&sw->dev, true);
    discovery = true;
}
```

During the initial boot scan `tcm->hotplug_active == false`, so newly-added switches are created with uevents *suppressed*. Once discovery completes, `tb_scan_finalize_switch()` runs:

```c
if (sw->boot)
    sw->authorized = 1;

dev_set_uevent_suppress(dev, false);
kobject_uevent(&dev->kobj, KOBJ_ADD);
```

There are two crucial bits in this finalize step:

1. **`sw->boot` is set only for switches the firmware already had tunnels for at boot** (BootACL pre-authorized devices). Those get `authorized = 1` *kernel-side*, without boltd needing to do anything. The 2-second auto-authorize you observed at cold-boot is almost certainly this path.
2. **For switches NOT in BootACL**, the same finalize emits a KOBJ_ADD uevent with `authorized = 0`. boltd receives this and decides.

The relevant kernel-internal "always-authorized" comment in `drivers/thunderbolt/switch.c`:

```c
/* Root switch is always authorized */
if (!route)
    sw->authorized = true;
```

That's the host router (the controller itself) — not downstream devices. Downstream devices always start at `authorized=0` regardless of when they appear.

At runtime, `tb_handle_hotplug()` runs in a workqueue:

```c
static void tb_handle_hotplug(struct work_struct *work)
{
    struct tb_hotplug_event *ev = container_of(work, typeof(*ev), work.work);
    ...
    pm_runtime_get_sync(&tb->dev);
    mutex_lock(&tb->lock);
    if (!tcm->hotplug_active)
        goto out; /* during init, suspend or shutdown */
```

It eventually calls `tb_scan_port()` for the affected port, which again calls `tb_switch_add()`. The only difference vs boot is that uevents are NOT suppressed (`hotplug_active == true`) so userspace sees the KOBJ_ADD immediately.

**Implication:** the kernel side is doing the right thing. boltd receives KOBJ_ADD at runtime. So the asymmetry is in boltd, not the kernel — *unless boltd never actually sees the uevent because of how the chassis power-cycle was perceived by the upstream TB router*.

### The boltd side — what *should* happen

From `boltd/bolt-manager.c` (Freedesktop bolt, current master, via salsa.debian.org mirror, c.f. `handle_udev_device_event` at line 1640):

```c
if (bolt_streq (devtype, "thunderbolt_device"))
  handle_udev_device_event (mgr, device, action);
```

The "add" action then dispatches:

```c
if (!dev)
  handle_udev_device_added (mgr, dom, device);
else if (!bolt_device_is_connected (dev))
  handle_udev_device_attached (mgr, dom, dev, device);
```

This is the critical branch. `dev` is the boltd-internal `BoltDevice` struct keyed by UUID. If boltd has *no record* of the UUID (cold first-plug), it goes to `handle_udev_device_added` which calls `manager_auto_enroll`. If boltd *does* have a record (re-plug — our scenario, since our device was enrolled 2026-05-24 with the `iommu` policy), it goes to `handle_udev_device_attached`.

The auto-authorize decision at `manager_auto_authorize` (line 1497):

```c
if (authmode)
  {
    if (policy == BOLT_POLICY_AUTO)
      authorize = TRUE;
    else if (policy == BOLT_POLICY_IOMMU && iommu)
      authorize = TRUE;
  }
```

So for our device (`policy=iommu`, `iommu_dma_protection=1`) the boltd policy outcome *should* be `authorize=TRUE`. That this didn't fire suggests one of:

1. **`handle_udev_device_attached` doesn't run `manager_auto_authorize`.** Inspection of the bolt source shows the auto-authorize path is wired into the device-added flow, not necessarily the re-attached flow — re-attach is treated as a state update on an already-stored device, and the assumption is that the kernel state will reflect whatever the firmware did (BootACL). When the firmware does NOT re-authorize (because the upstream link was never torn down so the upstream router never re-ran enrollment), boltd just records "device is back, status=connected" and the `authorized=0` sysfs state stays.
2. **boltd authmode is off in the running daemon's view.** `authmode` reads `/sys/bus/thunderbolt/devices/domainX/iommu_dma_protection` once at startup. If the value is "0" or the file is unreadable when boltd starts, authmode stays off forever for that domain. Worth checking `boltctl domains` for `authmode=enabled` on the live host.
3. **The Bz#1770579 class bug** — RHEL Bugzilla [Boltd does not re-authorized a Dock station](https://bugzilla.redhat.com/show_bug.cgi?id=1770579) describes the exact symptom: a dock that disconnects without a cable unplug (sleep/wake, power-cycle) comes back with `authorized=0` and stays there until manually re-authorized. The bug was filed against boltd 0.8 and the consensus on the thread was that the kernel's view of "what happened" depended on whether the upstream router (the dock's TB controller) emitted a fresh enumerate event or a quiet attach. When the cable stays plugged, you typically get the quiet-attach behaviour.

The empirical observation in your archive — *"Kernel saw fresh plug→unplug events on upstream port 1:2 (3 separate enumeration attempts, identical pattern), NO PCIe enumeration. Device sat invisible for 50+ minutes"* — is consistent with case (1)+(3): the kernel saw the device come and go on the port but boltd's add/attach handler classified it as a re-attach against a stored UUID and never ran the authorize step.

### Why does boltctl manually fix it?

`boltctl authorize <uuid>` calls the D-Bus method `Authorize` on the device object, which goes straight to writing `authorized=1` in sysfs, completely bypassing the policy evaluation. That's why it works regardless of authmode state, regardless of which add/attach branch boltd took, regardless of whether boltd even noticed the device at all (boltd serves D-Bus from its in-memory device DB, which it builds at startup and updates on udev events).

### Sources

- [USB4 and Thunderbolt — Linux kernel docs](https://docs.kernel.org/admin-guide/thunderbolt.html) — security levels, BootACL, IOMMU dma_protection semantics
- [boltd(8) — Arch manual pages](https://man.archlinux.org/man/extra/bolt/boltd.8.en) — auto-authorize IOMMU policy, BootACL kernel ≥4.17 requirement
- [bolt/boltd at master · gitlab.freedesktop.org](https://gitlab.freedesktop.org/bolt/bolt/-/tree/master/boltd) — canonical source; bolt-manager.c lines 1497, 1640, 1703, 1780 (mirror at https://salsa.debian.org/freedesktop-team/bolt/-/blob/debian/master/boltd/bolt-manager.c)
- [drivers/thunderbolt/switch.c (linux master)](https://github.com/torvalds/linux/blob/master/drivers/thunderbolt/switch.c) — `tb_switch_set_authorized`, `authorized_show`/`authorized_store`, root-switch auto-authorize
- [drivers/thunderbolt/tb.c (linux master)](https://github.com/torvalds/linux/blob/master/drivers/thunderbolt/tb.c) — `tb_handle_hotplug`, `tb_scan_finalize_switch`, uevent suppression during boot scan
- [Bugzilla 1770579 — Boltd does not re-authorize a Dock station](https://bugzilla.redhat.com/show_bug.cgi?id=1770579) — direct precedent for the re-attach asymmetry
- [systemd issue #40784 — authorize IOMMU-protected Thunderbolt devices via udev rule](https://github.com/systemd/systemd/issues/40784) — confirms the "udev-rule-as-backstop" pattern many users adopt instead of trusting boltd auto-authorize
- [Spinics linux-usb — [RFC] thunderbolt: Automatically authorize PCIe tunnels when IOMMU is active](https://www.spinics.net/lists/linux-usb/msg223924.html) — Mario Limonciello 2022 RFC to move the auto-authorize for IOMMU-protected devices *into the kernel*, removing boltd from the critical path. Not merged.

---

## Q2 — Why is there no Linux mechanism for runtime bridge-window reallocation?

### The architectural reason

Bridge windows are sized at enumeration time using a heuristic that depends on (a) the size of the largest BAR claimed by devices currently behind the bridge, and (b) hotplug hint reservations for empty hot-pluggable slots. Once the bridge window is sized AND siblings under the same parent bridge have been allocated addresses adjacent to it, the window cannot grow into the address space of those siblings without moving them. Moving them requires the drivers attached to those siblings to (a) pause DMA, (b) save state, (c) be told their MMIO physical address has changed, (d) restore, (e) resume DMA. The Linux PCI core has no such "pause" capability for drivers. macOS does. As the LWN piece on PCIe hotplug modernization put it:

> "When devices are hot-added, their memory requirements may not fit into the windows of their upstream bridges, necessitating a reorganization of resources: adjacent BARs need to be moved and bridge windows adjusted." ([LWN: The modernization of PCIe hotplug in Linux](https://lwn.net/Articles/767885/))

The article credits Sergei Miroshnichenko as the developer who tried to add this capability and describes it as "PCIe pause" in macOS terms. The series stalled (see Q3).

### What `pci=realloc=on` actually does

From `drivers/pci/setup-bus.c` (current master), the entry point is `pci_assign_unassigned_root_bus_resources()`:

```c
void pci_assign_unassigned_root_bus_resources(struct pci_bus *bus)
{
    LIST_HEAD(realloc_head);
    struct list_head *add_list = NULL;
    int tried_times = 0;
    enum release_type rel_type = leaf_only;
    LIST_HEAD(fail_head);
    int pci_try_num = 1;
    enum enable_type enable_local;

    /* Don't realloc if asked to do so */
    enable_local = pci_realloc_detect(bus, pci_realloc_enable);
    if (pci_realloc_enabled(enable_local)) {
        int max_depth = pci_bus_get_depth(bus);
        pci_try_num = max_depth + 1;
```

The retry loop with `pci_try_num = max_depth + 1` is the realloc machinery. On each retry, the kernel releases windows according to `rel_type` (which starts at `leaf_only` and escalates) and tries again. This works at **first enumeration**, when nothing has yet committed addresses. After a successful enumeration with drivers bound, the realloc loop won't run again from a per-device rescan — it only runs from a root-bus full rescan, and even then, the constraint about populated siblings still holds.

The hotplug-bridge sizing knobs are applied in the same file:

```c
if (bus->self->is_hotplug_bridge) {
    additional_io_size  = pci_hotplug_io_size;
    additional_mmio_size = pci_hotplug_mmio_size;
    additional_mmio_pref_size = pci_hotplug_mmio_pref_size;
}
```

These set the *empty-slot reservation* and the comment in `__assign_resources_sorted()` explains the contiguity problem:

```c
/*
 * Should not assign requested resources at first.  They could be
 * adjacent, so later reassign can not reallocate them one by one in
 * parent resource window.
 */
```

That comment is the architectural rationale. Once child resources are contiguous in the parent window, you cannot grow the parent window without moving children. The kernel deliberately *defers* assignment to allow first-pass redistribution; once assignment is committed, growth is structurally blocked.

### Why hotplug hints can't be sized for ReBAR

The Linux Foundation forum thread [Make the Linux kernel ReBAR-over-Thunderbolt friendly](https://forum.linuxfoundation.org/discussion/870568/make-the-linux-kernel-rebar-over-thunderbolt-friendly) (March-April 2025) lays it out (commenter quietcustomsboss, April 30 reply):

> "The hot-plug bridge sizing path applies the `pci=hpmmioprefsize` hint uniformly across all hot-pluggable downstream ports of a switch, regardless of whether anything is currently behind those ports. ... The redistribution pass triggered by `pci=realloc=on` cannot recover from this — by the time it tries to expand the populated bridge, the empty siblings have already been allocated their hint-sized windows."

That's our exact failure mode. A TB host controller has multiple downstream ports (in our case ports 1 through 4 of the NHI). At boot, each gets a `hpmmioprefsize` reservation. If you set the hint big enough for ReBAR-32G on every port, you blow past 32-bit address space. If you set it small (the default is 2M), the populated port's window can't grow at runtime to 32G because adjacent empty-port windows are already laid out.

And the OP framed it concisely:

> "The ReBAR capability is _never consulted_(!) during this process. ... this delivers the full 16 GB BAR _but_ only works for _cold-plug_(!) scenarios."

The OP is referring to `thunderbolt.host_reset=0`, which keeps the BIOS-laid-out tunnel and BAR assignments from POST. That's load-bearing on our stack too — we have `thunderbolt.host_reset=false` in our cmdline for exactly this reason.

### Bridge remove+rescan preserves windows — why

When you `echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove` and then `echo 1 > /sys/bus/pci/buses/.../rescan`, the kernel calls `pci_stop_and_remove_bus_device()` followed by `pci_rescan_bus()`. The rescan path calls `pci_assign_unassigned_bus_resources()` (note: *bus*, not *root_bus*), which does NOT release the parent bridge's window. The window was sized at the original enumeration, and rescan reassigns *children within* it. The 288MB intermediate-bridge window in your test is the original sizing decision from the boot-time enumeration of empty TB ports — it cannot grow without releasing the whole root-port subtree, which would tear the rest of your PCIe topology (including the boot disk if it shares the root port, which on the NUC 15 Pro+ it does not, but the kernel doesn't know that).

### Sources

- [drivers/pci/setup-bus.c (linux master)](https://github.com/torvalds/linux/blob/master/drivers/pci/setup-bus.c) — `pci_assign_unassigned_root_bus_resources`, hotplug bridge hint logic, `__assign_resources_sorted` constraint comment
- [LWN: The modernization of PCIe hotplug in Linux (2018)](https://lwn.net/Articles/767885/) — historical framing and credit to Miroshnichenko series
- [LF Forum: Make the Linux kernel ReBAR-over-Thunderbolt friendly](https://forum.linuxfoundation.org/discussion/870568/make-the-linux-kernel-rebar-over-thunderbolt-friendly) — the most current (March-April 2025) public diagnosis of our exact bug class
- [Arch Wiki — External GPU](https://wiki.archlinux.org/title/External_GPU) — recommends `pci=assign-busses,hpbussize=0x33,realloc,hpmmiosize=128M,hpmmioprefsize=16G` which is the brute-force "give every empty port 16G hint" workaround (works on systems with vast PCI address space, blows up on others)

---

## Q3 — Have upstream patches been proposed for ReBAR-aware hot-plug?

### Yes, and they have a long history of stalling

**Primary series: Miroshnichenko "PCI: Allow BAR movement during boot and hotplug"**

- v1 (2019) through v9 (Dec 2020) — 26 patches by the final version.
- Source: [Patchwork v9 cover](https://patchwork.ozlabs.org/project/linux-pci/cover/20201218174011.340514-1-s.miroshnichenko@yadro.com/), [spinics archive](https://www.spinics.net/lists/linux-pci/msg103195.html), [lore](https://lore.kernel.org/linux-pci/20201218174011.340514-23-s.miroshnichenko@yadro.com/)
- Status: **stalled, never merged**. Bjorn Helgaas (PCI maintainer) indicated uncertainty about how to move forward and requested clearer bug-report citations. The author moved off the work after v9.
- Relevance: this is the closest thing to what we'd need for our gap D-3. It introduced the concept of *movable BARs* and provided the kernel infrastructure to release-and-relay-out a bridge subtree at hotplug. Patch 22/26 was titled "PCI: hotplug: Enable the movable BARs feature by default" — the smoking gun that it directly addresses our problem.

**Recent activity: Ilpo Järvinen "PCI: Resizable BAR improvements" v2 (Sep 2025)**

- 11 patches, target Linux 6.19. [Patchew](https://patchew.org/linux/20250915091358.9203-1-ilpo.jarvinen@linux.intel.com/) [Phoronix coverage](https://www.phoronix.com/news/PCI-ReBAR-Better-Linux-6.19)
- Patches enumerated: (1) Move ReBAR code to rebar.c; (2) cleanup `pci_rebar_bytes_to_size`; (3) export `pci_rebar_size_to_bytes`; (4) kernel-doc cleanup; (5) Add `pci_rebar_size_supported()` helper; (6) i915 use new helper; (7) xe vram use helpers; (8) Add `pci_rebar_get_max_size()`; (9) xe vram use it; (10) amdgpu use it; (11) Convert BAR sizes bitmasks to u64.
- **None of these patches add hotplug-aware bridge sizing.** This is a refactor + API surface cleanup. The maintainer himself explicitly states in the cover letter: *"I'm not planning to pursue fixing the pinning problem within xe driver because the core changes to consider maximum size of the resizable BARs should take care of the main problem by different means."* — i.e., the "different means" is yet-to-be-written, not this series.

**Phoronix [ReBAR Code Cleaned Up For Linux 6.19](https://www.phoronix.com/news/Linux-6.19-PCI):**

> "Among the Resizable BAR improvements were preventing resource tree corruption when BAR resize fails and restoring BARs to the original size of a BAR resize fail."

So 6.19/7.0 ReBAR work is robustness, not enumeration.

**Adjacent series: "PCI: Release BAR0 of an integrated bridge to allow GPU BAR resize" (Oct 2025)**

- [dri-devel archive](https://lists.freedesktop.org/archives/dri-devel/2025-October/532596.html). 403 from WebFetch but the title indicates it's about a single-device case (integrated-bridge BAR0 holds the parent in place), not the eGPU bridge-window case.

**Mario Limonciello "thunderbolt: Automatically authorize PCIe tunnels when IOMMU is active" (Mar 2022)**

- [Spinics](https://www.spinics.net/lists/linux-usb/msg223924.html) [Linaro patchwork](https://patches.linaro.org/project/linux-usb/patch/20220315213008.5357-1-mario.limonciello@amd.com/)
- An RFC that would let the *kernel* auto-authorize on iommu_dma_protection, removing boltd from the critical path. Did not merge. Discussion concluded with "let boltd own this".
- Relevance to Q1: this is the upstream artifact of the exact discussion we're having about TB-side asymmetry. The decision to keep boltd in the loop is *why* we hit this gap.

**Maintainer position (synthesis)**

The PCI maintainer position is consistent across these series:
1. Adding "movable BARs" requires driver buy-in (`reset_prepare`/`reset_done` style pause-resume). The kernel cannot unilaterally move BARs.
2. ReBAR-aware enumeration is in scope but nobody has a complete series.
3. The thunderbolt-side fix (kernel-side auto-authorize on IOMMU) was bounced to userspace policy.

**Net: in-flight upstream work that would close gap D-3 = NONE as of 2026-05-25.** The 6.19 ReBAR refactor is necessary preliminary plumbing for a future hotplug-aware enumerator, but the enumerator itself has no in-flight series.

### Sources

- [Patchew: PCI: Resizable BAR improvements v2 (Sep 2025)](https://patchew.org/linux/20250915091358.9203-1-ilpo.jarvinen@linux.intel.com/)
- [Phoronix: PCI ReBAR Improvements Heading To Linux 6.19](https://www.phoronix.com/news/PCI-ReBAR-Better-Linux-6.19)
- [Phoronix: ReBAR Code Cleaned Up For Linux 6.19](https://www.phoronix.com/news/Linux-6.19-PCI)
- [Patchwork: PCI: Allow BAR movement during boot and hotplug (v9, 26 patches, Dec 2020) — STALLED](https://patchwork.ozlabs.org/project/linux-pci/cover/20201218174011.340514-1-s.miroshnichenko@yadro.com/)
- [LWN: PCI: VF resizable BAR (2025 — note: SR-IOV scope, not hotplug)](https://lwn.net/Articles/1022707/)
- [Spinics: [RFC] thunderbolt: Automatically authorize PCIe tunnels when IOMMU is active (Mario Limonciello, 2022)](https://www.spinics.net/lists/linux-usb/msg223924.html)
- [lore: pci hotplug: rescan bridge after device hotplug (active CAE9 thread)](https://lore.kernel.org/all/CAE9FiQWPpKE5vmzZqw-E_L_0Lt1QpqV=xk=Hu6Stzva5vXk1_g@mail.gmail.com/T/)

---

## Q4 — What do other eGPU users actually do?

### The honest answer: most don't have our problem, because most don't power-cycle the chassis

Our scenario — chassis powered off independently of the host, then back on with cable continuously attached — is genuinely uncommon. Mainstream eGPU workflows are: (1) cold boot with eGPU attached (works; BIOS does ReBAR during POST and Linux inherits via `thunderbolt.host_reset=false`); (2) suspend/resume with eGPU powered (mostly works via the D3cold PM machinery Mika Westerberg added in 4.20); (3) unplug+replug cable (mixed; often requires `boltctl authorize` once); (4) chassis power-cycle without cable unplug — largely undocumented, users either reboot anyway or don't notice the BAR1=256MB problem because their workload fits under 256MB BAR1-mapped VRAM.

### Direct evidence on the runtime power-cycle case

- [egpu.io: Aorus Gaming Box – Having to power cycle every time?](https://egpu.io/forums/pc-setup/aorus-gaming-box-having-to-power-cycle-every-time/) — Windows-focused thread, but documents the same chassis-power-state-vs-host-link confusion. Users report needing to unplug for 15-20 seconds to fully reset the dock's TB controller.
- [egpu.io: State of eGPU Hot-Plug for NVIDIA](https://egpu.io/forums/thunderbolt-linux-setup/state-of-egpu-hot-plug-for-nvidia/) — (403 on direct WebFetch; search snippets confirm the thread documents the cold-plug requirement) — the consensus on Linux is "plug at boot".
- [NVIDIA issue #979 — RTX 5080 Thunderbolt 5 eGPU hard lock](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979) — multiple users corroborate the BAR/bridge-window sensitivity and the *"hard lock on first CUDA op"* failure mode. Workarounds documented in the thread converge on `pcie_ports=native pcie_aspm=off pcie_port_pm=off pci=assign-busses,realloc`.
- [NVIDIA forums: RTX 5090 not working as eGPU on Ubuntu 22.04](https://forums.developer.nvidia.com/t/rtx-5090-not-working-as-egpu-on-ubuntu-22-04/348773) — one user explicitly documents the manual remove+rescan workflow: *"echo 1 > /sys/bus/pci/devices/$TB_BRIDGE/remove; echo 1 > /sys/bus/pci/rescan"* — same path we tried, with the same partial result (device appears, BAR sizing wrong).
- [Linux Mint forum: eGPU not detected by lspci](https://forums.linuxmint.com/viewtopic.php?t=407977) — long thread where the fix is always "reboot with cable plugged".

### Userspace tooling status

There is **no widely-adopted userspace tool** that solves the runtime power-cycle case end-to-end (boltd auto-authorize + bridge window resize). The components exist independently:

- `boltctl authorize` — solves the TB layer (Q1)
- PCI sysfs rescan — solves "make the device appear" but NOT the bridge window (Q2)
- `setpci`-style direct BAR resize attempts — don't work because parent window is too small

The closest thing to integration is the [JuliaComputing/nvidia-driver-pcie-rebar](https://github.com/JuliaComputing/nvidia-driver-pcie-rebar) patches which modify the NVIDIA driver to *request* a larger BAR via ReBAR — but that's still cold-plug only because the parent bridge window hasn't grown.

### Vendor documentation

Razer (Core X / Core X V2), OWC (Mercury Helios), AKiTiO (Node line), GIGABYTE (AORUS Gaming Box / AI Box) — all are Windows-validated only; none publish a Linux workflow for chassis power-cycle. The vendor pattern is to *avoid* exposing this scenario as supported because it depends on the host TB stack handling a quiet attach (kernel + boltd + PCI) the OS+firmware combo wasn't designed for.

### Arch Wiki recommendation

The [Arch Wiki External GPU page](https://wiki.archlinux.org/title/External_GPU) recommends `pcie_ports=native pci=assign-busses,hpbussize=0x33,realloc,hpmmiosize=128M,hpmmioprefsize=16G`. The `hpmmioprefsize=16G` reserves 16G prefetchable per empty hotplug port at boot — works on systems with huge address space (modern x86_64 with 39+ usable bits), can fail to boot on packed PCI topologies. We haven't tried this combination; low-priority experiment.

### Sources

- [egpu.io Thunderbolt Linux subforum index](https://egpu.io/forums/thunderbolt-linux-setup/) (many threads; 403 from automated fetches but visible via search engines)
- [GitHub: NVIDIA/open-gpu-kernel-modules issue #979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
- [NVIDIA Developer Forums: RTX 5090 not working as eGPU on Ubuntu 22.04](https://forums.developer.nvidia.com/t/rtx-5090-not-working-as-egpu-on-ubuntu-22-04/348773)
- [Arch Wiki: External GPU](https://wiki.archlinux.org/title/External_GPU)
- [JuliaComputing/nvidia-driver-pcie-rebar](https://github.com/JuliaComputing/nvidia-driver-pcie-rebar)
- [Framework community thread: SOLVED Thunderbolt eGPU detection on Linux](https://community.frame.work/t/solved-thunderbolt-egpu-detection-on-linux/11521)

---

## Q5 — Can we propose an Option E (kernel patch) with confidence?

### Two separate sub-problems, two different patches

**Sub-problem A: TB auto-authorize on quiet re-attach (Q1's gap)**

Tractable. Approach options:

A1. **Patch boltd's `handle_udev_device_attached`** to call `manager_auto_authorize` on the stored device if `authmode && policy in {auto, iommu}`. ~20 LOC change, restricted blast radius. Could be PR'd to https://gitlab.freedesktop.org/bolt/bolt. Maintainer (Christian Kellner) is responsive.

A2. **Add a kernel-side udev rule** (already documented as a workaround in [systemd #40784](https://github.com/systemd/systemd/issues/40784)):
```
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTRS{iommu_dma_protection}=="1", ATTR{authorized}=="0", ATTR{authorized}="1"
```
Zero code; rule installed at `/etc/udev/rules.d/`. The problem is this races with boltd's policy evaluation and may double-fire.

A3. **Resurrect Mario Limonciello's 2022 RFC** to do iommu-protected auto-authorize *in the kernel* itself, dropping the boltd dependency. Higher patch acceptance risk (was bounced once), but is the architecturally cleanest fix. Estimate 6-12 month upstream cycle if reattempted.

**Recommendation for sub-problem A:** ship A2 (udev rule) as immediate mitigation; consider A1 as a longer-term contribution but not as our critical path.

**Sub-problem B: Runtime bridge-window resize (Q2's gap, the actual show-stopper)**

Marginally tractable, very high effort, low confidence of upstream acceptance.

B1. **Per-domain "reserve N gigabytes per empty TB port" kernel parameter, computed automatically.** Currently `hpmmioprefsize` is global. A per-port variant (`pci=hpmmioprefsize_port=03:00.0:16G`) is plausible but probably gets NAK'd as a knob-explosion.

B2. **A scoped "release and re-lay-out this subtree on bridge rescan" path.** Conceptually a subset of Miroshnichenko's movable-BARs work. It would need to (i) quiesce drivers under the subtree (in our case just nvidia), (ii) release child resources of the rescanned bridge, (iii) re-run `pci_assign_unassigned_bus_resources()` with `release_type=whole_subtree`, (iv) rebind drivers. The NVIDIA driver does have `pci_error_handlers` registered in our patched fork (E1 work) so a quiesce/restore path is plausible. **But** this is a 20-30-patch series against drivers/pci/, would need months of maintainer engagement, and would likely face the same NAK Miroshnichenko did. Estimate 12-24 month upstream cycle, probably 60-200 hours of our effort.

B3. **ReBAR-aware hotplug enumerator.** What the LF Forum thread is asking for. ~"At enumeration time, query device for `PCI_EXT_CAP_ID_REBAR`, compute the largest size that fits in available bridge headroom, and *resize before commit*." This is the right fix architecturally. It's the natural next step after the 6.19/7.0 Järvinen refactor lands. **Bjorn Helgaas has historically been receptive to this direction but wants somebody to do the work end-to-end.** Estimate 6-12 months from a serious contributor.

### Honest assessment

Option E as "we ship a kernel patch and the problem is solved" is a 12-24-month investment with uncertain acceptance. Two reasons it's not in our critical path:

1. **The injector project's value proposition is fast iteration on NVIDIA-driver-side fixes.** Going deep into drivers/pci/ moves us into maintainer territory where iteration is measured in months per round-trip.
2. **The user's actual problem (runtime BAR1=256MB after chassis power-cycle) is recoverable today by reboot.** A 60-200-hour engineering investment to remove a reboot is poor ROI when the same engineering capacity could harden 3-4 other reliability dimensions.

**If we choose to do upstream work, A1 (boltd patch) is the high-value low-cost contribution.** B3 (ReBAR-aware enumerator) is the right "big" play but is a year-long commitment.

### Sources

- [Patchwork: Allow BAR movement during boot and hotplug — v9 cover (stalled precedent)](https://patchwork.ozlabs.org/project/linux-pci/cover/20201218174011.340514-1-s.miroshnichenko@yadro.com/)
- [Spinics: thunderbolt auto-authorize on iommu RFC (2022, bounced)](https://www.spinics.net/lists/linux-usb/msg223924.html)
- [systemd issue #40784 — udev rule for IOMMU-protected TB authorize](https://github.com/systemd/systemd/issues/40784)
- [LF Forum: Make the kernel ReBAR-over-Thunderbolt friendly](https://forum.linuxfoundation.org/discussion/870568/make-the-linux-kernel-rebar-over-thunderbolt-friendly) — current technical discussion that an upstream B3 patch would respond to

---

## Q6 — Design recommendation for our injector

### Three options, evaluated

**Option B — in-container watcher (poll for "TB connected + no PCI device", trigger `boltctl authorize` + PCI rescan)**

Pros:
- Closes the TB-authorize half of the gap (Q1) deterministically.
- Lives in our injector container, so it ships with the rest of our hardening (no host-side configuration drift).
- ~50-100 LOC bash watcher. Cheap to write, easy to test.
- Doesn't require host package installation — bolt CLI is already on the host; the watcher just invokes it (or uses the D-Bus API directly).
- Composes well with our existing label/lease producer.

Cons:
- Does NOT solve the BAR1 sizing problem (Q2). After the watcher authorizes, BAR1 still comes up at 256MB.
- Requires running `boltctl` from the container, which means either mounting `/var/run/dbus` into the container or running the watcher on the host. Mounting D-Bus is normal practice but adds a permission surface.
- A polling watcher races with boltd's own re-attach attempts; idempotency required.

**Option E — upstream kernel patch**

Per Q5 analysis: 12-24-month investment, uncertain acceptance, and even the most tractable variant (A1 boltd patch) doesn't fix BAR1 sizing.

Not recommended as our critical-path solution. Worth pursuing as a separate, slower-cadence initiative if we want to invest in upstream impact for its own sake.

**Option F — document the prerequisite, treat runtime power-cycle as "reboot required"**

Pros:
- Zero engineering effort.
- Aligns with the broader Linux eGPU ecosystem (Q4) — this is what everyone else does.
- Honest about a limitation rooted in the Linux PCI architecture, not our stack.

Cons:
- User-facing constraint we'd rather not have.
- Operationally: anyone managing the eGPU manually has to remember "cable in at boot".
- For k8s-vllm specifically, a chassis power-cycle becomes "drain the pod, reboot the node, undrain". Painful but tractable.

### Recommendation

**Ship B + F. Don't ship E now. Reconsider E only if both:**
- The runtime-power-cycle scenario shows up in actual operational logs more than once per month, AND
- The BAR1=256MB sizing comes up as a real workload constraint (it doesn't for our vLLM AWQ-4bit Qwen3-Coder model at 96k context — that fits well under 32G BAR1 but also runs fine if BAR1 isn't fully sized as long as VRAM accesses go through D3D PCIe rather than BAR1-mapped paths).

**Option B implementation sketch:**

A small `tb-egpu-reauth.sh` in `apnex/nvidia-driver-injector` container, run as a sidecar or a `systemd-tmpfiles`-style "run once on startup, then loop with udev events":

1. Subscribe to udev `thunderbolt_device` add events (or poll `/sys/bus/thunderbolt/devices/` every 10s).
2. For each device with `authorized=0` and a matching entry in `/var/lib/boltd/devices/<uuid>` (the stored DB):
   - Read `/sys/bus/thunderbolt/devices/<domain>/iommu_dma_protection`. If `==1`, proceed.
   - Read the stored policy. If `auto` or `iommu`, proceed.
   - Issue `boltctl authorize <uuid>` (or write `1 > /sys/.../authorized` if we don't want a D-Bus dependency).
3. Log the action to journald with a clear tag (`tb-egpu-reauth`) for observability.
4. After authorize, wait up to 30s for PCI enumeration of the NVIDIA device.
5. If PCI enum happens but BAR1<32G, log a one-line WARN noting "BAR1 sizing limited — chassis power-cycle workflow detected; reboot to recover full BAR1".

**Option F documentation sketch:**

Add to `apnex/nvidia-driver-injector` README:
- "Operational prerequisite: eGPU chassis must be powered ON when the host boots, for full BAR1 sizing. Runtime chassis power-cycle is partially supported (TB auto-reauthorize via injector sidecar) but BAR1 will be limited to 256MB until next reboot. For workloads that use >256MB of BAR1-mapped VRAM, schedule a node reboot after any chassis power-cycle event."
- Surface a node label `nvidia.gpu/bar1-degraded=true` when this state is detected, so the consumer (vllm-deployment) can refuse to start there.

### Sources

- All of Q1-Q5 sources.
- [Kernel docs: USB4 and Thunderbolt](https://docs.kernel.org/admin-guide/thunderbolt.html) — sysfs interface for the watcher to read
- Internal: `archive/power-on-test-20260525T005756Z/` empirical baseline

---

## Open questions / unresolved

- **Why did `boltd` on our host specifically not run the auto-authorize path?** Q1 narrowed this to three plausible causes (handler-attached vs handler-added branch, authmode-off, Bz#1770579 class race) but we haven't read the *running* boltd's state to confirm which. Concrete next step: capture `boltctl monitor` during the next chassis power-cycle event and grep boltd journald for the udev add receipt.
- **Does `hpmmioprefsize=16G` on cmdline actually help on the NUC 15 Pro+?** Arch Wiki recommends it; we haven't tried. If it works at boot, it might also help survive *cold* re-plugs by ensuring empty-port windows are pre-sized. Cheap experiment, but the existing project-guard memory warns against unreviewed cmdline changes — run `tools/check-cmdline-guards.sh` style review before trying.
- **Was the "3 separate enumeration attempts" pattern (Q1 trigger) an upstream-router instability or a downstream-device re-presentation?** The kernel-events.log distinguishes by which port the events fire on. Worth a careful re-read of `kernel-events.log` lines around the 1:2 events to confirm whether 1:0 (the host router) saw any state change. If 1:0 stayed quiet, that confirms our model (quiet re-attach on stored UUID, boltd's add-handler didn't fire).
- **Should we attempt Mario Limonciello's 2022 RFC resurrection (Option E-A3)?** If we want one upstream contribution from this initiative, that's the lowest-risk highest-reach one — the Q1 problem class affects every Blackwell-class eGPU and probably every TB-attached AMD GPU too.
- **Long-term: does the Järvinen 6.19/7.0 refactor enable a third party to write the ReBAR-aware hotplug enumerator within the next 12 months?** Worth monitoring linux-pci for any cover letter mentioning hotplug+rebar in the same series, and pinging if a serious draft appears.
