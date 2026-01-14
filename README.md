# k8s-admin

Deploy a kubeadm Kubernetes cluster on AWS with Flux GitOps.

## Quick Start

```bash
cd awssetup
cp config.env.example config.env
vim config.env  # Set KEY_NAME and FLUX_GIT_REPO

./deploy.sh
```

Wait ~10-15 minutes, then fetch kubeconfig:

```bash
aws secretsmanager get-secret-value \
  --secret-id /k8s/k8s-cluster/admin-kubeconfig \
  --query SecretString --output text --region eu-west-1 | base64 -d > ~/.kube/config

kubectl get nodes
```

## Structure

- `awssetup/` - AWS infrastructure scripts
- `fluxsetup/` - Flux GitOps manifests
- `scripts/` - User CSR creation scripts
- `user-deploy/` - Example nginx deployment for RBAC user

## What Gets Deployed

- 1 control plane + 2 workers
- Kubernetes 1.33 via kubeadm
- Cilium CNI with Gateway API
- Flux Operator
- AWS Cloud Controller Manager
- AWS EBS CSI Driver
- cert-manager

## RBAC User Demo

Create a limited user via Kubernetes CSR:

```bash
cd scripts
./1-generate-key-and-csr.sh
./2-submit-csr.sh
./3-approve-and-create-kubeconfig.sh

export KUBECONFIG=./user-creds/nginx-deployer.kubeconfig
kubectl apply -f user-deploy/
```

## Cleanup

```bash
cd awssetup
./destroy.sh
```
