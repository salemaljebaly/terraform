import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as random from "@pulumi/random";
import * as fs from "fs";
import * as path from "path";

// ── Config ────────────────────────────────────────────────────────────────────
const config = new pulumi.Config();
const projectConfig = new pulumi.Config("queue-buffer-hetzner-pulumi");

const hcloudToken    = config.requireSecret("hcloudToken");
const sshKeyName     = config.require("sshKeyName");

const location       = projectConfig.get("location")       ?? "nbg1";
const networkZone    = projectConfig.get("networkZone")     ?? "eu-central";
const dbServerType   = projectConfig.get("dbServerType")    ?? "cx22";
const queueServerType= projectConfig.get("queueServerType") ?? "cx22";
const serverImage    = projectConfig.get("serverImage")     ?? "ubuntu-24.04";
const networkCidr    = projectConfig.get("networkCidr")     ?? "10.10.0.0/16";
const subnetCidr     = projectConfig.get("subnetCidr")      ?? "10.10.1.0/24";
const dbPrivateIp    = projectConfig.get("dbPrivateIp")     ?? "10.10.1.10";
const queuePrivateIp = projectConfig.get("queuePrivateIp")  ?? "10.10.1.20";
const workerConcurrency = projectConfig.get("workerConcurrency") ?? "10";
const postgresDb     = projectConfig.get("postgresDb")      ?? "appdb";
const postgresUser   = projectConfig.get("postgresUser")    ?? "appuser";

// ── Secrets ───────────────────────────────────────────────────────────────────
const postgresPassword = new random.RandomPassword("postgres-password", {
  length: 24,
  special: false,
});

const rabbitPassword = new random.RandomPassword("rabbit-password", {
  length: 24,
  special: false,
});

// ── Provider ──────────────────────────────────────────────────────────────────
const provider = new hcloud.Provider("hcloud", {
  token: hcloudToken,
});

const providerOpts = { provider };

// ── SSH Key ───────────────────────────────────────────────────────────────────
const sshKey = hcloud.getSshKeyOutput({ name: sshKeyName }, providerOpts);
const sshKeyId = sshKey.apply(k => String(k.id));

// ── Network ───────────────────────────────────────────────────────────────────
const network = new hcloud.Network("main-network", {
  name: `${pulumi.getProject()}-network`,
  ipRange: networkCidr,
  labels: { project: pulumi.getProject(), managedBy: "pulumi" },
}, providerOpts);

const subnet = new hcloud.NetworkSubnet("main-subnet", {
  networkId: network.id.apply(id => Number(id)),
  type: "cloud",
  networkZone,
  ipRange: subnetCidr,
}, { ...providerOpts, dependsOn: [network] });

// ── Firewalls ─────────────────────────────────────────────────────────────────

// DB server: only accessible from queue server (private network)
const dbFirewall = new hcloud.Firewall("db-firewall", {
  name: `${pulumi.getProject()}-db-fw`,
  rules: [
    {
      direction: "in",
      protocol: "tcp",
      port: "5432",
      sourceIps: [subnetCidr],
      description: "PostgreSQL from private subnet only",
    },
    {
      direction: "in",
      protocol: "tcp",
      port: "22",
      sourceIps: [`${queuePrivateIp}/32`],
      description: "SSH from queue server (bastion)",
    },
  ],
  labels: { project: pulumi.getProject(), role: "db" },
}, providerOpts);

// Queue server: RabbitMQ AMQP (5672) + management UI (15672) + SSH from your IP
const sshAllowedCidrs = config.getObject<string[]>("sshAllowedCidrs") ?? ["0.0.0.0/0"];

const queueFirewall = new hcloud.Firewall("queue-firewall", {
  name: `${pulumi.getProject()}-queue-fw`,
  rules: [
    ...sshAllowedCidrs.map((cidr, i) => ({
      direction: "in" as const,
      protocol: "tcp" as const,
      port: "22",
      sourceIps: [cidr],
      description: `SSH access ${i}`,
    })),
    {
      direction: "in",
      protocol: "tcp",
      port: "5672",
      sourceIps: ["0.0.0.0/0", "::/0"],
      description: "RabbitMQ AMQP — restrict to your app IPs in production",
    },
    {
      direction: "in",
      protocol: "tcp",
      port: "15672",
      sourceIps: sshAllowedCidrs,
      description: "RabbitMQ management UI",
    },
  ],
  labels: { project: pulumi.getProject(), role: "queue" },
}, providerOpts);

// ── Cloud-init templates ──────────────────────────────────────────────────────
const tplDir = path.join(__dirname, "cloud-init");

function renderTemplate(filename: string, vars: Record<string, pulumi.Input<string>>): pulumi.Output<string> {
  const raw = fs.readFileSync(path.join(tplDir, filename), "utf8");
  return pulumi.all(Object.entries(vars).map(([k, v]) => pulumi.output(v).apply(val => [k, val] as [string, string])))
    .apply(entries => {
      let result = raw;
      for (const [k, v] of entries) {
        result = result.replaceAll(`\${${k}}`, v);
      }
      return result;
    });
}

// ── Database Server ───────────────────────────────────────────────────────────
const dbCloudInit = renderTemplate("db-server.yaml", {
  POSTGRES_DB:       postgresDb,
  POSTGRES_USER:     postgresUser,
  POSTGRES_PASSWORD: postgresPassword.result,
});

const dbServer = new hcloud.Server("db-server", {
  name: `${pulumi.getProject()}-db`,
  serverType: dbServerType,
  image: serverImage,
  location,
  sshKeys: [sshKeyId],
  firewallIds: [dbFirewall.id.apply(id => Number(id))],
  networks: [{
    networkId: network.id.apply(id => Number(id)),
    ip: dbPrivateIp,
  }],
  publicNets: [{
    ipv4Enabled: false,
    ipv6Enabled: false,
  }],
  userData: dbCloudInit,
  labels: { project: pulumi.getProject(), role: "db" },
}, { ...providerOpts, dependsOn: [subnet] });

// ── Queue + Worker Server ─────────────────────────────────────────────────────
const queueCloudInit = renderTemplate("queue-server.yaml", {
  RABBITMQ_USER:      "admin",
  RABBITMQ_PASSWORD:  rabbitPassword.result,
  POSTGRES_HOST:      dbPrivateIp,
  POSTGRES_DB:        postgresDb,
  POSTGRES_USER:      postgresUser,
  POSTGRES_PASSWORD:  postgresPassword.result,
  WORKER_CONCURRENCY: workerConcurrency,
});

const queueServer = new hcloud.Server("queue-server", {
  name: `${pulumi.getProject()}-queue`,
  serverType: queueServerType,
  image: serverImage,
  location,
  sshKeys: [sshKeyId],
  firewallIds: [queueFirewall.id.apply(id => Number(id))],
  networks: [{
    networkId: network.id.apply(id => Number(id)),
    ip: queuePrivateIp,
  }],
  publicNets: [{
    ipv4Enabled: true,
    ipv6Enabled: false,
  }],
  userData: queueCloudInit,
  labels: { project: pulumi.getProject(), role: "queue" },
}, { ...providerOpts, dependsOn: [subnet, dbServer] });

// ── Outputs ───────────────────────────────────────────────────────────────────
export const queuePublicIp      = queueServer.ipv4Address;
export const dbPrivateAddress   = dbPrivateIp;
export const rabbitmqAmqpUrl    = pulumi.interpolate`amqp://admin:${rabbitPassword.result}@${queueServer.ipv4Address}:5672`;
export const rabbitmqManagement = pulumi.interpolate`http://${queueServer.ipv4Address}:15672`;
export const postgresPrivateUrl = pulumi.interpolate`postgresql://${postgresUser}:${postgresPassword.result}@${dbPrivateIp}:5432/${postgresDb}`;
export const sshToQueue         = pulumi.interpolate`ssh root@${queueServer.ipv4Address}`;
export const sshToDb            = pulumi.interpolate`ssh -J root@${queueServer.ipv4Address} root@${dbPrivateIp}`;
