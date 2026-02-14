output "network_id" {
  description = "Hetzner network ID"
  value       = hcloud_network.main.id
}

output "subnets" {
  description = "Public and private subnet CIDRs"
  value = {
    public  = hcloud_network_subnet.public.ip_range
    private = hcloud_network_subnet.private.ip_range
  }
}

output "app_server_private_ips" {
  description = "Private IPs of app servers"
  value = {
    for name, server in hcloud_server.app : name => one(server.network).ip
  }
}

output "load_balancer_public_ipv4" {
  description = "Public IPv4 address of the load balancer"
  value       = hcloud_load_balancer.public.ipv4
}

output "load_balancer_private_ip" {
  description = "Private IP of the load balancer in the network"
  value       = hcloud_load_balancer_network.public_subnet_attachment.ip
}

output "nat_gateway_public_ipv4" {
  description = "Public IPv4 address of NAT gateway"
  value       = hcloud_server.nat.ipv4_address
}

output "nat_gateway_private_ip" {
  description = "Private IP address of NAT gateway"
  value       = one(hcloud_server.nat.network).ip
}
