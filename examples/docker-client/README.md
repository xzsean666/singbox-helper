# docker-client example

Shows how a docker container on *any other server* can use the sing-box proxy
that `setup-server.sh` installed, to reach the internet.

`config/sing-box-client.json` is generated automatically the first time you
run `../../setup-server.sh` - it gets overwritten with the real
host/port/UUID/Reality keys of whichever server you just set up. Until then
it contains placeholder values.

If you've set up more than one server and want to point this example at a
different one, copy that server's config over this one:

```bash
cp ../../servers/<alias>/client-config.json ./config/sing-box-client.json
docker compose restart sing-box-client
```

## Try it

```bash
docker compose up -d
docker compose exec app curl -x socks5h://127.0.0.1:1080 https://ifconfig.me
docker compose exec app curl -x http://127.0.0.1:1080 https://ifconfig.me
```

Both should print the IP address of the proxy server, not this machine's own
IP - confirming traffic is going out through the proxy.

## Using this in your own compose file

Add your own service instead of (or next to) `app`. All it needs is:

```yaml
services:
  your-service:
    image: your-image
    network_mode: "service:sing-box-client"
    depends_on:
      - sing-box-client
```

Then configure `your-service` to use `127.0.0.1:1080` as an HTTP or SOCKS5
proxy (however your app/language/library expects a proxy to be configured -
e.g. `HTTP_PROXY=http://127.0.0.1:1080`, a SOCKS5 client setting, etc). Because
it shares `sing-box-client`'s network namespace, `127.0.0.1` always reaches
the proxy - no docker-network hostname or extra networking config needed.
