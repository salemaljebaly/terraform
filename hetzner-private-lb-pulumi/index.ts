import * as fs from "node:fs";
import * as path from "node:path";
import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";

const stack = pulumi.getStack();
const project = pulumi.getProject();
const config = new pulumi.Config();
const projectConfig = new pulumi.Config(project);

const hcloudToken = config.requireSecret("hcloudToken");
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

const provider = new hcloud.Provider("hcloud", { token: hcloudToken });
const providerOpts: pulumi.CustomResourceOptions = { provider };

const network = new hcloud.Network("private-network", {
  name: `${namePrefix}-network`,
  ipRange: networkCidr,
  labels,
}, providerOpts);
const networkId = network.id.apply((id) => Number(id));

const privateSubnet = new hcloud.NetworkSubnet("private-subnet", {
  networkId,
  type: "cloud",
  networkZone,
  ipRange: privateSubnetCidr,
}, providerOpts);

const sshKeyRef: pulumi.Input<string> = existingSshKeyName
  ? existingSshKeyName
  : new hcloud.SshKey("deployer-key", {
    name: `${namePrefix}-ssh-key`,
    publicKey: sshPublicKey!,
    labels,
  }, providerOpts).id;

// Firewall: HTTP only from the LB private IP, SSH only from your allowed CIDRs.
// App servers have public IPs, so there is no default SSH access — you must set sshAllowedCidrs.
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
}, providerOpts);
const appFirewallId = appFirewall.id.apply((id) => Number(id));

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
  }, { ...providerOpts, dependsOn: [privateSubnet] });
});

const loadBalancer = new hcloud.LoadBalancer("public-load-balancer", {
  name: `${namePrefix}-lb`,
  loadBalancerType,
  location,
  labels: { ...labels, tier: "edge" },
}, providerOpts);
const loadBalancerIdNumber = loadBalancer.id.apply((id) => Number(id));

const loadBalancerNetwork = new hcloud.LoadBalancerNetwork("private-network-attachment", {
  loadBalancerId: loadBalancerIdNumber,
  subnetId: privateSubnet.id,
  ip: loadBalancerPrivateIpAddress,
  enablePublicInterface: true,
}, { ...providerOpts, dependsOn: [privateSubnet, loadBalancer] });

const loadBalancerTargets = appServers.map((server, i) => {
  const serverId = server.id.apply((id) => Number(id));
  return new hcloud.LoadBalancerTarget(`app-target-${i + 1}`, {
    type: "server",
    loadBalancerId: loadBalancerIdNumber,
    serverId,
    usePrivateIp: true,
  }, { ...providerOpts, dependsOn: [loadBalancerNetwork, server] });
});

const httpService = new hcloud.LoadBalancerService("http-service", {
  loadBalancerId: loadBalancer.id,
  protocol: "http",
  listenPort: 80,
  destinationPort: 80,
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
}, { ...providerOpts, dependsOn: loadBalancerTargets });

export const loadBalancerPublicIpv4 = loadBalancer.ipv4;
export const loadBalancerPrivateIp = pulumi.output(loadBalancerPrivateIpAddress);
export const appUrl = pulumi.interpolate`http://${loadBalancer.ipv4}/`;
export const appHealthUrl = pulumi.interpolate`http://${loadBalancer.ipv4}/health`;
export const server1Name = appServers[0].name;
export const server1PrivateIp = pulumi.output(appPrivateIp1);
export const server2Name = appServers[1].name;
export const server2PrivateIp = pulumi.output(appPrivateIp2);
export const loadBalancerServiceId = httpService.id;
