# Local proxy environment helper (Default: OFF)
export SINGBOX_PROXY_PORT={{PORT}}

unalias proxy 2>/dev/null || true
unalias proxy_on 2>/dev/null || true
unalias proxy_off 2>/dev/null || true
unalias proxy_status 2>/dev/null || true
unalias proxy_test 2>/dev/null || true

proxy() {
    local arg1="${1:-status}"
    local action="status"
    local target_port=""

    if [[ "$arg1" =~ ^[0-9]+$ ]]; then
        action="on"
        target_port="$arg1"
    else
        action="$arg1"
        target_port="${2:-${SINGBOX_PROXY_PORT:-1080}}"
    fi

    case "$action" in
        on|enable)
            export http_proxy="http://127.0.0.1:${target_port}"
            export https_proxy="http://127.0.0.1:${target_port}"
            export HTTP_PROXY="http://127.0.0.1:${target_port}"
            export HTTPS_PROXY="http://127.0.0.1:${target_port}"
            export all_proxy="socks5://127.0.0.1:${target_port}"
            export ALL_PROXY="socks5://127.0.0.1:${target_port}"
            export no_proxy="localhost,127.0.0.1,::1,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"
            export NO_PROXY="localhost,127.0.0.1,::1,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"
            echo -e "\033[32m[✓] Proxy environment enabled (127.0.0.1:${target_port})\033[0m"
            ;;
        off|disable)
            unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
            echo -e "\033[33m[!] Proxy environment disabled\033[0m"
            ;;
        status)
            echo "--- Proxy Status ---"
            local cur_p=""
            if [ -n "${http_proxy:-}" ]; then
                cur_p=$(echo "$http_proxy" | grep -oE '[0-9]+$' || echo "1080")
                echo -e "Env Proxy:   \033[32mENABLED (Port ${cur_p})\033[0m"
                echo "  http_proxy:  ${http_proxy:-}"
                echo "  all_proxy:   ${all_proxy:-}"
            else
                echo -e "Env Proxy:   \033[33mDISABLED (default)\033[0m"
            fi
            if command -v proxy-node >/dev/null 2>&1; then
                cur_p="${cur_p:-1080}"
                local cur_node
                cur_node=$(proxy-node "$cur_p" current 2>/dev/null || proxy-node current 2>/dev/null || echo "unknown")
                echo "Active Node: ${cur_node} (Port ${cur_p})"
            fi
            echo ""
            echo "Commands: proxy on [port] | proxy off | proxy status | proxy test [port] | pnode"
            ;;
        test)
            local test_p="$target_port"
            if [ -z "$2" ] && [ -n "${http_proxy:-}" ]; then
                test_p=$(echo "$http_proxy" | grep -oE '[0-9]+$' || echo "$target_port")
            fi
            echo "Testing proxy connection through 127.0.0.1:${test_p}..."
            local out_ip
            out_ip=$(curl -s -m 5 -x "http://127.0.0.1:${test_p}" https://api.ipify.org 2>/dev/null || curl -s -m 5 -x "http://127.0.0.1:${test_p}" https://ifconfig.me 2>/dev/null || echo "")
            if [ -n "$out_ip" ]; then
                echo -e "\033[32m[✓] Proxy working on Port ${test_p}! Outbound IP: ${out_ip}\033[0m"
            else
                echo -e "\033[31m[✗] Proxy test failed on Port ${test_p} (timed out or connection refused)\033[0m"
            fi
            ;;
        *)
            echo "Usage: proxy [on [port]|off|status|test [port]]"
            ;;
    esac
}

# Aliases
alias proxy_on="proxy on"
alias proxy_off="proxy off"
alias proxy_status="proxy status"
alias proxy_test="proxy test"
alias pnode="proxy-node"
alias dproxy="docker run --env-file /etc/sing-box-client/docker-proxy.env"
# <<< singbox-helper proxy environment <<<
