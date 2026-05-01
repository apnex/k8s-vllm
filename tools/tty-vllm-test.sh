#!/usr/bin/env bash
# TTY-with-fsync wrapper around vllm-tiny-model-test.sh.
#
# Drops to multi-user.target before running the vLLM container test, then
# restores graphical.target on exit (success, failure, or signal). Designed
# to be launched detached:
#
#   nohup setsid /root/vllm/tools/tty-vllm-test.sh </dev/null >/dev/null 2>&1 &
#   disown
#   sleep 1
#   sudo systemctl isolate multi-user.target
#
# Output: /root/aorus-vllm-tiny-test/  (created/managed by the inner test
# script). Plus this wrapper writes its own progress markers to
# /root/aorus-vllm-tty-progress.txt for the multi-user.target stage.

set -eo pipefail

INNER="${INNER:-/root/vllm/tools/vllm-tiny-model-test.sh}"
WRAPPER_OUT="/root/aorus-vllm-tty-progress.txt"

mark() {
    printf '%s %s\n' "$(date '+%F %T %Z')" "$*" >> "$WRAPPER_OUT"
    sync -f "$WRAPPER_OUT" 2>/dev/null || sync
}

return_to_graphical() {
    if ! systemctl is-active graphical.target >/dev/null 2>&1; then
        mark 'EXIT: restoring graphical.target'
        systemctl isolate graphical.target >/dev/null 2>&1 || true
    fi
}
trap return_to_graphical EXIT

if [[ "$EUID" -ne 0 ]]; then
    echo "tty-vllm-test.sh must be run as root" >&2
    exit 1
fi

: > "$WRAPPER_OUT"
mark 'wrapper started'

# Wait briefly for systemctl isolate multi-user.target to take effect.
# We expect to be invoked just before / just after the isolate; this gives
# the system 10 s to settle into multi-user before we hammer the GPU.
mark 'waiting 10s for multi-user settle'
sleep 10
mark 'multi-user settle done'

# Run the actual test (which has its own progress / status fsync).
mark 'invoking inner test'
"$INNER"
inner_rc=$?
mark "inner test exited rc=$inner_rc"

# Idle window for delayed-panic detection. Even if the inner test passed,
# bad state could still trip the host within the next 30 s.
mark 'idle 30s for delayed-panic detection'
sleep 30
mark 'idle complete - EXIT trap will restore graphical.target'

exit "$inner_rc"
