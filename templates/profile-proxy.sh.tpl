# Local proxy environment helper (Default: OFF)
export SINGBOX_PROXY_PORT={{PORT}}

unalias proxy 2>/dev/null || true
unalias proxy_on 2>/dev/null || true
unalias proxy_off 2>/dev/null || true
unalias proxy_status 2>/dev/null || true
unalias proxy_test 2>/dev/null || true

proxy() {
    local action="${1:-status}"
    case "$action" in
        on|enable)
            export http_proxy="http://127.0.0.1:${SINGBOX_PROXY_PORT}"
            export https_proxy="http://127.0.0.1:${SINGBOX_PROXY_PORT}"
            export HTTP_PROXY="http://127.0.0.1:${SINGBOX_PROXY_PORT}"
            export HTTPS_PROXY="http://127.0.0.1:${SINGBOX_PROXY_PORT}"
            export all_proxy="socks5://127.0.0.1:${SINGBOX_PROXY_PORT}"
            export ALL_PROXY="socks5://127.0.0.1:${SINGBOX_PROXY_PORT}"
            export no_proxy="localhost,127.0.0.1,::1"
            export NO_PROXY="localhost,127.0.0.1,::1"
            echo -e "\033[32m[✓] Proxy environment enabled (127.0.0.1:${SINGBOX_PROXY_PORT})\033[0m"
            ;;
        off|disable)
            unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
            echo -e "\033[33m[!] Proxy environment disabled\033[0m"
            ;;
        status)
            echo "--- Proxy Status ---"
            if [ -n "${http_proxy:-}" ] || [ -n "${all_proxy:-}" ]; then
                echo -e "Env Proxy:   \033[32mENABLED\033[0m"
                echo "  http_proxy:  ${http_proxy:-}"
                echo "  all_proxy:   ${all_proxy:-}"
            else
                echo -e "Env Proxy:   \033[33mDISABLED (default)\033[0m"
            fi
            if command -v systemctl >/dev/null 2>&1; then
                local svc_status
                svc_status=$(systemctl is-active sing-box-client 2>/dev/null || echo "inactive")
                if [ "$svc_status" = "active" ]; then
                    echo -e "Service:     \033[32mactive (sing-box-client)\033[0m"
                else
                    echo -e "Service:     \033[31m${svc_status} (sing-box-client)\033[0m"
                fi
            fi
            if command -v proxy-node >/dev/null 2>&1; then
                local cur_node
                cur_node=$(proxy-node current 2>/dev/null || echo "unknown")
                echo "Active Node: ${cur_node}"
            fi
            echo ""
            echo "Commands: proxy on | proxy off | proxy status | proxy test | pnode"
            ;;
        test)
            echo "Testing proxy connection through 127.0.0.1:${SINGBOX_PROXY_PORT}..."
            local out_ip
            out_ip=$(curl -s -m 5 -x "http://127.0.0.1:${SINGBOX_PROXY_PORT}" https://api.ipify.org 2>/dev/null || curl -s -m 5 -x "http://127.0.0.1:${SINGBOX_PROXY_PORT}" https://ifconfig.me 2>/dev/null || echo "")
            if [ -n "$out_ip" ]; then
                echo -e "\033[32m[✓] Proxy working! Outbound IP: ${out_ip}\033[0m"
            else
                echo -e "\033[31m[✗] Proxy test failed (timed out or connection refused)\033[0m"
            fi
            ;;
        *)
            echo "Usage: proxy [on|off|status|test]"
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
