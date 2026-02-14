data "hcloud_ssh_key" "selected" {
  name = var.ssh_key_name
}

resource "hcloud_server" "app" {
  for_each = var.app_servers

  name        = "${var.project_name}-${each.key}"
  server_type = var.server_type
  image       = var.server_image
  location    = coalesce(each.value.location, var.location)
  ssh_keys    = [data.hcloud_ssh_key.selected.id]
  firewall_ids = [
    hcloud_firewall.app.id
  ]

  network {
    network_id = hcloud_network.main.id
    ip         = each.value.private_ip
  }

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  user_data = templatefile("${path.module}/script/cloud-init.yaml.tpl", {
    server_name            = each.key
    nat_gateway_private_ip = var.nat_gateway_private_ip
    network_gateway_ip     = var.network_gateway_ip
  })

  labels = merge(local.common_labels, {
    role = "app"
    name = each.key
  })

  depends_on = [
    hcloud_network_subnet.private
  ]
}
