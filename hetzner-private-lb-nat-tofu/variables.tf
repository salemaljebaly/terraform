variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "salem-final-project"
}

variable "owner" {
  description = "Owner label"
  type        = string
  default     = "salem"
}

variable "location" {
  description = "Hetzner location for the load balancer"
  type        = string
  default     = "nbg1"
}

variable "network_zone" {
  description = "Hetzner network zone"
  type        = string
  default     = "eu-central"
}

variable "network_cidr" {
  description = "Main private network range"
  type        = string
  default     = "10.42.0.0/16"
}

variable "network_gateway_ip" {
  description = "Hetzner private network gateway IP used as default route inside servers"
  type        = string
  default     = "10.42.0.1"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR inside the Hetzner private network"
  type        = string
  default     = "10.42.10.0/24"
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR for app servers"
  type        = string
  default     = "10.42.20.0/24"
}

variable "lb_private_ip" {
  description = "Private IP for the load balancer network attachment"
  type        = string
  default     = "10.42.20.10"
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx23"
}

variable "server_image" {
  description = "OS image used for app servers"
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_key_name" {
  description = "Existing SSH key name in Hetzner Cloud"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH into app servers"
  type        = list(string)
  default     = []
}

variable "app_servers" {
  description = "Final project app servers with private subnet IPs"
  type = map(object({
    private_ip = string
    location   = optional(string)
  }))

  default = {
    app1 = { private_ip = "10.42.20.11" }
    app2 = { private_ip = "10.42.20.12" }
  }
}

variable "nat_gateway_server_type" {
  description = "Server type for NAT gateway instance"
  type        = string
  default     = "cx23"
}

variable "nat_gateway_image" {
  description = "OS image for NAT gateway"
  type        = string
  default     = "ubuntu-24.04"
}

variable "nat_gateway_private_ip" {
  description = "Private IP for NAT gateway in private subnet"
  type        = string
  default     = "10.42.20.2"
}
