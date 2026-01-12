#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

# Prevent interactive prompts during apt operations (Ubuntu 24.04 needrestart)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

REGION="__REGION__"
CLUSTER_NAME="__CLUSTER_NAME__"
K8S_VERSION="__K8S_VERSION__"

# Wait for instance metadata (IMDSv2)
get_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}
imds_get() {
    curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"
}
while ! TOKEN=$(get_token); do sleep 1; done
while ! imds_get instance-id; do sleep 1; done

# Install dependencies
apt-get update
apt-get install -y unzip curl containerd apt-transport-https ca-certificates gpg

# Install AWS CLI
curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip && ./aws/install

# Wait for control plane to be ready
echo "Waiting for control plane..."
until aws secretsmanager get-secret-value --secret-id /k8s/${CLUSTER_NAME}/control-plane-ready --region $REGION 2>/dev/null; do
    echo "Control plane not ready, waiting..."
    sleep 30
done

# Fetch join info
BOOTSTRAP_TOKEN=$(aws secretsmanager get-secret-value --secret-id /k8s/${CLUSTER_NAME}/bootstrap-token --query SecretString --output text --region $REGION)
CA_CERT_HASH=$(aws secretsmanager get-secret-value --secret-id /k8s/${CLUSTER_NAME}/ca-cert-hash --query SecretString --output text --region $REGION)
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

# Join cluster
kubeadm join ${API_ENDPOINT}:6443 \
    --token "$BOOTSTRAP_TOKEN" \
    --discovery-token-ca-cert-hash "$CA_CERT_HASH" \
    --kubelet-extra-args="--cloud-provider=external"

echo "Worker node joined successfully!"
