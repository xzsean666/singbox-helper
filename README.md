# singbox-helper

Give it an ssh login command for a server, and it installs and configures a
[sing-box](https://sing-box.sagernet.org) **VLESS + Reality** proxy server
there, plus a password-authenticated HTTP proxy on a separate port.

VLESS + Reality was chosen over plain Shadowsocks for its resistance to active
probing and DPI: the server performs a real TLS handshake using the
certificate of a genuine third-party website (the "SNI"/camouflage domain),
so passive traffic analysis sees what looks like a normal HTTPS connection to
that site, and anyone actively probing the port without the right key just
gets served that site's real content instead of anything that reveals a
proxy is running.

## Prerequisites

**Local machine** (where you run `setup-server.sh`): `bash`, `ssh`, `scp`, `openssl`.

**Remote server**: a systemd-based Linux distro (Ubuntu/Debian/CentOS/etc.),
and either a root SSH login or a user with **passwordless** sudo. The script
doesn't prompt for a sudo password, so an account that requires one at the
prompt won't work non-interactively.

## Usage

```bash
./setup-server.sh "ssh root@1.2.3.4"
# or
./setup-server.sh "ssh -i ~/.ssh/sean root@1.2.3.4"
# or, to pick a different camouflage domain than the default (www.microsoft.com):
./setup-server.sh "ssh root@1.2.3.4" --sni www.apple.com
```

This will:
1. Parse the ssh command you gave it (identity file, user, host, port).
2. Generate separate random high ports (never 80/443) for VLESS and the HTTP
   proxy, plus a UUID, Reality short ID, and HTTP proxy password.
3. Install sing-box on the remote host (downloads the latest release binary
   if it's not already installed), generate a Reality keypair **on the
   server itself** (the private key never leaves it), write the config, and
   run it as a `sing-box` systemd service.
4. Open the chosen port in `ufw` if it's active; otherwise it'll tell you to
   open it yourself (e.g. a cloud provider's security group / firewalld).
5. Save the connection details and client config locally.

The `--sni` domain must be a real, internet-reachable site that serves TLS
1.3 on port 443 - the server "pretends" to be that site to anyone who
doesn't have your key. `www.microsoft.com` is a safe default; other common
choices are `www.apple.com`, `www.samsung.com`, or `addons.mozilla.org`.

### Naming a server / setting up more than one

```bash
./setup-server.sh "ssh root@1.2.3.4" --name tokyo
./setup-server.sh "ssh root@5.6.7.8" --name frankfurt
```

Each server's details are saved under `servers/<alias>/` (gitignored - these
are credentials, not something to commit):

- `info.env` - host, ports, VLESS credentials, HTTP proxy credentials, and the
  ssh command used
- `client-config.json` - a ready sing-box **client** config pointing at it
- `http-proxy.txt` - a ready-to-use `http://username:password@host:port` URL

The setup script also prints a `vless://...` link you can import directly
into GUI clients (v2rayN, NekoBox, Shadowrocket, etc.), and a directly usable
password-authenticated HTTP proxy URL.

The HTTP proxy uses plain HTTP proxy authentication, so the password and proxy
traffic are not encrypted between your device and the server. Use it only on a
trusted network. For encrypted traffic, use the generated VLESS + Reality link.

Re-running against an alias that already exists is refused unless you pass
`--force` (which regenerates new ports, VLESS credentials, and HTTP proxy
credentials before reinstalling).

### Reinstalling

```bash
./reinstall-server.sh myserver
./reinstall-server.sh myserver --sni www.apple.com
```

Reuses the ssh command already saved in `servers/myserver/info.env`, so you
don't have to type it again. Equivalent to running `setup-server.sh` with
`--force` against that saved ssh command; regenerates the ports and VLESS/HTTP
proxy credentials and overwrites the existing service. Pass `--sni` to switch
the camouflage domain, otherwise the existing one is kept.

### Uninstalling

```bash
./uninstall-server.sh myserver
./uninstall-server.sh myserver --yes
./uninstall-server.sh myserver --purge-binary
```

Stops and removes the `sing-box` systemd service and its config from the
remote host, closes the VLESS and HTTP proxy ports in `ufw` if they were opened
there, and deletes the local `servers/myserver/` directory. Prompts for
confirmation unless `--yes` is passed. The `sing-box` binary itself is left on the remote host
(harmless, and shared across reinstalls) unless `--purge-binary` is given.

## Client Installation (`setup-client.sh`)

Installs a persistent, auto-starting `sing-box-client` systemd service on any Linux machine via SSH.

It supports:
- **Clash subscription URLs** (`--sub`): fetches and converts all nodes (VLESS, VMess, Trojan, Shadowsocks, Hysteria2), creating a selector group with hot node switching.
- **Single VLESS links** (`--vless`): converts a standard `vless://...` URI into a sing-box client config.
- **Custom configs** (`--config`): sing-box JSON or Clash YAML files.
- **Existing server aliases** (`--server`): seamlessly uses a server set up via `setup-server.sh`.

```bash
# 1. From a Clash subscription link:
./setup-client.sh "ssh root@client.ip" --sub "https://example.com/api/v1/client/subscribe?token=xxx"

# 2. From a single vless link:
./setup-client.sh "ssh root@client.ip" --vless "vless://uuid@host:443?security=reality&...#MyNode"

# 3. From a previously configured server alias:
./setup-client.sh "ssh root@client.ip" --server tokyo

# 4. From a local config file:
./setup-client.sh "ssh root@client.ip" --config my-config.json
```

### Managing Proxies, Nodes & Multi-Port Routing (`pnode` / `proxy-node`)

The client includes a unified proxy manager (`pnode`, alias of `proxy-node`) designed with a clean front-loaded port architecture: `pnode [port] <action>`.

> [!TIP]
> **Front-Loaded Port Rule**:
> - Omit the port: defaults to **Port 1080** (e.g. `pnode 2`, `pnode use 1`, `pnode ls`).
> - Provide the port: operations are 100% symmetric across ports (e.g. `pnode 1081 2`, `pnode 1081 use 1`, `pnode 1081 ls`).
> - Numbered indices and fuzzy names are supported everywhere!

#### 1. Quick Node Switching & Dashboard
```bash
# View active nodes (single port) or multi-port dashboard (when multiple ports are running)
pnode

# Hot-switch node on Port 1080 by index number or fuzzy name:
pnode 2                   # switch to node #2 on port 1080
pnode 日本                # fuzzy search by name on port 1080
pnode switch              # interactive node picker

# Switch node on a specific port (e.g. 1081):
pnode 1081 2              # switch to node #2 on port 1081
pnode 1081 香港           # fuzzy search by name on port 1081

# List all nodes available on a port:
pnode ls                  # nodes on 1080
pnode 1081 ls             # nodes on 1081 (or: pnode 1081)

# Check active node name:
pnode current             # current node on 1080
pnode 1081 current        # current node on 1081
```

#### 2. Profiles & Multi-Port Management
Run multiple profiles simultaneously across independent ports without conflicts (e.g. keep Port 1080 on one profile, while hosting other profiles on Ports 1081, 1082, etc.):

```bash
# List all configured profiles:
pnode profiles            # or: pnode p

# Switch active profile on Port 1080 by number or name:
pnode use 1               # switch 1080 to profile #1
pnode use tokyo           # switch 1080 to profile 'tokyo'

# Auto-allocate the next free port (1081, 1082...) and mount a profile:
pnode add 2               # mounts profile #2 to 1081 and starts it
pnode add clash-sub       # mounts profile 'clash-sub' to next free port

# Mount profile on a designated port:
pnode 1081 use 2          # mounts profile #2 on port 1081
pnode 1082 use clash-sub  # mounts 'clash-sub' on port 1082

# Stop and unbind a port:
pnode 1081 stop           # stop port 1081 (or: pnode stop 1081)
pnode stop all            # stop all secondary ports (keeps 1080 running)
```

#### 3. Diagnostics & One-Shot Proxy Runner
```bash
# Test connectivity and latency across ALL active ports simultaneously:
pnode test

# Test connectivity on a specific port:
pnode 1081 test           # or: pnode test 1081

# Execute a command through a proxy port without modifying shell environment:
pnode run curl -s https://api.ipify.org          # run through 1080
pnode 1081 run curl -s https://api.ipify.org     # run through 1081
pnode 1082 run git clone https://github.com/...  # run through 1082
```

#### 4. Profile Library Operations
```bash
# Add a new profile from subscription URL, VLESS link, or local file:
pnode profile add sub1 "https://example.com/sub/..."
pnode profile add my-node "vless://..."
pnode profile add custom /path/to/custom.json

# Update subscription nodes (re-fetches from remote URL and restarts active instances):
pnode update              # updates current active profile
pnode update clash-sub    # updates a specific named profile

# Save current running configuration as a named profile:
pnode profile save backup-2026

# Delete a configured profile:
pnode profile del old-profile
pnode profile del 3
```

#### 5. Shell Environment Proxy (`proxy on [port]`)
The shell integration supports activating any proxy port directly in your current terminal:

```bash
# Enable proxy on Port 1080 (default):
proxy on

# Enable proxy on a specific port:
proxy on 1081             # or shortcut: proxy 1081

# Disable proxy:
proxy off

# View current shell proxy status and active node:
proxy status

# Test current shell proxy connection:
proxy test
```

#### 6. Docker Proxy Management (`pnode docker [mode]`)

`pnode` provides 3 explicit states to cleanly separate Docker image pull acceleration from container traffic:

```bash
# View current Docker proxy status & mode:
pnode docker status

# Mode 1 - Global: All containers auto-proxied + Docker pull accelerated
pnode docker all

# Mode 2 - Pull-Only (Recommended): Docker pull accelerated, Containers default to Direct (On-Demand)
pnode docker pull

# Mode 3 - Disabled: Completely turn off all Docker proxying
pnode docker off

# Test container outbound connectivity:
pnode docker test
```

> [!TIP]
> Under **Mode 2 (Pull-Only)**, containers connect directly by default so background services won't accidentally drain your proxy bandwidth. When you need a container to use proxy, use:
> - `dproxy run -it ...` (CLI shortcut)
> - Or add `HTTP_PROXY=http://172.17.0.1:1080` to your `docker-compose.yml`.

### Uninstalling Client


```bash
./uninstall-client.sh "ssh root@client.ip"
./uninstall-client.sh "ssh root@client.ip" --yes
./uninstall-client.sh "ssh root@client.ip" --purge-binary
```

