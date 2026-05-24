#!/usr/bin/env bash
# soak-pods.sh — daily snapshot of vllm namespace pod state.
#
# Captures restart count drift, current pod identity, and recent events.
# Triggered by a systemd timer once a day (see tools/systemd/vllm-soak-pods.timer).
#
# Reading the output:
#   ls -lt /var/log/vllm-soak/pods-*.txt | head -5
#   diff /var/log/vllm-soak/pods-{$YESTERDAY,$TODAY}.txt

set -euo pipefail

OUT_DIR="${OUT_DIR:-/var/log/vllm-soak}"
mkdir -p "$OUT_DIR"

date_tag=$(date -u +%Y%m%d)
out_file="$OUT_DIR/pods-${date_tag}.txt"

{
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo ""
    echo "--- pods (wide) ---"
    kubectl get pods -n vllm -o wide 2>&1
    echo ""
    echo "--- deployment rollout status ---"
    kubectl get deployment vllm -n vllm -o wide 2>&1
    echo ""
    echo "--- container restart counts ---"
    kubectl get pods -n vllm -o jsonpath='{range .items[*]}{.metadata.name}{"  restarts: "}{.status.containerStatuses[0].restartCount}{"  ready: "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>&1
    echo ""
    echo "--- recent events (last 50, sorted by time) ---"
    kubectl get events -n vllm --sort-by=.lastTimestamp 2>&1 | tail -50
    echo ""
    echo "--- /health probe ---"
    curl -fsS --max-time 5 -o /dev/null -w "http_code=%{http_code}  time_total=%{time_total}s\n" \
        http://192.168.1.251:8000/health 2>&1 || echo "(probe failed)"
    echo ""
    echo "--- /v1/models ---"
    curl -fsS --max-time 5 http://192.168.1.251:8000/v1/models 2>&1 | python3 -m json.tool 2>&1 | head -20 || echo "(probe failed)"
} > "$out_file"
