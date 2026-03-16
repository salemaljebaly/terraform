resource "hcloud_firewall" "app" {
  name = "${var.project_name}-app-fw"

  # Allow SSH from the NAT/bastion host for ProxyJump access.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["${var.nat_gateway_private_ip}/32"]
  }

  dynamic "rule" {
    for_each = var.ssh_allowed_cidrs
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "22"
      source_ips = [rule.value]
    }
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["${var.lb_private_ip}/32"]
  }

  labels = local.common_labels
}
