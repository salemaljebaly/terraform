import * as fs from "node:fs";
import * as path from "node:path";
import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";

const config = new pulumi.Config();
const stack = pulumi.getStack();
const project = pulumi.getProject();

const namePrefix = config.get("namePrefix") ?? `${project}-${stack}`;
const location = config.get("location") ?? "nbg1";
const networkZone = config.get("networkZone") ?? "eu-central";
const image = config.get("image") ?? "ubuntu-24.04";
const serverType = config.get("serverType") ?? "cax11";

const networkCidr = config.get("networkCidr") ?? "10.30.0.0/16";
const subnetCidr = config.get("subnetCidr") ?? "10.30.1.0/24";

const sshAllowedCidr = config.get("sshAllowedCidr") ?? "0.0.0.0/0";
const appServerType = config.get("appServerType") ?? "cax11";
const appPrivateIp = config.get("appPrivateIp") ?? "10.30.1.100";

const existingSshKeyName = config.get("existingSshKeyName");
const sshPublicKeyPath = config.get("sshPublicKeyPath");
const ybDownloadUrl =
  config.get("ybDownloadUrl") ??
  "https://software.yugabyte.com/releases/2025.2.0.1/yugabyte-2025.2.0.1-b1-el8-aarch64.tar.gz";

const nodeCount = config.getNumber("nodeCount") ?? 3;

if (!existingSshKeyName && !sshPublicKeyPath) {
  throw new pulumi.RunError("Set either `sshPublicKeyPath` or `existingSshKeyName` in Pulumi config.");
}
if (nodeCount < 3) {
  throw new pulumi.RunError("nodeCount must be at least 3 — YugabyteDB requires RF=3 for fault tolerance.");
}
if (nodeCount > 10) {
  pulumi.log.warn("Hetzner spread placement groups support a maximum of 10 servers. nodeCount > 10 may fail.");
}

// Hetzner CAX servers are ARM (Ampere). CX/CPX/CCX are x86. Catch mismatched binaries early.
const isArmServerType = serverType.toLowerCase().startsWith("cax");
const isAarch64Url = ybDownloadUrl.includes("aarch64");
if (isAarch64Url && !isArmServerType) {
  throw new pulumi.RunError(
    `ybDownloadUrl contains 'aarch64' but serverType '${serverType}' is not ARM-based (CAX series). ` +
    `Use an x86_64 YugabyteDB download URL for non-CAX server types.`,
  );
}
if (!isAarch64Url && isArmServerType) {
  pulumi.log.warn(
    `serverType '${serverType}' is ARM-based (CAX) but ybDownloadUrl does not contain 'aarch64'. Verify the binary is ARM-compatible.`,
  );
}

if (sshAllowedCidr === "0.0.0.0/0") {
  pulumi.log.warn("sshAllowedCidr is 0.0.0.0/0 — SSH port 22 is open to the entire internet. Set sshAllowedCidr to restrict access.");
}

const sshPublicKey = sshPublicKeyPath
  ? fs
      .readFileSync(path.resolve(sshPublicKeyPath.replace(/^~(?=$|\/|\\)/, process.env.HOME ?? "~")), "utf-8")
      .trim()
  : undefined;

const labels = {
  project,
  stack,
  managedBy: "pulumi",
  serverType,
};

const privateNetwork = new hcloud.Network(`${namePrefix}-network`, {
  name: `${namePrefix}-network`,
  ipRange: networkCidr,
  labels,
});
const privateNetworkId = privateNetwork.id.apply((id) => Number(id));

const privateSubnet = new hcloud.NetworkSubnet(`${namePrefix}-subnet`, {
  networkId: privateNetworkId,
  type: "cloud",
  networkZone,
  ipRange: subnetCidr,
});

const placementGroup = new hcloud.PlacementGroup(`${namePrefix}-spread`, {
  name: `${namePrefix}-spread`,
  type: "spread",
  labels,
});
const placementGroupId = placementGroup.id.apply((id) => Number(id));

const firewall = new hcloud.Firewall(`${namePrefix}-firewall`, {
  name: `${namePrefix}-firewall`,
  labels,
  rules: [
    {
      description: "ICMP from anywhere",
      direction: "in",
      protocol: "icmp",
      sourceIps: ["0.0.0.0/0", "::/0"],
    },
    {
      description: "SSH access",
      direction: "in",
      protocol: "tcp",
      port: "22",
      sourceIps: [sshAllowedCidr],
    },
    {
      description: "YSQL from private network only",
      direction: "in",
      protocol: "tcp",
      port: "5433",
      sourceIps: [subnetCidr],
    },
    {
      description: "YugabyteDB web UIs and YCQL from private network only",
      direction: "in",
      protocol: "tcp",
      port: "7000-9000",
      sourceIps: [subnetCidr],
    },
    {
      description: "Private cluster RPC traffic",
      direction: "in",
      protocol: "tcp",
      port: "any",
      sourceIps: [subnetCidr],
    },
  ],
});
const firewallId = firewall.id.apply((id) => Number(id));

// App server firewall — HTTP open to internet, DB ports not present here.
const appFirewall = new hcloud.Firewall(`${namePrefix}-app-firewall`, {
  name: `${namePrefix}-app-firewall`,
  labels,
  rules: [
    {
      description: "ICMP from anywhere",
      direction: "in",
      protocol: "icmp",
      sourceIps: ["0.0.0.0/0", "::/0"],
    },
    {
      description: "HTTP from anywhere",
      direction: "in",
      protocol: "tcp",
      port: "80",
      sourceIps: ["0.0.0.0/0", "::/0"],
    },
    {
      description: "SSH access",
      direction: "in",
      protocol: "tcp",
      port: "22",
      sourceIps: [sshAllowedCidr],
    },
  ],
});
const appFirewallId = appFirewall.id.apply((id) => Number(id));

const sshKeyRef: pulumi.Input<string> = existingSshKeyName
  ? existingSshKeyName
  : new hcloud.SshKey(`${namePrefix}-ssh-key`, {
      name: `${namePrefix}-ssh-key`,
      publicKey: sshPublicKey!,
      labels,
    }).id;

const cloudInitTemplate = fs.readFileSync(path.join(__dirname, "scripts", "cloud-init.sh.tmpl"), "utf-8");
const appServerTemplate = fs.readFileSync(path.join(__dirname, "scripts", "app-server.yaml"), "utf-8");

interface NodeSpec {
  name: string;
  privateIp: string;
  publicIpv4: boolean;
  cloudLocation: string;
  joinIp?: string;
}

// Nodes are assigned sequential private IPs starting at 10.30.1.11.
// Cloud locations cycle through az1/az2/az3 so YugabyteDB sees each node
// in a different fault zone, regardless of total node count.
const bootstrapIp = "10.30.1.11";
const nodeSpecs: NodeSpec[] = Array.from({ length: nodeCount }, (_, i) => ({
  name: `${namePrefix}-node-${i + 1}`,
  privateIp: `10.30.1.${11 + i}`,
  publicIpv4: true,
  cloudLocation: `hetzner.${location}.az${(i % 3) + 1}`,
  joinIp: i === 0 ? undefined : bootstrapIp,
}));

function renderCloudInit(spec: NodeSpec): string {
  return cloudInitTemplate
    .replaceAll("__YB_DOWNLOAD_URL__", ybDownloadUrl)
    .replaceAll("__NODE_IP__", spec.privateIp)
    .replaceAll("__JOIN_IP__", spec.joinIp ?? "")
    .replaceAll("__CLOUD_LOCATION__", spec.cloudLocation);
}

const servers = nodeSpecs.map((spec) => {
  return new hcloud.Server(
    spec.name,
    {
      name: spec.name,
      location,
      image,
      serverType,
      placementGroupId,
      firewallIds: [firewallId],
      labels,
      sshKeys: [sshKeyRef],
      publicNets: [
        {
          ipv4Enabled: spec.publicIpv4,
          ipv6Enabled: false,
        },
      ],
      networks: [
        {
          networkId: privateNetworkId,
          ip: spec.privateIp,
        },
      ],
      userData: renderCloudInit(spec),
    },
    {
      dependsOn: [privateSubnet],
      deleteBeforeReplace: true,
    },
  );
});

// --- App server ---
// Sits on the private network alongside DB nodes.
// HTTP (port 80) is open to the internet; DB ports are unreachable from outside.

const appServer = new hcloud.Server(`${namePrefix}-app`, {
  name: `${namePrefix}-app`,
  location,
  image,
  serverType: appServerType,
  firewallIds: [appFirewallId],
  labels: { ...labels, tier: "app" },
  sshKeys: [sshKeyRef],
  publicNets: [{ ipv4Enabled: true, ipv6Enabled: false }],
  networks: [{ networkId: privateNetworkId, ip: appPrivateIp }],
  userData: appServerTemplate.replaceAll("__DB_HOST__", bootstrapIp),
}, { dependsOn: [privateSubnet, ...servers] });

const publicNode = servers[0];

export const publicIpv4 = publicNode.ipv4Address;
export const privateYsqlHost = nodeSpecs[0].privateIp;
export const publicIps = pulumi.all(servers.map((s) => s.ipv4Address)).apply((ips) =>
  ips.map((ip, i) => ({ node: nodeSpecs[i].name, ip })),
);
export const privateIps = pulumi.all(servers.map((s) => s.networks)).apply((allNetworks) =>
  allNetworks.map((networks, idx) => ({
    node: nodeSpecs[idx].name,
    privateIp: networks?.[0]?.ip ?? "unknown",
  })),
);
export const sshToPublicNode = pulumi.interpolate`ssh root@${publicNode.ipv4Address}`;
export const ysqlConnection = pulumi.interpolate`postgresql://yugabyte@${nodeSpecs[0].privateIp}:5433/yugabyte`;
export const ysqlSshTunnel = pulumi.interpolate`ssh -L 5433:${nodeSpecs[0].privateIp}:5433 root@${publicNode.ipv4Address}`;
export const appPublicIp = appServer.ipv4Address;
export const appUrl = pulumi.interpolate`http://${appServer.ipv4Address}`;
export const appHealthUrl = pulumi.interpolate`http://${appServer.ipv4Address}/health`;
export const sshToApp = pulumi.interpolate`ssh root@${appServer.ipv4Address}`;
export const benchmarkCmd = pulumi.interpolate`ssh root@${appServer.ipv4Address} 'pgbench -h ${bootstrapIp} -p 5433 -U yugabyte -c 32 -j 8 -T 120 yugabyte'`;
