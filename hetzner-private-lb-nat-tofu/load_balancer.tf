resource "hcloud_load_balancer" "public" {
  name               = "${var.project_name}-lb"
  load_balancer_type = "lb11"
  location           = var.location

  labels = merge(local.common_labels, {
    role = "edge"
  })
}

resource "hcloud_load_balancer_network" "public_subnet_attachment" {
  load_balancer_id = hcloud_load_balancer.public.id
  subnet_id        = hcloud_network_subnet.private.id
  ip               = var.lb_private_ip
}

resource "hcloud_load_balancer_target" "app" {
  for_each = hcloud_server.app

  type             = "server"
  load_balancer_id = hcloud_load_balancer.public.id
  server_id        = each.value.id
  use_private_ip   = true
}

resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.public.id
  protocol         = "http"
  listen_port      = 80
  destination_port = 80

  health_check {
    protocol = "http"
    port     = 80
    interval = 10
    timeout  = 5
    retries  = 3

    http {
      path         = "/"
      status_codes = ["200"]
    }
  }
}
