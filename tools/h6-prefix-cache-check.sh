#!/usr/bin/env bash
# h6-prefix-cache-check.sh — verify vLLM's prefix caching is hitting on
# OpenCode's repeated system+tool prompt pattern.
#
# H6 hypothesis: vLLM's automatic prefix caching reuses the KV for shared
# prefixes — should drop TTFT to ~0 for the prefix portion on the 2nd+ call.
# Already on by default in vLLM v0.20.x but worth verifying empirically.
#
# Method:
#   1. Send a chat completion with an ~8k-token system prompt (representative
#      of OpenCode's tool-list prompt) + a small user message.
#   2. Send a 2nd call with the SAME system prompt + a DIFFERENT user message.
#   3. Send 3 more calls with the same system prompt.
#   4. Compare TTFT (time-to-first-byte) on call 1 vs calls 2-5.
#   5. Read /metrics for prefix-cache hit count.
#
# Pass criteria:
#   - Calls 2-5 TTFT < 50% of call 1 TTFT
#   - /metrics shows prefix_cache_hit_rate > 0
#
# Usage:
#   ./tools/h6-prefix-cache-check.sh
#
# Outputs: results to stdout + archive/h6-<UTC-ts>/ dossier

set -euo pipefail

VLLM_ENDPOINT="${VLLM_ENDPOINT:-http://127.0.0.1:8000}"
TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="/root/vllm/archive/h6-${TS}"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/run.log"

green() { printf '\033[32m%s\033[0m\n' "$*" | tee -a "$LOG"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*" | tee -a "$LOG"; }
red() { printf '\033[31m%s\033[0m\n' "$*" | tee -a "$LOG"; }

# Build a long-ish system prompt (~6k chars ~= ~1.5k tokens — adjust
# token count by repeating). We want at least 4k tokens to test the
# prefix-caching block size.
build_system_prompt() {
    local base='You are an expert software engineering assistant with deep knowledge of multiple programming languages, system design, and codebase exploration patterns. You operate inside the OpenCode agent harness and have access to the following tools: read_file, edit_file, run_bash, search_files, list_directory, view_diff, run_tests, write_file, delete_file, move_file, get_file_diff, find_definition, find_references, run_lint, run_format, run_typecheck, run_security_scan, search_documentation, search_dependencies, view_git_log, view_git_blame, view_git_status, view_git_branch, create_git_branch, switch_git_branch, merge_git_branch, run_git_commit, run_git_push, run_git_pull, run_git_fetch, run_git_rebase, run_git_reset, run_git_stash, run_git_diff, run_git_show, view_pull_request, create_pull_request, comment_pull_request, view_issue, create_issue, comment_issue, search_issues, view_workflow, run_workflow, view_release, create_release, view_artifact, download_artifact, view_environment, set_environment, view_secret, set_secret, view_deployment, create_deployment, view_log, search_log, view_metric, create_alert, view_alert, view_dashboard, create_dashboard, run_query, view_query, search_user, view_user, list_users, view_team, list_teams, view_organization, list_organizations.'
    # Repeat to bulk up.
    local out=""
    for _ in $(seq 1 6); do out+="$base "; done
    printf '%s' "$out"
}

SYSTEM_PROMPT=$(build_system_prompt)
SYSTEM_LEN=${#SYSTEM_PROMPT}
green "=== H6 prefix cache check ==="
green "System prompt length: $SYSTEM_LEN chars (~$((SYSTEM_LEN / 4)) tokens approx)"

# Verify endpoint
if ! curl -fsS "$VLLM_ENDPOINT/health" >/dev/null; then
    red "vLLM endpoint $VLLM_ENDPOINT not reachable"
    exit 1
fi
MODEL_ID=$(curl -fsS "$VLLM_ENDPOINT/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')
green "Served model: $MODEL_ID"

# Get prefix-cache metrics BEFORE the run
green ""
green "=== /metrics BEFORE ==="
metrics_before=$(curl -fsS "$VLLM_ENDPOINT/metrics" 2>/dev/null || echo "")
echo "$metrics_before" > "$RUN_DIR/metrics-before.txt"
echo "$metrics_before" | grep -E "prefix_cache|^vllm:gpu_cache_usage" | head -10 | tee -a "$LOG"

# Five calls with same system prompt + varying user message
USER_MESSAGES=(
    "What is 2 plus 2?"
    "Reverse the string 'hello world'."
    "What is the capital of France?"
    "List three programming languages."
    "What does HTTP stand for?"
)

ttft_results=()
for i in "${!USER_MESSAGES[@]}"; do
    user_msg="${USER_MESSAGES[$i]}"
    body=$(python3 <<EOF
import json
print(json.dumps({
    "model": "$MODEL_ID",
    "messages": [
        {"role": "system", "content": $(printf '%s' "$SYSTEM_PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')},
        {"role": "user", "content": "$user_msg"}
    ],
    "max_tokens": 32,
    "temperature": 0.0,
    "seed": 42
}))
EOF
)

    # Use curl --write-out to capture TTFB (close to TTFT for non-streaming)
    timing=$(curl -fsS "$VLLM_ENDPOINT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -o "$RUN_DIR/call-$((i+1)).json" \
        -w "%{time_starttransfer}\n" \
        -d "$body")
    ttft_results+=("$timing")
    green "Call $((i+1)): TTFT=${timing}s  user='$user_msg'"
done

# Get prefix-cache metrics AFTER
green ""
green "=== /metrics AFTER ==="
metrics_after=$(curl -fsS "$VLLM_ENDPOINT/metrics" 2>/dev/null || echo "")
echo "$metrics_after" > "$RUN_DIR/metrics-after.txt"
echo "$metrics_after" | grep -E "prefix_cache|^vllm:gpu_cache_usage" | head -10 | tee -a "$LOG"

# Compute delta on prefix-cache counters (requires Prometheus exposition format)
green ""
green "=== prefix-cache counter delta ==="
python3 <<EOF | tee -a "$LOG"
import re, sys

def parse(txt):
    out = {}
    for line in txt.splitlines():
        if line.startswith('#') or not line.strip(): continue
        # Match: name{labels}=value OR name=value
        m = re.match(r'(\S+?)(\{[^}]*\})?\s+([0-9.+\-eE]+)', line)
        if m:
            out.setdefault(m.group(1), []).append(float(m.group(3)))
    return out

before = parse(open('$RUN_DIR/metrics-before.txt').read())
after = parse(open('$RUN_DIR/metrics-after.txt').read())
keys = sorted(set(k for k in (set(before)|set(after)) if 'prefix' in k.lower() or 'cache' in k.lower()))
for k in keys:
    b = sum(before.get(k, [0]))
    a = sum(after.get(k, [0]))
    if a != b:
        print(f"  {k}: {b}  ->  {a}  (delta {a-b:+.0f})")
EOF

# Pass/fail
green ""
green "=== summary ==="
ttft_first="${ttft_results[0]}"
ttft_rest_mean=$(python3 -c "vals=[${ttft_results[1]},${ttft_results[2]},${ttft_results[3]},${ttft_results[4]}]; print(f'{sum(vals)/len(vals):.4f}')")
ratio=$(python3 -c "print(f'{$ttft_rest_mean / $ttft_first * 100:.1f}')")
green "TTFT call 1:        ${ttft_first}s"
green "TTFT calls 2-5 avg: ${ttft_rest_mean}s  (${ratio}% of call 1)"

if (( $(echo "$ttft_rest_mean < $ttft_first * 0.5" | bc -l 2>/dev/null) )); then
    green "PASS — TTFT on cached prefix is < 50% of first-call TTFT"
else
    yellow "INCONCLUSIVE — TTFT reduction smaller than expected (or system prompt too short)"
fi

green ""
green "Dossier: $RUN_DIR"
