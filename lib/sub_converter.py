#!/usr/bin/env python3
"""
Convert Clash subscription, Clash YAML, Base64 proxy links, or single VLESS URI
into a sing-box client configuration JSON.
"""

import argparse
import base64
import json
import os
import re
import sys
import urllib.parse
import urllib.request

try:
    import yaml
except ImportError:
    yaml = None


def make_unique_tag(tag, existing_tags):
    tag = tag.strip() or "node"
    if tag not in existing_tags:
        existing_tags.add(tag)
        return tag
    count = 2
    while f"{tag} ({count})" in existing_tags:
        count += 1
    new_tag = f"{tag} ({count})"
    existing_tags.add(new_tag)
    return new_tag


def parse_vless_uri(uri, idx=1, existing_tags=None):
    parsed = urllib.parse.urlparse(uri)
    uuid = parsed.username
    host = parsed.hostname
    port = parsed.port or 443
    query = urllib.parse.parse_qs(parsed.query)
    raw_tag = urllib.parse.unquote(parsed.fragment) if parsed.fragment else f"vless-{idx}"
    tag = make_unique_tag(raw_tag, existing_tags if existing_tags is not None else set())

    flow = query.get("flow", [""])[0]
    security = query.get("security", [""])[0]
    sni = query.get("sni", [""])[0] or host
    fp = query.get("fp", ["chrome"])[0]
    pbk = query.get("pbk", [""])[0]
    sid = query.get("sid", [""])[0]
    net_type = query.get("type", ["tcp"])[0]
    path = query.get("path", ["/"])[0]

    out = {
        "type": "vless",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "uuid": uuid,
    }
    if flow:
        out["flow"] = flow

    if security in ("reality", "tls"):
        tls_cfg = {
            "enabled": True,
            "server_name": sni,
        }
        if fp:
            tls_cfg["utls"] = {"enabled": True, "fingerprint": fp}
        if security == "reality":
            tls_cfg["reality"] = {
                "enabled": True,
                "public_key": pbk,
                "short_id": sid,
            }
        out["tls"] = tls_cfg

    if net_type == "ws":
        out["transport"] = {
            "type": "ws",
            "path": path,
            "headers": {"Host": query.get("host", [""])[0] or sni},
        }
    elif net_type == "grpc":
        out["transport"] = {
            "type": "grpc",
            "service_name": query.get("serviceName", [""])[0],
        }

    return out


def parse_vmess_uri(uri, idx=1, existing_tags=None):
    raw_b64 = uri[len("vmess://") :]
    # Fix padding
    missing_padding = len(raw_b64) % 4
    if missing_padding:
        raw_b64 += "=" * (4 - missing_padding)
    decoded = base64.b64decode(raw_b64).decode("utf-8", errors="ignore")
    info = json.loads(decoded)

    raw_tag = info.get("ps", f"vmess-{idx}")
    tag = make_unique_tag(raw_tag, existing_tags if existing_tags is not None else set())
    host = info.get("add")
    port = int(info.get("port", 443))
    uuid = info.get("id")
    aid = int(info.get("aid", 0))
    net = info.get("net", "tcp")
    tls_str = info.get("tls", "")

    out = {
        "type": "vmess",
        "tag": tag,
        "server": host,
        "server_port": port,
        "uuid": uuid,
        "security": "auto",
        "alter_id": aid,
    }
    if tls_str == "tls":
        tls_cfg = {
            "enabled": True,
            "server_name": info.get("sni") or info.get("host") or host,
        }
        fp = info.get("fp")
        if fp:
            tls_cfg["utls"] = {"enabled": True, "fingerprint": fp}
        out["tls"] = tls_cfg

    if net == "ws":
        out["transport"] = {
            "type": "ws",
            "path": info.get("path", "/"),
            "headers": {"Host": info.get("host", "")},
        }
    elif net == "grpc":
        out["transport"] = {
            "type": "grpc",
            "service_name": info.get("path", ""),
        }
    return out


def parse_trojan_uri(uri, idx=1, existing_tags=None):
    parsed = urllib.parse.urlparse(uri)
    password = parsed.username
    host = parsed.hostname
    port = parsed.port or 443
    query = urllib.parse.parse_qs(parsed.query)
    raw_tag = urllib.parse.unquote(parsed.fragment) if parsed.fragment else f"trojan-{idx}"
    tag = make_unique_tag(raw_tag, existing_tags if existing_tags is not None else set())
    sni = query.get("sni", [""])[0] or host

    out = {
        "type": "trojan",
        "tag": tag,
        "server": host,
        "server_port": int(port),
        "password": password,
        "tls": {
            "enabled": True,
            "server_name": sni,
        },
    }
    net_type = query.get("type", ["tcp"])[0]
    if net_type == "ws":
        out["transport"] = {
            "type": "ws",
            "path": query.get("path", ["/"])[0],
            "headers": {"Host": query.get("host", [""])[0] or sni},
        }
    elif net_type == "grpc":
        out["transport"] = {
            "type": "grpc",
            "service_name": query.get("serviceName", [""])[0],
        }
    return out


def parse_ss_uri(uri, idx=1, existing_tags=None):
    raw = uri[len("ss://") :]
    tag_part = ""
    if "#" in raw:
        raw, tag_part = raw.split("#", 1)
        tag_part = urllib.parse.unquote(tag_part)
    raw_tag = tag_part or f"ss-{idx}"
    tag = make_unique_tag(raw_tag, existing_tags if existing_tags is not None else set())

    # Format 1: base64(method:password@host:port)
    # Format 2: base64(method:password)@host:port
    if "@" in raw:
        user_info, host_port = raw.split("@", 1)
        try:
            missing_padding = len(user_info) % 4
            if missing_padding:
                user_info += "=" * (4 - missing_padding)
            decoded_user = base64.b64decode(user_info).decode("utf-8")
            if ":" in decoded_user:
                method, password = decoded_user.split(":", 1)
            else:
                method, password = user_info.split(":", 1)
        except Exception:
            method, password = user_info.split(":", 1)
        host, port = host_port.split(":", 1)
        port = int(port.split("/")[0].split("?")[0])
    else:
        missing_padding = len(raw) % 4
        if missing_padding:
            raw += "=" * (4 - missing_padding)
        decoded = base64.b64decode(raw).decode("utf-8")
        user_info, host_port = decoded.split("@", 1)
        method, password = user_info.split(":", 1)
        host, port = host_port.split(":", 1)
        port = int(port.split("/")[0].split("?")[0])

    return {
        "type": "shadowsocks",
        "tag": tag,
        "server": host,
        "server_port": port,
        "method": method,
        "password": password,
    }


def parse_clash_proxy(p, idx=1, existing_tags=None):
    ptype = str(p.get("type", "")).lower()
    raw_tag = str(p.get("name", f"node-{idx}"))
    tag = make_unique_tag(raw_tag, existing_tags if existing_tags is not None else set())
    server = str(p.get("server", ""))
    port = int(p.get("port", 0))

    if ptype == "vless":
        out = {
            "type": "vless",
            "tag": tag,
            "server": server,
            "server_port": port,
            "uuid": str(p.get("uuid", "")),
        }
        if p.get("flow"):
            out["flow"] = p["flow"]

        tls_enabled = bool(p.get("tls")) or bool(p.get("reality-opts"))
        if tls_enabled:
            tls_cfg = {
                "enabled": True,
                "server_name": p.get("servername") or p.get("sni") or server,
                "insecure": bool(p.get("skip-cert-verify", False)),
            }
            fp = p.get("client-fingerprint", "chrome")
            if fp:
                tls_cfg["utls"] = {"enabled": True, "fingerprint": fp}
            reality = p.get("reality-opts")
            if reality:
                tls_cfg["reality"] = {
                    "enabled": True,
                    "public_key": reality.get("public-key", ""),
                    "short_id": reality.get("short-id", ""),
                }
            out["tls"] = tls_cfg

        net = p.get("network", "tcp")
        if net == "ws":
            ws_opts = p.get("ws-opts", {}) or {}
            out["transport"] = {
                "type": "ws",
                "path": ws_opts.get("path", "/"),
                "headers": ws_opts.get("headers", {}),
            }
        elif net == "grpc":
            grpc_opts = p.get("grpc-opts", {}) or {}
            out["transport"] = {
                "type": "grpc",
                "service_name": grpc_opts.get("grpc-service-name", ""),
            }
        return out

    elif ptype == "vmess":
        out = {
            "type": "vmess",
            "tag": tag,
            "server": server,
            "server_port": port,
            "uuid": str(p.get("uuid", "")),
            "security": p.get("cipher", "auto"),
            "alter_id": int(p.get("alterId", 0)),
        }
        if p.get("tls"):
            tls_cfg = {
                "enabled": True,
                "server_name": p.get("servername") or p.get("sni") or server,
                "insecure": bool(p.get("skip-cert-verify", False)),
            }
            fp = p.get("client-fingerprint")
            if fp:
                tls_cfg["utls"] = {"enabled": True, "fingerprint": fp}
            out["tls"] = tls_cfg

        net = p.get("network", "tcp")
        if net == "ws":
            ws_opts = p.get("ws-opts", {}) or {}
            out["transport"] = {
                "type": "ws",
                "path": ws_opts.get("path", "/"),
                "headers": ws_opts.get("headers", {}),
            }
        elif net == "grpc":
            grpc_opts = p.get("grpc-opts", {}) or {}
            out["transport"] = {
                "type": "grpc",
                "service_name": grpc_opts.get("grpc-service-name", ""),
            }
        return out

    elif ptype in ("ss", "shadowsocks"):
        out = {
            "type": "shadowsocks",
            "tag": tag,
            "server": server,
            "server_port": port,
            "method": p.get("cipher"),
            "password": str(p.get("password", "")),
        }
        return out

    elif ptype == "trojan":
        out = {
            "type": "trojan",
            "tag": tag,
            "server": server,
            "server_port": port,
            "password": str(p.get("password", "")),
            "tls": {
                "enabled": True,
                "server_name": p.get("sni") or p.get("servername") or server,
                "insecure": bool(p.get("skip-cert-verify", False)),
            },
        }
        net = p.get("network", "tcp")
        if net == "ws":
            ws_opts = p.get("ws-opts", {}) or {}
            out["transport"] = {
                "type": "ws",
                "path": ws_opts.get("path", "/"),
                "headers": ws_opts.get("headers", {}),
            }
        elif net == "grpc":
            grpc_opts = p.get("grpc-opts", {}) or {}
            out["transport"] = {
                "type": "grpc",
                "service_name": grpc_opts.get("grpc-service-name", ""),
            }
        return out

    elif ptype in ("hysteria2", "hy2"):
        out = {
            "type": "hysteria2",
            "tag": tag,
            "server": server,
            "server_port": port,
            "password": str(p.get("password") or p.get("auth", "")),
            "tls": {
                "enabled": True,
                "server_name": p.get("sni") or p.get("servername") or server,
                "insecure": bool(p.get("skip-cert-verify", False)),
            },
        }
        if p.get("obfs"):
            out["obfs"] = {
                "type": p.get("obfs", "salamander"),
                "password": p.get("obfs-password", ""),
            }
        return out

    return None


def fetch_subscription(url):
    headers = {"User-Agent": "clash-meta/1.18.0 (Clash.Meta; Windows NT 10.0; Win64; x64)"}
    # First try direct connection (to avoid interference from local dead/mismatched proxies)
    try:
        req = urllib.request.Request(url, headers=headers)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=20) as resp:
            return resp.read().decode("utf-8", errors="ignore")
    except Exception as e_direct:
        # If direct connection fails (e.g. site requires proxy), try system/env proxy
        try:
            req2 = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req2, timeout=20) as resp:
                return resp.read().decode("utf-8", errors="ignore")
        except Exception:
            raise e_direct


def parse_raw_content(content):
    existing_tags = set()
    outbounds = []

    # 1. Try Clash YAML
    if yaml is not None:
        try:
            clash_data = yaml.safe_load(content)
            if isinstance(clash_data, dict) and "proxies" in clash_data:
                proxies = clash_data.get("proxies", [])
                for idx, p in enumerate(proxies, 1):
                    try:
                        node = parse_clash_proxy(p, idx, existing_tags)
                        if node:
                            outbounds.append(node)
                    except Exception as e:
                        print(f"Warning: failed to parse proxy #{idx}: {e}", file=sys.stderr)
                if outbounds:
                    return outbounds
        except Exception:
            pass

    # 2. Try plain lines of URIs
    lines = [line.strip() for line in content.splitlines() if line.strip()]
    if lines and any(line.startswith(("vless://", "vmess://", "trojan://", "ss://")) for line in lines):
        for idx, line in enumerate(lines, 1):
            try:
                if line.startswith("vless://"):
                    outbounds.append(parse_vless_uri(line, idx, existing_tags))
                elif line.startswith("vmess://"):
                    outbounds.append(parse_vmess_uri(line, idx, existing_tags))
                elif line.startswith("trojan://"):
                    outbounds.append(parse_trojan_uri(line, idx, existing_tags))
                elif line.startswith("ss://"):
                    outbounds.append(parse_ss_uri(line, idx, existing_tags))
            except Exception as e:
                print(f"Warning: failed to parse URI #{idx}: {e}", file=sys.stderr)
        if outbounds:
            return outbounds

    # 3. Try Base64 decode
    try:
        clean_content = re.sub(r"\s+", "", content)
        missing_padding = len(clean_content) % 4
        if missing_padding:
            clean_content += "=" * (4 - missing_padding)
        decoded = base64.b64decode(clean_content).decode("utf-8", errors="ignore")
        decoded_lines = [line.strip() for line in decoded.splitlines() if line.strip()]
        for idx, line in enumerate(decoded_lines, 1):
            try:
                if line.startswith("vless://"):
                    outbounds.append(parse_vless_uri(line, idx, existing_tags))
                elif line.startswith("vmess://"):
                    outbounds.append(parse_vmess_uri(line, idx, existing_tags))
                elif line.startswith("trojan://"):
                    outbounds.append(parse_trojan_uri(line, idx, existing_tags))
                elif line.startswith("ss://"):
                    outbounds.append(parse_ss_uri(line, idx, existing_tags))
            except Exception as e:
                print(f"Warning: failed to parse base64 URI #{idx}: {e}", file=sys.stderr)
        if outbounds:
            return outbounds
    except Exception:
        pass

    return outbounds


def build_singbox_config(outbounds, port=1080, clash_port=9090):
    node_tags = [ob["tag"] for ob in outbounds]
    if not node_tags:
        raise ValueError("No valid proxy nodes found to configure.")

    config = {
        "log": {
            "level": "info"
        },
        "inbounds": [
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "0.0.0.0",
                "listen_port": int(port),
            }
        ],
        "outbounds": [
            {
                "type": "selector",
                "tag": "proxy",
                "outbounds": node_tags,
                "default": node_tags[0],
            },
            *outbounds,
            {
                "type": "direct",
                "tag": "direct",
            },
            {
                "type": "block",
                "tag": "block",
            },
        ],
        "route": {
            "rules": [
                {
                    "clash_mode": "Direct",
                    "outbound": "direct",
                },
                {
                    "clash_mode": "Global",
                    "outbound": "proxy",
                },
                {
                    "ip_is_private": True,
                    "outbound": "direct",
                },
            ],
            "auto_detect_interface": True,
            "final": "proxy",
        },
        "experimental": {
            "cache_file": {
                "enabled": True,
                "path": "/var/lib/sing-box-client/cache.db",
            },
            "clash_api": {
                "external_controller": f"127.0.0.1:{clash_port}",
            },
        },
    }
    return config


def main():
    parser = argparse.ArgumentParser(description="Convert subscriptions/configs into sing-box client config")
    parser.add_argument("--sub", help="Subscription URL (Clash YAML or Base64)")
    parser.add_argument("--file", help="Local file (Clash YAML or URI list or sing-box JSON)")
    parser.add_argument("--vless", help="Single VLESS URI")
    parser.add_argument("--port", type=int, default=1080, help="Inbound mixed port (default: 1080)")
    parser.add_argument("--clash-port", type=int, default=9090, help="Clash API port (default: 9090)")
    parser.add_argument("--output", required=True, help="Output sing-box config JSON path")

    args = parser.parse_args()

    content = ""
    outbounds = []

    if args.vless:
        outbounds.append(parse_vless_uri(args.vless, 1))
    elif args.sub:
        print(f"Fetching subscription from: {args.sub} ...", file=sys.stderr)
        content = fetch_subscription(args.sub)
        outbounds = parse_raw_content(content)
    elif args.file:
        with open(args.file, "r", encoding="utf-8") as f:
            content = f.read()

        # Check if already a valid singbox JSON
        try:
            sb_json = json.loads(content)
            if isinstance(sb_json, dict) and ("outbounds" in sb_json or "inbounds" in sb_json):
                # Ensure mixed inbound and clash_api are injected if missing
                has_mixed = any(ib.get("type") == "mixed" for ib in sb_json.get("inbounds", []))
                if not has_mixed:
                    sb_json.setdefault("inbounds", []).insert(
                        0,
                        {"type": "mixed", "tag": "mixed-in", "listen": "0.0.0.0", "listen_port": args.port},
                    )
                sb_json.setdefault("experimental", {})
                sb_json["experimental"].setdefault(
                    "cache_file", {"enabled": True, "path": "/var/lib/sing-box-client/cache.db"}
                )
                sb_json["experimental"].setdefault(
                    "clash_api", {"external_controller": f"127.0.0.1:{args.clash_port}"}
                )

                with open(args.output, "w", encoding="utf-8") as out_f:
                    json.dump(sb_json, out_f, indent=2, ensure_ascii=False)
                print(f"Sing-box config written to {args.output}", file=sys.stderr)
                return
        except Exception:
            pass

        outbounds = parse_raw_content(content)
    else:
        print("Error: must provide one of --sub, --file, or --vless", file=sys.stderr)
        sys.exit(1)

    if not outbounds:
        print("Error: Could not parse any valid proxy nodes from the provided source.", file=sys.stderr)
        sys.exit(1)

    print(f"Successfully parsed {len(outbounds)} proxy node(s).", file=sys.stderr)
    config = build_singbox_config(outbounds, port=args.port, clash_port=args.clash_port)

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

    print(f"Generated sing-box config saved to: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
