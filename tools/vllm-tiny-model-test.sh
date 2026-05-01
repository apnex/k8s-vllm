#!/usr/bin/env bash
# Phase 2/3 (constrained retry): pull vLLM image, start it with conservative
# flags, run one inference. This version is the post-2026-05-01-freeze
# rewrite with:
#   - NO --rm: container logs survive a crash for forensics
#   - NO --ipc=host: avoid IPC namespace conflict with host persistenced
#   - --enforce-eager: disable CUDA graphs (suspected freeze trigger)
#   - lower --gpu-memory-utilization (0.2 instead of 0.5)
#   - lower --max-model-len (1024 instead of 2048)
#   - real-time log tailer that fsyncs each line so we have data even if
#     the kernel freezes
#
# Defaults:
#   IMAGE       vllm/vllm-openai:v0.20.0
#   MODEL       HuggingFaceTB/SmolLM2-135M-Instruct
#   PORT        8000 (bound to 127.0.0.1)
#   HF_CACHE    /root/.cache/huggingface
#   OUT         /root/aorus-vllm-tiny-test (overwritten each run)
#   GPU_MEM     0.2
#   MAX_LEN     1024
#   STARTUP_TIMEOUT_SEC  600

set -eo pipefail

IMAGE="${IMAGE:-vllm/vllm-openai:v0.20.0}"
MODEL="${MODEL:-HuggingFaceTB/SmolLM2-135M-Instruct}"
PORT="${PORT:-8000}"
HF_CACHE="${HF_CACHE:-/root/.cache/huggingface}"
OUT="${OUT:-/root/aorus-vllm-tiny-test}"
GPU_MEM="${GPU_MEM:-0.2}"
MAX_LEN="${MAX_LEN:-1024}"
STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_SEC:-600}"
CONTAINER_NAME="${CONTAINER_NAME:-aorus-vllm-test}"

if [[ "$EUID" -ne 0 ]]; then
    echo "vllm-tiny-model-test.sh must be run as root" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$OUT" "$HF_CACHE"
rm -f "$OUT"/*

mark() {
    printf '%s %s\n' "$(date '+%F %T %Z')" "$*" >> "$OUT/progress.txt"
    sync -f "$OUT/progress.txt" 2>/dev/null || sync
}

set_status() {
    printf '%s\n' "$@" > "$OUT/status.txt"
    sync -f "$OUT/status.txt" 2>/dev/null || sync
}

cleanup_container() {
    # Capture final logs (if any new since last fsync), then stop+remove.
    if docker ps -aq --filter "name=^${CONTAINER_NAME}\$" | grep -q .; then
        docker logs "$CONTAINER_NAME" > "$OUT/container-logs-final.txt" 2>&1 || true
        sync -f "$OUT/container-logs-final.txt" 2>/dev/null || sync
        if docker ps -q --filter "name=^${CONTAINER_NAME}\$" | grep -q .; then
            yellow "  stopping $CONTAINER_NAME"
            docker stop --time 30 "$CONTAINER_NAME" >/dev/null 2>&1 || true
        fi
        # Remove the container only on script exit; we deliberately did NOT
        # use --rm so logs survive crashes during the run.
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n "${log_tailer_pid:-}" ]] && kill -0 "$log_tailer_pid" 2>/dev/null; then
        kill "$log_tailer_pid" 2>/dev/null || true
    fi
}
trap cleanup_container EXIT

set_status 'vllm-tiny-model-test started' 'stage=preflight'
mark 'started'

# ------------------------------------------------------ preconditions --
step "preconditions"
if ! grep -q '^nvidia ' /proc/modules; then
    red "nvidia kernel module not loaded"
    set_status 'aborted' 'reason=nvidia_not_loaded'
    exit 2
fi
if ! grep -q '^nvidia_uvm ' /proc/modules; then
    red "nvidia_uvm not loaded"
    set_status 'aborted' 'reason=nvidia_uvm_not_loaded'
    exit 3
fi
if ! systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    red "nvidia-persistenced.service not active"
    set_status 'aborted' 'reason=persistenced_not_active'
    exit 4
fi
if ! docker info 2>&1 | grep -q 'Runtimes:.*nvidia'; then
    red "docker does not have the nvidia runtime configured"
    set_status 'aborted' 'reason=docker_nvidia_runtime_missing'
    exit 5
fi
green "  ok"
mark 'preconditions ok'

if ss -tlnp 2>/dev/null | grep -qE ":${PORT}\b"; then
    red "port $PORT is already in use"
    set_status 'aborted' "reason=port_${PORT}_in_use"
    exit 6
fi

# ------------------------------------------------------ pre-state capture --
step "capture pre-state"
/usr/local/sbin/aorus-5090-status > "$OUT/pre-status.txt" 2>&1
sync -f "$OUT/pre-status.txt" 2>/dev/null || sync
nvidia-smi --query-gpu=memory.used,temperature.gpu,fan.speed,power.draw,pstate \
    --format=csv,noheader > "$OUT/pre-nvidia-smi.txt" 2>&1
sync -f "$OUT/pre-nvidia-smi.txt" 2>/dev/null || sync
mark 'pre-state captured'

# ------------------------------------------------------ image pull --
step "pull $IMAGE (cached if present)"
docker pull "$IMAGE" 2>&1 | tail -3 > "$OUT/docker-pull.txt"
sync -f "$OUT/docker-pull.txt" 2>/dev/null || sync
mark 'image pulled'

# ------------------------------------------------------ start container --
step "start vLLM container ($CONTAINER_NAME) with model $MODEL (constrained)"

# Remove any stale container of the same name from a previous failed run
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# IMPORTANT FLAGS RELATIVE TO PREVIOUS ATTEMPT:
#   - no --rm         (logs survive a crash; cleanup_container removes after)
#   - no --ipc=host   (each container gets its own IPC namespace)
#   - --enforce-eager (vLLM-side: disable CUDA graphs)
#   - GPU_MEM=0.2     (use only ~6 GB of GDDR for KV cache)
#   - MAX_LEN=1024    (smaller context window = less memory)
docker run -d \
    --gpus all \
    -p "127.0.0.1:$PORT:8000" \
    -v "$HF_CACHE:/root/.cache/huggingface" \
    --shm-size=2g \
    --name "$CONTAINER_NAME" \
    "$IMAGE" \
    --model "$MODEL" \
    --gpu-memory-utilization "$GPU_MEM" \
    --max-model-len "$MAX_LEN" \
    --enforce-eager \
    --port 8000 \
    --host 0.0.0.0 \
    > "$OUT/container-id.txt"
sync -f "$OUT/container-id.txt" 2>/dev/null || sync

container_id=$(< "$OUT/container-id.txt")
echo "  container: $container_id"
mark "container started: $container_id"

# ------------------------------------------------------ start log tailer --
# Stream container logs to a fsync'd file. If the kernel freezes during
# vLLM init, the last few lines are what tells us the trigger.
(
    docker logs -f "$CONTAINER_NAME" 2>&1 \
        | while IFS= read -r line; do
            printf '%s %s\n' "$(date '+%T')" "$line" >> "$OUT/container-logs.txt"
            sync -f "$OUT/container-logs.txt" 2>/dev/null || sync
        done
) &
log_tailer_pid=$!
mark "log tailer started: pid=$log_tailer_pid"

# ------------------------------------------------------ wait for /health --
step "wait for vLLM /health (timeout ${STARTUP_TIMEOUT_SEC}s)"

deadline=$(( $(date +%s) + STARTUP_TIMEOUT_SEC ))
healthy=0
last_status=""
while [[ $(date +%s) -lt $deadline ]]; do
    if ! docker ps -q --filter "name=^${CONTAINER_NAME}\$" | grep -q .; then
        red "  container exited unexpectedly"
        mark 'container exited unexpectedly during /health wait'
        set_status 'failed' 'reason=container_exited_during_startup'
        exit 7
    fi

    status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        healthy=1
        mark "/health returned 200"
        break
    fi
    if [[ "$status" != "$last_status" ]]; then
        echo "  /health -> $status (still waiting)"
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

# ------------------------------------------------------ inference test --
step "run a single inference"

prompt="The capital of France is"
echo "  prompt: '$prompt'"
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
    green "  PASS: model output contains 'Paris'"
    set_status 'PASSED' 'paris=yes'
    mark 'PASSED'
    exit 0
else
    yellow "  WARN: output did not mention 'Paris', but inference completed"
    set_status 'PASSED' 'paris=no_but_inferred'
    mark 'PASSED (no paris)'
    exit 0
fi
