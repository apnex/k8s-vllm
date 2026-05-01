#!/usr/bin/env bash
# Native (no Docker) vLLM smoke test from a multi-user.target context.
#
# Runs `vllm serve` from /root/vllm-venv directly against the host's CUDA
# stack - no container, no nvidia-container-toolkit, no CDI. Same constrained
# config as the docker test:
#   - tiny model (HuggingFaceTB/SmolLM2-135M-Instruct, pre-cached)
#   - --enforce-eager (no CUDA graphs)
#   - --gpu-memory-utilization 0.2
#   - --max-model-len 1024
#   - --disable-custom-all-reduce
#
# Run via the same launch pattern as the cuda/pytorch TTY tests:
#
#   nohup setsid /root/vllm/tools/tty-native-vllm-test.sh </dev/null >/dev/null 2>&1 &
#   disown
#   sleep 1
#   sudo systemctl isolate multi-user.target
#
# Output: /root/aorus-vllm-native-test/

set -eo pipefail

VENV_PATH="${VENV_PATH:-/root/vllm-venv}"
MODEL="${MODEL:-HuggingFaceTB/SmolLM2-135M-Instruct}"
PORT="${PORT:-8000}"
GPU_MEM="${GPU_MEM:-0.2}"
MAX_LEN="${MAX_LEN:-1024}"
STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_SEC:-600}"
OUT="${OUT:-/root/aorus-vllm-native-test}"

if [[ "$EUID" -ne 0 ]]; then
    echo "tty-native-vllm-test.sh must be run as root" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$OUT"
rm -f "$OUT"/*

mark() {
    printf '%s %s\n' "$(date '+%F %T %Z')" "$*" >> "$OUT/progress.txt"
    sync -f "$OUT/progress.txt" 2>/dev/null || sync
}

set_status() {
    printf '%s\n' "$@" > "$OUT/status.txt"
    sync -f "$OUT/status.txt" 2>/dev/null || sync
}

VLLM_PID=""
LOG_TAILER_PID=""

cleanup() {
    if [[ -n "${LOG_TAILER_PID:-}" ]] && kill -0 "$LOG_TAILER_PID" 2>/dev/null; then
        kill "$LOG_TAILER_PID" 2>/dev/null || true
    fi
    if [[ -n "${VLLM_PID:-}" ]] && kill -0 "$VLLM_PID" 2>/dev/null; then
        yellow "  stopping vllm pid=$VLLM_PID"
        kill -TERM "$VLLM_PID" 2>/dev/null || true
        # Give it 30s to exit cleanly, then SIGKILL
        for _ in $(seq 1 30); do
            kill -0 "$VLLM_PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$VLLM_PID" 2>/dev/null; then
            kill -KILL "$VLLM_PID" 2>/dev/null || true
        fi
    fi
    # Restore graphical.target if we were launched into multi-user
    if ! systemctl is-active graphical.target >/dev/null 2>&1; then
        mark 'EXIT: restoring graphical.target'
        systemctl isolate graphical.target >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

set_status 'tty-native-vllm-test started' 'stage=preflight'
mark 'started'

# ------------------------------------------------------ preconditions --
step "preconditions"
if ! grep -q '^nvidia ' /proc/modules; then
    red "nvidia not loaded"
    set_status 'aborted' 'reason=nvidia_not_loaded'
    exit 2
fi
if ! grep -q '^nvidia_uvm ' /proc/modules; then
    red "nvidia_uvm not loaded"
    set_status 'aborted' 'reason=nvidia_uvm_not_loaded'
    exit 3
fi
if ! systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    red "nvidia-persistenced not active"
    set_status 'aborted' 'reason=persistenced_not_active'
    exit 4
fi
if [[ ! -x "$VENV_PATH/bin/vllm" ]]; then
    red "vllm not found at $VENV_PATH/bin/vllm - run tools/setup-native-vllm-venv.sh first"
    set_status 'aborted' "reason=vllm_not_in_venv path=$VENV_PATH"
    exit 5
fi
if ss -tlnp 2>/dev/null | grep -qE ":${PORT}\b"; then
    red "port $PORT already in use"
    set_status 'aborted' "reason=port_${PORT}_in_use"
    exit 6
fi
green "  ok"
mark 'preconditions ok'

# ------------------------------------------------------ pre-state --
step "capture pre-state"
/usr/local/sbin/aorus-5090-status > "$OUT/pre-status.txt" 2>&1
sync -f "$OUT/pre-status.txt" 2>/dev/null || sync
nvidia-smi --query-gpu=memory.used,temperature.gpu,fan.speed,power.draw,pstate \
    --format=csv,noheader > "$OUT/pre-nvidia-smi.txt" 2>&1
sync -f "$OUT/pre-nvidia-smi.txt" 2>/dev/null || sync
mark 'pre-state captured'

# ------------------------------------------------------ wait for multi-user --
# Wrapper-less: this script is launched directly via the same nohup/setsid
# pattern. Give multi-user.target time to settle; wifi/DNS aren't needed
# (model is pre-cached via huggingface_hub) but the system still benefits
# from a moment of stability.
step "settle 5s after multi-user transition"
sleep 5
mark 'settled'

# ------------------------------------------------------ start vllm --
step "start vllm serve"
# All flags consistent with the docker constrained-retry. NCCL workarounds
# kept just in case (cheap; no harm if NCCL doesn't get there).
#
# HF_HUB_OFFLINE=1 + TRANSFORMERS_OFFLINE=1: model is pre-cached at
# ~/.cache/huggingface/. multi-user.target's DNS is not reliable in the
# first ~30 s after `systemctl isolate`, so any HuggingFace Hub query
# fails with name-resolution errors and vLLM exits before reaching GPU
# init. Force pure-local resolution.
NCCL_P2P_DISABLE=1 \
NCCL_SHM_DISABLE=1 \
NCCL_DEBUG=INFO \
HF_HUB_OFFLINE=1 \
TRANSFORMERS_OFFLINE=1 \
"$VENV_PATH/bin/vllm" serve "$MODEL" \
    --gpu-memory-utilization "$GPU_MEM" \
    --max-model-len "$MAX_LEN" \
    --enforce-eager \
    --disable-custom-all-reduce \
    --port "$PORT" \
    --host 0.0.0.0 \
    > "$OUT/vllm-stdout.txt" 2> "$OUT/vllm-stderr.txt" &
VLLM_PID=$!
echo "  vllm pid: $VLLM_PID"
mark "vllm started: pid=$VLLM_PID"

# Real-time fsync'd log tailer for both streams
(
    tail -F "$OUT/vllm-stdout.txt" "$OUT/vllm-stderr.txt" 2>/dev/null \
        | while IFS= read -r line; do
            printf '%s %s\n' "$(date '+%T')" "$line" >> "$OUT/vllm-combined.txt"
            sync -f "$OUT/vllm-combined.txt" 2>/dev/null || sync
        done
) &
LOG_TAILER_PID=$!
mark "log tailer started: pid=$LOG_TAILER_PID"

# ------------------------------------------------------ wait for /health --
step "wait for vLLM /health (timeout ${STARTUP_TIMEOUT_SEC}s)"

deadline=$(( $(date +%s) + STARTUP_TIMEOUT_SEC ))
healthy=0
last_status=""
while [[ $(date +%s) -lt $deadline ]]; do
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
        red "  vllm process died"
        mark 'vllm process exited unexpectedly'
        set_status 'failed' 'reason=vllm_process_exited'
        exit 7
    fi

    status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        healthy=1
        mark "/health -> 200"
        break
    fi
    if [[ "$status" != "$last_status" ]]; then
        echo "  /health -> $status"
        mark "/health -> $status"
        last_status="$status"
    fi
    sleep 5
done

if (( healthy != 1 )); then
    red "  /health did not return 200 within $STARTUP_TIMEOUT_SEC seconds"
    mark 'TIMEOUT waiting for /health'
    set_status 'failed' 'reason=health_timeout'
    exit 8
fi
green "  /health: 200"

# ------------------------------------------------------ inference --
step "single inference"
prompt="The capital of France is"
mark "before inference"
response=$(curl -sf -X POST "http://127.0.0.1:$PORT/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"$MODEL\",
        \"prompt\": \"$prompt\",
        \"max_tokens\": 20,
        \"temperature\": 0
    }" 2>&1)
curl_rc=$?
echo "$response" > "$OUT/inference-response.json"
sync -f "$OUT/inference-response.json" 2>/dev/null || sync
mark "after inference, curl_rc=$curl_rc"

if [[ "$curl_rc" -ne 0 ]]; then
    red "  curl failed (rc=$curl_rc)"
    set_status 'failed' "reason=inference_curl_rc=$curl_rc"
    exit 9
fi

text=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d["choices"][0]["text"], end="")
except Exception as e:
    print(f"PARSE_ERROR: {e}", end="")
' "$response")
echo "$text" > "$OUT/inference-text.txt"
echo "  generated: $text"
mark "generated: $text"

# ------------------------------------------------------ post-state --
step "capture post-state"
nvidia-smi --query-gpu=memory.used,temperature.gpu,fan.speed,power.draw,pstate \
    --format=csv,noheader > "$OUT/post-nvidia-smi.txt" 2>&1
sync -f "$OUT/post-nvidia-smi.txt" 2>/dev/null || sync
/usr/local/sbin/aorus-5090-status > "$OUT/post-status.txt" 2>&1
sync -f "$OUT/post-status.txt" 2>/dev/null || sync
mark 'post-state captured'

# ------------------------------------------------------ verify --
step "verify"
if echo "$text" | grep -qi "paris"; then
    green "  PASS: output contains 'Paris'"
    set_status 'PASSED' 'paris=yes'
    mark 'PASSED'
else
    yellow "  WARN: output did not mention 'Paris', but inference completed"
    set_status 'PASSED' 'paris=no_but_inferred'
    mark 'PASSED (no paris)'
fi

# Idle 30s for delayed-panic detection (consistency with previous TTY tests)
mark 'idle 30s for delayed-panic detection'
sleep 30
mark 'idle complete - EXIT trap will stop vllm and restore graphical.target'

exit 0
