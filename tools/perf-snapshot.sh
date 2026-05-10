#!/usr/bin/env bash
# perf-snapshot.sh — rigorous before/after benchmark for vLLM.
#
# Required by docs/perf-hypothesis-ledger.md as the canonical performance
# measurement entry point: run before + after every H-change, archive the
# output, diff to assess.
#
# Captures:
#   - TTFT (true time-to-first-content-token via streaming)
#   - Decode tok/s, n=3 sequential runs (median + min/max)
#   - Concurrent 4-way aggregate throughput
#   - /metrics deltas (prompt/generation tokens, prefix-cache hit %,
#     KV-cache util, e2e latency)
#   - GPU snapshot (util %, mem used) via nvidia-smi
#
# Usage:
#   ./tools/perf-snapshot.sh                   # default: prompt~1k, completion=256
#   ./tools/perf-snapshot.sh --label H2-baseline   # label goes in output filename
#   ./tools/perf-snapshot.sh --completion-tokens 512
#
# Output: archive/perf-<UTC-ts>-<model>-<label>.json + .md summary

set -euo pipefail

VLLM_ENDPOINT="${VLLM_ENDPOINT:-http://127.0.0.1:8000}"
LABEL="baseline"
COMPLETION_TOKENS=256
CONCURRENT=4
N_SEQUENTIAL=3

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL="$2"; shift 2 ;;
        --completion-tokens) COMPLETION_TOKENS="$2"; shift 2 ;;
        --concurrent) CONCURRENT="$2"; shift 2 ;;
        --sequential) N_SEQUENTIAL="$2"; shift 2 ;;
        --endpoint) VLLM_ENDPOINT="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# perf-snapshot/,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -1
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

# pre-flight
if ! curl -fs "$VLLM_ENDPOINT/health" >/dev/null 2>&1; then
    red "vLLM /health unreachable at $VLLM_ENDPOINT"
    exit 1
fi

MODEL=$(curl -fsS "$VLLM_ENDPOINT/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')
TS=$(date -u +%Y%m%dT%H%M%SZ)
MODEL_SAFE=$(echo "$MODEL" | tr '/:' '__')
ARCHIVE_DIR="/root/vllm/archive/perf-${TS}-${MODEL_SAFE}-${LABEL}"
mkdir -p "$ARCHIVE_DIR"

green "perf-snapshot starting"
green "  model:        $MODEL"
green "  label:        $LABEL"
green "  completion:   $COMPLETION_TOKENS tok"
green "  sequential:   n=$N_SEQUENTIAL"
green "  concurrent:   $CONCURRENT-way"
green "  archive:      $ARCHIVE_DIR"

# --- streaming timer helper ----------------------------------------------------
# Embedded Python: streams a chat completion and writes one JSON line to stdout
# with {ttft_s, decode_s, decode_tps, completion_tokens}. Uses raw HTTP to avoid
# adding any client-side library dependency.
PYTHON_TIMER='
import json, sys, time, http.client, urllib.parse

req_body = sys.stdin.read()
endpoint = sys.argv[1]
parsed = urllib.parse.urlparse(endpoint)
conn = http.client.HTTPConnection(parsed.hostname, parsed.port or 80, timeout=120)
conn.request("POST", parsed.path or "/", body=req_body, headers={
    "Content-Type": "application/json",
    "Authorization": "Bearer vllm-no-auth",
    "Accept": "text/event-stream",
})
resp = conn.getresponse()
if resp.status != 200:
    body_preview = repr(resp.read()[:500])
    sys.stderr.write(f"HTTP {resp.status}: {body_preview}\n")
    sys.exit(2)

t_start = time.monotonic()
t_first = None
n_chunks = 0
last_usage = None
buf = b""
while True:
    chunk = resp.read1(4096)
    if not chunk: break
    buf += chunk
    while b"\n\n" in buf:
        ev, buf = buf.split(b"\n\n", 1)
        for line in ev.split(b"\n"):
            if not line.startswith(b"data: "): continue
            data = line[6:]
            if data == b"[DONE]": continue
            try: obj = json.loads(data)
            except Exception: continue
            choices = obj.get("choices") or []
            if choices:
                delta = choices[0].get("delta") or {}
                content = delta.get("content")
                if content:
                    if t_first is None: t_first = time.monotonic()
                    n_chunks += 1
            if obj.get("usage"):
                last_usage = obj["usage"]
t_end = time.monotonic()

ttft = (t_first - t_start) if t_first else None
decode_s = (t_end - t_first) if t_first else None
completion_tokens = (last_usage or {}).get("completion_tokens", n_chunks)
decode_tps = completion_tokens / decode_s if decode_s and decode_s > 0 else None
out = dict(ttft_s=ttft, decode_s=decode_s, decode_tps=decode_tps,
           completion_tokens=completion_tokens, e2e_s=t_end - t_start, chunks=n_chunks)
print(json.dumps(out))
'

# Build a fixed-size prompt that exercises a bit of context (~500 tokens of
# stable text + 1 short instruction, to hit decode rather than prefill).
PROMPT_TEMPLATE='You are a senior software engineer reviewing a complex codebase. Below are notes on the architecture.

The system processes streaming events from multiple upstream sources, normalizes them through a transform layer, validates against a schema registry, persists to durable storage, and emits derived events to downstream consumers. Each component runs as an independent service with its own lifecycle, scaling characteristics, and failure modes. Critical paths include the schema cache, the persistence layer commit logic, and the consumer offset management. Latency budgets are tight: end-to-end p99 must stay under 50ms even during schema-cache warm-up after a rolling restart. Observability is wired through structured logs, metrics with rich labels, and trace propagation across the entire pipeline. The team has spent months tuning batch sizes, parallelism, GC settings, and connection pool limits to hit these targets.

Question: '

build_request() {
    local question="$1"
    python3 -c "
import json, sys, os
prompt = os.environ['PROMPT_TEMPLATE'] + sys.argv[1]
print(json.dumps({
    'model': os.environ['MODEL'],
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': int(os.environ['COMPLETION_TOKENS']),
    'temperature': 0.0,
    'seed': 42,
    'stream': True,
    'stream_options': {'include_usage': True}
}))
" "$question"
}

run_streaming_timer() {
    local question="$1"
    PROMPT_TEMPLATE="$PROMPT_TEMPLATE" MODEL="$MODEL" COMPLETION_TOKENS="$COMPLETION_TOKENS" \
        build_request "$question" \
        | python3 -c "$PYTHON_TIMER" "$VLLM_ENDPOINT/v1/chat/completions"
}
export -f build_request

# --- 1) Snapshot pre-state ----------------------------------------------------
step "1) pre-state snapshot"
curl -fsS "$VLLM_ENDPOINT/metrics" > "$ARCHIVE_DIR/metrics-pre.txt"
nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null > "$ARCHIVE_DIR/gpu-pre.csv" || true
green "  /metrics + nvidia-smi captured"

# --- 2) Warm-up (untimed) -----------------------------------------------------
step "2) warm-up"
run_streaming_timer "Reply OK." > /dev/null
green "  warm-up done"

# --- 3) Sequential timed runs -------------------------------------------------
step "3) sequential runs (n=$N_SEQUENTIAL)"
SEQ_RESULTS="[]"
QUESTIONS=("Summarize the main risks." "Identify the top three failure modes." "List the most important latency contributors." "What invariants must hold during rolling restart?")
for i in $(seq 1 $N_SEQUENTIAL); do
    q="${QUESTIONS[$(( (i-1) % ${#QUESTIONS[@]} ))]}"
    line=$(run_streaming_timer "$q")
    echo "  run $i: $line"
    SEQ_RESULTS=$(jq -c --argjson line "$line" '. + [$line]' <<<"$SEQ_RESULTS")
done

# --- 4) Concurrent run --------------------------------------------------------
step "4) concurrent runs ($CONCURRENT-way)"
PIPE_DIR=$(mktemp -d)
t0_concurrent=$(date +%s.%N)
for i in $(seq 1 $CONCURRENT); do
    q="${QUESTIONS[$(( (i-1) % ${#QUESTIONS[@]} ))]}"
    (run_streaming_timer "$q $i" > "$PIPE_DIR/run-$i.json") &
done
wait
t1_concurrent=$(date +%s.%N)
concurrent_wall=$(python3 -c "print(f'{$t1_concurrent - $t0_concurrent:.3f}')")

CONCURRENT_RESULTS="[]"
for i in $(seq 1 $CONCURRENT); do
    line=$(cat "$PIPE_DIR/run-$i.json")
    echo "  concurrent run $i: $line"
    CONCURRENT_RESULTS=$(jq -c --argjson line "$line" '. + [$line]' <<<"$CONCURRENT_RESULTS")
done
rm -rf "$PIPE_DIR"

CONCURRENT_AGG_TPS=$(jq -r --arg wall "$concurrent_wall" \
    '[.[].completion_tokens] | add / ($wall | tonumber)' <<<"$CONCURRENT_RESULTS")

# --- 5) Snapshot post-state ---------------------------------------------------
step "5) post-state snapshot"
curl -fsS "$VLLM_ENDPOINT/metrics" > "$ARCHIVE_DIR/metrics-post.txt"
nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null > "$ARCHIVE_DIR/gpu-post.csv" || true

# --- 6) Compute summary -------------------------------------------------------
step "6) summary"

# Median/min/max of sequential runs
SEQ_TTFT_MEDIAN=$(jq -r '[.[].ttft_s] | sort | .[length/2|floor]' <<<"$SEQ_RESULTS")
SEQ_TTFT_MIN=$(jq -r '[.[].ttft_s] | min' <<<"$SEQ_RESULTS")
SEQ_TTFT_MAX=$(jq -r '[.[].ttft_s] | max' <<<"$SEQ_RESULTS")
SEQ_DECODE_TPS_MEDIAN=$(jq -r '[.[].decode_tps] | sort | .[length/2|floor]' <<<"$SEQ_RESULTS")
SEQ_DECODE_TPS_MIN=$(jq -r '[.[].decode_tps] | min' <<<"$SEQ_RESULTS")
SEQ_DECODE_TPS_MAX=$(jq -r '[.[].decode_tps] | max' <<<"$SEQ_RESULTS")

# /metrics deltas — extract a few key counters
extract_metric() {
    local file="$1" name="$2"
    grep -E "^${name}" "$file" 2>/dev/null | awk '{print $2}' | head -1
}

PROMPT_TOKENS_PRE=$(extract_metric "$ARCHIVE_DIR/metrics-pre.txt"  'vllm:prompt_tokens_total\{')
PROMPT_TOKENS_POST=$(extract_metric "$ARCHIVE_DIR/metrics-post.txt" 'vllm:prompt_tokens_total\{')
GEN_TOKENS_PRE=$(extract_metric "$ARCHIVE_DIR/metrics-pre.txt"     'vllm:generation_tokens_total\{')
GEN_TOKENS_POST=$(extract_metric "$ARCHIVE_DIR/metrics-post.txt"   'vllm:generation_tokens_total\{')
PREFIX_QUERIES_PRE=$(extract_metric "$ARCHIVE_DIR/metrics-pre.txt"  'vllm:prefix_cache_queries_total\{')
PREFIX_QUERIES_POST=$(extract_metric "$ARCHIVE_DIR/metrics-post.txt" 'vllm:prefix_cache_queries_total\{')
PREFIX_HITS_PRE=$(extract_metric "$ARCHIVE_DIR/metrics-pre.txt"     'vllm:prefix_cache_hits_total\{')
PREFIX_HITS_POST=$(extract_metric "$ARCHIVE_DIR/metrics-post.txt"   'vllm:prefix_cache_hits_total\{')

# GPU
GPU_PRE=$(cat "$ARCHIVE_DIR/gpu-pre.csv" 2>/dev/null || echo "")
GPU_POST=$(cat "$ARCHIVE_DIR/gpu-post.csv" 2>/dev/null || echo "")

# Build summary JSON
SUMMARY_JSON="$ARCHIVE_DIR/summary.json"
python3 <<EOF > "$SUMMARY_JSON"
import json
def f(x):
    try: return float(x)
    except: return None

def delta(pre, post):
    a, b = f(pre), f(post)
    return (b - a) if (a is not None and b is not None) else None

prefix_queries_d = delta('$PREFIX_QUERIES_PRE', '$PREFIX_QUERIES_POST')
prefix_hits_d    = delta('$PREFIX_HITS_PRE',    '$PREFIX_HITS_POST')
prefix_hit_rate  = (prefix_hits_d / prefix_queries_d) if (prefix_queries_d and prefix_queries_d > 0) else None

print(json.dumps({
    'ts_utc': '$TS',
    'model': '$MODEL',
    'label': '$LABEL',
    'config': {
        'completion_tokens': $COMPLETION_TOKENS,
        'concurrent': $CONCURRENT,
        'sequential': $N_SEQUENTIAL,
    },
    'sequential': {
        'ttft_s': {'median': f('$SEQ_TTFT_MEDIAN'), 'min': f('$SEQ_TTFT_MIN'), 'max': f('$SEQ_TTFT_MAX')},
        'decode_tps': {'median': f('$SEQ_DECODE_TPS_MEDIAN'), 'min': f('$SEQ_DECODE_TPS_MIN'), 'max': f('$SEQ_DECODE_TPS_MAX')},
        'runs': $SEQ_RESULTS,
    },
    'concurrent': {
        'wall_s': f('$concurrent_wall'),
        'aggregate_tps': f('$CONCURRENT_AGG_TPS'),
        'runs': $CONCURRENT_RESULTS,
    },
    'metrics_delta': {
        'prompt_tokens': delta('$PROMPT_TOKENS_PRE', '$PROMPT_TOKENS_POST'),
        'generation_tokens': delta('$GEN_TOKENS_PRE', '$GEN_TOKENS_POST'),
        'prefix_cache_queries': prefix_queries_d,
        'prefix_cache_hits': prefix_hits_d,
        'prefix_cache_hit_rate': prefix_hit_rate,
    },
    'gpu': {
        'pre_csv':  '$GPU_PRE',
        'post_csv': '$GPU_POST',
    },
}, indent=2))
EOF

# Pretty-print summary
python3 <<EOF
import json
d = json.load(open('$SUMMARY_JSON'))
def fmt(v, suffix='', dec=2):
    if v is None: return 'n/a'
    return f'{v:.{dec}f}{suffix}'

s = d['sequential']
c = d['concurrent']
m = d['metrics_delta']

print()
print(f"=== SUMMARY  {d['model']}  ({d['label']}) ===")
print(f"  TTFT          median {fmt(s['ttft_s']['median'], 's', 3)}  range {fmt(s['ttft_s']['min'],'s',3)} - {fmt(s['ttft_s']['max'],'s',3)}")
print(f"  Decode tok/s  median {fmt(s['decode_tps']['median'], '', 1)}  range {fmt(s['decode_tps']['min'],'',1)} - {fmt(s['decode_tps']['max'],'',1)}")
print(f"  Concurrent {d['config']['concurrent']}-way: wall {fmt(c['wall_s'], 's', 2)}, aggregate {fmt(c['aggregate_tps'], ' tok/s', 1)}")
print(f"  Prefix cache: {fmt(m['prefix_cache_hits'], ' hits')}, {fmt(m['prefix_cache_queries'], ' queries')}, hit rate {fmt(100*(m['prefix_cache_hit_rate'] or 0), '%', 1)}")
print(f"  GPU pre:  {d['gpu']['pre_csv']}")
print(f"  GPU post: {d['gpu']['post_csv']}")
print(f"  Archive:  $ARCHIVE_DIR")
EOF
