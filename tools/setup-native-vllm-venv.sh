#!/usr/bin/env bash
# Idempotent native-vLLM venv setup. No GPU touch, no risk.
#
# Creates /root/vllm-venv/ with Python 3.13 (matches the validated
# /root/torch-test/ venv) and installs vllm + its preferred torch.
# Separate from /root/torch-test/ so vLLM can pull whichever torch
# version it pins without disturbing our PyTorch baseline.
#
# Configurable via env vars:
#   PYTHON       interpreter (default: python3.13)
#   VENV_PATH    venv location (default: /root/vllm-venv)
#   VLLM_VERSION version pin (default: 0.20.0)

set -eo pipefail

PYTHON="${PYTHON:-python3.13}"
VENV_PATH="${VENV_PATH:-/root/vllm-venv}"
VLLM_VERSION="${VLLM_VERSION:-0.20.0}"

if [[ "$EUID" -ne 0 ]]; then
    echo "setup-native-vllm-venv.sh must be run as root" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------- platform check --
step "verify platform (aorus-5090-gpu) is healthy"

if [[ -x /root/aorus-5090-gpu/status.sh ]]; then
    if /root/aorus-5090-gpu/status.sh > /tmp/aorus-status.$$ 2>&1; then
        green "  platform status: HEALTHY"
        rm -f /tmp/aorus-status.$$
    else
        red "Platform status returned non-zero - host not ready for vLLM."
        red "See /tmp/aorus-status.$$ for details."
        red "To proceed anyway, set AORUS_VLLM_SKIP_PLATFORM_CHECK=1."
        if [[ "${AORUS_VLLM_SKIP_PLATFORM_CHECK:-0}" != "1" ]]; then
            exit 3
        fi
        yellow "  AORUS_VLLM_SKIP_PLATFORM_CHECK=1 - proceeding"
    fi
fi

# ---------------------------------------------------- python check --
step "verify Python interpreter"
command -v "$PYTHON" >/dev/null || { red "$PYTHON not found"; exit 2; }
py_ver=$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')
echo "  $PYTHON ($py_ver)"

# ---------------------------------------------------- create venv --
step "create venv"
if [[ -x "$VENV_PATH/bin/python3" ]]; then
    echo "  $VENV_PATH already exists, reusing"
else
    "$PYTHON" -m venv "$VENV_PATH"
    echo "  created $VENV_PATH"
fi

PIP="$VENV_PATH/bin/pip"

step "upgrade pip"
"$PIP" install --upgrade pip 2>&1 | tail -3

# ---------------------------------------------------- install vllm --
step "install vllm $VLLM_VERSION (this is the slow step, several GB)"

if "$PIP" show vllm 2>/dev/null | grep -q "^Version: $VLLM_VERSION$"; then
    echo "  vllm $VLLM_VERSION already installed"
else
    if [[ -n "$VLLM_VERSION" ]]; then
        "$PIP" install "vllm==$VLLM_VERSION"
    else
        "$PIP" install vllm
    fi
fi

# huggingface_hub is needed for any pre-download via snapshot_download.
# vllm pulls it as a dep but pin it here for visibility.
"$PIP" install -q huggingface_hub 2>&1 | tail -3 || true

# ---------------------------------------------------- final summary --
step "installed versions"
"$PIP" list 2>/dev/null \
    | grep -iE '^(vllm|torch|transformers|tokenizers|huggingface-hub|nvidia-|triton|safetensors)\s' \
    | head -25
echo
green "setup-native-vllm-venv.sh complete."
green "venv: $VENV_PATH"
green "vllm CLI: $VENV_PATH/bin/vllm"
green "next: tools/tty-native-vllm-test.sh"
