#!/usr/bin/env bash
# Phase 2: Install K8s components after `pulumi up`.
#
# Prerequisites:
#   - pulumi up completed
#   - HCLOUD_TOKEN in environment
#   - kubectl, helm in PATH
#
# Usage:
#   set -a && source .env && set +a
#   ./scripts/install-k8s.sh
set -euo pipefail

# ── Stack outputs ─────────────────────────────────────────────────────────────
echo "==> Reading stack outputs..."
MASTER_IP=$(pulumi stack output masterIp)
CLUSTER_NAME=$(pulumi stack output clusterNameOutput)
NETWORK_NAME=$(pulumi stack output networkNameOutput)
SSH_KEY_NAME=$(pulumi stack output sshKeyNameOutput)
WORKER_FIREWALL=$(pulumi stack output workerFirewallName)
NODE_SPEC=$(pulumi stack output autoscalerNodeSpec)
K3S_TOKEN=$(pulumi stack output --show-secrets k3sTokenOutput)
K3S_VERSION=$(pulumi stack output k3sVersion 2>/dev/null || echo "v1.34.1+k3s1")

echo "    Cluster       : $CLUSTER_NAME"
echo "    Master IP     : $MASTER_IP"
echo "    Node spec     : $NODE_SPEC"
echo "    Worker firewall: $WORKER_FIREWALL"

# ── Kubeconfig ────────────────────────────────────────────────────────────────
echo ""
echo "==> Downloading kubeconfig..."
scp -o StrictHostKeyChecking=no root@"$MASTER_IP":/etc/rancher/k3s/k3s.yaml ./kubeconfig.yaml
sed -i.bak "s/127.0.0.1/$MASTER_IP/g" ./kubeconfig.yaml && rm ./kubeconfig.yaml.bak
export KUBECONFIG="$(pwd)/kubeconfig.yaml"

echo ""
echo "==> Waiting for all nodes Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

# ── Hetzner secrets ───────────────────────────────────────────────────────────
echo ""
echo "==> Creating hcloud secret (token + network)..."
kubectl create secret generic hcloud \
  --namespace kube-system \
  --from-literal=token="${HCLOUD_TOKEN}" \
  --from-literal=network="${NETWORK_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Hetzner CCM via Helm ─────────────────────────────────────────────────────
# FIX 1: Use Helm with networking.enabled=true so pod traffic routes over the
# private network. The raw YAML URL does not have this enabled by default.
echo ""
echo "==> Installing Hetzner CCM via Helm..."
helm repo add hcloud https://charts.hetzner.cloud 2>/dev/null || true
helm repo update hcloud

helm upgrade --install hccm hcloud/hcloud-cloud-controller-manager \
  --namespace kube-system \
  --set networking.enabled=true \
  --set networking.clusterCIDR=10.42.0.0/16 \
  --wait --timeout 5m

# ── Hetzner CSI via Helm ──────────────────────────────────────────────────────
echo ""
echo "==> Installing Hetzner CSI driver via Helm..."
# Delete StorageClass before CSI install to avoid reclaimPolicy field manager conflict
kubectl delete storageclass hcloud-volumes --ignore-not-found=true
helm upgrade --install hcloud-csi hcloud/hcloud-csi \
  --namespace kube-system \
  --wait --timeout 5m

# ── StorageClass ──────────────────────────────────────────────────────────────
echo ""
echo "==> Applying StorageClass..."
# Override CSI default StorageClass with our settings (Retain policy, count:1)
kubectl delete storageclass hcloud-volumes --ignore-not-found=true
kubectl apply -f k8s/hetzner-ccm/storageclass.yaml

# ── Cluster Autoscaler ────────────────────────────────────────────────────────
echo ""
echo "==> Setting up Cluster Autoscaler..."

# Render the worker join script with the real token
WORKER_JOIN_RENDERED=$(sed \
  -e "s/__K3S_VERSION__/${K3S_VERSION}/g" \
  -e "s/__K3S_TOKEN__/${K3S_TOKEN}/g" \
  -e "s/__MASTER_IP__/10.0.1.10/g" \
  -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
  scripts/k3s-worker-join.sh.tmpl)

# FIX 2 + 3: Use HCLOUD_CLUSTER_CONFIG (new format) instead of HCLOUD_CLOUD_INIT.
# This specifies the ARM64 image explicitly so autoscaler creates CAX (ARM) nodes,
# and sets the worker firewall so new nodes are protected immediately.
CLUSTER_CONFIG_JSON=$(cat <<EOF
{
  "imagesForArch": {
    "arm64": "ubuntu-24.04",
    "amd64": "ubuntu-24.04"
  },
  "defaultSubnetIPRange": "10.0.0.0/16",
  "nodeConfigs": {
    "${CLUSTER_NAME}-worker": {
      "cloudInit": "$(echo "${WORKER_JOIN_RENDERED}" | base64 | tr -d '\n')"
    }
  }
}
EOF
)
CLUSTER_CONFIG_B64=$(echo "${CLUSTER_CONFIG_JSON}" | base64 | tr -d '\n')

kubectl create secret generic autoscaler-cluster-config \
  --namespace kube-system \
  --from-literal=config="${CLUSTER_CONFIG_B64}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Render and apply autoscaler manifest
sed \
  -e "s/__NODE_SPEC__/${NODE_SPEC}/g" \
  -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
  k8s/cluster-autoscaler/autoscaler.yaml | kubectl apply -f -

echo ""
echo "==> Waiting for autoscaler to be ready..."
kubectl rollout status deployment/cluster-autoscaler -n kube-system --timeout=120s

# ── YugabyteDB ────────────────────────────────────────────────────────────────
echo ""
echo "==> Installing YugabyteDB via Helm..."
helm repo add yugabytedb https://charts.yugabyte.com 2>/dev/null || true
helm repo update yugabytedb

kubectl create namespace yugabyte --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install yugabyte yugabytedb/yugabyte \
  --namespace yugabyte \
  --values k8s/yugabyte/values.yaml \
  --timeout 10m \
  --wait

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Install complete!"
echo "================================================================"
echo ""
echo "  Nodes:"
kubectl get nodes -o wide
echo ""
echo "  YugabyteDB:"
kubectl get pods -n yugabyte -o wide
echo ""
WORKER_IP=$(kubectl get nodes \
  --selector='!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || echo "<worker-ip>")
YSQL_PORT=$(kubectl get svc -n yugabyte -o jsonpath='{.items[?(@.spec.type=="NodePort")].spec.ports[?(@.name=="ysql-port")].nodePort}' 2>/dev/null || echo "30433")
echo "  YSQL: postgresql://yugabyte@${WORKER_IP}:${YSQL_PORT}/yugabyte"
echo ""
echo "  KUBECONFIG: $(pwd)/kubeconfig.yaml"
