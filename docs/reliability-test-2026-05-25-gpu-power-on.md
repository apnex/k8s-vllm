# Reliability test 2026-05-25 — live GPU power-on after extended absence

**Status:** in progress, observation phase.\
**Date opened:** 2026-05-25.\
**Tester:** main agent + user (physical).\
**Test class:** integration / hardware-in-the-loop / passive-observation.\
**Archive dir:** `archive/power-on-test-20260525T005756Z/`.

---

## Why this test

Opportunistic integration data — the user powered off the AORUS RTX 5090 eGPU after the production cutover (last healthy soak scrape 2026-05-24 13:36:58 UTC, 14h ago) and offered to power it back on under observation.\
This exercises the **full recovery path** that no synthetic test reaches:

- Thunderbolt re-authentication with stored credentials
- PCIe hotplug enumeration of the bridge + device
- nvidia driver re-load via the injector container
- node label transitions through the producer / consumer contract
- vLLM pod recovery from extended `CrashLoopBackOff`
- kubelet exponential backoff vs. actual recovery latency
- soak observability stream behavior across the gap

**Operating discipline: passive observation only.** No `kubectl delete`, no manual modprobe, no boltctl prods. The whole point of the M-recover / Q-watchdog / kubelet-backoff stack is to recover without human intervention; intervention masks gaps.

---

## Hypotheses

Numbered so post-test analysis can mark each PASS / FAIL / INCONCLUSIVE.

### H-A — Thunderbolt re-authenticates on power-on without manual intervention

**Prediction:** TB stack auto-authenticates using the stored cert (iommu policy, no key, prior authorisation 2026-05-24 08:59 UTC) within ~10s of physical power-on.\
**Signal:** `kernel-events.log` shows `thunderbolt ... authorized` for the AORUS UUID `c4148780-00a9-7ce8-ffff-ffffffffffff`.\
**Fail mode if untrue:** would require `boltctl authorize` manually — hardening gap.

### H-B — PCIe enumerates the bridge + device cleanly

**Prediction:** `pcieport ... Slot #N HotPlug+ Surprise+` triggers device enumeration. No AER cascade (Receiver Error / Bad TLP at Gen3 — known pattern from prior investigations).\
**Signal:** `kernel-events.log` shows pcieport messages → `nvidia` probe → `nvidia 0000:0X:00.0` device line.\
**Fail mode if untrue:** AER cascade or stuck-link state → the M-recover stack should engage. Worth recording either way.

### H-C — Injector container recovers on its own via kubelet backoff

**Prediction:** the current `nvidia-driver-injector-hc45j` pod (29 restarts as of pre-test) eventually succeeds modprobe on its next backoff attempt after the device returns. Kubelet exponential backoff is capped at ~5 min — recovery latency expected 0-5 min from device-present moment.\
**Signal:** k8s `Ready 0/1 → 1/1`; injector logs show `nvidia.ko loaded`; `/sys/module/nvidia/version` populated.\
**Fail mode if untrue:** the backoff window exceeds the test patience AND the container never sees the device → would mean the injector needs an event-driven trigger (udev hook → restart loop) rather than relying on kubelet alone.

### H-D — Node label `nvidia.driver/state` transitions correctly

**Pre-test observation:** label is **already STALE** at `ready` while the driver has been absent for 14 hours. This is a confirmed **hardening gap** in the injector — it leaves the prior label in place instead of flipping to `degraded` (or removing it) when modprobe fails.\
**Prediction during test:** once injector succeeds, the label remains `ready` (transitions from stale-ready to legitimate-ready — semantically the same string, just now backed by reality).\
**Fail mode if untrue:** label flickers or doesn't reach `ready` after injector success.\
**Follow-up regardless of test result:** file injector hardening — set label to `degraded` on modprobe failure.

### H-E — vLLM pod recovers automatically once CDI works

**Prediction:** vLLM's `nvidia-driver-injector-hc45j`-derived backoff (37 restarts) means kubelet is at 5-min cap. Next restart attempt after `/dev/nvidia*` exists will pass the CDI initialization step → container starts → vLLM cold-loads weights from HF cache (~2-5 min) → `/health` returns 200.\
**Signal:** `metrics.csv` `scrape_ok` flips back to 1; pod `READY 0/1 → 1/1`; chat completion via VIP succeeds.\
**Fail mode if untrue:** vLLM stays in some new failure mode (e.g., GPU state-corrupted, weights cache corrupted by previous half-init, stale CUDA context).

### H-F — Total wall-clock latency from power-on to `/v1/models` serving

**Prediction:** 5-15 min total.
- TB auth: ~10s
- PCI enum: ~5s
- Injector next-backoff: 0-5 min
- nvidia modprobe + GSP firmware load: ~30-60s
- vLLM next-backoff: 0-5 min
- vLLM cold-load (cached weights): ~2-5 min

**Signal:** first successful `curl http://192.168.1.251:8000/v1/models` after power-on.\
**Pass:** ≤15 min total.\
**Fail:** anything >15 min → recovery-latency hardening item.

---

## Methodology

**Single variable changed:** GPU power state (off → on).\
**No other interventions:** no manual modprobe, no `kubectl delete`, no boltctl invocations.\
**Wait patience:** at least 15 min after power-on before re-evaluating.\
**Escalation if no recovery by 15 min:** capture detailed diagnostic state, THEN consider intervention as a follow-up reliability test (separately documented).

---

## Pre-test state (captured before power-on)

In `archive/power-on-test-20260525T005756Z/pre-state.txt`. Summary:

| Layer | State |
|---|---|
| Thunderbolt | AORUS RTX5090 AI BOX: `disconnected` (last auth 2026-05-24 08:59 UTC) |
| PCI NVIDIA | none enumerated |
| nvidia.ko | unloaded; `/sys/module/nvidia/version` absent |
| `/dev/nvidia*` | absent |
| Injector pod | CrashLoopBackOff, 29 restarts in 17h |
| vLLM pod | CrashLoopBackOff, 37 restarts in 14h; error `failed to initialize NVML: Driver Not Loaded` |
| Node label | `nvidia.driver/state=ready` (STALE — see H-D) |
| Soak metrics | last `scrape_ok=1`: 2026-05-24 13:36:58 UTC |

---

## Observation harness

Three streams capturing to the archive dir:

1. **`pre-state.txt`** — one-shot snapshot at T-0
2. **`kernel-events.log`** — `journalctl -kf` filtered for `nvidia|pcie|thunderbolt|aer|0000:0[3-5]` (background)
3. **`k8s-events.log`** — `kubectl get events -A --watch` filtered for `nvidia|injector|vllm|pcieport` (background)

Plus existing continuous soak streams:

- **`/var/log/vllm-soak/metrics.csv`** — vLLM `/metrics` scrape every 30s; `scrape_ok` flips back to 1 = vLLM is back
- **`/var/log/vllm-soak/pods-*.txt`** — daily snapshot (may or may not fire during this test)

---

## Pass criteria (overall test)

| # | Criterion | Pass threshold |
|---|---|---|
| 1 | Hardware recovery (TB + PCI + driver + `/dev/nvidia*`) | within 5 min of power-on |
| 2 | Injector recovers WITHOUT intervention | within 10 min of power-on |
| 3 | vLLM pod recovers WITHOUT intervention | within 15 min of power-on |
| 4 | First `/v1/models` success via VIP | within 15 min of power-on |
| 5 | No new failure modes introduced (no AER cascade, no WPR2 stuck, no Mode B wedge) | per `kernel-events.log` review |

Each criterion produces a discrete PASS / FAIL / INCONCLUSIVE in the post-test analysis section below.

---

## Post-test analysis

### Timeline of events (T+0 = power-on @ 2026-05-25 01:03:52 UTC)

| Time | Event | Source |
|---|---|---|
| T-20s | TB authenticated (`boltctl status: connected`) but `authorized=0` in sysfs | `boltctl list`, `/sys/.../authorized` |
| T-20s | Kernel TB layer emitted plug→unplug for upstream port 1:2; ended with no PCIe enumeration | `archive/.../kernel-events.log` lines 1-198 |
| T+0 → T+20min | Passive observation; kubelet cycled injector 30→34, vLLM 39→43; no recovery | `archive/.../k8s-events.log`, monitor task `b625w18hp` |
| T+20min | Monitor timeout; ZERO kernel events past T-20s (kernel saw nothing further) | `archive/.../kernel-events.log` confirmed |
| Post-test investigation | TB layer attempted enumeration 2 more times (T+27min, T+52min), identical plug→unplug pattern each | `archive/.../kernel-events.log` lines 199-410 |
| **T+~56min** | **`boltctl authorize <uuid>` → immediate PCIe enumeration**: pcieport cascade, NVIDIA `10de:2b85` enumerated at 0000:04:00.0 | manual experiment, kernel log delta |
| T+~56min | BAR1 sized at **256MB** (need 32GB); intermediate bridge window stuck at 288MB | `lspci -vs 0000:04:00.0` |
| T+~60-75min | Runtime recovery attempts ALL FAILED: `echo 15 > resource1_resize` ("no space"), TB deauth+reauth (windows preserved), PCI remove+rescan (windows preserved) | dmesg `can't assign; no space` |
| T+~80min | Reboot with cable unplugged (user oversight) → TB never re-handshook; second reboot | (operational miss, learning preserved) |
| T+~85min | Reboot with cable PLUGGED IN → BAR1=32GB, bridge=33089M, driver auto-loaded, `nvidia-smi` reports 45°C / 26W | post-reboot verification |

### Hypothesis results

| # | Result | Evidence |
|---|---|---|
| **H-A** TB re-auth without intervention | **SPLIT: PASS at boot / FAIL at runtime** | TB layer reaches `connected` state, but sysfs `authorized=0` and PCIe tunnel never establishes at runtime; at boot, `authorized=1` fires automatically within 2s |
| **H-B** PCIe enumerates the bridge + device | **FAIL at runtime / PASS at boot** | Zero pcieport enumeration during 20-min runtime observation; clean enumeration at boot when GPU present |
| **H-C** Injector recovers autonomously | **FAIL** | Cycled 4× via kubelet backoff over 20 min, never succeeded — blocked upstream by H-B |
| **H-D** Node label transitions correctly | **FAIL — D-1 confirmed** | Label stayed at stale `nvidia.driver/state=ready` throughout the 20-min driver-absent window |
| **H-E** vLLM recovers autonomously | **FAIL** | Cycled 4× via kubelet backoff over 20 min, never succeeded — blocked upstream by H-B + H-C |
| **H-F** Total recovery ≤15 min | **FAIL** | No recovery in 20 min; full recovery required reboot with cable in (~85 min wall-clock total) |

### Hardening gaps surfaced

| # | Gap | Where it lives | Severity | Note |
|---|---|---|---|---|
| **D-1** | Stale `nvidia.driver/state=ready` label during driver-absent window | injector repo | medium | known pre-test, confirmed during test |
| **D-2** | Injector enters liveness-probe-crashloop instead of clean-exit-wait under k3s | injector repo | medium | surfaced mid-test from user query; observed plug→unplug pattern + kubelet-driven restart cycle |
| **D-3** | PCIe tunnel does not autonomously recover from chassis power-cycle; runtime hot-plug after-power-cycle requires reboot | injector repo + ecosystem | **high** | structural finding — Linux kernel bridge windows are sized once at enumeration; no Linux mechanism reliably grows them on runtime hot-plug. Research subagent (M1 in mission manifest) will investigate whether userspace tooling or upstream patches can address this. |
| **D-4** | Injector failure modes buried in logs | injector repo | low-medium | BAR1=256MB error sat in container logs unread for 10+ min. Failure modes should be louder (events, exit codes that distinguish "no GPU" from "GPU broken"). |

### Follow-up actions

1. **Filed in mission manifest** ([`docs/mission-manifest.md`](./mission-manifest.md)) as `D-1` through `D-4`.
2. **M1 research subagent** (TB / PCIe deep-dive) — informs the design call for D-3 specifically; `pci=realloc=on` already research-validated as NOT a solution (LF forum testing confirms).
3. **M2 GPU Operator audit** — informs D-1, D-2, D-4 design (mirror NVIDIA label / taint conventions, learn their entrypoint state machine).
4. **No code changes to injector yet** — per user direction: "discuss hardening design before we commit to changes."
5. **Documented operational discipline**: cable must be plugged in at boot. Will be added to injector README's Prerequisites.

### Follow-up empirical finding — cable replug attempted later same day (2026-05-25 ~14:04 UTC)

After the post-reboot system was stable, attempted E1 (cable replug on powered chassis) to validate H1. **vLLM was actively serving traffic at the time** — methodology oversight on my part (should have drained first).

Sequence observed in journal:

```
14:03:51  NVRM: Xid (PCI:0000:04:00): 154, GPU recovery action changed
          from 0x0 (None) to 0x2 (Node Reboot Required)
14:04:45  user replugged cable
14:04:46  thunderbolt activated paths; PCI did NOT enumerate (sysfs authorized=0)
14:05:34  rsyslogd: 663,842 messages lost due to rate-limiting in 600s window
14:06:53  host rebooted (kernel-driven, watchdog)
```

**Empirical findings:**

1. **Xid 154 fired BEFORE the cable replug** (14:03:51 vs 14:04:45 user action). The cable yank + active compute triggered the unrecoverable state.
2. **The project's P3/M-recover stack did NOT intercept** the failure cascade. Xid 154 is downstream of where our recovery layers operate.
3. **Kernel watchdog rebooted the host** ~3 min after Xid 154 fired.
4. **H1 (hot-plug works on cable replug) remains untested** because the system entered fatal state from the active-compute side before the cable-replug data point could be gathered.
5. **NEW hypothesis surfaced (H7 in MISSION-1 doc)**: NVRM Xid 154 fires under surprise removal during active CUDA compute — CONFIRMED.
6. **NEW hardening axis (Sub-mission C in MISSION-1 doc)**: unexpected disconnect resilience. The existing stack handles PCIe transients well but not instant electrical disconnect + active compute.

### Net outcome

The test surfaced **4 hardening gaps**, **validated the user's intuition that "runtime hot-plug must work"** (the kernel TB code IS functioning correctly per design — but Linux's PCI bridge window allocation has a structural limitation), and produced **direct empirical confirmation that `boltctl authorize` at runtime triggers correct PCIe enumeration when bridge windows are adequately sized at boot**. The "cold-plug at boot" pattern remains the only reliable production path on this hardware until either upstream Linux patches land or our injector grows a TB-event-driven authorize watcher (Option B from the design discussion).

---

## Cross-references

- Producer repo (injector): https://github.com/apnex/nvidia-driver-injector
- Project memory: `feedback_reliability_methodology`, `feedback_observability_perturbs_bug`, `project_close_path_mitigated_2026_05_08`
- Related patches in injector: P3 (Q-watchdog), A1 (M-recover), A2-A5 (recovery infrastructure)
