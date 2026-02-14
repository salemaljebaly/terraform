#cloud-config

write_files:
  - path: /var/www/html/index.html
    permissions: "0644"
    owner: root:root
    content: |
      <html>
        <head><title>${server_name}</title></head>
        <body>
          <h1>${server_name}</h1>
          <p>Served from ${server_name} in Salem final project.</p>
        </body>
      </html>
  - path: /var/www/html/health
    permissions: "0644"
    owner: root:root
    content: "ok"
  - path: /etc/systemd/system/simple-web.service
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=Simple Python HTTP server for lab backend
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      WorkingDirectory=/var/www/html
      ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0
      Restart=always
      RestartSec=2
      User=root

      [Install]
      WantedBy=multi-user.target

runcmd:
  - ip route replace default via ${network_gateway_ip} dev enp7s0 || true
  - systemctl enable simple-web.service
  - systemctl restart simple-web.service
