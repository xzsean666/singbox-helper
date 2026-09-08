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

### Managing & Switching Nodes on Remote Server (`pnode` / `proxy-node`)

The client includes a command-line tool (`proxy-node`, aliased to `pnode`) on the remote server:

```bash
# 1. List all available nodes and show currently active node:
pnode

# 2. Switch to a node by number or name (hot switch, no restart needed):
pnode 2
pnode switch "Hong Kong 01"

# 3. Interactive prompt to choose a node:
pnode switch

# 4. Switch to a new Clash subscription URL directly on the server:
pnode sub "https://example.com/api/v1/client/subscribe?token=yyy" [profile_name]

# 5. Switch to a single VLESS link directly on the server:
pnode vless "vless://uuid@host:443?security=reality&...#MyNode" [profile_name]

# 6. Update current subscription nodes (re-fetch from saved URL):
pnode update

# 7. Docker container & daemon proxy management:
pnode docker status   # Check Docker proxy status (container mode, daemon pull, boot order)
pnode docker on       # Enable global proxy for ALL Docker containers
pnode docker off      # Switch to On-Demand mode (containers default to direct)
pnode docker test     # Test Docker container connectivity through proxy

# 8. Test connection and show outbound IP:
pnode test
```

### Docker Acceleration & Container Proxy Modes

The client setup automatically configures Docker integration:

1. **Docker Daemon Acceleration (`docker pull`)**:
   Always enabled by default via `/etc/systemd/system/docker.service.d/sing-box-client.conf`. Image pulls from Docker Hub / GHCR are accelerated, and Docker automatically starts after `sing-box-client`.

2. **Containers On-Demand Mode (Default)**:
   By default, containers connect directly to the internet (domestic speed, internal networks unaffected). When a specific container needs proxy:
   ```bash
   # CLI shortcut:
   dproxy run --rm curlimages/curl:latest -s https://api.ipify.org
   dproxy --rm -it alpine

   # Or standard docker run with env-file:
   docker run --rm --env-file /etc/sing-box-client/docker-proxy.env alpine

   # In docker-compose.yml:
   services:
     myservice:
       image: myimage
       env_file:
         - /etc/sing-box-client/docker-proxy.env
   ```

3. **Global Container Proxy Mode (Optional)**:
   ```bash
   pnode docker on    # All new containers automatically route through proxy
   pnode docker off   # Return to on-demand mode (containers default to direct)
   pnode docker status # View current Docker proxy status
   pnode docker test   # Run a test container through the proxy
   ```

### Config Profile Management (`pnode profile` / `pnode config`)

You can store multiple independent configurations (different subscriptions, standalone VLESS links, custom configs), switch between them, and delete old ones:

```bash
# List all configured profiles (shows active profile, node counts, type, source):
pnode profile        # or: pnode profiles / pnode config list

# Switch to a configured profile by name or number:
pnode profile use hk-vless
pnode profile use 1              # or: pnode config use 1

# Delete a configured profile by name or number:
pnode profile del old-sub
pnode profile del 3              # or: pnode config del 3

# Save current running configuration as a new named profile:
pnode profile save my-backup

# Add a new profile from subscription URL, VLESS link, or local file:
pnode profile add provider2 "https://example.com/sub/..."
pnode profile add backup-vless "vless://..."
pnode profile add custom /path/to/custom.json
```

### Shell Environment Proxy in `~/.bashrc` (Default: OFF)

`setup-client.sh` injects proxy helper functions into `~/.bashrc`. **The proxy is disabled by default** upon logging in.

```bash
# Enable proxy environment for current shell (127.0.0.1:1080):
proxy on

# Disable proxy environment:
proxy off

# View proxy environment, client service status, and active node:
proxy status

# Test outbound IP through the proxy:
proxy test
```

### Uninstalling Client

```bash
./uninstall-client.sh "ssh root@client.ip"
./uninstall-client.sh "ssh root@client.ip" --yes
./uninstall-client.sh "ssh root@client.ip" --purge-binary
```

