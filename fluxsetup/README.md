# Flux Setup

GitOps configuration for the Kubernetes cluster. The Flux Operator is installed during cluster initialization and bootstraps from this directory.

## Structure

```
fluxsetup/
├── kustomization.yaml           # Root kustomization
├── infrastructure/
│   ├── kustomization.yaml
│   ├── cilium/                  # Cilium CNI (full config)
│   │   ├── kustomization.yaml
│   │   ├── repository.yaml      # HelmRepository
│   │   └── release.yaml         # HelmRelease
│   ├── elb/                     # AWS integrations
│   │   ├── kustomization.yaml
│   │   ├── aws-ccm.yaml         # Cloud Controller Manager
│   │   ├── aws-ebs-csi.yaml     # EBS CSI Driver
│   │   └── storageclass.yaml    # gp3 StorageClass
│   ├── certmanager/             # (placeholder)
│   └── headlamp/                # (placeholder)
└── devns/                       # Dev namespace resources
```

## What Flux Manages

### Cilium CNI
Full configuration with:
- `kubeProxyReplacement: true`
- `gatewayAPI.enabled: true`
- Hubble enabled with UI

Note: A minimal Cilium is installed during bootstrap for basic networking. Flux upgrades it to the full configuration.

### AWS Cloud Controller Manager
Provides:
- Node lifecycle management
- LoadBalancer service support

### AWS EBS CSI Driver
Provides:
- Dynamic PersistentVolume provisioning
- gp3 default StorageClass (encrypted)

## Adding Components

To add new infrastructure:

1. Create a new directory under `infrastructure/`
2. Add your manifests with a `kustomization.yaml`
3. Include it in `infrastructure/kustomization.yaml`
4. Commit and push - Flux will reconcile automatically

## Verification

```bash
# Check Flux status
kubectl get fluxinstance -n flux-system
flux get kustomizations
flux get helmreleases -A

# Check Cilium
cilium status

# Check storage
kubectl get storageclass
```
