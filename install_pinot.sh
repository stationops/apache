echo ###
echo ### Environment variables
echo ###


export EKS_CLUSTER_NAME=pinot5
export EKS_CLUSTER_REGION=us-east-1
export VPC_NAME="gp5-test/test-gp5-vpc"
export ACCOUNT_ID=005651560631
export VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME}" --query "Vpcs[0].VpcId" --output text)

export PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:aws-cdk:subnet-type,Values=Private" --query "Subnets[*].SubnetId" --output text) 

export PRIVATE_SUBNET_IDS=$(echo $PRIVATE_SUBNET_IDS | tr ' ' ',')


echo "Private Subnet Ids"
echo $PRIVATE_SUBNET_IDS


echo ###
echo ### Download kubectl
echo ###

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl


echo ###
echo ### Download eksctl
echo ###


# for ARM systems, set ARCH to: `arm64`, `armv6` or `armv7`
ARCH=amd64
PLATFORM=$(uname -s)_$ARCH

curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"

# (Optional) Verify checksum
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check

tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz

sudo mv /tmp/eksctl /usr/local/bin

echo ### 
echo ### Create Cluster
echo ###

eksctl create cluster \
--name ${EKS_CLUSTER_NAME} \
--version 1.30 \
--region ${EKS_CLUSTER_REGION} \
--vpc-private-subnets ${PRIVATE_SUBNET_IDS} \
--node-private-networking \
--nodes 0

echo ### 
echo ### Create Node Groups
echo ### 

ROLE_NAME="${EKS_CLUSTER_NAME}EKSWorkerNodeRole"

# Create the IAM role with a trust policy
aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}'

# Attach the specified managed policies to the role
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy 

role_arn=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)




json_subnet_ids=$(echo "$PRIVATE_SUBNET_IDS" | jq -R 'split(",")')

# Create JSON input for aws eks create-nodegroup
json_input=$(jq -n \
  --arg clusterName "$EKS_CLUSTER_NAME" \
  --arg nodegroupName "pinot" \
  --arg nodeRole "$role_arn" \
  --argjson subnets "$json_subnet_ids" \
  '{
    clusterName: $clusterName,
    nodegroupName: $nodegroupName,
	nodeRole: $nodeRole,
    scalingConfig: {
      minSize: 1,
      maxSize: 3,
      desiredSize: 3
    },
    subnets: $subnets,
    instanceTypes: ["t3.xlarge"],
    taints: [
      {
        key: "group",
        value: "pinot",
        effect: "NO_SCHEDULE"
      }
    ],
	labels: {
      "alpha.eksctl.io/nodegroup-name": "pinot"
    }
  }')

# Run the aws eks create-nodegroup command
aws eks create-nodegroup --cli-input-json "$json_input" --region "$EKS_CLUSTER_REGION"


# Create JSON input for aws eks create-nodegroup
json_input=$(jq -n \
  --arg clusterName "$EKS_CLUSTER_NAME" \
  --arg nodegroupName "zookeeper" \
  --arg nodeRole "$role_arn" \
  --argjson subnets "$json_subnet_ids" \
  '{
    clusterName: $clusterName,
    nodegroupName: $nodegroupName,
	nodeRole: $nodeRole,
    scalingConfig: {
      minSize: 1,
      maxSize: 3,
      desiredSize: 3
    },
    subnets: $subnets,
    instanceTypes: ["t3.medium"],
    taints: [
      {
        key: "group",
        value: "zookeeper",
        effect: "NO_SCHEDULE"
      }
    ],
	labels: {
      "alpha.eksctl.io/nodegroup-name": "zookeeper"
    }
  }')

# Run the aws eks create-nodegroup command
aws eks create-nodegroup --cli-input-json "$json_input" --region "$EKS_CLUSTER_REGION"



# Create JSON input for aws eks create-nodegroup
json_input=$(jq -n \
  --arg clusterName "$EKS_CLUSTER_NAME" \
  --arg nodegroupName "workers" \
  --arg nodeRole "$role_arn" \
  --argjson subnets "$json_subnet_ids" \
  '{
    clusterName: $clusterName,
    nodegroupName: $nodegroupName,
	nodeRole: $nodeRole,
    scalingConfig: {
      minSize: 1,
      maxSize: 2,
      desiredSize: 2
    },
    subnets: $subnets,
    instanceTypes: ["t3.large"],
    taints: [
      
    ]
  }')

# Run the aws eks create-nodegroup command
aws eks create-nodegroup --cli-input-json "$json_input" --region "$EKS_CLUSTER_REGION"




echo ### 
echo ### Add Ons
echo ### 

eksctl utils associate-iam-oidc-provider --region=${EKS_CLUSTER_REGION} --cluster=${EKS_CLUSTER_NAME} --approve

eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster ${EKS_CLUSTER_NAME} \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --role-only \
  --role-name AmazonEKS_EBS_CSI_DriverRole_${EKS_CLUSTER_NAME} \
  --region ${EKS_CLUSTER_REGION}

eksctl create addon --name aws-ebs-csi-driver --cluster ${EKS_CLUSTER_NAME} --service-account-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/AmazonEKS_EBS_CSI_DriverRole_${EKS_CLUSTER_NAME} --region=${EKS_CLUSTER_REGION} --force
aws eks create-addon --cluster ${EKS_CLUSTER_NAME} --addon-name amazon-cloudwatch-observability


aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${EKS_CLUSTER_REGION}


echo ### 
echo ### Deploy Pinot
echo ### 

aws eks update-kubeconfig --region ${EKS_CLUSTER_REGION} --name ${EKS_CLUSTER_NAME}


helm repo add pinot https://raw.githubusercontent.com/apache/pinot/master/helm
kubectl create ns pinot-quickstart


controller_extra_config=$(cat <<EOF
pinot.set.instance.id.to.hostname=true
controller.task.scheduler.enabled=true
controller.enable.split.commit=true
pinot.controller.storage.factory.class.s3=org.apache.pinot.plugin.filesystem.S3PinotFS
pinot.controller.storage.factory.s3.region=$EKS_CLUSTER_REGION
pinot.controller.segment.fetcher.protocols=file,http,s3
pinot.controller.segment.fetcher.s3.class=org.apache.pinot.common.utils.fetcher.PinotFSSegmentFetcher
EOF
)



server_extra_config=$(cat <<EOF
pinot.set.instance.id.to.hostname=true
pinot.server.instance.realtime.alloc.offheap=true
pinot.query.server.port=7321
pinot.query.runner.port=7732
pinot.server.instance.enable.split.commit=true
pinot.server.storage.factory.class.s3=org.apache.pinot.plugin.filesystem.S3PinotFS
pinot.server.storage.factory.s3.region=$EKS_CLUSTER_REGION
pinot.server.storage.factory.s3.httpclient.maxConnections=50
pinot.server.storage.factory.s3.httpclient.socketTimeout=30s
pinot.server.storage.factory.s3.httpclient.connectionTimeout=2s
pinot.server.storage.factory.s3.httpclient.connectionTimeToLive=0s
pinot.server.storage.factory.s3.httpclient.connectionAcquisitionTimeout=10s
pinot.server.segment.fetcher.protocols=file,http,s3
pinot.server.segment.fetcher.s3.class=org.apache.pinot.common.utils.fetcher.PinotFSSegmentFetcher
	  
EOF
)


minion_extra_config=$(cat <<EOF
pinot.set.instance.id.to.hostname=true
pinot.minion.storage.factory.class.s3=org.apache.pinot.plugin.filesystem.S3PinotFS
pinot.minion.storage.factory.s3.region=$EKS_CLUSTER_REGION
pinot.minion.segment.fetcher.protocols=file,http,s3
pinot.minion.segment.fetcher.s3.class=org.apache.pinot.common.utils.fetcher.PinotFSSegmentFetcher
EOF
)

helm install pinot pinot/pinot \
-n pinot-quickstart \
--set cluster.name=${EKS_CLUSTER_NAME} \
--set controller.replicaCount=3 \
--set controller.resources.requests.cpu=1333m \
--set controller.resources.requests.memory=5.33Gi \
--set controller.persistence.storageClass=gp2 \
--set controller.persistence.size=100GB \
--set controller.tolerations[0].key=group \
--set controller.tolerations[0].value=pinot \
--set controller.tolerations[0].operator=Equal \
--set controller.tolerations[0].effect=NoSchedule \
--set controller.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set controller.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set controller.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=pinot \
--set controller.external.enabled=false \
--set controller.data.dir=$S3_BUCKET_URI \
--set controller.extra.configs=$controller_extra_config \
--set broker.replicaCount=3 \
--set broker.resources.requests.cpu=1333m \
--set broker.resources.requests.memory=5.33Gi \
--set broker.tolerations[0].key=group \
--set broker.tolerations[0].value=pinot \
--set broker.tolerations[0].operator=Equal \
--set broker.tolerations[0].effect=NoSchedule \
--set broker.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set broker.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set broker.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=pinot \
--set broker.external.enabled=false
--set server.replicaCount=3 \
--set server.resources.requests.cpu=1333m \
--set server.resources.requests.memory=5.33Gi \
--set server.persistence.storageClass=gp2 \
--set server.persistence.size=200GB \
--set server.tolerations[0].key=group \
--set server.tolerations[0].operator=Equal \
--set server.tolerations[0].value=pinot \
--set server.tolerations[0].effect=NoSchedule \
--set server.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set server.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set server.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=pinot \
--set server.extra.configs=$server_extra_config \
--set minion.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set minion.persistence.storageClass=gp2 \
--set minion.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set minion.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=workers \
--set minion.extra.configs=$minion_extra_config \--set minion.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set minionStateless.persistence.storageClass=gp2 \
--set minionStateless.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set minionStateless.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=workers \
--set minionStateless.extra.configs=$minion_extra_config \
--set zookeeper.replicaCount=3 \
--set zookeeper.resources.requests.cpu=1 \
--set zookeeper.resources.requests.memory=2Gi \
--set zookeeper.tolerations[0].key=group \
--set zookeeper.tolerations[0].value=zookeeper \
--set zookeeper.tolerations[0].effect=NoSchedule \
--set zookeeper.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set zookeeper.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set zookeeper.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=zookeeper \


echo ### 
echo ### Approve Certs
echo ### 

kubectl get csr --no-headers --sort-by=.metadata.creationTimestamp | awk '{print $1}' | xargs -I {} kubectl certificate approve {}



echo ### 
echo ### Install Load Balancer Controller
echo ### 

curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.5.4/docs/install/iam_policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json

eksctl create iamserviceaccount \
  --cluster=${EKS_CLUSTER_NAME} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --region=${EKS_CLUSTER_REGION} \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve


echo ### 
echo ### Add Load Balancer Routes
echo ### 

curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.5.4/docs/install/iam_policy.json


aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
	
eksctl create iamserviceaccount \
  --cluster=${EKS_CLUSTER_NAME} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller-${EKS_CLUSTER_NAME} \
  --role-name AmazonEKSLoadBalancerControllerRole-${EKS_CLUSTER_NAME} \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --region ${EKS_CLUSTER_REGION} \
  --approve

helm repo add eks-charts https://aws.github.io/eks-charts

helm repo update eks-charts

helm install aws-load-balancer-controller eks-charts/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName=${EKS_CLUSTER_NAME} \
    --set serviceAccount.create=false \
    --set region=${EKS_CLUSTER_REGION} \
    --set vpcId=${VPC_ID} \
    --set serviceAccount.name=aws-load-balancer-controller-${EKS_CLUSTER_NAME}
	
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --watch


				 
envsubst < controller-ingress.yaml | kubectl apply -f -
				  
envsubst < broker-ingress.yaml | kubectl apply -f -

envsubst < server-netty-ingress.yaml | kubectl apply -f -
		  
envsubst < server-admin-ingress.yaml | kubectl apply -f -

envsubst < zookeeper-admin-service.yaml | kubectl apply -f -

envsubst < zookeeper-admin-ingress.yaml | kubectl apply -f -



