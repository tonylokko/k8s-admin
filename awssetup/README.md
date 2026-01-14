# AWS Setup

Deploy a kubeadm Kubernetes cluster on AWS.

## Prerequisites

- AWS CLI configured
- EC2 key pair in target region

## Usage

```bash
cp config.env.example config.env
vim config.env  # Set KEY_NAME and FLUX_GIT_REPO

./deploy.sh
```

Fetch kubeconfig after ~10-15 minutes:

```bash
aws secretsmanager get-secret-value \
  --secret-id /k8s/k8s-cluster/admin-kubeconfig \
  --query SecretString --output text --region eu-west-1 | base64 -d > ~/.kube/config
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| CLUSTER_NAME | Cluster identifier | k8s-cluster |
| REGION | AWS region | eu-west-1 |
| KEY_NAME | EC2 key pair name | required |
| WORKER_COUNT | Number of workers | 2 |
| FLUX_GIT_REPO | Git repo for Flux | required |

## Structure

```
awssetup/
├── deploy.sh           # Deploy cluster
├── destroy.sh          # Delete cluster
├── cleanup.sh          # Force cleanup orphaned resources
├── pieces/             # Modular functions
└── user-data/          # Bootstrap scripts
```

## Cleanup

Normal cleanup:
```bash
./destroy.sh
```

Force cleanup (orphaned resources):
```bash
./cleanup.sh
```

## Troubleshooting

```bash
# Check user-data logs via SSM
aws ssm start-session --target <instance-id> --region eu-west-1

sudo cat /var/log/user-data.log
sudo journalctl -u kubelet
```
