#!/bin/bash
# Secrets Manager functions

create_secrets() {
    echo "=== Creating Secrets ==="

    # Generate bootstrap token and cert key
    BOOTSTRAP_TOKEN=$(openssl rand -hex 3).$(openssl rand -hex 8)
    CERT_KEY=$(openssl rand -hex 32)

    # Store bootstrap token
    aws secretsmanager create-secret \
        --name /k8s/${CLUSTER_NAME}/bootstrap-token \
        --secret-string "$BOOTSTRAP_TOKEN" \
        --region $REGION 2>/dev/null || \
    aws secretsmanager put-secret-value \
        --secret-id /k8s/${CLUSTER_NAME}/bootstrap-token \
        --secret-string "$BOOTSTRAP_TOKEN" \
        --region $REGION

    # Store certificate key
    aws secretsmanager create-secret \
        --name /k8s/${CLUSTER_NAME}/certificate-key \
        --secret-string "$CERT_KEY" \
        --region $REGION 2>/dev/null || \
    aws secretsmanager put-secret-value \
        --secret-id /k8s/${CLUSTER_NAME}/certificate-key \
        --secret-string "$CERT_KEY" \
        --region $REGION

    echo "Secrets created."
}

store_secret() {
    local name=$1
    local value=$2

    aws secretsmanager create-secret \
        --name /k8s/${CLUSTER_NAME}/${name} \
        --secret-string "$value" \
        --region $REGION 2>/dev/null || \
    aws secretsmanager put-secret-value \
        --secret-id /k8s/${CLUSTER_NAME}/${name} \
        --secret-string "$value" \
        --region $REGION
}

get_secret() {
    local name=$1
    aws secretsmanager get-secret-value \
        --secret-id /k8s/${CLUSTER_NAME}/${name} \
        --query SecretString --output text \
        --region $REGION
}

delete_secrets() {
    echo "=== Deleting Secrets ==="

    for secret in bootstrap-token certificate-key api-endpoint ca-cert-hash admin-kubeconfig control-plane-ready; do
        aws secretsmanager delete-secret \
            --secret-id /k8s/${CLUSTER_NAME}/${secret} \
            --force-delete-without-recovery \
            --region $REGION 2>/dev/null || true
    done

    echo "Secrets deleted."
}
