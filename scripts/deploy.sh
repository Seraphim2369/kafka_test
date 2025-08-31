#!/bin/bash
set -e

echo "Starting deployment..."

# Update IP address in docker-compose.yml
EC2_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
sed -i "s/KAFKA_ADVERTISED_LISTENERS:.*/KAFKA_ADVERTISED_LISTENERS: PLAINTEXT:\/\/$EC2_PUBLIC_IP:9092/" docker-compose.yml

# Stop existing services
docker-compose down

# Pull latest images
docker-compose pull

# Build and start services
docker-compose up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 30

# Initialize Airflow database
docker-compose exec -T airflow-webserver airflow db init
docker-compose exec -T airflow-webserver airflow users create \
    --username admin \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com \
    --password admin

# Create Kafka topics
docker-compose exec -T kafka kafka-topics.sh --create --topic spark-input --bootstrap-server localhost:9092 --partitions 3 --replication-factor 1 || true
docker-compose exec -T kafka kafka-topics.sh --create --topic spark-output --bootstrap-server localhost:9092 --partitions 3 --replication-factor 1 || true

echo "Deployment completed!"
echo "Airflow UI: http://$EC2_PUBLIC_IP:8080"
echo "Spark UI: http://$EC2_PUBLIC_IP:8081"
echo "Kafka: $EC2_PUBLIC_IP:9092"