#!/bin/bash
set -uxo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

# Prevent interactive prompts during apt operations (Ubuntu 24.04 needrestart)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

REGION="__REGION__"
CLUSTER_NAME="__CLUSTER_NAME__"
K8S_VERSION="__K8S_VERSION__"

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
        sleep "$delay"
    done
    return 1
}

fatal() {
    echo "FATAL: $1" >&2
    exit 1
}

# Wait for instance metadata (IMDSv2)
get_token() {
    curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}
imds_get() {
    curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      "http://169.254.169.254/latest/meta-data/$1"
}
while ! TOKEN=$(get_token); do sleep 1; done
while ! imds_get instance-id >/dev/null; do sleep 1; done
NODE_NAME=$(imds_get local-hostname)

# Install dependencies
retry 10 15 apt-get update || fatal "apt-get update failed"
retry 10 15 apt-get install -y \
    unzip curl containerd apt-transport-https ca-certificates gpg \
    || fatal "apt-get install failed"

# Install AWS CLI
retry 10 15 curl -sL \
  "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
  -o "awscliv2.zip" || fatal "AWS CLI download failed"
unzip -q awscliv2.zip && ./aws/install || fatal "AWS CLI install failed"

# Wait for control plane to be ready
echo "Waiting for control plane..."
until aws secretsmanager get-secret-value \
  --secret-id /k8s/${CLUSTER_NAME}/control-plane-ready \
  --query SecretString \
  --output text \
  --region "$REGION" 2>/dev/null | grep -qx true
do
    sleep 30
done

# Fetch join info
BOOTSTRAP_TOKEN=$(
  retry 10 10 aws secretsmanager get-secret-value \
    --secret-id /k8s/${CLUSTER_NAME}/bootstrap-token \
    --query SecretString \
    --output text \
    --region "$REGION"
) || fatal "Failed to fetch bootstrap token"
BOOTSTRAP_TOKEN="$(echo -n "$BOOTSTRAP_TOKEN")"

CA_CERT_HASH=$(
  retry 10 10 aws secretsmanager get-secret-value \
    --secret-id /k8s/${CLUSTER_NAME}/ca-cert-hash \
    --query SecretString \
    --output text \
    --region "$REGION"
) || fatal "Failed to fetch CA cert hash"
CA_CERT_HASH="$(echo -n "$CA_CERT_HASH")"

API_ENDPOINT=$(
  retry 10 10 aws secretsmanager get-secret-value \
    --secret-id /k8s/${CLUSTER_NAME}/api-endpoint \
    --query SecretString \
    --output text \
    --region "$REGION"
) || fatal "Failed to fetch API endpoint"
API_ENDPOINT="$(echo -n "$API_ENDPOINT")"

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
curl -fsSL \
  "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" |
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
> /etc/apt/sources.list.d/kubernetes.list
retry 10 15 apt-get update || fatal "k8s repo update failed"
retry 10 15 apt-get install -y kubelet kubeadm kubectl \
  || fatal "k8s package install failed"
apt-mark hold kubelet kubeadm kubectl

# Create kubeadm join config (--kubelet-extra-args removed in K8s 1.33)
cat <<JOINEOF > /root/kubeadm-join-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${API_ENDPOINT}:6443"
    token: "${BOOTSTRAP_TOKEN}"
    caCertHashes:
      - "${CA_CERT_HASH}"
nodeRegistration:
  name: "${NODE_NAME}"
  kubeletExtraArgs:
    cloud-provider: external
JOINEOF

# Join cluster
retry 5 30 kubeadm join --config /root/kubeadm-join-config.yaml \
    || fatal "kubeadm join failed"

systemctl daemon-reexec
systemctl restart kubelet

echo "Worker node joined successfully!"

