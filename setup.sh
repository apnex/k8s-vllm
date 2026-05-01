#!/usr/bin/env bash
# Idempotent vLLM venv installer.
#
# Creates /root/vllm-venv/ with the chosen Python interpreter and installs
# vLLM (and its dependencies, including its preferred torch). Safe to re-run.
#
# Configurable via env vars:
#   PYTHON     - interpreter to use (default: python3.13)
#   VENV_PATH  - where to create the venv (default: /root/vllm-venv)
#   VLLM_VERSION - vllm version pin (default: 0.20.0; empty = latest)

set -euo pipefail

PYTHON="${PYTHON:-python3.13}"
VENV_PATH="${VENV_PATH:-/root/vllm-venv}"
VLLM_VERSION="${VLLM_VERSION:-0.20.0}"

if [[ "$EUID" -ne 0 ]]; then
    echo "setup.sh must be run as root (writes to /root/vllm-venv/)" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

# ------------------------------------------------------------------- python --
step "verify Python interpreter"

if ! command -v "$PYTHON" >/dev/null; then
    red "$PYTHON not found in PATH."
    if [[ "$PYTHON" =~ ^python3\.[0-9]+$ ]]; then
        ver="${PYTHON#python}"
        red "Install with: sudo dnf install $PYTHON"
    fi
    exit 2
fi

py_version=$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')
echo "  using $PYTHON ($py_version)"

# ---------------------------------------------------------- platform check --
step "verify platform (aorus-5090-gpu) is healthy"

if [[ -x /root/aorus-5090-gpu/status.sh ]]; then
    if /root/aorus-5090-gpu/status.sh > /tmp/aorus-status-pre-vllm.$$ 2>&1; then
        echo "  platform status: HEALTHY"
    else
        rc=$?
        red "Platform status check returned $rc - the host may not be ready for vLLM."
        red "See /tmp/aorus-status-pre-vllm.$$ for details."
        red "Continue anyway by setting AORUS_VLLM_SKIP_PLATFORM_CHECK=1."
        if [[ "${AORUS_VLLM_SKIP_PLATFORM_CHECK:-0}" != "1" ]]; then
            exit 3
        fi
        yellow "  AORUS_VLLM_SKIP_PLATFORM_CHECK=1 - proceeding despite platform warnings"
    fi
    rm -f /tmp/aorus-status-pre-vllm.$$
else
    yellow "  /root/aorus-5090-gpu/status.sh not found; skipping platform check"
fi

# ---------------------------------------------------------- venv creation --
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

# ---------------------------------------------------------- install vllm --
step "install vllm"

# Check if vllm is already installed at the desired version
if "$PIP" show vllm 2>/dev/null | grep -q "^Version: $VLLM_VERSION$"; then
    echo "  vllm $VLLM_VERSION already installed"
else
    if [[ -n "$VLLM_VERSION" ]]; then
        "$PIP" install "vllm==$VLLM_VERSION"
    else
        "$PIP" install vllm
    fi
fi

# Optionally install hf_transfer for faster model downloads, and
# huggingface_hub which vllm uses anyway but pin it here for visibility.
"$PIP" install -q hf_transfer huggingface_hub 2>&1 | tail -3 || true

# ---------------------------------------------------------- final summary --
step "installed versions"

"$PIP" list 2>/dev/null | grep -iE '^(vllm|torch|transformers|tokenizers|huggingface-hub|nvidia-|triton|safetensors)\s' | head -20

echo
green "setup.sh complete."
green "venv: $VENV_PATH"
green "next: run tools/vllm-import-test.py to validate phase 1"
