#!/bin/bash
# Submit CSR to Kubernetes (run as admin)
set -euo pipefail

CSR_BASE64=$(cat ./user-creds/nginx-deployer.csr | base64 | tr -d '\n')

echo "Submitting CSR to Kubernetes..."
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: nginx-deployer
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
    - client auth
EOF

echo "CSR submitted. Check status with: kubectl get csr nginx-deployer"
