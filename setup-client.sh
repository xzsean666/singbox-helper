#!/usr/bin/env bash
# Sets up a sing-box client on a remote host via SSH.
# Supports Clash subscription URLs, multiple nodes with switching, standalone VLESS URIs,
# or existing server aliases.
#
# Usage:
#   ./setup-client.sh "ssh root@1.2.3.4" --sub "https://example.com/sub/..."
#   ./setup-client.sh "ssh -i ~/.ssh/id_rsa root@1.2.3.4" --vless "vless://..."
#   ./setup-client.sh "ssh root@1.2.3.4" --server myserver
#   ./setup-client.sh "ssh root@1.2.3.4" --config /path/to/config.json
#
# Requires passwordless sudo (or a root login) on the remote host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse_ssh.sh
source "${SCRIPT_DIR}/lib/parse_ssh.sh"

usage() {
    cat >&2 <<EOF
Usage: $0 "<ssh command>" [options]

Config Source Options (one required):
  --sub URL         Clash subscription URL (or Base64 link list)
  --vless URI       Standalone vless://... link
  --config PATH     Path to local sing-box JSON or Clash YAML config
  --server ALIAS    Use config of a server previously set up by setup-server.sh

Other Options:
  --name NAME       Profile name to save as (e.g. clash-sub, hk-vless)
  --port PORT       Local inbound proxy port (default: 1080, supports mixed SOCKS5/HTTP)
  --clash-port PORT Local Clash API controller port for switching nodes (default: 9090)
  --force           Overwrite existing client installation without prompting

Examples:
  $0 "ssh root@1.2.3.4" --sub "https://example.com/api/v1/client/subscribe?token=xxx"
  $0 "ssh root@1.2.3.4" --vless "vless://uuid@host:443?security=reality&...#MyNode"
  $0 "ssh root@1.2.3.4" --server tokyo
EOF
    exit 1
}

[[ $# -ge 1 ]] || usage

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
fi

SSH_CMD="$1"
shift

SUB_URL=""
VLESS_URI=""
CONFIG_PATH=""
SERVER_ALIAS=""
PROFILE_NAME=""
PORT=1080
CLASH_PORT=9090
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            PROFILE_NAME="${2:?--name requires a profile name}"
            shift 2
            ;;
        --sub)
            SUB_URL="${2:?--sub requires a URL}"
            shift 2
            ;;
        --vless)
            VLESS_URI="${2:?--vless requires a URI}"
            shift 2
            ;;
        --config)
            CONFIG_PATH="${2:?--config requires a file path}"
            shift 2
            ;;
        --server)
            SERVER_ALIAS="${2:?--server requires an alias}"
            shift 2
            ;;
        --port)
            PORT="${2:?--port requires a port number}"
            shift 2
            ;;
        --clash-port)
            CLASH_PORT="${2:?--clash-port requires a port number}"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            ;;
    esac
done

# Load .env if present
ENV_FILE=""
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    ENV_FILE="${SCRIPT_DIR}/.env"
elif [[ -f ".env" ]]; then
    ENV_FILE=".env"
fi

if [[ -n "$ENV_FILE" && -z "$SUB_URL" && -z "$VLESS_URI" && -z "$CONFIG_PATH" && -z "$SERVER_ALIAS" ]]; then
    ENV_SUB=$(grep -E '^[[:space:]]*CLASH_SUBSCRIPTION_URL=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r\n' | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//' || true)
    ENV_VLESS=$(grep -E '^[[:space:]]*VLESS_URI=' "$ENV_FILE" | head -n1 | cut -d= -f2- | tr -d '\r\n' | sed -e 's/^[[:space:]]*["'\'']//' -e 's/["'\''][[:space:]]*$//' || true)

    if [[ -n "$ENV_SUB" ]]; then
        echo "==> Using CLASH_SUBSCRIPTION_URL from .env"
        SUB_URL="$ENV_SUB"
    elif [[ -n "$ENV_VLESS" ]]; then
        echo "==> Using VLESS_URI from .env"
        VLESS_URI="$ENV_VLESS"
    fi
fi

# Ensure exactly one config source is given
SOURCE_COUNT=0
[[ -n "$SUB_URL" ]] && SOURCE_COUNT=$((SOURCE_COUNT + 1))
[[ -n "$VLESS_URI" ]] && SOURCE_COUNT=$((SOURCE_COUNT + 1))
[[ -n "$CONFIG_PATH" ]] && SOURCE_COUNT=$((SOURCE_COUNT + 1))
[[ -n "$SERVER_ALIAS" ]] && SOURCE_COUNT=$((SOURCE_COUNT + 1))

if [[ "$SOURCE_COUNT" -ne 1 ]]; then
    echo "Error: Please specify exactly one config source (--sub, --vless, --config, or --server)." >&2
    usage
fi

parse_ssh_command "$SSH_CMD"
build_ssh_args
build_scp_args

echo "==> Target client: ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"

# Prepare temporary work directory
TMP_WORK=$(mktemp -d)
cleanup() { rm -rf "$TMP_WORK"; }
trap cleanup EXIT

# Run Python conversion
run_python() {
    if command -v uv >/dev/null 2>&1; then
        uv run --with pyyaml python "$@"
    else
        python3 "$@"
    fi
}

CLIENT_CONFIG="${TMP_WORK}/config.json"
echo "==> Generating sing-box client configuration..."

if [[ -n "$SUB_URL" ]]; then
    run_python "${SCRIPT_DIR}/lib/sub_converter.py" \
        --sub "$SUB_URL" \
        --port "$PORT" \
        --clash-port "$CLASH_PORT" \
        --output "$CLIENT_CONFIG"
    echo "$SUB_URL" > "${TMP_WORK}/sub_url.txt"
elif [[ -n "$VLESS_URI" ]]; then
    run_python "${SCRIPT_DIR}/lib/sub_converter.py" \
        --vless "$VLESS_URI" \
        --port "$PORT" \
        --clash-port "$CLASH_PORT" \
        --output "$CLIENT_CONFIG"
elif [[ -n "$CONFIG_PATH" ]]; then
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "Error: Config file not found: ${CONFIG_PATH}" >&2
        exit 1
    fi
    run_python "${SCRIPT_DIR}/lib/sub_converter.py" \
        --file "$CONFIG_PATH" \
        --port "$PORT" \
        --clash-port "$CLASH_PORT" \
        --output "$CLIENT_CONFIG"
elif [[ -n "$SERVER_ALIAS" ]]; then
    SERVER_DIR="${SCRIPT_DIR}/servers/${SERVER_ALIAS}"
    if [[ -f "${SERVER_DIR}/vless.txt" ]]; then
        SAVED_VLESS=$(cat "${SERVER_DIR}/vless.txt")
        run_python "${SCRIPT_DIR}/lib/sub_converter.py" \
            --vless "$SAVED_VLESS" \
            --port "$PORT" \
            --clash-port "$CLASH_PORT" \
            --output "$CLIENT_CONFIG"
    elif [[ -f "${SERVER_DIR}/client-config.json" ]]; then
        run_python "${SCRIPT_DIR}/lib/sub_converter.py" \
            --file "${SERVER_DIR}/client-config.json" \
            --port "$PORT" \
            --clash-port "$CLASH_PORT" \
            --output "$CLIENT_CONFIG"
    else
        echo "Error: Could not find client configuration in ${SERVER_DIR}" >&2
        exit 1
    fi
fi

# Determine profile metadata for initial installation
if [[ -z "$PROFILE_NAME" ]]; then
    if [[ -n "$SUB_URL" ]]; then
        PROFILE_NAME="clash-sub"
        PROFILE_TYPE="subscription"
        PROFILE_SOURCE="$SUB_URL"
    elif [[ -n "$VLESS_URI" ]]; then
        PROFILE_NAME="vless-node"
        PROFILE_TYPE="vless"
        PROFILE_SOURCE="$VLESS_URI"
    elif [[ -n "$CONFIG_PATH" ]]; then
        PROFILE_NAME="$(basename "${CONFIG_PATH%.*}")"
        PROFILE_TYPE="file"
        PROFILE_SOURCE="$CONFIG_PATH"
    elif [[ -n "$SERVER_ALIAS" ]]; then
        PROFILE_NAME="${SERVER_ALIAS}"
        PROFILE_TYPE="server"
        PROFILE_SOURCE="${SERVER_ALIAS}"
    fi
else
    if [[ -n "$SUB_URL" ]]; then
        PROFILE_TYPE="subscription"
        PROFILE_SOURCE="$SUB_URL"
    elif [[ -n "$VLESS_URI" ]]; then
        PROFILE_TYPE="vless"
        PROFILE_SOURCE="$VLESS_URI"
    elif [[ -n "$CONFIG_PATH" ]]; then
        PROFILE_TYPE="file"
        PROFILE_SOURCE="$CONFIG_PATH"
    elif [[ -n "$SERVER_ALIAS" ]]; then
        PROFILE_TYPE="server"
        PROFILE_SOURCE="${SERVER_ALIAS}"
    fi
fi

cat > "${TMP_WORK}/profile_info.json" <<EOF
{
  "name": "${PROFILE_NAME}",
  "type": "${PROFILE_TYPE}",
  "source": "${PROFILE_SOURCE}",
  "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
echo "${PROFILE_NAME}" > "${TMP_WORK}/current_profile.txt"

# Prepare service and profile templates
sed "s|{{PORT}}|${PORT}|g" "${SCRIPT_DIR}/templates/profile-proxy.sh.tpl" > "${TMP_WORK}/profile-proxy.sh"
cp "${SCRIPT_DIR}/templates/sing-box-client.service.tpl" "${TMP_WORK}/sing-box-client.service"
cp "${SCRIPT_DIR}/lib/proxy-node" "${TMP_WORK}/proxy-node"
chmod +x "${TMP_WORK}/proxy-node"

echo "==> Uploading files to ${SSH_USER}@${SSH_HOST}:/tmp/singbox-client-setup/ ..."
ssh "${SSH_ARGS[@]}" "mkdir -p /tmp/singbox-client-setup"

FILES_TO_UPLOAD=(
    "${CLIENT_CONFIG}"
    "${TMP_WORK}/sing-box-client.service"
    "${TMP_WORK}/proxy-node"
    "${TMP_WORK}/profile-proxy.sh"
    "${TMP_WORK}/profile_info.json"
    "${TMP_WORK}/current_profile.txt"
    "${SCRIPT_DIR}/lib/dproxy"
    "${SCRIPT_DIR}/lib/sub_converter.py"
    "${SCRIPT_DIR}/lib/remote_client_install.sh"
)
if [[ -f "${TMP_WORK}/sub_url.txt" ]]; then
    FILES_TO_UPLOAD+=("${TMP_WORK}/sub_url.txt")
fi

scp "${SCP_ARGS[@]}" "${FILES_TO_UPLOAD[@]}" "${SSH_USER}@${SSH_HOST}:/tmp/singbox-client-setup/"

echo "==> Running remote client installer..."
set +e
REMOTE_OUTPUT=$(ssh "${SSH_ARGS[@]}" \
    "chmod +x /tmp/singbox-client-setup/remote_client_install.sh && /tmp/singbox-client-setup/remote_client_install.sh ${PORT}" 2>&1)
REMOTE_STATUS=$?
set -e

echo "$REMOTE_OUTPUT"

if [[ $REMOTE_STATUS -ne 0 ]] || ! grep -q "SINGBOX_CLIENT_SETUP_OK" <<<"$REMOTE_OUTPUT"; then
    echo "==> Client installation failed on remote host. Aborting." >&2
    exit 1
fi

echo ""
echo "================================================================="
echo "==> sing-box client installed and started successfully!"
echo "================================================================="
echo "    Target Host:       ${SSH_HOST}"
echo "    Mixed Proxy Port:  127.0.0.1:${PORT} (HTTP & SOCKS5)"
echo "    Clash API Port:    127.0.0.1:${CLASH_PORT} (Internal Controller)"
echo "    Service Name:      sing-box-client (auto-starts on boot)"
echo ""
echo "    Environment Proxy in Shell (Default: OFF):"
echo "      proxy on        - Enable environment proxy for current shell"
echo "      proxy off       - Disable environment proxy"
echo "      proxy status    - Check proxy environment and client service status"
echo "      proxy test      - Test outbound IP through proxy"
echo ""
echo "    Node Management (CLI tool on remote server):"
echo "      pnode           - List all available nodes & show current active node"
echo "      pnode switch    - Interactive prompt to select a node"
echo "      pnode <number>  - Quick switch to node by number (e.g. 'pnode 2')"
echo "      pnode test      - Test latency and outbound IP"
echo ""
echo "    Config Profile Management:"
echo "      pnode profile   - List configured config profiles (or: pnode profiles)"
echo "      pnode profile use <name|#> - Switch active config profile (restart service)"
echo "      pnode profile del <name|#> - Delete a configured profile"
echo "      pnode profile save <name>  - Save current config as named profile"
echo "      pnode profile add <name> <url|vless|file> - Add a new config profile"
echo "======================================================================="
echo ""
