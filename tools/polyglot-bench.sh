#!/usr/bin/env bash
# polyglot-bench.sh — minimal custom runner for the Aider polyglot benchmark.
#
# Why custom (not aider's harness): aider-chat pins old numpy that won't
# build on Python 3.14 (current Fedora 43 default), and aider's official
# benchmark uses Docker-in-Docker for sandboxed test execution. We bypass
# both by talking to vLLM via curl directly and running the language-native
# test command in a sandboxed copy of the problem dir.
#
# Usage:
#   ./tools/polyglot-bench.sh [N_PROBLEMS] [LANGUAGE]
# Examples:
#   ./tools/polyglot-bench.sh 10 python    # 10 python problems
#   ./tools/polyglot-bench.sh 5  rust      # 5 rust problems
#
# Currently supports: python (more languages as we extend).
#
# Outputs:
#   /root/vllm/archive/polyglot-<UTC-ts>-<model>-<lang>/
#     ├── env.txt            # frozen config snapshot
#     ├── compose-config.yml # exact compose state
#     ├── results.jsonl      # one line per problem: {problem, pass, time_s, retries}
#     └── summary.json       # {total, pass, pass_rate, mean_time}
#
# Each H in docs/perf-hypothesis-ledger.md that touches the model uses
# this as the quality gate.

set -euo pipefail

N_PROBLEMS="${1:-5}"
LANG_NAME="${2:-python}"

VLLM_ENDPOINT="${VLLM_ENDPOINT:-http://127.0.0.1:8000/v1}"
VLLM_API_KEY="${VLLM_API_KEY:-vllm-no-auth}"
WORK_DIR="${WORK_DIR:-/root/aider-polyglot-work}"
REPO_DIR="$WORK_DIR/polyglot-benchmark"
SANDBOX_BASE="$WORK_DIR/sandboxes"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

# ============================================================================
# Pre-flight
# ============================================================================
step "pre-flight"

if ! curl -fsS "$VLLM_ENDPOINT/models" >/dev/null; then
    red "vLLM endpoint $VLLM_ENDPOINT not reachable"
    exit 1
fi
MODEL_ID=$(curl -fsS "$VLLM_ENDPOINT/models" | jq -r '.data[0].id')
green "  served model: $MODEL_ID"

if [[ ! -d "$REPO_DIR" ]]; then
    mkdir -p "$WORK_DIR"
    git clone --depth 1 https://github.com/Aider-AI/polyglot-benchmark.git "$REPO_DIR"
fi

case "$LANG_NAME" in
    python)
        problem_root="$REPO_DIR/python/exercises/practice"
        starter_glob='*.py'
        test_glob='*_test.py'
        instr_path='.docs/instructions.md'
        run_test() {
            local sandbox="$1"
            (cd "$sandbox" && python3 -m unittest discover -p '*_test.py' -v 2>&1)
        }
        ;;
    *)
        red "language '$LANG_NAME' not yet supported (only python)"
        exit 1
        ;;
esac

# ============================================================================
# Snapshot run config
# ============================================================================
ts=$(date -u +%Y%m%dT%H%M%SZ)
model_safe=$(echo "$MODEL_ID" | tr '/:' '__')
archive_dir="/root/vllm/archive/polyglot-${ts}-${model_safe}-${LANG_NAME}"
mkdir -p "$archive_dir"

{
    echo "timestamp_utc: $ts"
    echo "model_id: $MODEL_ID"
    echo "endpoint: $VLLM_ENDPOINT"
    echo "n_problems: $N_PROBLEMS"
    echo "language: $LANG_NAME"
    echo "host_kernel: $(uname -r)"
    echo "host_nvidia_version: $(cat /sys/module/nvidia/version 2>/dev/null || echo unknown)"
    echo "container:"
    docker ps --filter name=aorus-vllm --format '  {{.Image}} {{.Status}}' || echo "  not found"
} > "$archive_dir/env.txt"

(cd /root/vllm && docker compose config) > "$archive_dir/compose-config.yml" 2>&1 || true

results_jsonl="$archive_dir/results.jsonl"
: > "$results_jsonl"

# ============================================================================
# Per-problem loop
# ============================================================================
step "running $N_PROBLEMS $LANG_NAME problems"

problems=$(ls "$problem_root" | head -"$N_PROBLEMS")
n_done=0
n_pass=0

for problem in $problems; do
    n_done=$((n_done + 1))
    pdir="$problem_root/$problem"
    sandbox="$SANDBOX_BASE/${ts}/${problem}"
    rm -rf "$sandbox"; mkdir -p "$sandbox"
    cp -r "$pdir"/. "$sandbox/"

    instr=$(cat "$pdir/$instr_path" 2>/dev/null || echo "(no instructions.md)")
    starter_files=("$pdir"/$starter_glob)
    starter_file="${starter_files[0]}"
    [[ -f "$starter_file" ]] || { red "  [$n_done/$N_PROBLEMS] $problem: no starter — skipping"; continue; }

    # Find the test file (the *_test.py one)
    test_file=$(find "$pdir" -maxdepth 1 -name "$test_glob" | head -1)
    if [[ -z "$test_file" ]]; then
        red "  [$n_done/$N_PROBLEMS] $problem: no test file — skipping"
        continue
    fi

    starter_content=$(cat "$starter_file")
    test_content=$(cat "$test_file")
    starter_basename=$(basename "$starter_file")

    # Build prompt (single-shot — no chat back-and-forth, just edit-the-file)
    prompt=$(cat <<EOF
You are a software engineer. Implement the following exercise.

## Task
$instr

## Starter file: ${starter_basename}
\`\`\`python
$starter_content
\`\`\`

## Tests that must pass (do NOT modify these — they're the spec)
\`\`\`python
$test_content
\`\`\`

## Output requirements
Output ONLY the complete updated content of \`${starter_basename}\`,
inside a single python code block. No prose, no other text, no
explanation. Be concise — minimum lines of code that pass the tests.
EOF
)

    # Build JSON body. Notes on the params:
    # - max_tokens: env-controlled, default 30000. Bumped from 16384 on
    #   2026-05-11 because reasoning models (R1-Distill, QwQ, etc.) emit
    #   long <think> traces — H16 first run hit 16384 on 3/4 failures.
    #   30000 leaves room within a 32k max_model_len. For non-reasoning
    #   models this just raises the ceiling; they still hit EOS earlier.
    #   Override via POLYGLOT_MAX_TOKENS=N when needed.
    # - temperature=0.0 + seed=42: REQUIRED for reproducibility. vLLM's
    #   continuous batching has small numerical jitter at temp=0 without
    #   a fixed seed; greedy decoding is NOT byte-identical across runs
    #   otherwise (observed 2026-05-09: same temp=0 prompt produced
    #   different outputs on beer-song and dot-dsl, pass→fail flip).
    : "${POLYGLOT_MAX_TOKENS:=30000}"
    body=$(jq -nc \
        --arg model "$MODEL_ID" \
        --arg content "$prompt" \
        --argjson mt "$POLYGLOT_MAX_TOKENS" \
        '{model: $model, messages: [{role: "user", content: $content}], max_tokens: $mt, temperature: 0.0, seed: 42}')

    t0=$(date +%s.%N)
    resp=$(curl -fsS "$VLLM_ENDPOINT/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $VLLM_API_KEY" \
        -d "$body" 2>&1) || {
            red "  [$n_done/$N_PROBLEMS] $problem: curl failed"
            jq -nc --arg p "$problem" '{problem:$p, pass:false, error:"curl-failed"}' >> "$results_jsonl"
            continue
        }
    t1=$(date +%s.%N)
    dt=$(awk "BEGIN { printf \"%.2f\", $t1 - $t0 }")

    raw=$(echo "$resp" | jq -r '.choices[0].message.content // ""')
    completion_tokens=$(echo "$resp" | jq -r '.usage.completion_tokens // 0')

    # Extract code from ```python ... ``` block; fallback to full response
    code=$(echo "$raw" | awk '
        /^```python$/ { in_block=1; next }
        /^```$/ && in_block { in_block=0; exit }
        in_block { print }
    ')
    if [[ -z "$code" ]]; then
        # try generic ``` block
        code=$(echo "$raw" | awk '
            /^```/ { if (in_block) { in_block=0; exit } else { in_block=1; next } }
            in_block { print }
        ')
    fi
    if [[ -z "$code" ]]; then
        # fallback: assume full response is code
        code="$raw"
    fi

    # Write extracted code to sandbox
    echo "$code" > "$sandbox/$starter_basename"

    # Run tests
    test_out=$(run_test "$sandbox" || true)
    if echo "$test_out" | grep -qE '^OK( |$)'; then
        passed=true
        n_pass=$((n_pass + 1))
        green "  [$n_done/$N_PROBLEMS] $problem: PASS  (${dt}s, ${completion_tokens} tok)"
    else
        passed=false
        red "  [$n_done/$N_PROBLEMS] $problem: FAIL  (${dt}s, ${completion_tokens} tok)"
        # Capture failure detail to sandbox dir for review
        echo "$test_out" > "$sandbox/_test_output.log"
    fi

    jq -nc \
        --arg p "$problem" \
        --argjson pass "$passed" \
        --arg dt "$dt" \
        --argjson tokens "$completion_tokens" \
        '{problem:$p, pass:$pass, time_s:($dt|tonumber), completion_tokens:$tokens}' \
        >> "$results_jsonl"
done

# ============================================================================
# Summary
# ============================================================================
step "summary"

pass_rate=$(awk "BEGIN { printf \"%.1f\", ($n_pass / $n_done) * 100 }")
mean_time=$(jq -s 'map(.time_s) | add/length' "$results_jsonl" 2>/dev/null || echo "?")

jq -nc \
    --arg model "$MODEL_ID" \
    --arg lang "$LANG_NAME" \
    --argjson total "$n_done" \
    --argjson pass "$n_pass" \
    --argjson rate "$pass_rate" \
    --arg mean_time "$mean_time" \
    '{model: $model, language: $lang, total: $total, passed: $pass, pass_rate_pct: $rate, mean_time_s: ($mean_time|tonumber)}' \
    > "$archive_dir/summary.json"

green ""
green "RESULT  $MODEL_ID  ($LANG_NAME, n=$n_done)"
green "  passed: $n_pass / $n_done   ($pass_rate%)"
green "  mean time per problem: ${mean_time}s"
green "  archive: $archive_dir"
green ""
green "Update docs/perf-hypothesis-ledger.md with this result."
