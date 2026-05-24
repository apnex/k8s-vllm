#!/usr/bin/env bash
# soak-metrics.sh — single-shot vLLM /metrics scrape.
#
# Pulls the key counters from vLLM's Prometheus endpoint and appends one CSV
# row to the soak log. Designed to be triggered by a systemd timer every 30s
# (see tools/systemd/vllm-soak-metrics.timer).
#
# Counters captured:
#   - generation_tokens_total      (monotonic; wedge detector: diff == 0 with traffic)
#   - prompt_tokens_total          (monotonic; cross-check on workload)
#   - num_requests_running         (in-flight; wedge gate: must be > 0 for a wedge)
#   - num_requests_waiting         (queue depth)
#   - prefix_cache_queries_total   (monotonic; for hit-rate computation)
#   - prefix_cache_hits_total      (monotonic; for hit-rate computation)
#
# The wedge signature (per audit #42897):
#   num_requests_running > 0  AND  generation_tokens_total flat for ≥3 rows (90s)
#
# Reading the output:
#   tail -f /var/log/vllm-soak/metrics.csv | column -t -s,

set -euo pipefail

VLLM_METRICS_URL="${VLLM_METRICS_URL:-http://192.168.1.251:8000/metrics}"
OUT_DIR="${OUT_DIR:-/var/log/vllm-soak}"
OUT_FILE="$OUT_DIR/metrics.csv"

mkdir -p "$OUT_DIR"

if [[ ! -s "$OUT_FILE" ]]; then
    echo "ts_iso,generation_tokens_total,prompt_tokens_total,num_requests_running,num_requests_waiting,prefix_cache_queries_total,prefix_cache_hits_total,scrape_ok" \
        > "$OUT_FILE"
fi

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Single curl; if it fails we still log a row so the gap is visible in the CSV.
metrics=$(curl -fsS --max-time 5 "$VLLM_METRICS_URL" 2>/dev/null || true)

if [[ -z "$metrics" ]]; then
    echo "${ts},,,,,,,0" >> "$OUT_FILE"
    exit 0
fi

extract() {
    local name="$1"
    echo "$metrics" \
        | grep -E "^${name}\{" \
        | awk '{print $NF}' \
        | head -1 \
        | awk '{printf "%.0f", $1}'
}

gen_tokens=$(extract 'vllm:generation_tokens_total')
prompt_tokens=$(extract 'vllm:prompt_tokens_total')
req_running=$(extract 'vllm:num_requests_running')
req_waiting=$(extract 'vllm:num_requests_waiting')
prefix_queries=$(extract 'vllm:prefix_cache_queries_total')
prefix_hits=$(extract 'vllm:prefix_cache_hits_total')

echo "${ts},${gen_tokens},${prompt_tokens},${req_running},${req_waiting},${prefix_queries},${prefix_hits},1" \
    >> "$OUT_FILE"
