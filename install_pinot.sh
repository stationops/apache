###
### Environment variables
###

export EKS_CLUSTER_NAME=pinot2-prod
export EKS_CLUSTER_REGION=us-east-1
export VPC_NAME="hibtest-test/test-hibtest-vpc"
export ACCOUNT_ID=005651560631
export VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME}" --query "Vpcs[0].VpcId" --output text)

export PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:aws-cdk:subnet-type,Values=Private" --query "Subnets[*].SubnetId" --output text) 

export PRIVATE_SUBNET_IDS=$(echo $PRIVATE_SUBNET_IDS | tr ' ' ',')




###
### Download kubectl
###

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl


###
### Download eksctl
###


# for ARM systems, set ARCH to: `arm64`, `armv6` or `armv7`
ARCH=amd64
PLATFORM=$(uname -s)_$ARCH

curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"

# (Optional) Verify checksum
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check

tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz

sudo mv /tmp/eksctl /usr/local/bin

### 
### Create Cluster
###

eksctl create cluster \
--name ${EKS_CLUSTER_NAME} \
--version 1.30 \
--region ${EKS_CLUSTER_REGION} \
--vpc-private-subnets ${PRIVATE_SUBNET_IDS} \
--node-private-networking


### 
### Create Node Groups
### 

eksctl create nodegroup \
  --cluster $EKS_CLUSTER_NAME \
  --name workers \
  --node-type t3.large \
  --nodes 2 \
  --subnet-ids ${PRIVATE_SUBNET_IDS} \
  --region ${EKS_CLUSTER_REGION} \
  --nodes-min 1 \
  --nodes-max 2 \
  --node-private-networking

eksctl create nodegroup \
  --cluster $EKS_CLUSTER_NAME \
  --name pinot \
  --node-type t3.xlarge \
  --nodes 3 \
  --subnet-ids ${PRIVATE_SUBNET_IDS} \
  --region ${EKS_CLUSTER_REGION} \
  --nodes-min 1 \
  --nodes-max 3 \
  --node-private-networking



eksctl create nodegroup \
  --cluster $EKS_CLUSTER_NAME \
  --name zookeeper \
  --node-type t3.xlarge \
  --nodes 3 \
  --subnet-ids ${PRIVATE_SUBNET_IDS} \
  --region ${EKS_CLUSTER_REGION} \
  --nodes-min 1 \
  --nodes-max 3 \
  --node-private-networking




### 
### Add Ons
### 

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

aws eks describe-cluster --name ${EKS_CLUSTER_NAME} --region ${EKS_CLUSTER_REGION}


### 
### Deploy Pinot
### 

aws eks update-kubeconfig --region ${EKS_CLUSTER_REGION} --name ${EKS_CLUSTER_NAME}



helm repo add pinot https://raw.githubusercontent.com/apache/pinot/master/helm
kubectl create ns pinot-quickstart


helm install pinot pinot/pinot \
-n pinot-quickstart \
--set cluster.name=${EKS_CLUSTER_NAME} \
--set server.replicaCount=2 \
--set controller.persistence.storageClass=gp2 \
--set server.persistence.storageClass=gp2 \
--set minion.persistence.storageClass=gp2 \
--set zookeeper.persistence.storageClass=gp2 \
--set controller.tolerations[0].key=group \
--set controller.tolerations[0].value=pinot \
--set controller.tolerations[0].operator=Equal \
--set controller.tolerations[0].effect=NoSchedule \
--set controller.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set controller.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set controller.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=pinot \
--set broker.tolerations[0].key=group \
--set broker.tolerations[0].value=pinot \
--set broker.tolerations[0].operator=Equal \
--set broker.tolerations[0].effect=NoSchedule \
--set broker.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set broker.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set broker.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=pinot \
--set server.tolerations[0].key=group \
--set server.tolerations[0].operator=Equal \
--set server.tolerations[0].value=pinot \
--set server.tolerations[0].effect=NoSchedule \
--set server.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set server.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set server.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=pinot \
--set minion.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set minion.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set minion.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=workers \
--set zookeeper.tolerations[0].key=group \
--set zookeeper.tolerations[0].value=zookeeper \
--set zookeeper.tolerations[0].effect=NoSchedule \
--set zookeeper.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=alpha.eksctl.io/nodegroup-name \
--set zookeeper.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In \
--set zookeeper.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]=zookeeper


### 
### Approve Certs
### 

kubectl get csr --no-headers --sort-by=.metadata.creationTimestamp | awk '{print $1}' | xargs -I {} kubectl certificate approve {}

kubernetes - kubectl exec/logs on GKE returns "remote error: tls: internal error" - Stack Overflow


### 
### Install Load Balancer Controller
### 

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


### 
### Add Load Balancer Routes
### 

curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.5.4/docs/install/iam_policy.json


aws iam create-policy \ 
    --policy-name AWSLoadBalancerControllerIAMPolicy \ 
    --policy-document file://iam_policy.json
	
eksctl create iamserviceaccount \ 
  --cluster=${EKS_CLUSTER_NAME} \ 
  --namespace=kube-system \ 
  --name=aws-load-balancer-controller \ 
  --role-name AmazonEKSLoadBalancerControllerRole \ 
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \ 
  --approve

helm repo add eks-charts https://aws.github.io/eks-charts

helm repo update eks-charts

helm install aws-load-balancer-controller eks-charts/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName=${EKS_CLUSTER_NAME} \
    --set serviceAccount.create=false \
    --set region=${EKS_CLUSTER_REGION} \
    --set vpcId=${VPC_ID} \
    --set serviceAccount.name=aws-load-balancer-controller


				 
wget https://raw.githubusercontent.com/stationops/apache/main/broker-ingress.yaml
envsubst < controller-ingress.yaml | kubectl apply -f -
		
		
wget https://raw.githubusercontent.com/stationops/apache/main/broker-ingress.yaml				  
envsubst < broker-ingress.yaml | kubectl apply -f -


wget https://raw.githubusercontent.com/stationops/apache/main/broker-ingress.yaml				  
envsubst < server-netty-ingress.yaml | kubectl apply -f -




### 
### Test With kafka
### 


helm repo add kafka https://charts.bitnami.com/bitnami
helm install -n pinot-quickstart kafka kafka/kafka --set replicas=1,zookeeper.image.tag=latest,listeners.client.protocol=PLAINTEXT



kubectl -n pinot-quickstart exec kafka-controller-0 -- kafka-topics.sh --bootstrap-server kafka-controller-0:9092 --topic flights-realtime --create --partitions 1 --replication-factor 1
kubectl -n pinot-quickstart exec kafka-controller-0 -- kafka-topics.sh --bootstrap-server kafka-controller-0:9092 --topic flights-realtime-avro --create --partitions 1 --replication-factor 1

rm -rf /var/lib/apt/lists/* && \
pip install \
    psycopg2-binary==2.9.1 \
    pinotdb>=0.3.9 \
    redis==3.5.3 && \

