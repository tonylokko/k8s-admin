#!/bin/bash
# Cleanup script - discovers and deletes resources by name/tag
# Use this when destroy.sh can't run due to missing state file
# Usage: ./cleanup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [[ ! -f "${SCRIPT_DIR}/config.env" ]]; then
    echo "ERROR: config.env not found."
    exit 1
fi
source "${SCRIPT_DIR}/config.env"

echo "============================================================"
echo "Cleanup: ${CLUSTER_NAME} in ${REGION}"
echo "============================================================"
echo ""
echo "Discovering resources..."
echo ""

# Discover resources
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text --region $REGION 2>/dev/null || true)

NLB_ARN=$(aws elbv2 describe-load-balancers \
    --names ${CLUSTER_NAME}-api \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text --region $REGION 2>/dev/null || true)
[[ "$NLB_ARN" == "None" ]] && NLB_ARN=""

TG_ARN=$(aws elbv2 describe-target-groups \
    --names ${CLUSTER_NAME}-api-tg \
    --query 'TargetGroups[0].TargetGroupArn' --output text --region $REGION 2>/dev/null || true)
[[ "$TG_ARN" == "None" ]] && TG_ARN=""

VPC_IDS=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
    --query 'Vpcs[].VpcId' --output text --region $REGION 2>/dev/null || true)
[[ "$VPC_IDS" == "None" ]] && VPC_IDS=""

NAT_GW_ID=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:Name,Values=${CLUSTER_NAME}-nat" \
    --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text --region $REGION 2>/dev/null || true)

EIP_ALLOCS=$(aws ec2 describe-addresses \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-nat-eip" \
    --query 'Addresses[].AllocationId' --output text --region $REGION 2>/dev/null || true)
[[ "$EIP_ALLOCS" == "None" ]] && EIP_ALLOCS=""

IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-igw" \
    --query 'InternetGateways[0].InternetGatewayId' --output text --region $REGION 2>/dev/null || true)
[[ "$IGW_ID" == "None" ]] && IGW_ID=""

SECRETS=$(aws secretsmanager list-secrets \
    --filter Key=name,Values=/k8s/${CLUSTER_NAME}/ \
    --query 'SecretList[].Name' --output text --region $REGION 2>/dev/null || true)

# Report what was found
echo "Found resources:"
echo "  Instances:    ${INSTANCE_IDS:-none}"
echo "  NLB:          ${NLB_ARN:-none}"
echo "  Target Group: ${TG_ARN:-none}"
echo "  VPCs:         ${VPC_IDS:-none}"
echo "  NAT Gateway:  ${NAT_GW_ID:-none}"
echo "  EIPs:         ${EIP_ALLOCS:-none}"
echo "  IGW:          ${IGW_ID:-none}"
echo "  Secrets:      ${SECRETS:-none}"
echo "  IAM:          ${CLUSTER_NAME}-node-role (will check)"
echo ""

read -p "Delete all these resources? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# Delete in dependency order

# 1. Instances
if [[ -n "$INSTANCE_IDS" ]]; then
    echo "=== Terminating instances ==="
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region $REGION >/dev/null
    echo "Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region $REGION 2>/dev/null || true
    echo "Done."
fi

# 2. NLB
if [[ -n "$NLB_ARN" ]]; then
    echo "=== Deleting NLB ==="
    aws elbv2 delete-load-balancer --load-balancer-arn $NLB_ARN --region $REGION 2>/dev/null || true
    echo "Waiting for NLB deletion..."
    sleep 30
    echo "Done."
fi

# 3. Target Group
if [[ -n "$TG_ARN" ]]; then
    echo "=== Deleting Target Group ==="
    aws elbv2 delete-target-group --target-group-arn $TG_ARN --region $REGION 2>/dev/null || true
    echo "Done."
fi

# 4. NAT Gateway
if [[ -n "$NAT_GW_ID" ]]; then
    echo "=== Deleting NAT Gateway ==="
    aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW_ID --region $REGION 2>/dev/null || true
    echo "Waiting for NAT Gateway deletion (this can take a few minutes)..."
    for i in {1..30}; do
        STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_GW_ID \
            --query 'NatGateways[0].State' --output text --region $REGION 2>/dev/null || echo "deleted")
        if [[ "$STATE" == "deleted" || "$STATE" == "None" ]]; then
            break
        fi
        echo "  State: $STATE, waiting..."
        sleep 10
    done
    echo "Done."
fi

# 5. EIPs
if [[ -n "$EIP_ALLOCS" ]]; then
    echo "=== Releasing EIPs ==="
    for EIP_ALLOC in $EIP_ALLOCS; do
        echo "Releasing EIP: $EIP_ALLOC"
        aws ec2 release-address --allocation-id "$EIP_ALLOC" --region $REGION 2>/dev/null || true
    done
    echo "Done."
fi

# 6. VPC resources (subnets, SGs, route tables, IGW, ENIs)
for VPC_ID in $VPC_IDS; do
    [[ -z "$VPC_ID" ]] && continue
    echo "=== Deleting VPC resources for: $VPC_ID ==="

    # Find and delete all load balancers in this VPC first
    echo "Checking for load balancers in VPC..."
    for LB_ARN in $(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text --region $REGION 2>/dev/null); do
        [[ -z "$LB_ARN" || "$LB_ARN" == "None" ]] && continue
        echo "Deleting load balancer: $LB_ARN"
        aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" --region $REGION 2>/dev/null || true
    done
    # Wait for LB ENIs to be released
    sleep 15

    # Delete NAT Gateways in this VPC
    for NGW_ID in $(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
        --query 'NatGateways[].NatGatewayId' --output text --region $REGION 2>/dev/null); do
        [[ -z "$NGW_ID" ]] && continue
        echo "Deleting NAT Gateway: $NGW_ID"
        aws ec2 delete-nat-gateway --nat-gateway-id "$NGW_ID" --region $REGION 2>/dev/null || true
    done

    # Wait for NAT gateways to delete
    echo "Waiting for NAT Gateways to delete..."
    for i in {1..30}; do
        PENDING=$(aws ec2 describe-nat-gateways \
            --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending,deleting" \
            --query 'NatGateways[].NatGatewayId' --output text --region $REGION 2>/dev/null || true)
        [[ -z "$PENDING" ]] && break
        sleep 10
    done

    # Delete ENIs (network interfaces) - these block everything else
    echo "Deleting network interfaces..."
    for ENI_ID in $(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text --region $REGION 2>/dev/null); do
        [[ -z "$ENI_ID" ]] && continue
        # Detach first if attached
        ATTACH_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" \
            --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text --region $REGION 2>/dev/null || true)
        if [[ -n "$ATTACH_ID" && "$ATTACH_ID" != "None" ]]; then
            echo "  Detaching ENI: $ENI_ID"
            aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region $REGION 2>/dev/null || true
            sleep 2
        fi
        echo "  Deleting ENI: $ENI_ID"
        aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region $REGION 2>/dev/null || true
    done

    # Delete subnets
    for SUBNET_ID in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[].SubnetId' --output text --region $REGION 2>/dev/null); do
        echo "Deleting subnet: $SUBNET_ID"
        for i in {1..5}; do
            aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region $REGION 2>/dev/null && break
            sleep 5
        done
    done

    # Delete security groups (non-default)
    SG_IDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text --region $REGION 2>/dev/null)

    if [[ -n "$SG_IDS" ]]; then
        echo "Revoking security group rules..."
        for SG_ID in $SG_IDS; do
            INGRESS_RULES=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
                --query 'SecurityGroups[0].IpPermissions' --output json --region $REGION 2>/dev/null)
            if [[ -n "$INGRESS_RULES" && "$INGRESS_RULES" != "[]" ]]; then
                aws ec2 revoke-security-group-ingress --group-id "$SG_ID" \
                    --ip-permissions "$INGRESS_RULES" --region $REGION 2>/dev/null || true
            fi
            EGRESS_RULES=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
                --query 'SecurityGroups[0].IpPermissionsEgress' --output json --region $REGION 2>/dev/null)
            if [[ -n "$EGRESS_RULES" && "$EGRESS_RULES" != "[]" ]]; then
                aws ec2 revoke-security-group-egress --group-id "$SG_ID" \
                    --ip-permissions "$EGRESS_RULES" --region $REGION 2>/dev/null || true
            fi
        done

        for SG_ID in $SG_IDS; do
            echo "Deleting security group: $SG_ID"
            for i in {1..5}; do
                aws ec2 delete-security-group --group-id "$SG_ID" --region $REGION 2>/dev/null && break
                sleep 3
            done
        done
    fi

    # Delete route tables (non-main)
    for RT_ID in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text --region $REGION 2>/dev/null); do
        echo "Deleting route table: $RT_ID"
        for ASSOC_ID in $(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
            --query 'RouteTables[].Associations[?!Main].RouteTableAssociationId' --output text --region $REGION 2>/dev/null); do
            aws ec2 disassociate-route-table --association-id "$ASSOC_ID" --region $REGION 2>/dev/null || true
        done
        aws ec2 delete-route-table --route-table-id "$RT_ID" --region $REGION 2>/dev/null || true
    done

    # Detach and delete all IGWs for this VPC
    for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[].InternetGatewayId' --output text --region $REGION 2>/dev/null); do
        echo "Deleting IGW: $IGW"
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" --region $REGION 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" --region $REGION 2>/dev/null || true
    done

    # Delete VPC
    echo "Deleting VPC: $VPC_ID"
    aws ec2 delete-vpc --vpc-id "$VPC_ID" --region $REGION 2>/dev/null || true
    echo "Done with VPC: $VPC_ID"
done

# 7. IAM
echo "=== Deleting IAM resources ==="
aws iam remove-role-from-instance-profile \
    --instance-profile-name ${CLUSTER_NAME}-node-profile \
    --role-name ${CLUSTER_NAME}-node-role 2>/dev/null || true
aws iam delete-instance-profile \
    --instance-profile-name ${CLUSTER_NAME}-node-profile 2>/dev/null || true

# Detach all managed policies from role
for POLICY_ARN in $(aws iam list-attached-role-policies --role-name ${CLUSTER_NAME}-node-role \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    echo "Detaching managed policy: $POLICY_ARN"
    aws iam detach-role-policy --role-name ${CLUSTER_NAME}-node-role \
        --policy-arn "$POLICY_ARN" 2>/dev/null || true
done

# Delete all inline policies from role
for POLICY_NAME in $(aws iam list-role-policies --role-name ${CLUSTER_NAME}-node-role \
    --query 'PolicyNames[]' --output text 2>/dev/null); do
    echo "Deleting inline policy: $POLICY_NAME"
    aws iam delete-role-policy --role-name ${CLUSTER_NAME}-node-role \
        --policy-name "$POLICY_NAME" 2>/dev/null || true
done

aws iam delete-role \
    --role-name ${CLUSTER_NAME}-node-role 2>/dev/null || true
echo "Done."

# 8. Secrets
if [[ -n "$SECRETS" ]]; then
    echo "=== Deleting Secrets ==="
    for SECRET in $SECRETS; do
        echo "Deleting: $SECRET"
        aws secretsmanager delete-secret \
            --secret-id "$SECRET" \
            --force-delete-without-recovery \
            --region $REGION 2>/dev/null || true
    done
    echo "Done."
fi

# Remove state file if exists
rm -f "${SCRIPT_DIR}/cluster-state.env"

echo ""
echo "============================================================"
echo "Cleanup complete."
echo "============================================================"
