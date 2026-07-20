{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
      "listen_port": 1080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy-out",
      "server": "{{HOST}}",
      "server_port": {{PORT}},
      "uuid": "{{UUID}}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "{{SNI}}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "{{PUBLIC_KEY}}",
          "short_id": "{{SHORT_ID}}"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "proxy-out"
  }
}
