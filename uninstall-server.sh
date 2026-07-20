#!/usr/bin/env bash
# Removes a sing-box server previously set up with setup-server.sh: stops and
# removes the systemd service and config on the remote host, then deletes the
# local servers/<alias>/ directory.
#
# Usage:
#   ./uninstall-server.sh myserver
#   ./uninstall-server.sh myserver --yes
#   ./uninstall-server.sh myserver --purge-binary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse_ssh.sh
source "${SCRIPT_DIR}/lib/parse_ssh.sh"

usage() {
    cat >&2 <<EOF
Usage: $0 <alias> [--yes] [--purge-binary]

Examples:
  $0 myserver
  $0 myserver --yes
  $0 myserver --purge-binary

--yes           skip the confirmation prompt
--purge-binary  also remove the sing-box binary from the remote host
                (left in place by default, since it's harmless and shared
                across reinstalls)
EOF
    exit 1
}

[[ $# -ge 1 ]] || usage

ALIAS="$1"
shift

CONFIRM=1
PURGE_BINARY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)
            CONFIRM=0
            shift
            ;;
        --purge-binary)
            PURGE_BINARY=1
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            ;;
    esac
done

SERVER_DIR="${SCRIPT_DIR}/servers/${ALIAS}"
INFO_FILE="${SERVER_DIR}/info.env"

if [[ ! -e "$INFO_FILE" ]]; then
    echo "No server named '${ALIAS}' found at ${SERVER_DIR}." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$INFO_FILE"

if [[ "$CONFIRM" -eq 1 ]]; then
    read -r -p "This will remove the sing-box service from ${HOST} (alias '${ALIAS}') and delete ${SERVER_DIR}. Continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

parse_ssh_command "$SSH_COMMAND"
build_ssh_args
build_scp_args

echo "==> Removing sing-box from ${SSH_USER}@${SSH_HOST}:${PORT}..."

ssh "${SSH_ARGS[@]}" "mkdir -p /tmp/singbox-setup"
scp "${SCP_ARGS[@]}" "${SCRIPT_DIR}/lib/remote_uninstall.sh" "${SSH_USER}@${SSH_HOST}:/tmp/singbox-setup/"

UNINSTALL_ARGS="${PORT}"
if [[ "$PURGE_BINARY" -eq 1 ]]; then
    UNINSTALL_ARGS="${PORT} --purge-binary"
fi

set +e
REMOTE_OUTPUT=$(ssh "${SSH_ARGS[@]}" \
    "chmod +x /tmp/singbox-setup/remote_uninstall.sh && /tmp/singbox-setup/remote_uninstall.sh ${UNINSTALL_ARGS}" 2>&1)
REMOTE_STATUS=$?
set -e

echo "$REMOTE_OUTPUT"

if [[ $REMOTE_STATUS -ne 0 ]] || ! grep -q "SINGBOX_UNINSTALL_OK" <<<"$REMOTE_OUTPUT"; then
    echo "==> Remote uninstall did not report success. Local server directory left in place." >&2
    exit 1
fi

rm -rf "$SERVER_DIR"
echo "==> Done. Removed ${SERVER_DIR} and the remote sing-box service."
