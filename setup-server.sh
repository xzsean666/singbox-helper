#!/usr/bin/env bash
# Sets up a sing-box (VLESS + Reality) proxy server on a remote host, given the
# ssh command you'd normally use to log into it.
#
# Usage:
#   ./setup-server.sh "ssh root@1.2.3.4"
#   ./setup-server.sh "ssh -i ~/.ssh/sean root@1.2.3.4" --name myserver
#   ./setup-server.sh "ssh -i ~/.ssh/sean root@1.2.3.4" --sni www.apple.com
#   ./setup-server.sh "ssh -i ~/.ssh/sean root@1.2.3.4" --force
#
# Requires passwordless sudo (or a root login) on the remote host - see README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse_ssh.sh
source "${SCRIPT_DIR}/lib/parse_ssh.sh"

usage() {
    cat >&2 <<EOF
Usage: $0 "<ssh command>" [--name ALIAS] [--sni DOMAIN] [--force]

Examples:
  $0 "ssh root@1.2.3.4"
  $0 "ssh -i ~/.ssh/sean root@1.2.3.4" --name myserver
  $0 "ssh -i ~/.ssh/sean root@1.2.3.4" --sni www.apple.com

--sni sets the camouflage domain Reality impersonates (default: www.microsoft.com).
It must be a real, internet-reachable site that speaks TLS 1.3 on port 443.
EOF
    exit 1
}

[[ $# -ge 1 ]] || usage

SSH_CMD="$1"
shift

ALIAS=""
FORCE=0
SNI="www.microsoft.com"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            ALIAS="${2:?--name requires a value}"
            shift 2
            ;;
        --sni)
            SNI="${2:?--sni requires a value}"
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

parse_ssh_command "$SSH_CMD"
build_ssh_args
build_scp_args

if [[ -z "$ALIAS" ]]; then
    ALIAS=$(echo "$SSH_HOST" | tr -c 'a-zA-Z0-9' '-')
fi

SERVER_DIR="${SCRIPT_DIR}/servers/${ALIAS}"
if [[ -e "${SERVER_DIR}/info.env" && "$FORCE" -ne 1 ]]; then
    echo "A server named '${ALIAS}' already exists at ${SERVER_DIR}." >&2
    echo "Use --name <other-alias> to set up a new server, or --force to overwrite this one." >&2
    exit 1
fi

echo "==> Target: ${SSH_USER}@${SSH_HOST}:${SSH_PORT} (alias: ${ALIAS}, sni: ${SNI})"

gen_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        python3 -c 'import uuid; print(uuid.uuid4())'
    fi
}

UUID=$(gen_uuid)
SHORT_ID=$(openssl rand -hex 8)

TMP_WORK=$(mktemp -d)
cleanup() { rm -rf "$TMP_WORK"; }
trap cleanup EXIT

cp "${SCRIPT_DIR}/templates/server-config.json.tpl" "${TMP_WORK}/server-config.json.tpl"
cp "${SCRIPT_DIR}/templates/sing-box.service.tpl" "${TMP_WORK}/sing-box.service"

MAX_ATTEMPTS=5
ATTEMPT=1
REMOTE_OUTPUT=""
SUCCESS=0

while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
    PORT=$(( (RANDOM % 40000) + 20000 ))
    echo "==> Attempt ${ATTEMPT}/${MAX_ATTEMPTS}: trying port ${PORT}"

    ssh "${SSH_ARGS[@]}" "mkdir -p /tmp/singbox-setup"
    scp "${SCP_ARGS[@]}" \
        "${TMP_WORK}/server-config.json.tpl" \
        "${TMP_WORK}/sing-box.service" \
        "${SCRIPT_DIR}/lib/remote_install.sh" \
        "${SSH_USER}@${SSH_HOST}:/tmp/singbox-setup/"

    set +e
    REMOTE_OUTPUT=$(ssh "${SSH_ARGS[@]}" \
        "chmod +x /tmp/singbox-setup/remote_install.sh && /tmp/singbox-setup/remote_install.sh ${PORT} ${UUID} ${SHORT_ID} ${SNI}" 2>&1)
    REMOTE_STATUS=$?
    set -e

    echo "$REMOTE_OUTPUT"

    if [[ $REMOTE_STATUS -eq 0 ]] && grep -q "SINGBOX_SETUP_OK" <<<"$REMOTE_OUTPUT"; then
        SUCCESS=1
        break
    elif grep -q "SINGBOX_SETUP_PORT_TAKEN" <<<"$REMOTE_OUTPUT"; then
        echo "==> Port ${PORT} is already taken on the remote host, trying another..."
        ATTEMPT=$((ATTEMPT + 1))
        continue
    else
        echo "==> Remote install failed (exit ${REMOTE_STATUS}). Aborting." >&2
        exit 1
    fi
done

if [[ "$SUCCESS" -ne 1 ]]; then
    echo "==> Failed to find a free port after ${MAX_ATTEMPTS} attempts." >&2
    exit 1
fi

PUBLIC_KEY=$(sed -n 's/^SINGBOX_PUBLIC_KEY=//p' <<<"$REMOTE_OUTPUT" | tail -n1)
if [[ -z "$PUBLIC_KEY" ]]; then
    echo "==> Remote install reported success but no public key was returned. Aborting." >&2
    exit 1
fi

echo "==> sing-box installed and running on ${SSH_HOST}:${PORT}"

mkdir -p "$SERVER_DIR"
cat > "${SERVER_DIR}/info.env" <<EOF
HOST=${SSH_HOST}
PORT=${PORT}
UUID=${UUID}
SHORT_ID=${SHORT_ID}
SNI=${SNI}
PUBLIC_KEY=${PUBLIC_KEY}
SSH_COMMAND=${SSH_CMD}
EOF

render_client_config() {
    sed -e "s|{{PORT}}|${PORT}|g" \
        -e "s|{{HOST}}|${SSH_HOST}|g" \
        -e "s|{{UUID}}|${UUID}|g" \
        -e "s|{{SHORT_ID}}|${SHORT_ID}|g" \
        -e "s|{{SNI}}|${SNI}|g" \
        -e "s|{{PUBLIC_KEY}}|${PUBLIC_KEY}|g" \
        "$1" > "$2"
}
render_client_config "${SCRIPT_DIR}/templates/client-config.json.tpl" "${SERVER_DIR}/client-config.json"

mkdir -p "${SCRIPT_DIR}/examples/docker-client/config"
cp "${SERVER_DIR}/client-config.json" "${SCRIPT_DIR}/examples/docker-client/config/sing-box-client.json"

VLESS_URI="vless://${UUID}@${SSH_HOST}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${ALIAS}"

echo ""
echo "==> Done. Server info saved to ${SERVER_DIR}/"
echo "    (The private key never leaves the server - only the public key was returned.)"
echo "    Host:       ${SSH_HOST}"
echo "    Port:       ${PORT}"
echo "    UUID:       ${UUID}"
echo "    SNI:        ${SNI}"
echo "    Public key: ${PUBLIC_KEY}"
echo "    Short ID:   ${SHORT_ID}"
echo ""
echo "    vless:// link (import into v2rayN/NekoBox/Shadowrocket/etc.):"
echo "    ${VLESS_URI}"
echo ""
echo "    Docker client example is ready at: examples/docker-client/"
echo "    Run: cd examples/docker-client && docker compose up -d"
