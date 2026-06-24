[Unit]
Description=placeholder_kernel_desc
After=network.target NetworkManager.service systemd-networkd.service iwd.service

[Service]
Type=simple
LimitNOFILE=1000000
placeholder_run_as_user
CapabilityBoundingSet=~
AmbientCapabilities=~
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=placeholder_cmd_full
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
