#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER to uninstall sing-box-client.
#
# Usage: remote_client_uninstall.sh [--purge-binary]

set -euo pipefail

PURGE_BINARY=0
for arg in "$@"; do
    case "$arg" in
        --purge-binary) PURGE_BINARY=1 ;;
    esac
done

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

echo "Stopping and disabling sing-box-client service..."
$SUDO systemctl stop sing-box-client 2>/dev/null || true
$SUDO systemctl disable sing-box-client 2>/dev/null || true

SERVICE_FILE="/etc/systemd/system/sing-box-client.service"
if [[ -e "$SERVICE_FILE" ]]; then
    $SUDO rm -f "$SERVICE_FILE"
    $SUDO systemctl daemon-reload
    $SUDO systemctl reset-failed 2>/dev/null || true
fi

echo "Removing sing-box-client configuration and data..."
$SUDO rm -rf /etc/sing-box-client /var/lib/sing-box-client
$SUDO rm -f /usr/local/bin/proxy-node /usr/local/bin/pnode /usr/local/bin/dproxy
$SUDO rm -f /etc/profile.d/singbox-proxy.sh

# Clean up ~/.bashrc
USER_BASHRC="$HOME/.bashrc"
if [[ -f "$USER_BASHRC" ]]; then
    sed -i '/singbox-proxy.sh/d' "$USER_BASHRC" || true
fi

if [[ "$PURGE_BINARY" -eq 1 ]]; then
    # Check if sing-box server service exists before deleting binary
    if [[ ! -e "/etc/systemd/system/sing-box.service" ]]; then
        echo "Removing /usr/local/bin/sing-box binary..."
        $SUDO rm -f /usr/local/bin/sing-box
    else
        echo "Keeping /usr/local/bin/sing-box (in use by sing-box server service)"
    fi
fi

echo "SINGBOX_CLIENT_UNINSTALL_OK"
