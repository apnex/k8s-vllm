#!/usr/bin/env bash
# Idempotent installer for the Docker-based vLLM stack.
#
# 1. Verifies the host platform (aorus-5090-gpu) is healthy.
# 2. Adds NVIDIA's container toolkit dnf repo.
# 3. Installs nvidia-container-toolkit.
# 4. Configures Docker runtime for nvidia (preserves existing daemon.json keys).
# 5. Restarts dockerd to pick up the runtime config.
# 6. Validates GPU passthrough with a small CUDA test container.
#
# Does NOT pull the vLLM image or start any vLLM container - that's the next
# phase, gated by tools/docker-gpu-smoke.sh passing first.

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "setup.sh must be run as root" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------- platform check --
step "verify platform (aorus-5090-gpu) is healthy"

if [[ -x /root/aorus-5090-gpu/status.sh ]]; then
    if /root/aorus-5090-gpu/status.sh > /tmp/aorus-status-pre-vllm.$$ 2>&1; then
        green "  platform status: HEALTHY"
        rm -f /tmp/aorus-status-pre-vllm.$$
    else
        rc=$?
        red "Platform status returned $rc - host is not ready for vLLM."
        red "See /tmp/aorus-status-pre-vllm.$$ for the full report."
        red "To proceed anyway, set AORUS_VLLM_SKIP_PLATFORM_CHECK=1."
        if [[ "${AORUS_VLLM_SKIP_PLATFORM_CHECK:-0}" != "1" ]]; then
            exit 3
        fi
        yellow "  AORUS_VLLM_SKIP_PLATFORM_CHECK=1 - proceeding"
    fi
else
    yellow "  /root/aorus-5090-gpu/status.sh not found; skipping platform check"
fi

# -------------------------------------------------- docker daemon running --
step "verify docker daemon"

if ! systemctl is-active docker.service >/dev/null 2>&1; then
    red "docker.service is not active. Start it with: systemctl start docker"
    exit 4
fi
green "  docker.service is active"

docker_ver=$(docker --version 2>&1 || true)
echo "  $docker_ver"

# -------------------------------------------------- container toolkit repo --
step "ensure NVIDIA container toolkit repo is configured"

repo_file=/etc/yum.repos.d/nvidia-container-toolkit.repo
if [[ -f "$repo_file" ]]; then
    echo "  $repo_file already exists"
else
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        -o "$repo_file"
    echo "  installed $repo_file"
fi

# -------------------------------------------------- install toolkit pkg --
step "ensure nvidia-container-toolkit is installed"

if rpm -q nvidia-container-toolkit >/dev/null 2>&1; then
    installed_ver=$(rpm -q --qf '%{VERSION}-%{RELEASE}' nvidia-container-toolkit)
    echo "  nvidia-container-toolkit $installed_ver already installed"
else
    dnf install -y nvidia-container-toolkit
    rpm -q nvidia-container-toolkit
fi

# -------------------------------------------------- configure docker runtime
step "configure Docker for nvidia runtime"

before_hash=$(sha256sum /etc/docker/daemon.json 2>/dev/null | awk '{print $1}' || echo "missing")
nvidia-ctk runtime configure --runtime=docker
after_hash=$(sha256sum /etc/docker/daemon.json 2>/dev/null | awk '{print $1}' || echo "missing")

if [[ "$before_hash" == "$after_hash" ]]; then
    echo "  /etc/docker/daemon.json already configured (no change)"
else
    echo "  /etc/docker/daemon.json updated"
fi

# Sanity-check that the nvidia runtime is in the docker config
if ! grep -q '"nvidia"' /etc/docker/daemon.json 2>/dev/null; then
    red "nvidia runtime not visible in /etc/docker/daemon.json after configure - manual review needed"
    cat /etc/docker/daemon.json 2>&1 || true
    exit 5
fi
echo "  nvidia runtime present in daemon.json"

# -------------------------------------------------- restart dockerd --
step "restart dockerd to pick up runtime config"

# Detect whether a restart is needed by checking docker info for the nvidia runtime
if docker info 2>&1 | grep -q 'Runtimes:.*nvidia'; then
    green "  dockerd already exposes nvidia runtime, no restart needed"
else
    yellow "  restarting docker.service"
    systemctl restart docker.service
    sleep 2
    if docker info 2>&1 | grep -q 'Runtimes:.*nvidia'; then
        green "  dockerd now exposes nvidia runtime"
    else
        red "  nvidia runtime still not visible in docker info; manual investigation needed"
        exit 6
    fi
fi

# ---------------------------------------------------- final summary --
step "next steps"

cat <<'EOF'
setup.sh complete.

To validate GPU passthrough, run:
    sudo /root/vllm/tools/docker-gpu-smoke.sh

That runs a small NVIDIA CUDA test image with --gpus all and confirms
nvidia-smi sees the RTX 5090 from inside the container. If that passes,
the next step is to pull the vLLM image and start the model load test.
EOF
