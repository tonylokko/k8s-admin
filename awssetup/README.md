# AWS Setup

Deploy a kubeadm Kubernetes cluster on AWS using bash and AWS CLI.

## Features

- Single control plane with configurable workers
- Cilium CNI (minimal install, Flux manages full config)
- Flux Operator for GitOps
- AWS Cloud Controller Manager (via Flux)
- EBS CSI Driver (via Flux)
- Secrets Manager for bootstrap tokens and kubeconfig
- Internal NLB for API server (HA-ready)
- IMDSv2 enforced on all instances
- gp3 default StorageClass

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- Existing EC2 key pair in target region
- Bash 4+
- Git repo with fluxsetup/ manifests (this repo)

## Quick Start

```bash
# 1. Configure
cp config.env.example config.env
vim config.env  # Set KEY_NAME and FLUX_GIT_REPO

# 2. Deploy
./deploy.sh

# 3. Wait ~10-15 minutes, then fetch kubeconfig
aws secretsmanager get-secret-value \
  --secret-id /k8s/k8s-cluster/admin-kubeconfig \
  --query SecretString --output text --region eu-west-1 | base64 -d > ~/.kube/config

# 4. Verify
kubectl get nodes
kubectl get fluxinstance -n flux-system
flux get kustomizations

# 5. When done
./destroy.sh
```

## Structure

```
awssetup/
├── deploy.sh              # Main deployment script
├── destroy.sh             # Cleanup script
├── config.env.example     # Configuration template
├── config.env             # Your configuration (gitignored)
├── cluster-state.env      # Generated state (gitignored)
├── pieces/
│   ├── secrets.sh         # Secrets Manager functions
│   ├── vpc.sh             # VPC/networking functions
│   ├── iam.sh             # IAM setup functions
│   └── compute.sh         # EC2/NLB functions
└── user-data/
    ├── control-plane.sh   # Control plane bootstrap
    └── worker.sh          # Worker bootstrap
```

## Configuration

Edit `config.env`:

| Variable | Description | Default |
|----------|-------------|---------|
| CLUSTER_NAME | Cluster identifier | k8s-cluster |
| REGION | AWS region | eu-west-1 |
| KEY_NAME | EC2 key pair name | **required** |
| K8S_VERSION | Kubernetes version | 1.29 |
| WORKER_COUNT | Number of workers | 2 |
| FLUX_GIT_REPO | Git repo for Flux | **required** |
| FLUX_GIT_BRANCH | Git branch | main |
| FLUX_PATH | Path to Flux manifests | fluxsetup |

## Bootstrap Flow

1. **deploy.sh** creates AWS infrastructure (VPC, security groups, IAM, NLB)
2. **Control plane user-data** runs kubeadm init, installs minimal Cilium, then Flux Operator
3. **Flux Operator** creates FluxInstance which syncs from your git repo
4. **Flux** reconciles full Cilium config, AWS CCM, EBS CSI driver, StorageClasses
5. **Workers** wait for control plane ready signal, then join cluster

## Troubleshooting

### Check user-data logs

```bash
# Via SSM (if enabled) or SSH via bastion
sudo cat /var/log/user-data.log
sudo journalctl -u kubelet
```

### Check Flux status

```bash
kubectl get fluxinstance -n flux-system
flux get kustomizations
flux get helmreleases -A
```

### Control plane not ready

Workers wait for `/k8s/{CLUSTER_NAME}/control-plane-ready` secret. If stuck:

1. Check control plane user-data log
2. Verify NLB health checks passing
3. Check API server is responding: `curl -k https://{NLB_DNS}:6443/healthz`
