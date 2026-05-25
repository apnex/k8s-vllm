# Mission — TB eGPU runtime hot-plug + hot-power

**Status:** ACTIVE — declared 2026-05-25.\
**Owner:** main agent + user.\
**Trigger:** Reliability test 2026-05-25 surfaced gap D-3 (`docs/reliability-test-2026-05-25-gpu-power-on.md`); user elevated it to project mission.\
**Companion research:** [`audit/tb-pcie/CONSOLIDATED.md`](../audit/tb-pcie/CONSOLIDATED.md) (M1 deep-dive).

---

## Mission statement

Achieve reliable runtime hot-plug AND hot-power capability for TB-attached eGPUs on Linux **without requiring host reboot**, on code we can read and control.

This is elevated to **first-class project mission** alongside reliability and performance — comparable in weight to "no hard locks, no surprise-removal cascades, recovery autonomous." It is a standing engineering goal, not a hardening sprint.

---

## Investigation discipline

**We investigate code we can read.**

In scope (open source, iterable, debuggable):

- Linux kernel — `drivers/thunderbolt/`, `drivers/pci/setup-bus.c`, `drivers/pci/hotplug/pciehp_*`, `drivers/pci/pcie/rebar.c`
- boltd userspace daemon — `https://github.com/anjlab/bolt`
- Our injector — `apnex/nvidia-driver-injector` (entrypoint, scripts, manifests)
- Linux sysfs / ioctl / netlink APIs touching PCIe + TB

Explicitly out of scope (closed, opaque, un-iterable):

- AORUS chassis firmware (GIGABYTE proprietary, no public source, no debug hooks)
- Intel TB4 controller microcode (closed)
- NVIDIA GPU VBIOS (closed)
- Anything that would require a NDA + access to vendor private trees

If a hypothesis points to chassis firmware as the root cause, we **note it but do not pursue it** — we work around it from layers we control.

---

## Two sub-missions (distinct tractability)

### Sub-mission A — Hot-PLUG (cable physically inserted while host is up)

**Mechanism today:** USB-C connector's CC1/CC2 lines transition on physical cable insert → host TB controller fires fresh enumeration → bridge windows sized based on what device announces → BAR1 reaches 32GB → PCIe tunnel established cleanly.

**Status:** *probably works* on our hardware via the well-trodden cable-insert code path, but **NOT YET EMPIRICALLY VERIFIED on this rig**. Confirmation test is cheap (cable unplug + 5s + replug).

**Tractability:** weeks. Primarily an injector hardening problem — Option B watcher detects + responds to the existing hotplug events; doesn't require kernel work.

### Sub-mission B — Hot-POWER (chassis power-cycled, cable untouched)

**Mechanism today:** No CC transition (cable was never removed). TB controller sees link-layer signal loss + reappearance. Linux thunderbolt subsystem processes events but does NOT trigger fresh USB-C-level enumeration → bridge windows NOT reallocated → BAR1 stays at boot-time-allocated size (256MB if GPU was off at boot, never grows at runtime).

**Status:** **definitively broken** (today's test, 50+ min observation, 3 separate TB enumeration attempts each ending in plug→unplug pattern, no PCIe enumeration). M1 research found zero in-flight upstream kernel patches that fix this.

**Tractability:** multi-month. Requires either:
- A software-only signal that triggers the same bridge-enumeration path that CC events trigger (unknown if exists; Phase 2 investigation), OR
- An upstream Linux kernel patch series adding runtime bridge-window regrow for populated bridges (Phase 3, multi-quarter)

---

## Hypotheses

Numbered for cross-reference in commits and future tests. Each hypothesis has a falsification gate.

### H1 — Hot-PLUG works on our hardware via CC-event-triggered enumeration

**Prediction:** Cable replug on the powered-on chassis triggers full PCIe enumeration with BAR1 = 32GB and bridge window 03:00.0 ≥ 32GB, identical to the cold-boot path.\
**Falsification gate:** cable replug test produces BAR1 < 32GB OR enumeration fails entirely.\
**Status:** UNTESTED on this rig. Empirical test pending.\
**Why it matters:** if FALSIFIED, sub-mission A becomes much harder than expected.

### H2 — Hot-POWER fails specifically because no CC event fires

**Prediction:** Chassis power-cycle generates only TB-link-layer signaling (signal loss + reappearance on data pairs), NOT a USB-C CC pin transition. Without the CC event, the kernel's USB-C / PD layer never declares "fresh cable" — and the downstream bridge-enumeration cascade never re-runs.\
**Falsification gate:** instrument USB-C CC state during chassis power-cycle and observe a transition.\
**Status:** PLAUSIBLE based on USB-C/TB spec understanding; not empirically validated on our hardware.\
**Why it matters:** if CONFIRMED, the fix target is "trigger the post-CC code path from software"; if FALSIFIED, the problem is somewhere else entirely.

### H3 — Linux thunderbolt kernel driver behaves correctly given the events it receives

**Prediction:** The kernel thunderbolt subsystem processes incoming TB events per spec. The "plug-then-unplug-in-one-second" pattern observed at T-20s in today's test is the kernel correctly handling what the chassis sent, not the kernel misinterpreting clean events.\
**Falsification gate:** find a kernel commit or LKML thread showing this exact decision logic is buggy.\
**Status:** PARTIALLY CONFIRMED by M1 (source code review of `tb_handle_hotplug` shows behaviorally identical paths boot vs runtime). The "ignore disconnected port" decisions are documented kernel behavior, not bugs.\
**Why it matters:** if CONFIRMED, kernel-side fix scope shrinks to "support new event types or new behavior on existing events," not "fix existing event handling."

### H4 — Chassis firmware emits a spurious unplug immediately after power-on plug (NOTED, OUT-OF-SCOPE for investigation)

**Prediction:** AORUS chassis firmware, on chassis power-up, generates a plug event for the upstream PCIe port, then within milliseconds an unplug event for the same port. The unplug aborts kernel enumeration. This is a chassis-side bug.\
**Falsification gate:** observe a different chassis (different vendor, e.g. Razer Core / OWC Helios) exhibit OR not exhibit the same plug+unplug pattern under chassis power-cycle.\
**Status:** PLAUSIBLE based on the kernel-events.log pattern from today's test, but **investigation is OUT OF SCOPE** per the discipline above — chassis firmware is closed and un-iterable. If a future test on different hardware confirms or rules out, we record the finding but do not pursue a fix at the chassis layer.\
**Why it matters:** if CONFIRMED, any Linux-side mitigation is by definition "papering over a vendor firmware bug" — but it may still be the right engineering choice given Phase 3 timelines.

### H5 — Bridge window sizing is sticky once allocated; no Linux kernel path exists to grow it for populated bridges at runtime

**Prediction:** Bridge windows allocated at boot or at first-enumeration are immutable for the lifetime of those bridges. Linux has no `pci_resize_bridge_resource()` API. The runtime workarounds we tried (`resource1_resize`, deauth+reauth, bridge remove+rescan) all preserve the boot-time window sizing.\
**Falsification gate:** find a Linux kernel API (existing or proposed) that grows bridge windows at runtime for populated bridges.\
**Status:** CONFIRMED by M1 (source comment in `__assign_resources_sorted` is explicit; Miroshnichenko "movable BARs" series proposed an API but stalled in 2020).\
**Why it matters:** this is the structural constraint that makes hot-POWER hard. Without a kernel API to grow windows, we cannot fix this purely in userspace.

### H6 — A software-only trigger for bridge re-enumeration exists that we haven't found

**Prediction:** Among the many sysfs / ioctl / netlink APIs touching PCIe + TB, at least one of them can trigger the same "do full bridge enumeration" code path that USB-C CC events trigger — we just haven't found it yet.\
**Falsification gate:** exhaustively enumerate all sysfs paths under `/sys/bus/pci/` and `/sys/bus/thunderbolt/`, all ioctls in `<linux/pci.h>`, all kernel debugfs entries; test each that plausibly could trigger; document each as "doesn't trigger" or "does trigger" with evidence.\
**Status:** OPEN — Phase 2 investigation. We have tried: `boltctl authorize`, `boltctl forget+enroll`, sysfs `authorized=0/1` toggle, `resource1_resize`, PCI `remove`+`rescan` at three different bridge levels. None worked. There are more paths we haven't tried.\
**Why it matters:** if H6 holds, the mission collapses to "find the right sysfs write" + Option B watcher. Phase 3 (upstream patches) becomes unnecessary.

---

## Phase plan

Each phase has explicit entry / exit criteria so we know when to stop pursuing or escalate.

### Phase 1 — Tactical (weeks)

**Goal:** unblock the most-common operational case (hot-PLUG of cable while host up) AND confirm or falsify H1.

**Work:**

1. Empirical: cable-replug test on our rig. Validates H1.
2. If H1 confirmed: build Option B watcher in the injector — detects "TB connected + sysfs authorized=0" pattern, calls `boltctl authorize` automatically. Also detects "TB connected + auth=1 + no PCI device" and triggers any remaining sysfs prods we identify in Phase 2.
3. If H1 falsified: scope-expand to Phase 2 immediately; document the surprise.

**Exit criteria:** hot-PLUG works autonomously on our rig (no manual operator action when cable is replugged on powered chassis), OR documented as falsified and escalated.

### Phase 2 — Software-path archaeology (1-3 months)

**Goal:** answer H6 definitively — does any Linux software API trigger the bridge-re-enumeration path that hot-POWER needs?

**Work:**

1. **Kernel source archaeology** — every function in `drivers/pci/setup-bus.c` and `drivers/pci/hotplug/pciehp_*.c` that touches bridge window allocation. Trace which APIs invoke them.
2. **Sysfs surface enumeration** — every writable file under `/sys/bus/pci/` and `/sys/bus/thunderbolt/`. Test each that plausibly could trigger re-enumeration. Document each result.
3. **ioctl surface** — every PCI-related ioctl in `<linux/pci.h>`. Test from userspace.
4. **debugfs surface** — every entry under `/sys/kernel/debug/pci/` and `/sys/kernel/debug/thunderbolt/`. Test.
5. **netlink surface** — `udev` events, PCI uevents. Can we synthesize an event that triggers re-enumeration?
6. **pcihp slot power cycle** — `/sys/bus/pci/slots/<N>/power` — untested today; high-priority candidate.
7. **boltd source review** — `https://github.com/anjlab/bolt` — does boltd have a code path that triggers fuller re-enumeration than `boltctl authorize` does?

**Output:** comprehensive matrix of every software path tried + result + kernel events generated.

**Exit criteria:** ONE of:
- (a) we find a working software-only trigger → integrate into Option B watcher, sub-mission B closed
- (b) we exhaustively prove no software-only trigger exists in current kernel → escalate to Phase 3
- (c) we hit a partial success (e.g., works on some kernel versions but not ours) → narrow scope and escalate to Phase 3

### Phase 3 — Upstream kernel work (6-12 months)

**Goal:** if Phase 2 says "no software-only fix exists today," contribute a kernel patch that makes one exist.

**Work:**

1. **Archive review** — read the full Miroshnichenko "movable BARs" v9 thread (Dec 2020) and all subsequent discussion on linux-pci. Understand exactly why it stalled.
2. **Engage maintainers** — Mika Westerberg (TB), Bjorn Helgaas (PCI) — share our use case + reliability test as a concrete bug report (which M1 noted was the main thing the Miroshnichenko series lacked).
3. **Patch design** — either (a) resurrect Miroshnichenko's approach with our bug report as supporting evidence, OR (b) propose a narrower API specifically for "redo bridge window allocation on hotplug event from TB driver."
4. **Code + test** — implement, test on our rig, post as RFC to linux-pci.
5. **Iterate** — respond to review, possibly multiple revisions.

**Output:** upstream patch series posted to linux-pci, either merged or with clear architectural NAK.

**Exit criteria:** patch merged to mainline OR maintainer position clarifies why the approach won't work (in which case, re-enter Phase 2 with the narrower scope).

### Phase X — Chassis firmware (INFORMATIONAL ONLY, not pursued)

If at any point we identify the chassis firmware as the root cause (per H4):

- Document the specific firmware behavior observed
- Report to GIGABYTE via consumer support channels
- DO NOT block any work on chassis firmware update — too slow / no transparency / un-iterable
- Continue Phase 2/3 work as the path that's under our control

---

## Empirical experiments queued

| # | Experiment | Validates / falsifies | Cost | Priority |
|---|---|---|---|---|
| **E1** | Cable replug on powered chassis (NUC-side unplug, 5s wait, replug) | H1 | 2 min | **HIGH — do first** |
| **E2** | `echo 0 > /sys/bus/pci/slots/<N>/power; echo 1 > /sys/bus/pci/slots/<N>/power` | H6 (pcihp slot power cycle path) | 5 min | HIGH |
| **E3** | Cycle through every writable sysfs file under `/sys/bus/pci/devices/0000:0X:00.0/` | H6 (sysfs surface) | 30 min | MEDIUM (Phase 2 scope) |
| **E4** | `udevadm trigger` with various subsystem filters | H6 (udev re-trigger path) | 15 min | MEDIUM |
| **E5** | Force `setpci` rewrite of bridge BAR registers + rescan | H6 (manual register manipulation) | 30 min | LOW (high risk, lowest expected yield) |
| **E6** | Test with a different TB chassis (e.g., Razer Core, OWC Helios) if available | H4 (chassis firmware vs Linux kernel as root cause) | hardware-dependent | LOW (informational only) |

---

## Cross-references

- [`audit/tb-pcie/CONSOLIDATED.md`](../audit/tb-pcie/CONSOLIDATED.md) — M1 deep-dive (TB / PCIe research)
- [`docs/reliability-test-2026-05-25-gpu-power-on.md`](./reliability-test-2026-05-25-gpu-power-on.md) — origin reliability test (D-3 surfaced)
- [`docs/mission-manifest.md`](./mission-manifest.md) — top-level mission entry-point
- Linux Foundation forum thread: `https://forum.linuxfoundation.org/discussion/870568/make-the-linux-kernel-rebar-over-thunderbolt-friendly` (community-validated pci=realloc analysis)
- Linux thunderbolt subsystem source: `https://elixir.bootlin.com/linux/latest/source/drivers/thunderbolt`
- boltd userspace daemon: `https://github.com/anjlab/bolt`
- Miroshnichenko "movable BARs" patch series (Dec 2020, stalled): search linux-pci archive for relevant thread
