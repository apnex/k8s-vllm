#!/usr/bin/env bash
# soak-uninstall.sh — remove the soak observability stack.
#
# Stops + disables both timers, removes unit files + installed scripts,
# leaves the log dir (/var/log/vllm-soak) intact for post-soak inspection.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

UNITS=(vllm-soak-metrics.timer vllm-soak-metrics.service
       vllm-soak-pods.timer    vllm-soak-pods.service)

echo "=== stopping + disabling ==="
for u in "${UNITS[@]}"; do
    systemctl disable --now "$u" 2>&1 || true
done

echo ""
echo "=== removing unit files ==="
for u in "${UNITS[@]}"; do
    rm -fv "/etc/systemd/system/$u"
done

echo ""
echo "=== removing installed scripts ==="
rm -fv /usr/local/sbin/vllm-soak-metrics.sh
rm -fv /usr/local/sbin/vllm-soak-pods.sh

echo ""
echo "=== reloading systemd ==="
systemctl daemon-reload

echo ""
echo "Log dir /var/log/vllm-soak preserved for post-soak inspection."
echo "Remove it manually if no longer needed: sudo rm -rf /var/log/vllm-soak"
