import * as fs from "node:fs";
import * as path from "node:path";
import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as random from "@pulumi/random";

const config = new pulumi.Config();
const stack = pulumi.getStack();
const project = pulumi.getProject();

const clusterName = config.get("clusterName") ?? `${project}-${stack}`;
const location = config.get("location") ?? "nbg1";
const networkZone = config.get("networkZone") ?? "eu-central";
const masterServerType = config.get("masterServerType") ?? "cax21";
const workerServerType = config.get("workerServerType") ?? "cax11";
const workerCount = config.getNumber("workerCount") ?? 3;
const workerMinCount = config.getNumber("workerMinCount") ?? 3;
const workerMaxCount = config.getNumber("workerMaxCount") ?? 10;
const k3sVersion = config.get("k3sVersion") ?? "v1.34.1+k3s1";
const sshAllowedCidr = config.get("sshAllowedCidr") ?? "0.0.0.0/0";
const k8sApiAllowedCidr = config.get("k8sApiAllowedCidr") ?? sshAllowedCidr;

const existingSshKeyName = config.get("existingSshKeyName");
const sshPublicKeyPath = config.get("sshPublicKeyPath");

if (!existingSshKeyName && !sshPublicKeyPath) {
  throw new pulumi.RunError("Set either `sshPublicKeyPath` or `existingSshKeyName` in Pulumi config.");
}
if (workerCount < 3) {
  throw new pulumi.RunError("workerCount must be at least 3 — YugabyteDB requires RF=3.");
}
if (workerMinCount < 3) {
  throw new pulumi.RunError("workerMinCount must be at least 3 — YugabyteDB requires RF=3.");
}
if (sshAllowedCidr === "0.0.0.0/0") {
  pulumi.log.warn("sshAllowedCidr is 0.0.0.0/0 — SSH port 22 is open to the entire internet.");
}
if (k8sApiAllowedCidr === "0.0.0.0/0") {
  pulumi.log.warn("k8sApiAllowedCidr is 0.0.0.0/0 — K8s API port 6443 is open to the entire internet.");
}

const sshPublicKey = sshPublicKeyPath
  ? fs.readFileSync(path.resolve(sshPublicKeyPath.replace(/^~(?=$|\/|\\)/, process.env.HOME ?? "~")), "utf-8").trim()
  : undefined;

const labels = { project, stack, managedBy: "pulumi", clusterName };

// ─── K3s cluster token (generated once, stored in Pulumi state) ────────────
const k3sToken = new random.RandomPassword(`${clusterName}-k3s-token`, {
  length: 64,
  special: false,
});

// ─── Network ────────────────────────────────────────────────────────────────
const MASTER_IP = "10.0.1.10";
const NETWORK_CIDR = "10.0.0.0/16";
const SUBNET_CIDR = "10.0.1.0/24";

const network = new hcloud.Network(`${clusterName}-network`, {
  name: `${clusterName}-network`,
  ipRange: NETWORK_CIDR,
  labels,
});
const networkId = network.id.apply((id) => Number(id));

const subnet = new hcloud.NetworkSubnet(`${clusterName}-subnet`, {
  networkId,
  type: "cloud",
  networkZone,
  ipRange: SUBNET_CIDR,
});

// ─── Firewalls ───────────────────────────────────────────────────────────────
const masterFirewall = new hcloud.Firewall(`${clusterName}-master-fw`, {
  name: `${clusterName}-master-fw`,
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
      description: "K3s API server",
      direction: "in",
      protocol: "tcp",
      port: "6443",
      sourceIps: [k8sApiAllowedCidr],
    },
    {
      description: "Private cluster TCP",
      direction: "in",
      protocol: "tcp",
      port: "any",
      sourceIps: [SUBNET_CIDR],
    },
    {
      description: "Private cluster UDP",
      direction: "in",
      protocol: "udp",
      port: "any",
      sourceIps: [SUBNET_CIDR],
    },
  ],
});
const masterFirewallId = masterFirewall.id.apply((id) => Number(id));

const workerFirewall = new hcloud.Firewall(`${clusterName}-worker-fw`, {
  name: `${clusterName}-worker-fw`,
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
      description: "NodePort services",
      direction: "in",
      protocol: "tcp",
      port: "30000-32767",
      sourceIps: ["0.0.0.0/0"],
    },
    {
      description: "Private cluster TCP",
      direction: "in",
      protocol: "tcp",
      port: "any",
      sourceIps: [SUBNET_CIDR],
    },
    {
      description: "Private cluster UDP",
      direction: "in",
      protocol: "udp",
      port: "any",
      sourceIps: [SUBNET_CIDR],
    },
  ],
});
const workerFirewallId = workerFirewall.id.apply((id) => Number(id));

// ─── SSH Key ─────────────────────────────────────────────────────────────────
const sshKeyRef: pulumi.Input<string> = existingSshKeyName
  ? existingSshKeyName
  : new hcloud.SshKey(`${clusterName}-ssh-key`, {
      name: `${clusterName}-ssh-key`,
      publicKey: sshPublicKey!,
      labels,
    }).id;

// ─── Script templates ────────────────────────────────────────────────────────
const masterInitTemplate = fs.readFileSync(
  path.join(__dirname, "scripts", "k3s-master-init.sh.tmpl"),
  "utf-8",
);
const workerJoinTemplate = fs.readFileSync(
  path.join(__dirname, "scripts", "k3s-worker-join.sh.tmpl"),
  "utf-8",
);

function renderMasterInit(token: string): string {
  return masterInitTemplate
    .replaceAll("__K3S_VERSION__", k3sVersion)
    .replaceAll("__K3S_TOKEN__", token)
    .replaceAll("__MASTER_IP__", MASTER_IP)
    .replaceAll("__CLUSTER_NAME__", clusterName)
    .replaceAll("__NETWORK_NAME__", `${clusterName}-network`);
}

function renderWorkerJoin(token: string): string {
  return workerJoinTemplate
    .replaceAll("__K3S_VERSION__", k3sVersion)
    .replaceAll("__K3S_TOKEN__", token)
    .replaceAll("__MASTER_IP__", MASTER_IP)
    .replaceAll("__CLUSTER_NAME__", clusterName);
}

// ─── Master node ─────────────────────────────────────────────────────────────
// Tainted with CriticalAddonsOnly=true:NoSchedule so YugabyteDB workloads
// never land on the control plane node.
const master = new hcloud.Server(`${clusterName}-master`, {
  name: `${clusterName}-master`,
  location,
  image: "ubuntu-24.04",
  serverType: masterServerType,
  firewallIds: [masterFirewallId],
  labels: { ...labels, role: "master" },
  sshKeys: [sshKeyRef],
  publicNets: [{ ipv4Enabled: true, ipv6Enabled: false }],
  networks: [{ networkId, ip: MASTER_IP }],
  userData: k3sToken.result.apply((token) => renderMasterInit(token)),
}, { dependsOn: [subnet] });

// ─── Worker nodes ────────────────────────────────────────────────────────────
// Initial worker count is set by workerCount config.
// The Cluster Autoscaler (deployed in Phase 2) scales from workerMinCount
// to workerMaxCount based on pending pod pressure.
const workers = Array.from({ length: workerCount }, (_, i) => {
  const workerIp = `10.0.1.${20 + i}`;
  return new hcloud.Server(`${clusterName}-worker-${i + 1}`, {
    name: `${clusterName}-worker-${i + 1}`,
    location,
    image: "ubuntu-24.04",
    serverType: workerServerType,
    firewallIds: [workerFirewallId],
    labels: {
      ...labels,
      role: "worker",
      "hcloud/node-group": `${clusterName}-worker`,
    },
    sshKeys: [sshKeyRef],
    publicNets: [{ ipv4Enabled: true, ipv6Enabled: false }],
    networks: [{ networkId, ip: workerIp }],
    userData: k3sToken.result.apply((token) => renderWorkerJoin(token)),
  }, { dependsOn: [subnet, master] });
});

// ─── Outputs ─────────────────────────────────────────────────────────────────
export const masterIp = master.ipv4Address;
export const sshToMaster = pulumi.interpolate`ssh root@${master.ipv4Address}`;
export const kubeconfigCmd = pulumi.interpolate`scp root@${master.ipv4Address}:/etc/rancher/k3s/k3s.yaml ./kubeconfig.yaml && sed -i '' 's/127.0.0.1/${master.ipv4Address}/g' ./kubeconfig.yaml`;
export const workerIps = pulumi.all(workers.map((w) => w.ipv4Address));
export const clusterNameOutput = clusterName;
export const networkNameOutput = `${clusterName}-network`;
export const sshKeyNameOutput = existingSshKeyName ?? `${clusterName}-ssh-key`;
export const workerFirewallName = `${clusterName}-worker-fw`;
export const autoscalerNodeGroup = `${clusterName}-worker`;

// Exported as secret — used by install-k8s.sh to build HCLOUD_CLUSTER_CONFIG
export const k3sTokenOutput = pulumi.secret(k3sToken.result);

// Autoscaler node spec string — passed to --nodes flag
// Format: min:max:SERVER_TYPE:LOCATION:node-group-name
export const autoscalerNodeSpec = `${workerMinCount}:${workerMaxCount}:${workerServerType.toUpperCase()}:${location.toUpperCase()}:${clusterName}-worker`;
