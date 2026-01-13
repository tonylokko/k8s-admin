#!/bin/bash
set -uxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

# Prevent interactive prompts during apt operations (Ubuntu 24.04 needrestart)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

REGION="__REGION__"
CLUSTER_NAME="__CLUSTER_NAME__"
K8S_VERSION="__K8S_VERSION__"
POD_CIDR="__POD_CIDR__"
FLUX_GIT_REPO="__FLUX_GIT_REPO__"
FLUX_GIT_BRANCH="__FLUX_GIT_BRANCH__"
FLUX_PATH="__FLUX_PATH__"

# Retry function for transient failures
retry() {
    local retries=$1; shift
    local delay=$1; shift
    local cmd=("$@")

    for ((i=1; i<=retries; i++)); do
        echo "Attempt $i: ${cmd[*]}" >&2
        if "${cmd[@]}"; then
            return 0
        fi
        echo "Attempt $i failed, retrying in ${delay}s..." >&2
        sleep "$delay"
    done
    echo "All $retries attempts failed for: ${cmd[*]}" >&2
    return 1
}

# Fatal error handler
fatal() {
    echo "FATAL: $1"
    exit 1
}

# Wait for instance metadata (IMDSv2)
get_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}
imds_get() {
    curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"
}
while ! TOKEN=$(get_token); do sleep 1; done
while ! imds_get instance-id >/dev/null; do sleep 1; done
PRIVATE_IP=$(imds_get local-ipv4)

# Install dependencies
retry 10 15 apt-get update || fatal "apt-get update failed"
retry 10 15 apt-get install -y unzip curl containerd apt-transport-https ca-certificates gpg || fatal "apt-get install failed"

# Install AWS CLI
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" || fatal "Failed to download AWS CLI"
unzip -q awscliv2.zip && ./aws/install || fatal "Failed to install AWS CLI"

# Fetch secrets (with retries for transient failures)
retry 5 10 aws secretsmanager get-secret-value --secret-id /k8s/${CLUSTER_NAME}/bootstrap-token --query SecretString --output text --region $REGION > /tmp/bootstrap-token || fatal "Failed to fetch bootstrap token"
BOOTSTRAP_TOKEN=$(tr -d '\n' < /tmp/bootstrap-token)

retry 5 10 aws secretsmanager get-secret-value --secret-id /k8s/${CLUSTER_NAME}/certificate-key --query SecretString --output text --region $REGION > /tmp/cert-key || fatal "Failed to fetch certificate key"
CERT_KEY=$(tr -d '\n' < /tmp/cert-key)

retry 5 10 aws secretsmanager get-secret-value --secret-id /k8s/${CLUSTER_NAME}/api-endpoint --query SecretString --output text --region $REGION > /tmp/api-endpoint || fatal "Failed to fetch API endpoint"
API_ENDPOINT=$(tr -d '\n' < /tmp/api-endpoint)

# Disable swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# Kernel modules
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Sysctl
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system

# Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Install kubeadm, kubelet, kubectl
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
retry 10 15 apt-get update || fatal "apt-get update for k8s repo failed"
retry 10 15 apt-get install -y kubelet kubeadm kubectl || fatal "Failed to install k8s packages"
apt-mark hold kubelet kubeadm kubectl

# Get installed kubeadm version for ClusterConfiguration
KUBEADM_VERSION=$(kubeadm version -o short)

# Wait for NLB DNS to be resolvable (can take a few minutes after creation)
echo "Waiting for NLB DNS to propagate..."
for i in {1..60}; do
    if getent hosts ${API_ENDPOINT} >/dev/null 2>&1; then
        echo "NLB DNS is resolvable: ${API_ENDPOINT}"
        break
    fi
    echo "  DNS not ready, waiting... (attempt $i/60)"
    sleep 10
done
getent hosts ${API_ENDPOINT} >/dev/null 2>&1 || fatal "NLB DNS never became resolvable"

# Kubeadm config
cat <<EOF > /root/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
bootstrapTokens:
- token: "${BOOTSTRAP_TOKEN}"
  ttl: "24h"
nodeRegistration:
  kubeletExtraArgs:
    cloud-provider: external
certificateKey: "${CERT_KEY}"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: ${KUBEADM_VERSION}
controlPlaneEndpoint: "${API_ENDPOINT}:6443"
networking:
  podSubnet: "${POD_CIDR}"
apiServer:
  certSANs: ["${API_ENDPOINT}", "${PRIVATE_IP}", "localhost", "127.0.0.1"]
controllerManager:
  extraArgs:
    cloud-provider: external
EOF

# Initialize cluster
kubeadm init --config /root/kubeadm-config.yaml --upload-certs || fatal "kubeadm init failed"

# Setup kubeconfig
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/root/.kube/config

# Patch CoreDNS to tolerate uninitialized taint (so DNS works before CCM removes taint)
retry 5 10 kubectl -n kube-system patch deployment coredns --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/tolerations/-", "value": {
    "key": "node.cloudprovider.kubernetes.io/uninitialized",
    "operator": "Exists",
    "effect": "NoSchedule"
  }}
]' || echo "WARNING: Failed to patch CoreDNS tolerations"

# Store admin kubeconfig (with retries)
KUBECONFIG_B64=$(base64 -w0 /etc/kubernetes/admin.conf)
retry 5 10 bash -c "aws secretsmanager put-secret-value --secret-id /k8s/${CLUSTER_NAME}/admin-kubeconfig --secret-string '${KUBECONFIG_B64}' --region $REGION 2>/dev/null || aws secretsmanager create-secret --name /k8s/${CLUSTER_NAME}/admin-kubeconfig --secret-string '${KUBECONFIG_B64}' --region $REGION" || fatal "Failed to store admin kubeconfig"

# Store CA cert hash for workers
CA_CERT_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
retry 5 10 bash -c "aws secretsmanager put-secret-value --secret-id /k8s/${CLUSTER_NAME}/ca-cert-hash --secret-string 'sha256:${CA_CERT_HASH}' --region $REGION 2>/dev/null || aws secretsmanager create-secret --name /k8s/${CLUSTER_NAME}/ca-cert-hash --secret-string 'sha256:${CA_CERT_HASH}' --region $REGION" || fatal "Failed to store CA cert hash"

# Install minimal Cilium CNI (basic networking only - Flux will manage full config)
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz | tar xzC /usr/local/bin || fatal "Failed to install Cilium CLI"
retry 3 30 cilium install --set ipam.operator.clusterPoolIPv4PodCIDRList="{${POD_CIDR}}" || fatal "Failed to install Cilium"

# Wait for Cilium to be ready
retry 10 30 cilium status --wait || echo "WARNING: Cilium status check timed out, continuing anyway"

# Install Flux Operator
retry 5 15 kubectl apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/install.yaml || fatal "Failed to install Flux Operator"

# Add tolerations so flux-operator can run on control plane (before workers join and before CCM initializes node)
retry 5 10 kubectl patch deployment flux-operator -n flux-system --type=json -p='[
  {"op": "add", "path": "/spec/template/spec/tolerations", "value": [
    {"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"},
    {"key": "node.cloudprovider.kubernetes.io/uninitialized", "operator": "Exists", "effect": "NoSchedule"}
  ]}
]' || fatal "Failed to patch flux-operator tolerations"

# Wait for Flux Operator to be ready
retry 20 15 kubectl wait --for=condition=available --timeout=30s deployment/flux-operator -n flux-system || fatal "Flux Operator never became ready"

# Create cluster-config ConfigMap for Flux variable substitution
retry 5 10 kubectl apply -f - <<EOF || fatal "Failed to create cluster-config ConfigMap"
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config
  namespace: flux-system
data:
  POD_CIDR: "${POD_CIDR}"
  CLUSTER_NAME: "${CLUSTER_NAME}"
  REGION: "${REGION}"
EOF

# Create FluxInstance to bootstrap from git repo
retry 5 10 kubectl apply -f - <<EOF || fatal "Failed to create FluxInstance"
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.x"
    registry: ghcr.io/fluxcd
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
  cluster:
    type: kubernetes
  kustomize:
    patches:
      - target:
          kind: Deployment
        patch: |
          - op: add
            path: /spec/template/spec/tolerations
            value:
              - key: "node-role.kubernetes.io/control-plane"
                operator: "Exists"
                effect: "NoSchedule"
              - key: "node.cloudprovider.kubernetes.io/uninitialized"
                operator: "Exists"
                effect: "NoSchedule"
  sync:
    kind: GitRepository
    url: https://${FLUX_GIT_REPO}
    ref: refs/heads/${FLUX_GIT_BRANCH}
    path: ${FLUX_PATH}
EOF

# Signal ready
retry 5 10 bash -c "aws secretsmanager put-secret-value --secret-id /k8s/${CLUSTER_NAME}/control-plane-ready --secret-string 'true' --region $REGION 2>/dev/null || aws secretsmanager create-secret --name /k8s/${CLUSTER_NAME}/control-plane-ready --secret-string 'true' --region $REGION" || fatal "Failed to signal control-plane-ready"

echo "Control plane initialization complete!"
