#!/usr/bin/env bash
# Removes sing-box-client service, configs, proxy-node CLI tool, and profile helpers from a remote host.
#
# Usage:
#   ./uninstall-client.sh "ssh root@1.2.3.4"
#   ./uninstall-client.sh "ssh root@1.2.3.4" --yes
#   ./uninstall-client.sh "ssh root@1.2.3.4" --purge-binary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parse_ssh.sh
source "${SCRIPT_DIR}/lib/parse_ssh.sh"

usage() {
    cat >&2 <<EOF
Usage: $0 "<ssh command>" [--yes] [--purge-binary]

Examples:
  $0 "ssh root@1.2.3.4"
  $0 "ssh -i ~/.ssh/id_rsa root@1.2.3.4" --yes
  $0 "ssh root@1.2.3.4" --purge-binary

--yes           skip confirmation prompt
--purge-binary  also remove /usr/local/bin/sing-box binary (if not used by server)
EOF
    exit 1
}

[[ $# -ge 1 ]] || usage

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
fi

SSH_CMD="$1"
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

parse_ssh_command "$SSH_CMD"
build_ssh_args
build_scp_args

if [[ "$CONFIRM" -eq 1 ]]; then
    read -r -p "This will remove sing-box-client from ${SSH_USER}@${SSH_HOST}. Continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

echo "==> Removing sing-box-client from ${SSH_USER}@${SSH_HOST}..."

ssh "${SSH_ARGS[@]}" "mkdir -p /tmp/singbox-client-setup"
scp "${SCP_ARGS[@]}" "${SCRIPT_DIR}/lib/remote_client_uninstall.sh" "${SSH_USER}@${SSH_HOST}:/tmp/singbox-client-setup/"

UNINSTALL_ARGS=""
if [[ "$PURGE_BINARY" -eq 1 ]]; then
    UNINSTALL_ARGS="--purge-binary"
fi

set +e
REMOTE_OUTPUT=$(ssh "${SSH_ARGS[@]}" \
    "chmod +x /tmp/singbox-client-setup/remote_client_uninstall.sh && /tmp/singbox-client-setup/remote_client_uninstall.sh ${UNINSTALL_ARGS}" 2>&1)
REMOTE_STATUS=$?
set -e

echo "$REMOTE_OUTPUT"

if [[ $REMOTE_STATUS -ne 0 ]] || ! grep -q "SINGBOX_CLIENT_UNINSTALL_OK" <<<"$REMOTE_OUTPUT"; then
    echo "==> Remote client uninstall did not report success. Aborting." >&2
    exit 1
fi

echo "==> Done. sing-box-client removed from ${SSH_HOST}."
