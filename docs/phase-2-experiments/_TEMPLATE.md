# E?? — <short-title>

**Status:** PENDING
**Phase:** 2.?
**Risk:** LOW | MEDIUM | HIGH
**Cost:** ~N min
**Reversibility:** auto | manual | reboot required
**Last updated:** YYYY-MM-DD

## Hypothesis

<One paragraph. State the specific prediction this experiment tests. Reference H10 (or other applicable hypothesis from the mission doc) if extending an existing hypothesis. Be specific about which Linux kernel mechanism is being exercised and what behavior is predicted.>

## Falsification gates

**PASS:** <Specific state-change signature in `get-pci-stats.sh --diff` output that demonstrates H10 confirmed via this path. Usually: BAR1 size transitions from `256M` → `32G`, bridge `03:00.0` prefetchable window from `288M` → `≥32G`.>

**FAIL:** <Specific state-change signature indicating the experiment did NOT recover the bridge window. Usually: BAR1 stays at `256M`, bridge stays at `288M`, but the device DID re-enumerate (so the experiment ran, just didn't fix the problem).>

**INCONCLUSIVE:** <State-change signature that's ambiguous. Usually: enumeration didn't complete, AER cascade fired, or some new failure mode replaced the original one.>

## Prerequisites

- <Starting cluster state required (e.g., "broken-BAR1 state per `_STARTING-STATE-RECIPE.md`" or "post-cold-boot healthy state with BAR1=32GB")>
- <Other experiments that must precede or specific external triggers>
- <Tooling required beyond `get-pci-stats.sh`>

## Method

### Step 1 — Pre-experiment state capture

```bash
sudo /root/k8s-vllm/tools/get-pci-stats.sh --baseline E??
```

### Step 2 — Drain workload if not already drained

```bash
kubectl scale -n vllm deployment/vllm --replicas=0
kubectl wait -n vllm --for=delete pod -l app=vllm --timeout=120s
```

### Step 3 — Execute experiment

```bash
<EXACT commands here — no placeholders>
```

### Step 4 — Wait period

`sleep <N>` — <rationale for the wait time>

### Step 5 — Post-experiment state capture + diff

```bash
sudo /root/k8s-vllm/tools/get-pci-stats.sh --snapshot E??
sudo /root/k8s-vllm/tools/get-pci-stats.sh --diff E??
```

### Step 6 — Scale workload back up (only if PASS)

```bash
kubectl scale -n vllm deployment/vllm --replicas=1
kubectl rollout status -n vllm deployment/vllm --timeout=900s
```

## Predicted PASS signature

```
<example diff snippet showing the expected before/after state if H10 holds via this path>
```

## Predicted FAIL signature

```
<example diff snippet showing the expected before/after state if H10 doesn't hold>
```

## Known failure modes / recovery

| Failure | Symptom | Recovery |
|---|---|---|
| <specific failure mode> | <observable symptom> | <recovery command(s); or "reboot required"> |

## Actual result

**Status:** PENDING — fill in when run

**Date:** <YYYY-MM-DD HH:MM:SS UTC>

**Diff highlights:**

```
<key state changes from get-pci-stats.sh --diff output>
```

**Conclusion:**

<1-paragraph interpretation. State whether H10 was confirmed, falsified, or remains open via this path. Note any unexpected observations that inform other experiments.>

## Cross-references

- <Links to related experiments, matrix doc rows, or external sources>
