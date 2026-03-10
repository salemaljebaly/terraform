import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";

// Read the API token from stack config (encrypted)
const config = new pulumi.Config();
const hcloudToken = config.requireSecret("hcloudToken");

// Create the Hetzner Cloud provider
const provider = new hcloud.Provider("hcloud", {
  token: hcloudToken,
});

// Provision a server
const server = new hcloud.Server("my-first-server", {
  name:       "my-first-server",
  serverType: "cx22",
  image:      "ubuntu-24.04",
  location:   "nbg1",
  labels: {
    managedBy: "pulumi",
    env:       "tutorial",
  },
}, { provider });

// Export the server's public IP so you can connect to it
export const serverIp   = server.ipv4Address;
export const serverName = server.name;
