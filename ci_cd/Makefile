# Makefile
include secrets.env
export


IMAGE_NAME_CON = azure-connector
IMAGE_NAME_KSTR = stream-app
TAG = latest
FULL_IMAGE_CON = $(ACR_NAME).azurecr.io/$(IMAGE_NAME_CON):$(TAG)
FULL_IMAGE_KSTR = $(ACR_NAME).azurecr.io/$(IMAGE_NAME_KSTR):$(TAG)
CONTAINER = data

# YAML files' path
CONFLUENT_YAML = k8s/confluent-platform.yaml
PRODUCER_YAML = k8s/producer-app-data.yaml
STREAM_APP_YAML = k8s/stream-app.yaml

upload-dir:
	az storage blob upload-batch \
		--account-name $(STORAGE_ACCOUNT) \
		--destination $(CONTAINER) \
		--source . \
		--pattern "root_cicd/*"


# Login to Azure and ACR
login:
	az acr login --name $(ACR_NAME)


# Build image_con
build_con:
	docker build -t $(FULL_IMAGE_CON) -f connectors/Dockerfile .

# Push con_image to ACR
push_con:
	docker push $(FULL_IMAGE_CON)
	
# Build image_kstr
build_kstr:
	docker build -t $(FULL_IMAGE_KSTR) .

# Push kstr_image to ACR
push_kstr: 
	docker push $(FULL_IMAGE_KSTR)


# Confluent deployment
deploy-confluent:
	kubectl apply -f $(CONFLUENT_YAML)

# Producer-app deployment
deploy-producer:
	kubectl apply -f $(PRODUCER_YAML)	

# Confluent deletion
delete-confluent:
	kubectl delete -f $(CONFLUENT_YAML) 

# Producer-app deletion
delete-producer:
	kubectl delete -f $(PRODUCER_YAML)	
	
# Status verification
status:
	kubectl get pods -o wide  
	
	
# Port forward Control Center
port-forward-controlcenter:
	kubectl port-forward controlcenter-0 9021:9021 &


# Port forward Kafka Connect
port-forward-connect:
	kubectl port-forward connect-0 8083:8083 &

# Kafka topic creation (expedia)
create-topic:
	kubectl exec kafka-0 -c kafka -- bash -c "/usr/bin/kafka-topics --create --topic expedia --replication-factor 3 --partitions 3 --bootstrap-server kafka:9092"

# Delete alias
fix-curl:
	powershell -Command "Remove-Item alias:curl"


# Kafka Connect connector upload from JSON file
upload-connector:
	powershell -Command "Invoke-RestMethod -Method Post -Uri http://localhost:8083/connectors -ContentType 'application/json' -Body (Get-Content -Raw -Path azure-source-cc.json)"
	
# Create an output kafka topic
output-topic:
	kubectl exec kafka-0 -c kafka -- bash -c '/usr/bin/kafka-topics --create --topic expedia_ext --replication-factor 3 --partitions 3 --bootstrap-server kafka:9092'

# Stream application deployment
deploy-stream-app:
	kubectl apply -f $(STREAM_APP_YAML)

# Stream application deletion
delete-stream-app:
	kubectl delete -f $(STREAM_APP_YAML)
	
# Command to access the KSQL command prompt
ksql-access:
	kubectl exec -it ksqldb-0 -- ksql
	
# Port forward for ksqldb:
port-forward-ksqldb:
	kubectl port-forward connect-0 8088:8088 &

# Create a stream from expedia_ext topic0
create_stream:
	curl -X POST http://localhost:8088/ksql \
	-H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
	-d @ksql/create_stream.json

# Create table from stream as select query
create_table:
	curl -X POST http://localhost:8088/ksql \
	-H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
	-d @ksql/create_table.json

# Retrieve the total number of hotels (hotel_id) and the number of distinct hotels per category
select_hotels:
	curl -X POST http://localhost:8088/query \
	-H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
	-d @ksql/select_hotels.json
