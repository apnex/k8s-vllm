#!/usr/bin/env bash
# Phase 2/3: pull vLLM image, start it with a tiny model, run one inference.
#
# Defaults:
#   IMAGE       vllm/vllm-openai:v0.20.0
#   MODEL       HuggingFaceTB/SmolLM2-135M-Instruct
#   PORT        8000 (bound to 127.0.0.1)
#   HF_CACHE    /root/.cache/huggingface (mounted into container)
#   OUT         /root/aorus-vllm-tiny-test (overwritten each run)
#   GPU_MEM     0.5 (gpu-memory-utilization)
#   MAX_LEN     2048 (max model context)
#   STARTUP_TIMEOUT_SEC  600 (max time to wait for /health)
#
# This script is freeze-risk-managed by:
#   - precondition checks for nvidia / nvidia_uvm / persistenced before doing
#     anything that touches the GPU
#   - docker container isolation: a vLLM crash exits the container; the host
#     shell stays available
#   - docker stop on script exit so a left-running container does not hold the
#     GPU after we are done

set -eo pipefail

IMAGE="${IMAGE:-vllm/vllm-openai:v0.20.0}"
MODEL="${MODEL:-HuggingFaceTB/SmolLM2-135M-Instruct}"
PORT="${PORT:-8000}"
HF_CACHE="${HF_CACHE:-/root/.cache/huggingface}"
OUT="${OUT:-/root/aorus-vllm-tiny-test}"
GPU_MEM="${GPU_MEM:-0.5}"
MAX_LEN="${MAX_LEN:-2048}"
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

cleanup_container() {
    if docker ps -q --filter "name=^${CONTAINER_NAME}\$" | grep -q .; then
        yellow "  stopping $CONTAINER_NAME"
        docker stop --time 30 "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup_container EXIT

# ------------------------------------------------------ preconditions --
step "preconditions"

if ! grep -q '^nvidia ' /proc/modules; then
    red "nvidia kernel module not loaded"
    exit 2
fi
if ! grep -q '^nvidia_uvm ' /proc/modules; then
    red "nvidia_uvm not loaded - run aorus-5090-compute-load-nvidia.service first"
    exit 3
fi
if ! systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    red "nvidia-persistenced.service not active"
    exit 4
fi
if ! docker info 2>&1 | grep -q 'Runtimes:.*nvidia'; then
    red "docker does not have the nvidia runtime configured - run setup.sh"
    exit 5
fi
green "  ok"

# ------------------------------------------------------ port not in use --
if ss -tlnp 2>/dev/null | grep -qE ":${PORT}\b"; then
    red "port $PORT is already in use; set PORT=<other> or stop whatever is listening"
    exit 6
fi

# ------------------------------------------------------ image pull --
step "pull $IMAGE"
docker pull "$IMAGE"

# ------------------------------------------------------ start container --
step "start vLLM container ($CONTAINER_NAME) with model $MODEL"

# Remove any stale container of the same name
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d --rm --gpus all \
    -p "127.0.0.1:$PORT:8000" \
    -v "$HF_CACHE:/root/.cache/huggingface" \
    --shm-size=4g \
    --name "$CONTAINER_NAME" \
    --ipc=host \
    "$IMAGE" \
    --model "$MODEL" \
    --gpu-memory-utilization "$GPU_MEM" \
    --max-model-len "$MAX_LEN" \
    --port 8000 \
    --host 0.0.0.0 \
    > "$OUT/container-id.txt"

container_id=$(< "$OUT/container-id.txt")
echo "  container: $container_id"

# ------------------------------------------------------ wait for /health --
step "wait for vLLM /health (timeout ${STARTUP_TIMEOUT_SEC}s)"

deadline=$(( $(date +%s) + STARTUP_TIMEOUT_SEC ))
healthy=0
last_status=""
while [[ $(date +%s) -lt $deadline ]]; do
    if ! docker ps -q --filter "name=^${CONTAINER_NAME}\$" | grep -q .; then
        red "  container exited unexpectedly"
        docker logs "$CONTAINER_NAME" > "$OUT/container-logs.txt" 2>&1 || true
        exit 7
    fi

    status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        healthy=1
        break
    fi
    if [[ "$status" != "$last_status" ]]; then
        echo "  /health -> $status (still waiting)"
        last_status="$status"
    fi
    sleep 5
done

if (( healthy != 1 )); then
    red "  /health did not return 200 within $STARTUP_TIMEOUT_SEC seconds"
    docker logs "$CONTAINER_NAME" > "$OUT/container-logs.txt" 2>&1 || true
    exit 8
fi
green "  /health: 200"

# ------------------------------------------------------ inference test --
step "run a single inference"

prompt="The capital of France is"
echo "  prompt: '$prompt'"
echo "  expecting model to mention Paris"

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

if [[ "$curl_rc" -ne 0 ]]; then
    red "  curl failed (rc=$curl_rc): $response"
    docker logs "$CONTAINER_NAME" > "$OUT/container-logs.txt" 2>&1
    exit 9
fi

# Extract the generated text
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

# ------------------------------------------------------ capture state --
step "capture state"
docker logs "$CONTAINER_NAME" > "$OUT/container-logs.txt" 2>&1
nvidia-smi --query-gpu=memory.used,temperature.gpu,fan.speed,power.draw,pstate \
    --format=csv,noheader > "$OUT/gpu-state-during.txt"
echo "  during run: $(< "$OUT/gpu-state-during.txt")"

# ------------------------------------------------------ verify --
step "verify"
if echo "$text" | grep -qi "paris"; then
    green "  PASS: model output contains 'Paris'"
    pass=1
else
    yellow "  WARN: model output did not mention 'Paris', but inference completed (model is small)"
    pass=0
fi

# Stop happens via EXIT trap. Log result for the archive.
{
    echo "model: $MODEL"
    echo "prompt: $prompt"
    echo "generated: $text"
    echo "pass_paris: $pass"
} > "$OUT/result.txt"

green "
vllm-tiny-model-test complete. Output captured to $OUT/.
The container will be stopped on exit."
