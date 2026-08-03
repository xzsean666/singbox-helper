#!/usr/bin/env bash
# Runs ON THE REMOTE SERVER (uploaded there by setup-server.sh).
# Expects /tmp/singbox-setup/server-config.json.tpl and
# /tmp/singbox-setup/sing-box.service to already have been uploaded alongside
# this script.
#
# Usage: remote_install.sh <vless_port> <http_port> <uuid> <short_id> <sni> <http_username> <http_password>
#
# The Reality keypair is generated HERE (not on the local machine) because it
# requires the sing-box binary itself - the private key never leaves this
# server; only the public key is printed back for the caller to build a
# client config with.
#
# Exit codes:
#   0  - success, prints "SINGBOX_SETUP_OK PORT=<port>" and "SINGBOX_PUBLIC_KEY=<key>"
#   75 - the requested port is already in use (caller should pick another port and retry)
#   1  - any other failure

set -euo pipefail

PORT="${1:?usage: remote_install.sh <vless_port> <http_port> <uuid> <short_id> <sni> <http_username> <http_password>}"
HTTP_PORT="${2:?usage: remote_install.sh <vless_port> <http_port> <uuid> <short_id> <sni> <http_username> <http_password>}"
UUID="${3:?usage: remote_install.sh <vless_port> <http_port> <uuid> <short_id> <sni> <http_username> <http_password>}"
SHORT_ID="${4:?usage: remote_install.sh <vless_port> <http_port> <uuid> <short_id> <sni> <http_username> <http_password>}"
SNI="${5:?usage: remote_install.sh <vless_port> <http_port> <uuid> <short_id> <sni> <http_username> <http_password>}"
HTTP_USERNAME="${6:?usage: remote_install.sh <vless_port> <http_port> <uuid> <short_id> <sni> <http_username> <http_password>}"
HTTP_PASSWORD="${7:?usage: remote_install.sh <vless_port> <http_port> <uuid> <short_id> <sni> <http_username> <http_password>}"

SETUP_DIR="/tmp/singbox-setup"
INSTALL_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

port_is_listening() {
    local candidate_port="$1"
    command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${candidate_port}\$"
}

for candidate_port in "$PORT" "$HTTP_PORT"; do
    if port_is_listening "$candidate_port"; then
        echo "SINGBOX_SETUP_PORT_TAKEN PORT=${candidate_port}" >&2
        exit 75
    fi
done

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "remote_install.sh: only Linux targets are supported" >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l) ARCH=armv7 ;;
    *)
        echo "remote_install.sh: unsupported architecture $(uname -m)" >&2
        exit 1
        ;;
esac

if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found, attempting to install it..."
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq curl
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y -q curl
    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache curl
    else
        echo "remote_install.sh: curl is required but not found, and no known package manager to install it with" >&2
        exit 1
    fi
fi

if [[ ! -x "$INSTALL_BIN" ]]; then
    echo "Installing sing-box (arch: ${ARCH})..."
    TMP_DL=$(mktemp -d)
    trap 'rm -rf "$TMP_DL"' EXIT

    API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    RELEASE_JSON=$(curl -fsSL "$API_URL")
    DOWNLOAD_URL=$(echo "$RELEASE_JSON" \
        | { grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}\.tar\.gz\"" || true; } \
        | head -n1 \
        | sed -E 's/.*"(https[^"]+)".*/\1/')

    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo "remote_install.sh: could not resolve a sing-box download URL for linux-${ARCH}" >&2
        exit 1
    fi

    curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DL/sing-box.tar.gz"
    tar -xzf "$TMP_DL/sing-box.tar.gz" -C "$TMP_DL"
    BIN_PATH=$(find "$TMP_DL" -type f -name sing-box | head -n1)
    if [[ -z "$BIN_PATH" ]]; then
        echo "remote_install.sh: sing-box binary not found inside downloaded archive" >&2
        exit 1
    fi
    $SUDO install -m 0755 "$BIN_PATH" "$INSTALL_BIN"
else
    echo "sing-box already installed at ${INSTALL_BIN}, skipping download"
fi

echo "Generating Reality keypair..."
KEYPAIR_OUTPUT=$("$INSTALL_BIN" generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYPAIR_OUTPUT" | sed -n 's/^PrivateKey: *//p')
PUBLIC_KEY=$(echo "$KEYPAIR_OUTPUT" | sed -n 's/^PublicKey: *//p')

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo "remote_install.sh: failed to parse a Reality keypair out of 'sing-box generate reality-keypair' output:" >&2
    echo "$KEYPAIR_OUTPUT" >&2
    exit 1
fi

sed -e "s|{{PORT}}|${PORT}|g" \
    -e "s|{{HTTP_PORT}}|${HTTP_PORT}|g" \
    -e "s|{{HTTP_USERNAME}}|${HTTP_USERNAME}|g" \
    -e "s|{{HTTP_PASSWORD}}|${HTTP_PASSWORD}|g" \
    -e "s|{{UUID}}|${UUID}|g" \
    -e "s|{{SHORT_ID}}|${SHORT_ID}|g" \
    -e "s|{{SNI}}|${SNI}|g" \
    -e "s|{{PRIVATE_KEY}}|${PRIVATE_KEY}|g" \
    "${SETUP_DIR}/server-config.json.tpl" > "${SETUP_DIR}/config.json"

$SUDO mkdir -p "$CONFIG_DIR"
$SUDO cp "${SETUP_DIR}/config.json" "${CONFIG_DIR}/config.json"
$SUDO cp "${SETUP_DIR}/sing-box.service" "$SERVICE_FILE"

if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    $SUDO ufw allow "${PORT}/tcp" >/dev/null
    $SUDO ufw allow "${PORT}/udp" >/dev/null
    $SUDO ufw allow "${HTTP_PORT}/tcp" >/dev/null
    echo "ufw: opened VLESS port ${PORT} (tcp+udp) and HTTP proxy port ${HTTP_PORT} (tcp)"
else
    echo "NOTE: no active ufw firewall detected - if this server uses something else (firewalld, a cloud security group, etc.) open VLESS port ${PORT}/tcp+udp and HTTP proxy port ${HTTP_PORT}/tcp manually"
fi

$SUDO systemctl daemon-reload
$SUDO systemctl enable sing-box >/dev/null
$SUDO systemctl restart sing-box

sleep 1

if ! $SUDO systemctl is-active --quiet sing-box; then
    echo "remote_install.sh: sing-box service failed to start" >&2
    $SUDO systemctl status sing-box --no-pager || true
    exit 1
fi

for candidate_port in "$PORT" "$HTTP_PORT"; do
    if ! port_is_listening "$candidate_port"; then
        echo "remote_install.sh: sing-box is active but not listening on port ${candidate_port}" >&2
        exit 1
    fi
done

echo "SINGBOX_SETUP_OK PORT=${PORT} HTTP_PORT=${HTTP_PORT}"
echo "SINGBOX_PUBLIC_KEY=${PUBLIC_KEY}"
