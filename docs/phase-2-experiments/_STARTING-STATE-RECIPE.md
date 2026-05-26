# Starting-state recipe — "broken-BAR1" condition

Section 1 + Section 2 experiments test whether a recovery path can restore BAR1=32GB from the broken state. They MUST start from the broken state — running them from a healthy cold-plug state would produce false-positives (the cluster is already fine).

## What the broken state looks like

```
BAR1:                    256M  (target: 32G)
Bridge 0000:03:00.0:     288M prefetchable window  (target: ≥32G)
PCI nvidia present:      yes
Driver loaded:           yes
/dev/nvidia*:            present
TB authorized:           1
```

This is the state that 2026-05-25 E7 (cable replug NUC-side, drain-first) produced. It's also the state that hot-power-cycle of the chassis produces (per 2026-05-25 morning).

## Recipe to deliberately enter the broken state

```bash
# 1. Confirm starting cluster is healthy + BAR1=32GB
sudo /root/k8s-vllm/tools/get-pci-stats.sh --baseline pre-broken
grep 'size=32G' /var/log/mission-1-archaeology/pre-broken.baseline.txt && echo "OK 32GB"

# 2. Drain vLLM (critical — prevents Xid 154 cascade per H7)
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s

# 3. Verify GPU idle (no compute apps, low power)
nvidia-smi --query-compute-apps=pid,name --format=csv,noheader
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader
# Expected: empty + 0% + 0 MiB

# 4. Physical cable cycle (you do this):
#    a. Unplug the TB cable at the NUC side (NOT chassis side)
#    b. Wait 5 seconds
#    c. Plug back in
#
# OR (no physical action needed; programmatic path):
#    boltctl deauthorize <uuid> && sleep 5 && boltctl authorize <uuid>
#    (May produce same end state; not verified equivalent to cable cycle)

# 5. Wait for boltd to complete (auto-authorize) OR manually authorize:
boltctl authorize c4148780-00a9-7ce8-ffff-ffffffffffff
sleep 5

# 6. Verify broken state achieved
sudo /root/k8s-vllm/tools/get-pci-stats.sh --snapshot pre-broken
sudo /root/k8s-vllm/tools/get-pci-stats.sh --diff pre-broken
# Expected: BAR1 transitions 32G → 256M; bridge 33089M → 288M
```

## Recovery from the broken state (if the experiment also fails)

```bash
# 1. Reboot with cable in place
sudo systemctl reboot

# 2. After reboot, verify BAR1=32G via cold-plug-at-boot path
sudo /root/k8s-vllm/tools/get-pci-stats.sh --baseline post-reboot
grep 'size=32G' /var/log/mission-1-archaeology/post-reboot.baseline.txt

# 3. Scale vLLM back up
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Notes

- The broken state is **inherent to MISSION-1's gap** — entering it deliberately is fine because we've validated reboot-recovery is the documented escape.
- Section 1 + 2 experiments may compound state (e.g., E02 then E10 then E12 in sequence) — each experiment's `Actual result` section should note whether it ran from "fresh broken state" or "after E0X compound".
- Section 3 + 4 experiments don't use this recipe — they involve reboots or kernel builds as part of the method.

## Cross-references

- E7 result: `archive/cable-replug-test-E7-20260525T084717Z/post-test-finding.txt`
- 2026-05-25 morning hot-power-cycle: `archive/power-on-test-20260525T005756Z/`
- H1 falsification: `docs/mission-egpu-hot-plug-hot-power.md` H1 entry
