#cloud-config

write_files:
  - path: /usr/local/sbin/configure-nat.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      WAN_IF=$(ip route | awk '/^default/ {print $5; exit}')
      if [[ -z "$${WAN_IF}" ]]; then
        echo "No default WAN interface found" >&2
        exit 1
      fi

      sysctl -w net.ipv4.ip_forward=1
      sed -i 's/^#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

      iptables -t nat -C POSTROUTING -s ${private_subnet_cidr} -o "$${WAN_IF}" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s ${private_subnet_cidr} -o "$${WAN_IF}" -j MASQUERADE

      iptables -C FORWARD -s ${private_subnet_cidr} -o "$${WAN_IF}" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -s ${private_subnet_cidr} -o "$${WAN_IF}" -j ACCEPT

      iptables -C FORWARD -d ${private_subnet_cidr} -m conntrack --ctstate ESTABLISHED,RELATED -i "$${WAN_IF}" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -d ${private_subnet_cidr} -m conntrack --ctstate ESTABLISHED,RELATED -i "$${WAN_IF}" -j ACCEPT

  - path: /etc/systemd/system/nat-gateway.service
    permissions: "0644"
    owner: root:root
    content: |
      [Unit]
      Description=Configure NAT for private subnet egress
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/configure-nat.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl daemon-reload
  - systemctl enable nat-gateway.service
  - systemctl start nat-gateway.service
