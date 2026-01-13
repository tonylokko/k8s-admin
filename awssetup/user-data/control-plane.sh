#!/bin/bash
set -euxo pipefail
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

# Wait for instance metadata (IMDSv2)
get_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}
imds_get() {
    curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"
}
while ! TOKEN=$(get_token); do sleep 1; done
while ! imds_get instance-id; do sleep 1; done
PRIVATE_IP=$(imds_get local-ipv4)

# Install dependencies
apt-get update
apt-get install -y unzip curl containerd apt-transport-https ca-certificates gpg

# Install AWS CLI
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip && ./aws/install

# Fetch secrets
BOOTSTRAP_TOKEN=$(aws secretsmanager get-secret-value --secret-id /k8s/${CLUSTER_NAME}/bootstrap-token --query SecretString --output text --region $REGION)
CERT_KEY=$(aws secretsmanager get-secret-value --secret-id /k8s/${CLUSTER_NAME}/certificate-key --query SecretString --output text --region $REGION)
API_ENDPOINT=$(aws secretsmanager get-secret-value --secret-id /k8s/${CLUSTER_NAME}/api-endpoint --query SecretString --output text --region $REGION)

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
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Get installed kubeadm version for ClusterConfiguration
KUBEADM_VERSION=$(kubeadm version -o short)

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
kubeadm init --config /root/kubeadm-config.yaml --upload-certs

# Setup kubeconfig
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/root/.kube/config

# Store admin kubeconfig
aws secretsmanager put-secret-value --secret-id /k8s/${CLUSTER_NAME}/admin-kubeconfig --secret-string "$(base64 -w0 /etc/kubernetes/admin.conf)" --region $REGION 2>/dev/null || \
aws secretsmanager create-secret --name /k8s/${CLUSTER_NAME}/admin-kubeconfig --secret-string "$(base64 -w0 /etc/kubernetes/admin.conf)" --region $REGION

# Store CA cert hash for workers
CA_CERT_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
aws secretsmanager put-secret-value --secret-id /k8s/${CLUSTER_NAME}/ca-cert-hash --secret-string "sha256:${CA_CERT_HASH}" --region $REGION 2>/dev/null || \
aws secretsmanager create-secret --name /k8s/${CLUSTER_NAME}/ca-cert-hash --secret-string "sha256:${CA_CERT_HASH}" --region $REGION

# Install minimal Cilium CNI (basic networking only - Flux will manage full config)
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz | tar xzC /usr/local/bin
cilium install --set ipam.operator.clusterPoolIPv4PodCIDRList="{${POD_CIDR}}"

# Wait for Cilium to be ready
cilium status --wait

# Install Flux Operator
kubectl apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/install.yaml

# Wait for Flux Operator to be ready
kubectl wait --for=condition=available --timeout=300s deployment/flux-operator -n flux-system

# Create cluster-config ConfigMap for Flux variable substitution
cat <<EOF | kubectl apply -f -
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
cat <<EOF | kubectl apply -f -
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
  sync:
    kind: GitRepository
    url: https://${FLUX_GIT_REPO}
    ref: refs/heads/${FLUX_GIT_BRANCH}
    path: ${FLUX_PATH}
EOF

# Signal ready
aws secretsmanager put-secret-value --secret-id /k8s/${CLUSTER_NAME}/control-plane-ready --secret-string "true" --region $REGION 2>/dev/null || \
aws secretsmanager create-secret --name /k8s/${CLUSTER_NAME}/control-plane-ready --secret-string "true" --region $REGION

echo "Control plane initialization complete!"
