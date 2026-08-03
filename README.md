# singbox-helper

Give it an ssh login command for a server, and it installs and configures a
[sing-box](https://sing-box.sagernet.org) **VLESS + Reality** proxy server
there, plus a password-authenticated HTTP proxy on a separate port. Includes a
ready-to-run docker-compose example showing how a container
on a *different* server can use that proxy to reach the internet.

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
5. Save the connection details locally and generate a docker-client config.

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

## Using the proxy from docker (on any other server)

See [`examples/docker-client/`](examples/docker-client/) - a docker-compose
setup where a business container shares the sing-box client container's
network namespace, so it can reach the proxy at `127.0.0.1:1080` with no
extra docker networking. `setup-server.sh` automatically drops the
most-recently-set-up server's client config into that example so it works
out of the box; see that directory's README for how to point it at a
different server if you've set up several.
