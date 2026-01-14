#!/bin/bash
# Approve CSR and create kubeconfig (run as admin)
set -euo pipefail

echo "Approving CSR..."
kubectl certificate approve nginx-deployer

echo "Waiting for certificate..."
sleep 2

echo "Extracting signed certificate..."
kubectl get csr nginx-deployer -o jsonpath='{.status.certificate}' | base64 -d > ./user-creds/nginx-deployer.crt

# Get cluster info from current kubeconfig
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

echo "Creating kubeconfig..."
cat <<EOF > ./user-creds/nginx-deployer.kubeconfig
apiVersion: v1
kind: Config
clusters:
  - name: k8s-cluster
    cluster:
      certificate-authority-data: ${CLUSTER_CA}
      server: ${CLUSTER_SERVER}
contexts:
  - name: nginx-deployer@k8s-cluster
    context:
      cluster: k8s-cluster
      user: nginx-deployer
      namespace: devns
current-context: nginx-deployer@k8s-cluster
users:
  - name: nginx-deployer
    user:
      client-certificate-data: $(base64 -w0 ./user-creds/nginx-deployer.crt)
      client-key-data: $(base64 -w0 ./user-creds/nginx-deployer.key)
EOF

echo ""
echo "Done! Kubeconfig created at ./user-creds/nginx-deployer.kubeconfig"
echo ""
echo "Test with:"
echo "  export KUBECONFIG=./user-creds/nginx-deployer.kubeconfig"
echo "  kubectl get pods"
