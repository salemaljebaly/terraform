import * as fs from "node:fs";
import * as path from "node:path";
import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as cloudflare from "@pulumi/cloudflare";

const stack = pulumi.getStack();
const project = pulumi.getProject();
const config = new pulumi.Config();
const projectConfig = new pulumi.Config(project);

// Read from environment variables (loaded from .env via set -a && source .env && set +a)
const domain = process.env.DOMAIN;
const cloudflareZoneId = process.env.CLOUDFLARE_ZONE_ID;
const tlsCertificate = process.env.TLS_CERT;
const tlsPrivateKey = process.env.TLS_PRIVATE_KEY;

if (!domain) throw new pulumi.RunError("DOMAIN must be set in .env");
if (!cloudflareZoneId) throw new pulumi.RunError("CLOUDFLARE_ZONE_ID must be set in .env");
if (!tlsCertificate) throw new pulumi.RunError("TLS_CERT must be set in .env");
if (!tlsPrivateKey) throw new pulumi.RunError("TLS_PRIVATE_KEY must be set in .env");

const existingSshKeyName = config.get("sshKeyName");
const sshPublicKeyPath = config.get("sshPublicKeyPath");
const sshAllowedCidrs = config.getObject<string[]>("sshAllowedCidrs") ?? [];

if (!existingSshKeyName && !sshPublicKeyPath) {
  throw new pulumi.RunError(
    "Set either `sshKeyName` (existing Hetzner SSH key name) or `sshPublicKeyPath` (local public key path).",
  );
}

const location = projectConfig.get("location") ?? "nbg1";
const networkZone = projectConfig.get("networkZone") ?? "eu-central";
const loadBalancerType = projectConfig.get("loadBalancerType") ?? "lb11";
const serverType = projectConfig.get("serverType") ?? "cx23";
const image = projectConfig.get("image") ?? "ubuntu-24.04";
const networkCidr = projectConfig.get("networkCidr") ?? "10.44.0.0/16";
const privateSubnetCidr = projectConfig.get("privateSubnetCidr") ?? "10.44.10.0/24";
const loadBalancerPrivateIpAddress = projectConfig.get("loadBalancerPrivateIp") ?? "10.44.10.10";
const appPrivateIp1 = projectConfig.get("appPrivateIp1") ?? "10.44.10.11";
const appPrivateIp2 = projectConfig.get("appPrivateIp2") ?? "10.44.10.12";
const namePrefix = `${project}-${stack}`;

const sshPublicKey = sshPublicKeyPath
  ? fs
    .readFileSync(path.resolve(sshPublicKeyPath.replace(/^~(?=$|\/|\\)/, process.env.HOME ?? "~")), "utf-8")
    .trim()
  : undefined;

const labels = {
  project,
  stack,
  managedBy: "pulumi",
  role: "tutorial",
};

// --- Providers ---

// Providers read HCLOUD_TOKEN and CLOUDFLARE_API_TOKEN from the environment automatically.
const hcloudProvider = new hcloud.Provider("hcloud", {});
const hcloudOpts: pulumi.CustomResourceOptions = { provider: hcloudProvider };

const cloudflareProvider = new cloudflare.Provider("cloudflare", {});
const cloudflareOpts: pulumi.CustomResourceOptions = { provider: cloudflareProvider };

// --- Network ---

const network = new hcloud.Network("private-network", {
  name: `${namePrefix}-network`,
  ipRange: networkCidr,
  labels,
}, hcloudOpts);
const networkId = network.id.apply((id) => Number(id));

const privateSubnet = new hcloud.NetworkSubnet("private-subnet", {
  networkId,
  type: "cloud",
  networkZone,
  ipRange: privateSubnetCidr,
}, hcloudOpts);

// --- SSH key ---

const sshKeyRef: pulumi.Input<string> = existingSshKeyName
  ? existingSshKeyName
  : new hcloud.SshKey("deployer-key", {
    name: `${namePrefix}-ssh-key`,
    publicKey: sshPublicKey!,
    labels,
  }, hcloudOpts).id;

// --- Firewall ---
// App servers accept HTTP only from the LB private IP.
// SSH is restricted to your allowed CIDRs.
// Port 443 is not needed on the servers — TLS is terminated at the Load Balancer.

const appFirewall = new hcloud.Firewall("app-firewall", {
  name: `${namePrefix}-app-fw`,
  labels: { ...labels, tier: "app" },
  rules: [
    {
      description: "HTTP from load balancer private IP only",
      direction: "in",
      protocol: "tcp",
      port: "80",
      sourceIps: [`${loadBalancerPrivateIpAddress}/32`],
    },
    ...sshAllowedCidrs.map((cidr, index) => ({
      description: `SSH allowlist entry ${index + 1}`,
      direction: "in" as const,
      protocol: "tcp" as const,
      port: "22",
      sourceIps: [cidr],
    })),
  ],
}, hcloudOpts);
const appFirewallId = appFirewall.id.apply((id) => Number(id));

// --- App servers ---

const cloudInitTemplate = fs.readFileSync(path.join(__dirname, "cloud-init", "app-server.yaml"), "utf-8");

const serverDefs = [
  { suffix: "app-1", privateIp: appPrivateIp1 },
  { suffix: "app-2", privateIp: appPrivateIp2 },
];

const appServers = serverDefs.map((def) => {
  const userData = cloudInitTemplate
    .split("${SERVER_NAME}")
    .join(`${namePrefix}-${def.suffix}`)
    .split("${SERVER_PRIVATE_IP}")
    .join(def.privateIp);

  return new hcloud.Server(`server-${def.suffix}`, {
    name: `${namePrefix}-${def.suffix}`,
    serverType,
    image,
    location,
    sshKeys: [sshKeyRef],
    firewallIds: [appFirewallId],
    publicNets: [{ ipv4Enabled: true, ipv6Enabled: false }],
    networks: [{ networkId, ip: def.privateIp }],
    userData,
    labels: { ...labels, tier: "app", instance: def.suffix },
  }, { ...hcloudOpts, dependsOn: [privateSubnet] });
});

// --- Load Balancer ---

const loadBalancer = new hcloud.LoadBalancer("public-load-balancer", {
  name: `${namePrefix}-lb`,
  loadBalancerType,
  location,
  labels: { ...labels, tier: "edge" },
}, hcloudOpts);
const loadBalancerIdNumber = loadBalancer.id.apply((id) => Number(id));

const loadBalancerNetwork = new hcloud.LoadBalancerNetwork("private-network-attachment", {
  loadBalancerId: loadBalancerIdNumber,
  subnetId: privateSubnet.id,
  ip: loadBalancerPrivateIpAddress,
  enablePublicInterface: true,
}, { ...hcloudOpts, dependsOn: [privateSubnet, loadBalancer] });

const loadBalancerTargets = appServers.map((server, i) => {
  const serverId = server.id.apply((id) => Number(id));
  return new hcloud.LoadBalancerTarget(`app-target-${i + 1}`, {
    type: "server",
    loadBalancerId: loadBalancerIdNumber,
    serverId,
    usePrivateIp: true,
  }, { ...hcloudOpts, dependsOn: [loadBalancerNetwork, server] });
});

// --- Cloudflare Origin Certificate uploaded to Hetzner ---
// The certificate is generated in the Cloudflare dashboard and valid for 15 years.
// It is trusted only by Cloudflare's edge — traffic must be proxied through Cloudflare.

const certificate = new hcloud.UploadedCertificate("tls-cert", {
  name: `${namePrefix}-cert`,
  certificate: pulumi.secret(tlsCertificate),
  privateKey: pulumi.secret(tlsPrivateKey),
  labels,
}, { ...hcloudOpts, dependsOn: loadBalancerTargets });

// --- LB services ---
// HTTPS on port 443 terminates TLS and forwards to servers on port 80.
// HTTP on port 80 redirects all traffic to HTTPS.

const httpsService = new hcloud.LoadBalancerService("https-service", {
  loadBalancerId: loadBalancer.id,
  protocol: "https",
  listenPort: 443,
  destinationPort: 80,
  http: {
    certificates: [certificate.id.apply((id) => Number(id))],
    redirectHttp: true,
  },
  healthCheck: {
    protocol: "http",
    port: 80,
    interval: 10,
    timeout: 5,
    retries: 3,
    http: {
      path: "/health",
      statusCodes: ["200"],
      response: "ok",
    },
  },
}, { ...hcloudOpts, dependsOn: [certificate] });

// --- Cloudflare DNS A record ---
// Proxied: traffic routes through Cloudflare before reaching the Load Balancer.
// This hides the real Load Balancer IP and enables DDoS protection and bot detection.

const dnsRecord = new cloudflare.Record("lb-dns-record", {
  zoneId: cloudflareZoneId,
  name: "@",
  type: "A",
  content: loadBalancer.ipv4,
  proxied: true,
  ttl: 1,
}, { ...cloudflareOpts, dependsOn: [httpsService] });

// --- Outputs ---

export const loadBalancerPublicIpv4 = loadBalancer.ipv4;
export const appUrl = pulumi.interpolate`https://${domain}/`;
export const appHealthUrl = pulumi.interpolate`https://${domain}/health`;
export const server1Name = appServers[0].name;
export const server1PrivateIp = pulumi.output(appPrivateIp1);
export const server2Name = appServers[1].name;
export const server2PrivateIp = pulumi.output(appPrivateIp2);
export const cloudflareNote = pulumi.interpolate`Traffic is proxied through Cloudflare — the Load Balancer IP is hidden from the public`;
