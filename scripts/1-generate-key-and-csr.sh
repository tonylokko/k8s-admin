#!/bin/bash
# Generate private key and CSR for nginx-deployer user
set -euo pipefail

mkdir -p ./user-creds
cd ./user-creds

echo "Generating private key..."
openssl genrsa -out nginx-deployer.key 2048

echo "Generating CSR..."
openssl req -new -key nginx-deployer.key -out nginx-deployer.csr \
    -subj "/CN=nginx-deployer/O=developers"

echo "Done. Files created in ./user-creds/"
ls -la
