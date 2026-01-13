#!/bin/bash
# IAM functions

create_iam() {
    echo "=== Creating IAM Resources ==="

    # Create node role
    aws iam create-role --role-name ${CLUSTER_NAME}-node-role \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }' 2>/dev/null || echo "Role already exists"

    # Combined node policy (secrets + ec2 + ebs)
    aws iam put-role-policy --role-name ${CLUSTER_NAME}-node-role \
        --policy-name node-policy \
        --policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": [
                        "secretsmanager:GetSecretValue",
                        "secretsmanager:CreateSecret",
                        "secretsmanager:PutSecretValue"
                    ],
                    "Resource": "arn:aws:secretsmanager:*:*:secret:/k8s/*"
                },
                {
                    "Effect": "Allow",
                    "Action": [
                        "ec2:Describe*",
                        "ecr:GetAuthorizationToken",
                        "ecr:BatchCheckLayerAvailability",
                        "ecr:GetDownloadUrlForLayer",
                        "ecr:BatchGetImage",
                        "ec2:CreateSnapshot",
                        "ec2:AttachVolume",
                        "ec2:DetachVolume",
                        "ec2:ModifyVolume",
                        "ec2:CreateVolume",
                        "ec2:DeleteVolume",
                        "ec2:CreateTags",
                        "ec2:DeleteTags",
                        "ec2:DeleteSnapshot"
                    ],
                    "Resource": "*"
                }
            ]
        }'

    # Create instance profile
    aws iam create-instance-profile \
        --instance-profile-name ${CLUSTER_NAME}-node-profile 2>/dev/null || echo "Instance profile already exists"

    aws iam add-role-to-instance-profile \
        --instance-profile-name ${CLUSTER_NAME}-node-profile \
        --role-name ${CLUSTER_NAME}-node-role 2>/dev/null || echo "Role already attached"

    # Attach SSM managed policy for Session Manager access
    aws iam attach-role-policy \
        --role-name ${CLUSTER_NAME}-node-role \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true

    echo "Waiting for IAM propagation..."
    sleep 10

    echo "IAM resources created."
}

delete_iam() {
    echo "=== Deleting IAM Resources ==="

    aws iam remove-role-from-instance-profile \
        --instance-profile-name ${CLUSTER_NAME}-node-profile \
        --role-name ${CLUSTER_NAME}-node-role 2>/dev/null || true

    aws iam delete-instance-profile \
        --instance-profile-name ${CLUSTER_NAME}-node-profile 2>/dev/null || true

    # Detach all managed policies from role
    for POLICY_ARN in $(aws iam list-attached-role-policies --role-name ${CLUSTER_NAME}-node-role \
        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
        aws iam detach-role-policy --role-name ${CLUSTER_NAME}-node-role \
            --policy-arn "$POLICY_ARN" 2>/dev/null || true
    done

    # Delete all inline policies from role
    for POLICY_NAME in $(aws iam list-role-policies --role-name ${CLUSTER_NAME}-node-role \
        --query 'PolicyNames[]' --output text 2>/dev/null); do
        aws iam delete-role-policy --role-name ${CLUSTER_NAME}-node-role \
            --policy-name "$POLICY_NAME" 2>/dev/null || true
    done

    aws iam delete-role \
        --role-name ${CLUSTER_NAME}-node-role 2>/dev/null || true

    echo "IAM resources deleted."
}
