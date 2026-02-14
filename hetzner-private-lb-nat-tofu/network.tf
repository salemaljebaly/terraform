resource "hcloud_network" "main" {
  name     = "${var.project_name}-network"
  ip_range = var.network_cidr

  labels = local.common_labels
}

resource "hcloud_network_subnet" "public" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.public_subnet_cidr
}

resource "hcloud_network_subnet" "private" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.private_subnet_cidr
}
