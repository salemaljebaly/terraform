import * as pulumi from "@pulumi/pulumi";
import * as hcloud from "@pulumi/hcloud";
import * as random from "@pulumi/random";
import * as fs from "fs";
import * as path from "path";

// ── Config ────────────────────────────────────────────────────────────────────
const config = new pulumi.Config();
const projectConfig = new pulumi.Config("queue-buffer-hetzner-pulumi");

const hcloudToken        = config.requireSecret("hcloudToken");
const existingSshKeyName = config.get("sshKeyName");
const sshPublicKeyPath   = config.get("sshPublicKeyPath");

if (!existingSshKeyName && !sshPublicKeyPath) {
  throw new pulumi.RunError(
    "Set either `sshPublicKeyPath` (path to your public key) or `sshKeyName` (existing Hetzner key name)."
  );
}

const sshPublicKey = sshPublicKeyPath
  ? fs.readFileSync(
      path.resolve(sshPublicKeyPath.replace(/^~(?=$|\/|\\)/, process.env.HOME ?? "~")),
      "utf-8"
    ).trim()
  : undefined;

const location        = projectConfig.get("location")        ?? "nbg1";
const networkZone     = projectConfig.get("networkZone")      ?? "eu-central";
const dbServerType    = projectConfig.get("dbServerType")     ?? "cx23";
const queueServerType = projectConfig.get("queueServerType")  ?? "cx23";
// Hetzner Docker CE app — Docker pre-installed, fastest boot time
const dbImage         = projectConfig.get("dbImage")          ?? "docker-ce";
const queueImage      = projectConfig.get("queueImage")       ?? "docker-ce";
const networkCidr     = projectConfig.get("networkCidr")      ?? "10.10.0.0/16";
const subnetCidr      = projectConfig.get("subnetCidr")       ?? "10.10.1.0/24";
const dbPrivateIp     = projectConfig.get("dbPrivateIp")      ?? "10.10.1.10";
const queuePrivateIp  = projectConfig.get("queuePrivateIp")   ?? "10.10.1.20";
const workerConcurrency = projectConfig.get("workerConcurrency") ?? "10";
const postgresDb      = projectConfig.get("postgresDb")       ?? "appdb";
const postgresUser    = projectConfig.get("postgresUser")     ?? "appuser";
const sshAllowedCidrs = config.getObject<string[]>("sshAllowedCidrs") ?? ["0.0.0.0/0"];

// ── Secrets ───────────────────────────────────────────────────────────────────
const postgresPassword = new random.RandomPassword("postgres-password", {
  length: 24, special: false,
});

const rabbitPassword = new random.RandomPassword("rabbit-password", {
  length: 24, special: false,
});

// ── Provider ──────────────────────────────────────────────────────────────────
const provider = new hcloud.Provider("hcloud", { token: hcloudToken });
const providerOpts = { provider };

// ── SSH Key ───────────────────────────────────────────────────────────────────
const sshKeyRef: pulumi.Input<string> = existingSshKeyName
  ? existingSshKeyName
  : new hcloud.SshKey(`${pulumi.getProject()}-ssh-key`, {
      name: `${pulumi.getProject()}-ssh-key`,
      publicKey: sshPublicKey!,
      labels: { project: pulumi.getProject(), managedBy: "pulumi" },
    }, providerOpts).id;

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

// DB firewall: SSH from your IP, PostgreSQL from queue server only
const dbFirewall = new hcloud.Firewall("db-firewall", {
  name: `${pulumi.getProject()}-db-fw`,
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
      port: "5432",
      sourceIps: [`${queuePrivateIp}/32`],
      description: "PostgreSQL from queue server only",
    },
  ],
  labels: { project: pulumi.getProject(), role: "db" },
}, providerOpts);

// Queue firewall: SSH + RabbitMQ AMQP + management UI
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
  return pulumi.all(vars).apply(resolvedVars => {
    let result = raw;
    for (const [k, v] of Object.entries(resolvedVars)) {
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
  name:        `${pulumi.getProject()}-db`,
  serverType:  dbServerType,
  image:       dbImage,
  location,
  sshKeys:     [sshKeyRef],
  firewallIds: [dbFirewall.id.apply(id => Number(id))],
  networks:    [{ networkId: network.id.apply(id => Number(id)), ip: dbPrivateIp }],
  publicNets:  [{ ipv4Enabled: true, ipv6Enabled: false }],
  userData:    dbCloudInit,
  labels:      { project: pulumi.getProject(), role: "db" },
}, { ...providerOpts, dependsOn: [subnet] });

// ── Queue + Worker Server ─────────────────────────────────────────────────────
const queueCloudInit = renderTemplate("queue-server.yaml", {
  RABBITMQ_USER:      "admin",
  RABBITMQ_PASSWORD:  rabbitPassword.result,
  POSTGRES_HOST:      dbPrivateIp,  // use private IP — DB firewall allows from queue private IP only
  POSTGRES_DB:        postgresDb,
  POSTGRES_USER:      postgresUser,
  POSTGRES_PASSWORD:  postgresPassword.result,
  WORKER_CONCURRENCY: workerConcurrency,
});

const queueServer = new hcloud.Server("queue-server", {
  name:        `${pulumi.getProject()}-queue`,
  serverType:  queueServerType,
  image:       queueImage,
  location,
  sshKeys:     [sshKeyRef],
  firewallIds: [queueFirewall.id.apply(id => Number(id))],
  networks:    [{ networkId: network.id.apply(id => Number(id)), ip: queuePrivateIp }],
  publicNets:  [{ ipv4Enabled: true, ipv6Enabled: false }],
  userData:    queueCloudInit,
  labels:      { project: pulumi.getProject(), role: "queue" },
}, { ...providerOpts, dependsOn: [subnet, dbServer] });

// ── Outputs ───────────────────────────────────────────────────────────────────
export const queuePublicIp      = queueServer.ipv4Address;
export const dbPublicIp         = dbServer.ipv4Address;
export const rabbitmqAmqpUrl    = pulumi.interpolate`amqp://admin:${rabbitPassword.result}@${queueServer.ipv4Address}:5672`;
export const rabbitmqManagement = pulumi.interpolate`http://${queueServer.ipv4Address}:15672`;
export const postgresUrl        = pulumi.interpolate`postgresql://${postgresUser}:${postgresPassword.result}@${dbServer.ipv4Address}:5432/${postgresDb}`;
export const sshToQueue         = pulumi.interpolate`ssh root@${queueServer.ipv4Address}`;
export const sshToDb            = pulumi.interpolate`ssh root@${dbServer.ipv4Address}`;
