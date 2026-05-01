#!/usr/bin/env bash
# Phase 1: validate GPU passthrough into a Docker container.
#
# Pulls a small NVIDIA CUDA base image and runs `nvidia-smi` inside it with
# --gpus all. If this passes, the host's nvidia-container-toolkit setup is
# correct and the kernel modules / persistenced are accessible from inside
# containers.
#
# This does NOT exercise vLLM. That's phase 2 and beyond. Keep the validation
# stages separate so we know which layer broke if something does.

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "docker-gpu-smoke.sh should be run as root (or via sudo)" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step()  { printf '\n=== %s ===\n' "$*"; }

# Use the official CUDA base. cuda:13.0.0 lines up with the host driver
# (NVIDIA 580.142 supports CUDA 13.x). Smaller -base variants without the
# full toolkit, just enough to run nvidia-smi.
IMG="${IMG:-nvidia/cuda:13.0.0-base-ubi9}"

step "preflight - confirm host preconditions"

# Read /proc/modules directly: 'lsmod | grep -q' with set -o pipefail fails
# with SIGPIPE (rc=141) when grep exits early before lsmod finishes writing.
if ! grep -q '^nvidia ' /proc/modules; then
    red "nvidia kernel module is not loaded on the host"
    exit 2
fi
if ! grep -q '^nvidia_uvm ' /proc/modules; then
    red "nvidia_uvm is not loaded - run aorus-5090-compute-load-nvidia.service first"
    exit 3
fi
if ! systemctl is-active nvidia-persistenced.service >/dev/null 2>&1; then
    red "nvidia-persistenced.service is not active"
    exit 4
fi
if ! docker info 2>&1 | grep -q 'Runtimes:.*nvidia'; then
    red "docker does not have the nvidia runtime configured - run setup.sh first"
    exit 5
fi
green "  preconditions ok"

step "pull $IMG (cached if present)"
docker pull "$IMG"

step "run container with --gpus all and execute nvidia-smi"
container_output=$(docker run --rm --gpus all "$IMG" nvidia-smi 2>&1)
container_rc=$?

echo "$container_output"

if [[ "$container_rc" -ne 0 ]]; then
    red "nvidia-smi inside container exited $container_rc"
    exit "$container_rc"
fi

if ! grep -q 'NVIDIA GeForce RTX 5090' <<<"$container_output"; then
    red "nvidia-smi ran but did not report 'NVIDIA GeForce RTX 5090'"
    exit 6
fi

green "
GPU passthrough verified. The container saw the RTX 5090.
Next: pull vllm/vllm-openai and run tools/vllm-cuda-detect.sh"
