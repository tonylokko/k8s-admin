#!/bin/bash
# Compute (EC2, NLB) functions

create_nlb() {
    echo "=== Creating Network Load Balancer ==="

    NLB_ARN=$(aws elbv2 create-load-balancer \
        --name ${CLUSTER_NAME}-api \
        --type network \
        --scheme internet-facing \
        --subnets $PUBLIC_SUBNET_ID \
        --tags Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text --region $REGION)
    echo "NLB: $NLB_ARN"

    TG_ARN=$(aws elbv2 create-target-group \
        --name ${CLUSTER_NAME}-api-tg \
        --protocol TCP \
        --port 6443 \
        --vpc-id $VPC_ID \
        --health-check-protocol TCP \
        --health-check-port 6443 \
        --target-type instance \
        --query 'TargetGroups[0].TargetGroupArn' --output text --region $REGION)
    echo "Target Group: $TG_ARN"

    aws elbv2 create-listener \
        --load-balancer-arn $NLB_ARN \
        --protocol TCP \
        --port 6443 \
        --default-actions Type=forward,TargetGroupArn=$TG_ARN \
        --region $REGION >/dev/null

    NLB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns $NLB_ARN \
        --query 'LoadBalancers[0].DNSName' --output text --region $REGION)
    echo "NLB DNS: $NLB_DNS"

    # Store endpoint for user-data scripts
    store_secret "api-endpoint" "$NLB_DNS"

    echo "NLB created."
}

get_ami() {
    AMI_ID=$(aws ec2 describe-images \
        --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text --region $REGION)
    echo "AMI: $AMI_ID"
}

launch_control_plane() {
    echo "=== Launching Control Plane ==="

    get_ami

    # Load user-data template and substitute variables
    local user_data=$(cat "${SCRIPT_DIR}/user-data/control-plane.sh" | \
        sed "s|__REGION__|$REGION|g" | \
        sed "s|__CLUSTER_NAME__|$CLUSTER_NAME|g" | \
        sed "s|__K8S_VERSION__|$K8S_VERSION|g" | \
        sed "s|__POD_CIDR__|$POD_CIDR|g" | \
        sed "s|__FLUX_GIT_REPO__|$FLUX_GIT_REPO|g" | \
        sed "s|__FLUX_GIT_BRANCH__|$FLUX_GIT_BRANCH|g" | \
        sed "s|__FLUX_PATH__|$FLUX_PATH|g")

    CP_INSTANCE_ID=$(aws ec2 run-instances \
        --image-id $AMI_ID \
        --instance-type $CP_INSTANCE_TYPE \
        --key-name $KEY_NAME \
        --subnet-id $PRIVATE_SUBNET_ID \
        --security-group-ids $CP_SG_ID \
        --iam-instance-profile Name=${CLUSTER_NAME}-node-profile \
        --user-data "$user_data" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cp},{Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned}]" \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${CP_DISK_SIZE},\"VolumeType\":\"gp3\"}}]" \
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
        --query 'Instances[0].InstanceId' --output text --region $REGION)
    echo "Control Plane Instance: $CP_INSTANCE_ID"

    # Wait for instance to be running before registering with NLB
    echo "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids $CP_INSTANCE_ID --region $REGION

    # Register with NLB
    aws elbv2 register-targets --target-group-arn $TG_ARN \
        --targets Id=$CP_INSTANCE_ID --region $REGION

    echo "Control plane launched and registered with NLB."
}

launch_workers() {
    echo "=== Launching Workers ==="

    get_ami

    # Load user-data template and substitute variables
    local user_data=$(cat "${SCRIPT_DIR}/user-data/worker.sh" | \
        sed "s|__REGION__|$REGION|g" | \
        sed "s|__CLUSTER_NAME__|$CLUSTER_NAME|g" | \
        sed "s|__K8S_VERSION__|$K8S_VERSION|g")

    WORKER_INSTANCE_IDS=()
    for i in $(seq 1 $WORKER_COUNT); do
        WORKER_ID=$(aws ec2 run-instances \
            --image-id $AMI_ID \
            --instance-type $WORKER_INSTANCE_TYPE \
            --key-name $KEY_NAME \
            --subnet-id $PRIVATE_SUBNET_ID \
            --security-group-ids $WORKER_SG_ID \
            --iam-instance-profile Name=${CLUSTER_NAME}-node-profile \
            --user-data "$user_data" \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-worker-${i}},{Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned}]" \
            --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${WORKER_DISK_SIZE},\"VolumeType\":\"gp3\"}}]" \
            --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled" \
            --query 'Instances[0].InstanceId' --output text --region $REGION)
        echo "Worker $i Instance: $WORKER_ID"
        WORKER_INSTANCE_IDS+=($WORKER_ID)
    done

    echo "Workers launched."
}

terminate_instances() {
    echo "=== Terminating Instances ==="

    # Find all instances by cluster tag
    INSTANCE_IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
                  "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text --region $REGION)

    if [[ -n "$INSTANCE_IDS" ]]; then
        echo "Terminating: $INSTANCE_IDS"
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region $REGION >/dev/null

        echo "Waiting for instances to terminate..."
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region $REGION 2>/dev/null || true
    else
        echo "No instances found."
    fi

    echo "Instances terminated."
}

delete_nlb() {
    echo "=== Deleting NLB ==="

    if [[ -n "${NLB_ARN:-}" ]]; then
        aws elbv2 delete-load-balancer --load-balancer-arn $NLB_ARN --region $REGION 2>/dev/null || true
        echo "Waiting for NLB deletion..."
        sleep 30
    fi

    if [[ -n "${TG_ARN:-}" ]]; then
        aws elbv2 delete-target-group --target-group-arn $TG_ARN --region $REGION 2>/dev/null || true
    fi

    echo "NLB deleted."
}
