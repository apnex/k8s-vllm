#!/usr/bin/env bash
# perf-watch.sh — live TUI for vLLM throughput.
#
# Polls /metrics every 2s, computes deltas, prints a clean refreshing
# table. Useful while running OpenCode tasks to spot stalls and watch
# decode rate in real time.
#
# Usage:
#   ./tools/perf-watch.sh                    # default 2s refresh
#   POLL_S=1 ./tools/perf-watch.sh           # 1s refresh
#   ./tools/perf-watch.sh --endpoint http://other:8000
#
# Exit: Ctrl+C

set -u

VLLM_ENDPOINT="${VLLM_ENDPOINT:-http://127.0.0.1:8000}"
POLL_S="${POLL_S:-2}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --endpoint) VLLM_ENDPOINT="$2"; shift 2 ;;
        --poll-s)   POLL_S="$2"; shift 2 ;;
        -h|--help)  sed -n '/^# perf-watch/,/^set -u/p' "$0" | sed 's/^# \?//' | head -n -1; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

# Pre-flight
if ! curl -fs "$VLLM_ENDPOINT/health" >/dev/null 2>&1; then
    echo "vLLM /health unreachable at $VLLM_ENDPOINT" >&2
    exit 1
fi

# Get model name once
MODEL=$(curl -fsS "$VLLM_ENDPOINT/v1/models" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null \
    || echo "unknown")

# Trap Ctrl+C — restore cursor + exit cleanly
cleanup() { tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; exit 0; }
trap cleanup INT TERM

# Use alternate screen so we don't pollute the user's scrollback
tput smcup 2>/dev/null
tput civis 2>/dev/null   # hide cursor

# Rolling history for tok/s smoothing — last 15 samples (30s at 2s poll)
HIST_GEN=()
HIST_PROMPT=()
HIST_PFX_Q=()
HIST_PFX_H=()
HIST_T=()

# Single Python helper does the metric extraction in one pass — cheaper
# than ten greps.
PARSE_METRICS='
import sys, re
keys = {
    "prompt_tokens_total":          None,
    "generation_tokens_total":      None,
    "prefix_cache_queries_total":   None,
    "prefix_cache_hits_total":      None,
    "num_requests_running":         None,
    "num_requests_waiting":         None,
    "gpu_cache_usage_perc":         None,
    "kv_cache_usage_perc":          None,
    "time_to_first_token_seconds_count": None,
    "e2e_request_latency_seconds_count": None,
}
for line in sys.stdin:
    if line.startswith("#") or "vllm:" not in line: continue
    m = re.match(r"vllm:(\S+?)(\{[^}]*\})?\s+([0-9eE.+-]+)", line)
    if not m: continue
    name, val = m.group(1), m.group(3)
    if name in keys and keys[name] is None:
        try: keys[name] = float(val)
        except: pass
print(" ".join(str(keys[k] if keys[k] is not None else "") for k in keys))
'

read_metrics() {
    curl -fsS "$VLLM_ENDPOINT/metrics" 2>/dev/null | python3 -c "$PARSE_METRICS"
}

read_gpu() {
    nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null
}

# First sample — establish baseline
prev=( $(read_metrics) )
prev_t=$(date +%s.%N)
sleep "$POLL_S"

while true; do
    cur=( $(read_metrics) )
    cur_t=$(date +%s.%N)
    dt=$(python3 -c "print(f'{$cur_t - $prev_t:.3f}')")

    # Indices into the metrics array (matches PARSE_METRICS keys order)
    PROMPT_TOKENS=${cur[0]:-0}
    GEN_TOKENS=${cur[1]:-0}
    PFX_Q=${cur[2]:-0}
    PFX_H=${cur[3]:-0}
    REQ_RUNNING=${cur[4]:-0}
    REQ_WAITING=${cur[5]:-0}
    GPU_CACHE=${cur[6]:-0}
    KV_CACHE=${cur[7]:-0}
    TTFT_COUNT=${cur[8]:-0}
    E2E_COUNT=${cur[9]:-0}

    PROMPT_PREV=${prev[0]:-0}
    GEN_PREV=${prev[1]:-0}
    PFX_Q_PREV=${prev[2]:-0}
    PFX_H_PREV=${prev[3]:-0}

    # Per-poll deltas
    d_prompt=$(python3 -c "print(int(${PROMPT_TOKENS} - ${PROMPT_PREV}))")
    d_gen=$(python3 -c "print(int(${GEN_TOKENS} - ${GEN_PREV}))")
    d_pfx_q=$(python3 -c "print(int(${PFX_Q} - ${PFX_Q_PREV}))")
    d_pfx_h=$(python3 -c "print(int(${PFX_H} - ${PFX_H_PREV}))")

    # Update history (cap at 15 samples)
    HIST_GEN+=("$d_gen")
    HIST_PROMPT+=("$d_prompt")
    HIST_PFX_Q+=("$d_pfx_q")
    HIST_PFX_H+=("$d_pfx_h")
    HIST_T+=("$dt")
    if [[ ${#HIST_GEN[@]} -gt 15 ]]; then
        HIST_GEN=("${HIST_GEN[@]:1}")
        HIST_PROMPT=("${HIST_PROMPT[@]:1}")
        HIST_PFX_Q=("${HIST_PFX_Q[@]:1}")
        HIST_PFX_H=("${HIST_PFX_H[@]:1}")
        HIST_T=("${HIST_T[@]:1}")
    fi

    # Comma-join arrays for python list literals
    join_csv() { local IFS=','; echo "$*"; }
    HIST_GEN_CSV="$(join_csv "${HIST_GEN[@]}")"
    HIST_PROMPT_CSV="$(join_csv "${HIST_PROMPT[@]}")"
    HIST_PFX_Q_CSV="$(join_csv "${HIST_PFX_Q[@]}")"
    HIST_PFX_H_CSV="$(join_csv "${HIST_PFX_H[@]}")"
    HIST_T_CSV="$(join_csv "${HIST_T[@]}")"

    # Rolling decode tok/s + prefix-cache hit rate over the window
    rolling=$(python3 <<EOF
gen = [${HIST_GEN_CSV:-0}]
prompt = [${HIST_PROMPT_CSV:-0}]
pfx_q = [${HIST_PFX_Q_CSV:-0}]
pfx_h = [${HIST_PFX_H_CSV:-0}]
times = [${HIST_T_CSV:-1}]
total_t = sum(times) or 1
gen_tps = sum(gen) / total_t
prompt_tps = sum(prompt) / total_t
hit_rate = (sum(pfx_h) / sum(pfx_q) * 100) if sum(pfx_q) > 0 else 0.0
print(f"{gen_tps:.1f} {prompt_tps:.1f} {hit_rate:.1f} {total_t:.1f}")
EOF
)
    read -r ROLLING_GEN_TPS ROLLING_PROMPT_TPS ROLLING_HIT_RATE WINDOW_S <<<"$rolling"

    # GPU
    gpu_csv=$(read_gpu)
    GPU_UTIL=$(echo "$gpu_csv" | awk -F',' '{print $1+0}')
    GPU_MEM_USED=$(echo "$gpu_csv" | awk -F',' '{print $2+0}')
    GPU_MEM_TOTAL=$(echo "$gpu_csv" | awk -F',' '{print $3+0}')
    GPU_TEMP=$(echo "$gpu_csv" | awk -F',' '{print $4+0}')

    # Render
    tput cup 0 0
    printf '\033[2K=== vLLM perf-watch — \033[36m%-50s\033[0m  %s\n' "$MODEL" "$(date +%T)"
    printf '\033[2K   endpoint: %s   poll: %ss\n' "$VLLM_ENDPOINT" "$POLL_S"
    printf '\033[2K\n'

    printf '\033[2K\033[1mrequests:\033[0m   running %d   waiting %d\n' \
        "$(printf '%.0f' "${REQ_RUNNING}")" "$(printf '%.0f' "${REQ_WAITING}")"
    printf '\033[2K\n'

    printf '\033[2K\033[1mthroughput\033[0m  (rolling %s s window)\n' "$WINDOW_S"
    printf '\033[2K   decode tok/s     \033[32m%6.1f\033[0m  (last 2s: %d)\n' \
        "$ROLLING_GEN_TPS" "$d_gen"
    printf '\033[2K   prompt tok/s     %6.1f  (last 2s: %d)\n' \
        "$ROLLING_PROMPT_TPS" "$d_prompt"
    printf '\033[2K\n'

    printf '\033[2K\033[1mprefix cache\033[0m\n'
    printf '\033[2K   hit rate         \033[32m%6.1f%%\033[0m  (rolling, %d hits / %d queries)\n' \
        "$ROLLING_HIT_RATE" \
        "$(awk 'BEGIN{s=0; for(i=1;i<=NF;i++)s+=$i; print s}' <<<"${HIST_PFX_H[*]:-0}")" \
        "$(awk 'BEGIN{s=0; for(i=1;i<=NF;i++)s+=$i; print s}' <<<"${HIST_PFX_Q[*]:-0}")"
    printf '\033[2K   total queries    %d\n' "$(printf '%.0f' "${PFX_Q}")"
    printf '\033[2K\n'

    # vLLM exposes kv_cache_usage_perc / gpu_cache_usage_perc already in %
    # (range 0-100), not as a fraction. Don't double-multiply.
    printf '\033[2K\033[1mKV cache util:\033[0m   %.1f%%\n' "${KV_CACHE:-${GPU_CACHE:-0}}"
    printf '\033[2K\n'

    printf '\033[2K\033[1mGPU:\033[0m  util %3d%%   mem %s / %s MB (%.0f%%)   temp %d°C\n' \
        "$GPU_UTIL" "$GPU_MEM_USED" "$GPU_MEM_TOTAL" \
        "$(python3 -c "print(${GPU_MEM_USED}/${GPU_MEM_TOTAL}*100)" 2>/dev/null || echo 0)" \
        "$GPU_TEMP"
    printf '\033[2K\n'

    printf '\033[2K\033[1mcumulative:\033[0m\n'
    printf '\033[2K   prompt_tokens    %d\n' "$(printf '%.0f' "${PROMPT_TOKENS}")"
    printf '\033[2K   generation_tokens%d\n' "$(printf '%.0f' "${GEN_TOKENS}")"
    printf '\033[2K   ttft samples     %d\n' "$(printf '%.0f' "${TTFT_COUNT}")"
    printf '\033[2K   e2e samples      %d\n' "$(printf '%.0f' "${E2E_COUNT}")"
    printf '\033[2K\n'

    printf '\033[2K\033[2m[ Ctrl+C to exit ]\033[0m\n'

    prev=("${cur[@]}")
    prev_t=$cur_t
    sleep "$POLL_S"
done
