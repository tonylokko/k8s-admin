#!/bin/bash
# Destroy kubeadm Kubernetes cluster on AWS
# Usage: ./destroy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load state
if [[ ! -f "${SCRIPT_DIR}/cluster-state.env" ]]; then
    echo "ERROR: cluster-state.env not found. Nothing to destroy."
    exit 1
fi
source "${SCRIPT_DIR}/cluster-state.env"

# Also load config for any functions that need it
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    source "${SCRIPT_DIR}/config.env"
fi

# Load pieces
source "${SCRIPT_DIR}/pieces/secrets.sh"
source "${SCRIPT_DIR}/pieces/vpc.sh"
source "${SCRIPT_DIR}/pieces/iam.sh"
source "${SCRIPT_DIR}/pieces/compute.sh"

echo "============================================================"
echo "Destroying Kubernetes cluster: ${CLUSTER_NAME}"
echo "Region: ${REGION}"
echo "============================================================"
echo ""

read -p "Are you sure you want to destroy this cluster? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# Order matters for dependencies
terminate_instances
delete_nlb
delete_vpc
delete_iam
delete_secrets

# Remove state file
rm -f "${SCRIPT_DIR}/cluster-state.env"

echo ""
echo "============================================================"
echo "Cluster ${CLUSTER_NAME} destroyed."
echo "============================================================"
