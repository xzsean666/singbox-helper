[Unit]
Description=sing-box client service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/sing-box-client
ExecStart={{INSTALL_BIN}} run -c /etc/sing-box-client/config.json
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
