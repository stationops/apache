echo ###
echo ### Environment variables
echo ###


# Prompt the user for each value without defaults
read -p "Enter the EKS Cluster Name: " EKS_CLUSTER_NAME
read -p "Enter the EKS Cluster Region: " EKS_CLUSTER_REGION
read -p "Enter the VPC Name: " VPC_NAME
read -p "Enter the Account ID: " ACCOUNT_ID
read -p "Enter the S3 Bucket Name: " S3_BUCKET_NAME

# Export the variables
export EKS_CLUSTER_NAME
export EKS_CLUSTER_REGION
export VPC_NAME
export ACCOUNT_ID
export S3_BUCKET_NAME



export VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME}" --query "Vpcs[0].VpcId" --output text)
export S3_BUCKET_URI=s3://$S3_BUCKET_NAME
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


# Attach the custom inline policy for S3 read and write access
aws iam put-role-policy --role-name $ROLE_NAME --policy-name S3ReadWritePolicy --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
        {
            \"Effect\": \"Allow\",
            \"Action\": [
                \"s3:PutObject\",
                \"s3:PutObjectAcl\",
                \"s3:GetObject\"
            ],
            \"Resource\": \"arn:aws:s3:::${S3_BUCKET_NAME}/*\"
        },
        {
            \"Effect\": \"Allow\",
            \"Action\": [
                \"s3:ListBucket\"
            ],
            \"Resource\": \"arn:aws:s3:::${S3_BUCKET_NAME}\"
        }
    ]
}"

role_arn=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)




json_subnet_ids=$(echo "$PRIVATE_SUBNET_IDS" | jq -R 'split(",")')


aws ec2 create-launch-template \
    --launch-template-name pinot-xlarge-launch-template-$EKS_CLUSTER_NAME \
    --version-description "Version 1" \
    --launch-template-data '{
        "InstanceType": "t3.xlarge",
        "MetadataOptions": {
            "HttpTokens": "required",
            "HttpPutResponseHopLimit": 2
        }
    }'

aws ec2 create-launch-template \
    --launch-template-name pinot-large-launch-template-$EKS_CLUSTER_NAME \
    --version-description "Version 1" \
    --launch-template-data '{
        "InstanceType": "t3.large",
        "MetadataOptions": {
            "HttpTokens": "required",
            "HttpPutResponseHopLimit": 2
        }
    }'



# Create JSON input for aws eks create-nodegroup
json_input=$(jq -n \
  --arg clusterName "$EKS_CLUSTER_NAME" \
  --arg nodegroupName "pinot" \
  --arg nodeRole "$role_arn" \
  --arg templateName "pinot-xlarge-launch-template-$EKS_CLUSTER_NAME" \
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
	launchTemplate: {
      name: $templateName,
      version: "1"
    },
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
  --arg templateName "pinot-large-launch-template-$EKS_CLUSTER_NAME" \
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
	launchTemplate: {
      name: $templateName,
      version: "1"
    },
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
  --arg templateName "pinot-large-launch-template-$EKS_CLUSTER_NAME" \
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
	launchTemplate: {
      name: $templateName,
      version: "1"
    },
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


eksctl create iamserviceaccount \
  --name cloudwatch-agent \
  --namespace amazon-cloudwatch \
  --cluster ${EKS_CLUSTER_NAME} \
  --role-name Cloud_Watch_Agent_${EKS_CLUSTER_NAME} \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --role-only \
  --region ${EKS_CLUSTER_REGION} \
  --approve

eksctl create addon --name amazon-cloudwatch-observability --cluster ${EKS_CLUSTER_NAME} --service-account-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/Cloud_Watch_Agent_${EKS_CLUSTER_NAME} --region=${EKS_CLUSTER_REGION} --force

envsubst < cwagent-configmap.yaml | kubectl apply -f -

kubectl annotate serviceaccount cloudwatch-agent \
  -n amazon-cloudwatch \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/Cloud_Watch_Agent_${EKS_CLUSTER_NAME}


# kubectl -n amazon-cloudwatch edit amazoncloudwatchagents.cloudwatch.aws.amazon.com 

aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${EKS_CLUSTER_REGION}


echo ### 
echo ### Deploy Pinot
echo ### 

aws eks update-kubeconfig --region ${EKS_CLUSTER_REGION} --name ${EKS_CLUSTER_NAME}


helm repo add pinot https://raw.githubusercontent.com/apache/pinot/master/helm
kubectl create ns pinot-quickstart


envsubst < pinot-values.yaml | helm install pinot pinot/pinot -n pinot-quickstart -f -


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

#eksctl create iamserviceaccount \
#  --cluster=${EKS_CLUSTER_NAME} \
#  --namespace=kube-system \
#  --name=aws-load-balancer-controller \
#  --region=${EKS_CLUSTER_REGION} \
#  --role-name AmazonEKSLoadBalancerControllerRole \
#  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
#  --approve


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



