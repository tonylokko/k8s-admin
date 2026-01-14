# Flux Setup

GitOps manifests for the Kubernetes cluster. Flux Operator bootstraps from this directory.

## Structure

```
fluxsetup/
├── kustomization.yaml
├── flux-instance-ks.yaml        # FluxInstance Kustomization
├── flux-operator/               # Flux Operator management
├── infrastructure-ks.yaml       # Infrastructure Kustomization
├── infrastructure/
│   ├── gateway-api/             # Gateway API CRDs
│   ├── cilium/                  # Cilium CNI + GatewayClass
│   ├── elb/                     # AWS CCM + EBS CSI
│   └── certmanager/             # cert-manager + self-signed CA
├── devns-ks.yaml                # Dev namespace Kustomization
└── devns/                       # Namespace, RBAC, Gateway
```

## Components

**Gateway API CRDs** - Installed before Cilium for Gateway support

**Cilium** - CNI with kubeProxyReplacement, Gateway API, Hubble

**AWS CCM** - Node lifecycle, LoadBalancer services

**AWS EBS CSI** - PersistentVolume provisioning, gp3 StorageClass

**cert-manager** - Certificate management with self-signed CA

**devns** - Dev namespace with RBAC for nginx-deployer user

## Verification

```bash
flux get kustomizations
flux get helmreleases -A
kubectl get gateway -n devns
kubectl get clusterissuer
```
