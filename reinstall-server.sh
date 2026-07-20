#!/usr/bin/env bash
# Reinstalls a sing-box server previously set up with setup-server.sh, using
# the ssh command already saved for it - no need to type it again. This is
# equivalent to `setup-server.sh "<saved ssh command>" --name <alias> --force`:
# it regenerates the port/UUID/keys and overwrites the existing service.
#
# Usage:
#   ./reinstall-server.sh myserver
#   ./reinstall-server.sh myserver --sni www.apple.com

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<EOF
Usage: $0 <alias> [--sni DOMAIN]

Examples:
  $0 myserver
  $0 myserver --sni www.apple.com

Re-runs setup-server.sh --force against the ssh command already saved for
this alias, keeping its existing --sni unless you override it here.
EOF
    exit 1
}

[[ $# -ge 1 ]] || usage

ALIAS="$1"
shift

SNI_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sni)
            SNI_OVERRIDE="${2:?--sni requires a value}"
            shift 2
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

if [[ -n "$SNI_OVERRIDE" ]]; then
    SNI="$SNI_OVERRIDE"
fi

echo "==> Reinstalling '${ALIAS}' (${HOST}) with sni: ${SNI}..."
exec "${SCRIPT_DIR}/setup-server.sh" "$SSH_COMMAND" --name "$ALIAS" --sni "$SNI" --force
