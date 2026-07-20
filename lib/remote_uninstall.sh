#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER (uploaded there by uninstall-server.sh).
#
# Stops and removes the sing-box systemd service and its config. The
# sing-box binary itself is left in place by default (it's harmless and
# shared across reinstalls) unless --purge-binary is passed.
#
# Usage: remote_uninstall.sh <port> [--purge-binary]

set -euo pipefail

PORT="${1:?usage: remote_uninstall.sh <port> [--purge-binary]}"
PURGE_BINARY=0
if [[ "${2:-}" == "--purge-binary" ]]; then
    PURGE_BINARY=1
fi

INSTALL_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

if $SUDO systemctl list-unit-files sing-box.service >/dev/null 2>&1; then
    $SUDO systemctl disable --now sing-box >/dev/null 2>&1 || true
fi

$SUDO rm -f "$SERVICE_FILE"
$SUDO rm -rf "$CONFIG_DIR"
$SUDO systemctl daemon-reload

if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    $SUDO ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
    $SUDO ufw delete allow "${PORT}/udp" >/dev/null 2>&1 || true
    echo "ufw: closed port ${PORT} (tcp+udp)"
fi

if [[ "$PURGE_BINARY" -eq 1 ]]; then
    $SUDO rm -f "$INSTALL_BIN"
    echo "Removed sing-box binary"
fi

echo "SINGBOX_UNINSTALL_OK"
