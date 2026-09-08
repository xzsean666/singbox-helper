#!/usr/bin/env bash
# Runs ON THE REMOTE CLIENT SERVER (uploaded there by setup-client.sh).
# Expects /tmp/singbox-client-setup to contain:
#   - config.json
#   - sing-box-client.service
#   - proxy-node
#   - profile-proxy.sh
#   - sub_url.txt (optional)
#
# Usage: remote_client_install.sh <port>
#
# Exit codes:
#   0  - success, prints "SINGBOX_CLIENT_SETUP_OK PORT=<port>"
#   1  - any failure

set -euo pipefail

PORT="${1:-1080}"
SETUP_DIR="/tmp/singbox-client-setup"
INSTALL_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box-client"
STATE_DIR="/var/lib/sing-box-client"
SERVICE_FILE="/etc/systemd/system/sing-box-client.service"
PROFILE_FILE="/etc/profile.d/singbox-proxy.sh"

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "remote_client_install.sh: only Linux targets are supported" >&2
    exit 1
fi

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l) ARCH=armv7 ;;
    *)
        echo "remote_client_install.sh: unsupported architecture $(uname -m)" >&2
        exit 1
        ;;
esac

# Ensure curl and python3 are available
NEED_APT_UPDATE=0
for pkg in curl python3; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        echo "Package '$pkg' not found, attempting to install it..."
        if command -v apt-get >/dev/null 2>&1; then
            if [[ "$NEED_APT_UPDATE" -eq 0 ]]; then
                $SUDO apt-get update -qq
                NEED_APT_UPDATE=1
            fi
            $SUDO apt-get install -y -qq "$pkg"
        elif command -v yum >/dev/null 2>&1; then
            $SUDO yum install -y -q "$pkg"
        elif command -v apk >/dev/null 2>&1; then
            $SUDO apk add --no-cache "$pkg"
        else
            echo "remote_client_install.sh: $pkg is required but package manager not recognized" >&2
            exit 1
        fi
    fi
done

# Install sing-box binary if missing
INSTALL_BIN=""
if command -v sing-box >/dev/null 2>&1; then
    INSTALL_BIN=$(command -v sing-box)
    echo "sing-box already installed at ${INSTALL_BIN}, keeping existing binary"
elif [[ -x "/usr/local/bin/sing-box" ]]; then
    INSTALL_BIN="/usr/local/bin/sing-box"
    echo "sing-box already installed at ${INSTALL_BIN}, keeping existing binary"
else
    INSTALL_BIN="/usr/local/bin/sing-box"
    echo "Installing sing-box binary (arch: ${ARCH})..."
    TMP_DL=$(mktemp -d)
    trap 'rm -rf "$TMP_DL"' EXIT

    API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    RELEASE_JSON=$(curl -fsSL "$API_URL")
    DOWNLOAD_URL=$(echo "$RELEASE_JSON" \
        | { grep -o "\"browser_download_url\": *\"[^\"]*linux-${ARCH}\.tar\.gz\"" || true; } \
        | head -n1 \
        | sed -E 's/.*"(https[^"]+)".*/\1/')

    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo "remote_client_install.sh: could not resolve sing-box download URL for linux-${ARCH}" >&2
        exit 1
    fi

    curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DL/sing-box.tar.gz"
    tar -xzf "$TMP_DL/sing-box.tar.gz" -C "$TMP_DL"
    BIN_PATH=$(find "$TMP_DL" -type f -name sing-box | head -n1)
    if [[ -z "$BIN_PATH" ]]; then
        echo "remote_client_install.sh: sing-box binary not found inside downloaded archive" >&2
        exit 1
    fi
    $SUDO install -m 0755 "$BIN_PATH" "$INSTALL_BIN"
fi

# Prepare directories
$SUDO mkdir -p "$CONFIG_DIR"
$SUDO mkdir -p "${CONFIG_DIR}/profiles"
$SUDO mkdir -p "$STATE_DIR"

# Copy configuration and subscription
$SUDO cp "${SETUP_DIR}/config.json" "${CONFIG_DIR}/config.json"
$SUDO chmod 0644 "${CONFIG_DIR}/config.json"
if [[ -f "${SETUP_DIR}/sub_url.txt" ]]; then
    $SUDO cp "${SETUP_DIR}/sub_url.txt" "${CONFIG_DIR}/sub_url.txt"
    $SUDO chmod 0600 "${CONFIG_DIR}/sub_url.txt"
fi

# Save initial profile if provided
if [[ -f "${SETUP_DIR}/profile_info.json" && -f "${SETUP_DIR}/current_profile.txt" ]]; then
    PNAME=$(head -n1 "${SETUP_DIR}/current_profile.txt" | tr -d '\r\n')
    if [[ -n "$PNAME" ]]; then
        $SUDO cp "${SETUP_DIR}/config.json" "${CONFIG_DIR}/profiles/${PNAME}.json"
        $SUDO chmod 0644 "${CONFIG_DIR}/profiles/${PNAME}.json"
        $SUDO cp "${SETUP_DIR}/profile_info.json" "${CONFIG_DIR}/profiles/${PNAME}.meta.json"
        $SUDO chmod 0644 "${CONFIG_DIR}/profiles/${PNAME}.meta.json"
        $SUDO cp "${SETUP_DIR}/current_profile.txt" "${CONFIG_DIR}/current_profile.txt"
        $SUDO chmod 0644 "${CONFIG_DIR}/current_profile.txt"
    fi
fi

# Install sub_converter.py on client for local node/sub management
if [[ -f "${SETUP_DIR}/sub_converter.py" ]]; then
    $SUDO cp "${SETUP_DIR}/sub_converter.py" "${CONFIG_DIR}/sub_converter.py"
    $SUDO chmod 0755 "${CONFIG_DIR}/sub_converter.py"
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
    echo "Installing python3-yaml for subscription management..."
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq python3-yaml || true
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y -q python3-pyyaml || true
    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache py3-yaml || true
    fi
fi

# Create docker on-demand proxy env file
$SUDO tee "${CONFIG_DIR}/docker-proxy.env" >/dev/null <<EOF
HTTP_PROXY=http://172.17.0.1:${PORT}
HTTPS_PROXY=http://172.17.0.1:${PORT}
ALL_PROXY=socks5://172.17.0.1:${PORT}
http_proxy=http://172.17.0.1:${PORT}
https_proxy=http://172.17.0.1:${PORT}
all_proxy=socks5://172.17.0.1:${PORT}
NO_PROXY=localhost,127.0.0.1,::1,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8
no_proxy=localhost,127.0.0.1,::1,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8
EOF
$SUDO chmod 0644 "${CONFIG_DIR}/docker-proxy.env"

# If docker is installed, configure daemon pull proxy and boot order
if command -v docker >/dev/null 2>&1; then
    $SUDO mkdir -p /etc/systemd/system/docker.service.d
    $SUDO tee /etc/systemd/system/docker.service.d/sing-box-client.conf >/dev/null <<EOF
[Unit]
After=sing-box-client.service
Wants=sing-box-client.service

[Service]
Environment="HTTP_PROXY=http://127.0.0.1:${PORT}"
Environment="HTTPS_PROXY=http://127.0.0.1:${PORT}"
Environment="NO_PROXY=localhost,127.0.0.1,::1,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"
EOF
    $SUDO systemctl daemon-reload 2>/dev/null || true
    $SUDO systemctl restart docker 2>/dev/null || true
fi

# Install proxy-node CLI tool and dproxy helper
$SUDO cp "${SETUP_DIR}/proxy-node" /usr/local/bin/proxy-node
$SUDO chmod 0755 /usr/local/bin/proxy-node
$SUDO ln -sf /usr/local/bin/proxy-node /usr/local/bin/pnode
if [[ -f "${SETUP_DIR}/dproxy" ]]; then
    $SUDO cp "${SETUP_DIR}/dproxy" /usr/local/bin/dproxy
    $SUDO chmod 0755 /usr/local/bin/dproxy
fi

# Install profile.d proxy helper
$SUDO cp "${SETUP_DIR}/profile-proxy.sh" "$PROFILE_FILE"
$SUDO chmod 0644 "$PROFILE_FILE"

# Inject into user's ~/.bashrc if not already present
USER_BASHRC="$HOME/.bashrc"
if [[ -f "$USER_BASHRC" ]] && ! grep -q "singbox-proxy.sh" "$USER_BASHRC"; then
    cat >> "$USER_BASHRC" <<'EOF'

# singbox-client proxy environment helper (default: OFF)
[ -f /etc/profile.d/singbox-proxy.sh ] && source /etc/profile.d/singbox-proxy.sh
EOF
fi

# If installing as non-root with sudo, also configure root's bashrc if exists
if [[ -n "$SUDO" && -f /root/.bashrc ]] && ! $SUDO grep -q "singbox-proxy.sh" /root/.bashrc; then
    $SUDO bash -c 'cat >> /root/.bashrc <<'\''EOF'\''

# singbox-client proxy environment helper (default: OFF)
[ -f /etc/profile.d/singbox-proxy.sh ] && source /etc/profile.d/singbox-proxy.sh
EOF'
fi

# Stop and disable any conflicting generic sing-box service if running
if $SUDO systemctl is-active --quiet sing-box 2>/dev/null; then
    echo "Stopping conflicting sing-box service..."
    $SUDO systemctl stop sing-box 2>/dev/null || true
    $SUDO systemctl disable sing-box 2>/dev/null || true
fi

# Install systemd service
sed -i "s|{{INSTALL_BIN}}|${INSTALL_BIN}|g" "${SETUP_DIR}/sing-box-client.service"
$SUDO cp "${SETUP_DIR}/sing-box-client.service" "$SERVICE_FILE"
$SUDO chmod 0644 "$SERVICE_FILE"

$SUDO systemctl daemon-reload
$SUDO systemctl enable sing-box-client >/dev/null
$SUDO systemctl restart sing-box-client

sleep 1

if ! $SUDO systemctl is-active --quiet sing-box-client; then
    echo "remote_client_install.sh: sing-box-client service failed to start" >&2
    $SUDO systemctl status sing-box-client --no-pager || true
    exit 1
fi

# Open port for Docker bridge in ufw if active
if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    $SUDO ufw allow from 172.16.0.0/12 to any port "${PORT}" proto tcp comment 'Docker bridge to sing-box client' >/dev/null 2>&1 || true
fi

echo "SINGBOX_CLIENT_SETUP_OK PORT=${PORT}"
