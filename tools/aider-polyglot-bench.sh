#!/usr/bin/env bash
# aider-polyglot-bench.sh
#
# Run the Aider Polyglot code-edit benchmark against our local vLLM
# endpoint, on a configurable subset of problems.
#
# This is the QUALITY GATE for every hypothesis in
# docs/perf-hypothesis-ledger.md that touches model selection,
# quantization, KV-cache dtype, or context limits.
#
# Usage:
#   ./tools/aider-polyglot-bench.sh [N_PROBLEMS] [LANGUAGE_FILTER]
# Examples:
#   ./tools/aider-polyglot-bench.sh                 # default: 30 problems, all langs
#   ./tools/aider-polyglot-bench.sh 60              # 60 problems, all langs
#   ./tools/aider-polyglot-bench.sh 10 python       # 10 python problems
#
# Requires:
#   - vLLM container running (docker compose up -d) and reporting healthy
#   - Internet (one-time clone of polyglot-benchmark repo + aider install)
#   - A scratch dir at /root/aider-polyglot-work/ (created if missing)
#
# Outputs:
#   /root/vllm/archive/aider-polyglot-<UTC-timestamp>-<model>/
#     ├── run.log                   # full aider stdout
#     ├── summary.json              # pass/fail per problem + aggregate
#     ├── env.txt                   # frozen config snapshot
#     └── compose-config.yml        # exact compose state at run-time
#
# This script never modifies the running vLLM container. It only
# measures. Restart vLLM with the new config BEFORE running this.

set -euo pipefail

N_PROBLEMS="${1:-30}"
LANG_FILTER="${2:-all}"

VLLM_ENDPOINT="${VLLM_ENDPOINT:-http://127.0.0.1:8000/v1}"
VLLM_API_KEY="${VLLM_API_KEY:-vllm-no-auth}"
WORK_DIR="${WORK_DIR:-/root/aider-polyglot-work}"
REPO_DIR="$WORK_DIR/polyglot-benchmark"
VENV_DIR="$WORK_DIR/aider-venv"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

# ============================================================================
# 1. Pre-flight — vLLM running + model identifier
# ============================================================================
step "pre-flight"

if ! curl -fsS "$VLLM_ENDPOINT/models" >/dev/null; then
    red "vLLM endpoint $VLLM_ENDPOINT not reachable. Start it with:"
    red "    cd /root/vllm && docker compose up -d"
    exit 1
fi

MODEL_ID=$(curl -fsS "$VLLM_ENDPOINT/models" | jq -r '.data[0].id')
green "  vLLM endpoint: $VLLM_ENDPOINT"
green "  served model:  $MODEL_ID"

# ============================================================================
# 2. Set up aider venv + polyglot benchmark repo (one-time)
# ============================================================================
step "set up aider + polyglot-benchmark"

mkdir -p "$WORK_DIR"

if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    # Aider with benchmark extras
    "$VENV_DIR/bin/pip" install --quiet 'aider-chat[benchmark]'
    green "  aider venv installed at $VENV_DIR"
else
    yellow "  aider venv exists at $VENV_DIR (skipping install)"
fi

if [[ ! -d "$REPO_DIR" ]]; then
    git clone --depth 1 https://github.com/Aider-AI/polyglot-benchmark.git "$REPO_DIR"
    green "  polyglot-benchmark cloned"
else
    yellow "  polyglot-benchmark exists (skipping clone). To refresh: rm -rf $REPO_DIR"
fi

# ============================================================================
# 3. Snapshot the run config — frozen archive
# ============================================================================
step "snapshot config"

ts=$(date -u +%Y%m%dT%H%M%SZ)
model_safe=$(echo "$MODEL_ID" | tr '/:' '__')
archive_dir="/root/vllm/archive/aider-polyglot-${ts}-${model_safe}"
mkdir -p "$archive_dir"

{
    echo "timestamp_utc: $ts"
    echo "model_id: $MODEL_ID"
    echo "endpoint: $VLLM_ENDPOINT"
    echo "n_problems: $N_PROBLEMS"
    echo "lang_filter: $LANG_FILTER"
    echo "host_kernel: $(uname -r)"
    echo "host_nvidia_version: $(cat /sys/module/nvidia/version 2>/dev/null || echo unknown)"
    echo "container:"
    docker ps --filter name=aorus-vllm --format '  {{.Image}} {{.Status}}' || echo "  not found"
} > "$archive_dir/env.txt"

(cd /root/vllm && docker compose config) > "$archive_dir/compose-config.yml" 2>&1 || true

# ============================================================================
# 4. Run the benchmark
# ============================================================================
step "run aider benchmark — $N_PROBLEMS problems, lang=$LANG_FILTER"

# Aider talks to OpenAI-compatible endpoints via these env vars
export OPENAI_API_BASE="$VLLM_ENDPOINT"
export OPENAI_API_KEY="$VLLM_API_KEY"

# Aider uses LiteLLM under the hood; openai/<model> tells it to use
# the OpenAI-compatible adapter against $OPENAI_API_BASE.
AIDER_MODEL="openai/$MODEL_ID"

run_log="$archive_dir/run.log"

# Build aider benchmark args
benchmark_args=(
    --model "$AIDER_MODEL"
    --edit-format "diff"
    --num-tests "$N_PROBLEMS"
    --threads 1
    --new
    --keywords "$LANG_FILTER"
)
# When LANG_FILTER is "all", drop --keywords (aider treats absence as no filter)
if [[ "$LANG_FILTER" == "all" ]]; then
    unset 'benchmark_args[-1]'
    unset 'benchmark_args[-1]'
fi

green "  aider benchmark $(printf ' %s' "${benchmark_args[@]}") → $run_log"
green "  this typically takes 30-90 min depending on N and model speed"

(
    cd "$REPO_DIR"
    "$VENV_DIR/bin/python" -m aider.benchmark.benchmark \
        "${benchmark_args[@]}" 2>&1
) | tee "$run_log"

# ============================================================================
# 5. Aggregate summary
# ============================================================================
step "extract summary"

# Aider writes a results file per run; find the latest under .benchmarks/
results_json=$(find "$REPO_DIR/.benchmarks" -name 'results.json' -newer "$archive_dir/env.txt" 2>/dev/null \
                | head -1 || true)

if [[ -n "$results_json" && -f "$results_json" ]]; then
    cp "$results_json" "$archive_dir/summary.json"
    pass_rate=$(jq -r '.percent_cases_well_formed // .percent // "?"' "$results_json")
    green "  pass-rate: $pass_rate%"
    green "  full summary: $archive_dir/summary.json"
else
    yellow "  could not auto-locate results.json — check $run_log manually"
fi

green ""
green "DONE. Archive: $archive_dir"
green "Update docs/perf-hypothesis-ledger.md with the result."
