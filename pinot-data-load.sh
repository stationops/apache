helm repo add kafka https://charts.bitnami.com/bitnami
helm install -n pinot-quickstart kafka kafka/kafka \
	--set replicas=1,zookeeper.image.tag=latest,listeners.client.protocol=PLAINTEXT,zookeeper.persistence.storageClass=gp2,global.storageClass=gp2



kubectl -n pinot-quickstart exec kafka-controller-0 -- kafka-topics.sh --bootstrap-server kafka-controller-0:9092 --topic flights-realtime --create --partitions 1 --replication-factor 1
kubectl -n pinot-quickstart exec kafka-controller-0 -- kafka-topics.sh --bootstrap-server kafka-controller-0:9092 --topic flights-realtime-avro --create --partitions 1 --replication-factor 1


export JOB_INDEX=1
envsubst < data-load-job.yaml | kubectl create -f -
for i in {1..10}; do export JOB_INDEX=$i; envsubst < data-load-job.yaml | kubectl create -f -; done
