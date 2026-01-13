#!/bin/bash
# Deploy kubeadm Kubernetes cluster on AWS
# Usage: ./deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ ! -f "${SCRIPT_DIR}/config.env" ]]; then
    echo "ERROR: config.env not found. Copy config.env.example and configure it."
    exit 1
fi
source "${SCRIPT_DIR}/config.env"

# Load pieces
source "${SCRIPT_DIR}/pieces/secrets.sh"
source "${SCRIPT_DIR}/pieces/vpc.sh"
source "${SCRIPT_DIR}/pieces/iam.sh"
source "${SCRIPT_DIR}/pieces/compute.sh"

echo "============================================================"
echo "Deploying Kubernetes cluster: ${CLUSTER_NAME}"
echo "Region: ${REGION}"
echo "============================================================"
echo ""

# Pre-flight checks
echo "=== Pre-flight Checks ==="
if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERROR: AWS credentials not configured"
    exit 1
fi
echo "AWS credentials OK"

if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region $REGION &>/dev/null; then
    echo "ERROR: Key pair '${KEY_NAME}' not found in ${REGION}"
    exit 1
fi
echo "Key pair OK"
echo ""

# Save state on exit (success or failure) for cleanup
save_state() {
    cat <<EOF > "${SCRIPT_DIR}/cluster-state.env"
# Generated state file - do not edit
CLUSTER_NAME="${CLUSTER_NAME}"
REGION="${REGION}"
VPC_ID="${VPC_ID:-}"
PUBLIC_SUBNET_ID="${PUBLIC_SUBNET_ID:-}"
PRIVATE_SUBNET_ID="${PRIVATE_SUBNET_ID:-}"
PUBLIC_RT_ID="${PUBLIC_RT_ID:-}"
PRIVATE_RT_ID="${PRIVATE_RT_ID:-}"
IGW_ID="${IGW_ID:-}"
NAT_GW_ID="${NAT_GW_ID:-}"
EIP_ALLOC="${EIP_ALLOC:-}"
CP_SG_ID="${CP_SG_ID:-}"
WORKER_SG_ID="${WORKER_SG_ID:-}"
NLB_ARN="${NLB_ARN:-}"
TG_ARN="${TG_ARN:-}"
NLB_DNS="${NLB_DNS:-}"
CP_INSTANCE_ID="${CP_INSTANCE_ID:-}"
EOF
}
trap save_state EXIT

# Deploy
create_secrets
create_vpc
create_security_groups
create_iam
create_nlb
launch_control_plane
launch_workers

echo ""
echo "State saved to cluster-state.env"
echo ""
echo "============================================================"
echo "Cluster deployment initiated!"
echo "============================================================"
echo ""
echo "Control Plane: ${CP_INSTANCE_ID}"
echo "API Endpoint:  ${NLB_DNS}:6443"
echo ""
echo "The cluster will take 10-15 minutes to initialize."
echo ""
echo "Monitor progress:"
echo "  aws ec2 get-console-output --instance-id ${CP_INSTANCE_ID} --region ${REGION}"
echo ""
echo "Once ready, fetch kubeconfig:"
echo "  aws secretsmanager get-secret-value \\"
echo "    --secret-id /k8s/${CLUSTER_NAME}/admin-kubeconfig \\"
echo "    --query SecretString --output text --region ${REGION} | base64 -d > ~/.kube/config"
echo ""
echo "Then verify:"
echo "  kubectl get nodes"
echo "  kubectl get fluxinstance -n flux-system"
echo "  flux get kustomizations"
echo ""
echo "============================================================"
