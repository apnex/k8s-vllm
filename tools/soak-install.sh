#!/usr/bin/env bash
# soak-install.sh — install the soak observability stack on the host.
#
# Idempotent. Run as root.
#
# Installs:
#   /usr/local/sbin/vllm-soak-metrics.sh           (bin_t SELinux label — systemd-executable)
#   /usr/local/sbin/vllm-soak-pods.sh
#   /etc/systemd/system/vllm-soak-metrics.{service,timer}
#   /etc/systemd/system/vllm-soak-pods.{service,timer}
# Creates:
#   /var/log/vllm-soak/                            (output dir for both timers)
# Enables + starts both timers.
#
# Why /usr/local/sbin and not /root/k8s-vllm/tools/ directly:
#   SELinux's init_t (systemd) cannot exec admin_home_t (/root/...) files.
#   /usr/local/sbin/ is labeled bin_t which init_t can execute.
#
# Uninstall: ./soak-uninstall.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_TOOLS="$REPO_ROOT/tools"
SRC_UNITS="$REPO_ROOT/tools/systemd"
DST_BIN=/usr/local/sbin
DST_UNITS=/etc/systemd/system

echo "=== installing scripts to $DST_BIN ==="
install -m 0755 "$SRC_TOOLS/soak-metrics.sh" "$DST_BIN/vllm-soak-metrics.sh"
install -m 0755 "$SRC_TOOLS/soak-pods.sh"    "$DST_BIN/vllm-soak-pods.sh"

UNITS=(vllm-soak-metrics.service vllm-soak-metrics.timer
       vllm-soak-pods.service    vllm-soak-pods.timer)

echo ""
echo "=== installing units to $DST_UNITS ==="
for u in "${UNITS[@]}"; do
    install -m 0644 "$SRC_UNITS/$u" "$DST_UNITS/$u"
done

echo ""
echo "=== creating output dir ==="
mkdir -p /var/log/vllm-soak
chmod 755 /var/log/vllm-soak

echo ""
echo "=== reloading systemd ==="
systemctl daemon-reload

echo ""
echo "=== enabling + starting timers ==="
systemctl enable --now vllm-soak-metrics.timer
systemctl enable --now vllm-soak-pods.timer

echo ""
echo "=== status ==="
systemctl list-timers 'vllm-soak-*' --no-pager
