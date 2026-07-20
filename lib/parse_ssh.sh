#!/usr/bin/env bash
# Parses an ssh command string (as you'd type it on the CLI) into:
#   SSH_USER, SSH_HOST, SSH_PORT (default 22), SSH_IDENTITY (empty if none)
#
# Supports things like:
#   ssh root@1.2.3.4
#   ssh -i ~/.ssh/sean root@1.2.3.4
#   ssh -i ~/.ssh/sean -p 2222 user@host.example.com
#   ssh -p 2222 -i ~/.ssh/sean user@host.example.com
#
# Usage: parse_ssh_command "<ssh command string>"
# On success sets SSH_USER/SSH_HOST/SSH_PORT/SSH_IDENTITY and returns 0.
# On failure prints an error to stderr and returns 1.

parse_ssh_command() {
    local raw="$1"
    # shellcheck disable=SC2206 # intentional word-splitting of a user-typed ssh command
    local words=($raw)

    if [[ "${words[0]}" != "ssh" ]]; then
        echo "parse_ssh_command: expected command to start with 'ssh', got: $raw" >&2
        return 1
    fi

    SSH_PORT=22
    SSH_IDENTITY=""
    local target=""

    local i=1
    while [[ $i -lt ${#words[@]} ]]; do
        local w="${words[$i]}"
        case "$w" in
            -i)
                i=$((i + 1))
                SSH_IDENTITY="${words[$i]}"
                ;;
            -p)
                i=$((i + 1))
                SSH_PORT="${words[$i]}"
                ;;
            -i*)
                SSH_IDENTITY="${w#-i}"
                ;;
            -p*)
                SSH_PORT="${w#-p}"
                ;;
            -*)
                # unrecognized flag - ignore it (and its value if it looks like a separate token
                # is not something we understand); we only care about -i/-p/user@host
                ;;
            *)
                target="$w"
                ;;
        esac
        i=$((i + 1))
    done

    if [[ -z "$target" ]]; then
        echo "parse_ssh_command: could not find a user@host target in: $raw" >&2
        return 1
    fi

    if [[ "$target" != *"@"* ]]; then
        echo "parse_ssh_command: target '$target' must be in user@host form" >&2
        return 1
    fi

    SSH_USER="${target%%@*}"
    SSH_HOST="${target#*@}"

    if [[ -z "$SSH_USER" || -z "$SSH_HOST" ]]; then
        echo "parse_ssh_command: could not parse user/host from '$target'" >&2
        return 1
    fi

    return 0
}

# Builds an `ssh` argument array (into the SSH_ARGS bash array) from the parsed
# SSH_USER/SSH_HOST/SSH_PORT/SSH_IDENTITY globals. Caller must have run
# parse_ssh_command first.
build_ssh_args() {
    SSH_ARGS=(-p "$SSH_PORT")
    if [[ -n "$SSH_IDENTITY" ]]; then
        SSH_ARGS+=(-i "$SSH_IDENTITY")
    fi
    SSH_ARGS+=("${SSH_USER}@${SSH_HOST}")
}

# Same as build_ssh_args but for `scp` (which uses -P for port, not -p).
build_scp_args() {
    SCP_ARGS=(-P "$SSH_PORT")
    if [[ -n "$SSH_IDENTITY" ]]; then
        SCP_ARGS+=(-i "$SSH_IDENTITY")
    fi
}
