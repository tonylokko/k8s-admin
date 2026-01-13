#!/bin/bash
# VPC and networking functions

create_vpc() {
    echo "=== Creating VPC and Networking ==="

    # Create VPC
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block $VPC_CIDR \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${CLUSTER_NAME}-vpc},{Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned}]" \
        --query 'Vpc.VpcId' --output text --region $REGION)
    echo "VPC: $VPC_ID"

    # Enable DNS hostnames
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames --region $REGION

    # Create Internet Gateway
    IGW_ID=$(aws ec2 create-internet-gateway \
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${CLUSTER_NAME}-igw}]" \
        --query 'InternetGateway.InternetGatewayId' --output text --region $REGION)
    echo "IGW: $IGW_ID"

    aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID --region $REGION

    # Get first AZ
    AZ=$(aws ec2 describe-availability-zones \
        --region $REGION --query 'AvailabilityZones[0].ZoneName' --output text)
    echo "AZ: $AZ"

    # Create public subnet
    PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id $VPC_ID \
        --cidr-block $PUBLIC_SUBNET_CIDR \
        --availability-zone $AZ \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public}]" \
        --query 'Subnet.SubnetId' --output text --region $REGION)
    echo "Public Subnet: $PUBLIC_SUBNET_ID"

    # Create private subnet
    PRIVATE_SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id $VPC_ID \
        --cidr-block $PRIVATE_SUBNET_CIDR \
        --availability-zone $AZ \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-private},{Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned}]" \
        --query 'Subnet.SubnetId' --output text --region $REGION)
    echo "Private Subnet: $PRIVATE_SUBNET_ID"

    # Create public route table
    PUBLIC_RT_ID=$(aws ec2 create-route-table \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public-rt}]" \
        --query 'RouteTable.RouteTableId' --output text --region $REGION)

    aws ec2 create-route --route-table-id $PUBLIC_RT_ID \
        --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID --region $REGION
    aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET_ID --route-table-id $PUBLIC_RT_ID --region $REGION

    # Create NAT Gateway
    EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${CLUSTER_NAME}-nat-eip}]" \
        --query 'AllocationId' --output text --region $REGION)

    NAT_GW_ID=$(aws ec2 create-nat-gateway \
        --subnet-id $PUBLIC_SUBNET_ID \
        --allocation-id $EIP_ALLOC \
        --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${CLUSTER_NAME}-nat}]" \
        --query 'NatGateway.NatGatewayId' --output text --region $REGION)
    echo "NAT Gateway: $NAT_GW_ID (waiting for availability...)"

    aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID --region $REGION

    # Create private route table
    PRIVATE_RT_ID=$(aws ec2 create-route-table \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${CLUSTER_NAME}-private-rt}]" \
        --query 'RouteTable.RouteTableId' --output text --region $REGION)

    aws ec2 create-route --route-table-id $PRIVATE_RT_ID \
        --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID --region $REGION
    aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET_ID --route-table-id $PRIVATE_RT_ID --region $REGION

    echo "VPC and networking created."
}

create_security_groups() {
    echo "=== Creating Security Groups ==="

    # Control Plane SG
    CP_SG_ID=$(aws ec2 create-security-group \
        --group-name "${CLUSTER_NAME}-cp-sg" \
        --description "K8s control plane" \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cp-sg}]" \
        --query 'GroupId' --output text --region $REGION)
    echo "Control Plane SG: $CP_SG_ID"

    # Worker SG
    WORKER_SG_ID=$(aws ec2 create-security-group \
        --group-name "${CLUSTER_NAME}-worker-sg" \
        --description "K8s workers" \
        --vpc-id $VPC_ID \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${CLUSTER_NAME}-worker-sg}]" \
        --query 'GroupId' --output text --region $REGION)
    echo "Worker SG: $WORKER_SG_ID"

    # Control Plane rules - Kubernetes
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol tcp --port 6443 --cidr 0.0.0.0/0 --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol tcp --port 2379-2380 --source-group $CP_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol tcp --port 10250-10259 --source-group $CP_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol tcp --port 10250 --source-group $WORKER_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION

    # Control Plane rules - Cilium (CP to CP for HA)
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol udp --port 8472 --source-group $CP_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol tcp --port 4240 --source-group $CP_SG_ID --region $REGION

    # Control Plane rules - Cilium (Workers to CP)
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol udp --port 8472 --source-group $WORKER_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol tcp --port 4240 --source-group $WORKER_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID \
        --protocol tcp --port 4244 --source-group $WORKER_SG_ID --region $REGION

    # Worker rules - Kubernetes
    aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID \
        --protocol tcp --port 10250 --source-group $CP_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID \
        --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0 --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION

    # Worker rules - Cilium (Worker to Worker)
    aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID \
        --protocol udp --port 8472 --source-group $WORKER_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID \
        --protocol tcp --port 4240 --source-group $WORKER_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID \
        --protocol tcp --port 4244 --source-group $WORKER_SG_ID --region $REGION

    # Worker rules - Cilium (CP to Workers)
    aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID \
        --protocol udp --port 8472 --source-group $CP_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID \
        --protocol tcp --port 4240 --source-group $CP_SG_ID --region $REGION
    aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID \
        --protocol tcp --port 4244 --source-group $CP_SG_ID --region $REGION

    echo "Security groups created."
}

delete_vpc() {
    echo "=== Deleting VPC and Networking ==="

    # Delete NAT Gateway first (takes time)
    if [[ -n "${NAT_GW_ID:-}" ]]; then
        aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW_ID --region $REGION 2>/dev/null || true
        echo "Waiting for NAT Gateway deletion..."
        for i in {1..30}; do
            STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids $NAT_GW_ID \
                --query 'NatGateways[0].State' --output text --region $REGION 2>/dev/null || echo "deleted")
            [[ "$STATE" == "deleted" || "$STATE" == "None" ]] && break
            sleep 10
        done
    fi

    # Release EIP
    if [[ -n "${EIP_ALLOC:-}" ]]; then
        aws ec2 release-address --allocation-id $EIP_ALLOC --region $REGION 2>/dev/null || true
    fi

    # Delete subnets
    if [[ -n "${PUBLIC_SUBNET_ID:-}" ]]; then
        aws ec2 delete-subnet --subnet-id $PUBLIC_SUBNET_ID --region $REGION 2>/dev/null || true
    fi
    if [[ -n "${PRIVATE_SUBNET_ID:-}" ]]; then
        aws ec2 delete-subnet --subnet-id $PRIVATE_SUBNET_ID --region $REGION 2>/dev/null || true
    fi

    # Delete security groups - revoke rules first to break cross-references
    for SG_ID in "${CP_SG_ID:-}" "${WORKER_SG_ID:-}"; do
        if [[ -n "$SG_ID" ]]; then
            # Revoke all ingress rules
            INGRESS_RULES=$(aws ec2 describe-security-groups --group-ids $SG_ID \
                --query 'SecurityGroups[0].IpPermissions' --output json --region $REGION 2>/dev/null || echo "[]")
            if [[ -n "$INGRESS_RULES" && "$INGRESS_RULES" != "[]" ]]; then
                aws ec2 revoke-security-group-ingress --group-id $SG_ID \
                    --ip-permissions "$INGRESS_RULES" --region $REGION 2>/dev/null || true
            fi
            # Revoke all egress rules
            EGRESS_RULES=$(aws ec2 describe-security-groups --group-ids $SG_ID \
                --query 'SecurityGroups[0].IpPermissionsEgress' --output json --region $REGION 2>/dev/null || echo "[]")
            if [[ -n "$EGRESS_RULES" && "$EGRESS_RULES" != "[]" ]]; then
                aws ec2 revoke-security-group-egress --group-id $SG_ID \
                    --ip-permissions "$EGRESS_RULES" --region $REGION 2>/dev/null || true
            fi
        fi
    done
    # Now delete the security groups
    if [[ -n "${CP_SG_ID:-}" ]]; then
        aws ec2 delete-security-group --group-id $CP_SG_ID --region $REGION 2>/dev/null || true
    fi
    if [[ -n "${WORKER_SG_ID:-}" ]]; then
        aws ec2 delete-security-group --group-id $WORKER_SG_ID --region $REGION 2>/dev/null || true
    fi

    # Delete route tables (non-main only)
    if [[ -n "${PUBLIC_RT_ID:-}" ]]; then
        aws ec2 delete-route-table --route-table-id $PUBLIC_RT_ID --region $REGION 2>/dev/null || true
    fi
    if [[ -n "${PRIVATE_RT_ID:-}" ]]; then
        aws ec2 delete-route-table --route-table-id $PRIVATE_RT_ID --region $REGION 2>/dev/null || true
    fi

    # Detach and delete IGW
    if [[ -n "${IGW_ID:-}" ]] && [[ -n "${VPC_ID:-}" ]]; then
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID --region $REGION 2>/dev/null || true
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID --region $REGION 2>/dev/null || true
    fi

    # Delete VPC
    if [[ -n "${VPC_ID:-}" ]]; then
        aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION 2>/dev/null || true
    fi

    echo "VPC deleted."
}
