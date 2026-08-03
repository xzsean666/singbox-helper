{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": {{PORT}},
      "users": [
        {
          "uuid": "{{UUID}}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "{{SNI}}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "{{SNI}}",
            "server_port": 443
          },
          "private_key": "{{PRIVATE_KEY}}",
          "short_id": ["{{SHORT_ID}}"]
        }
      }
    },
    {
      "type": "http",
      "tag": "http-in",
      "listen": "::",
      "listen_port": {{HTTP_PORT}},
      "users": [
        {
          "username": "{{HTTP_USERNAME}}",
          "password": "{{HTTP_PASSWORD}}"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
