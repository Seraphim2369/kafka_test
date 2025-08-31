#!/bin/bash
set -e

echo "Starting deployment on Amazon Linux..."

# Get current directory
PROJECT_DIR=$(pwd)

# Update IP address in docker-compose.yml
EC2_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Using EC2 Public IP: $EC2_PUBLIC_IP"

# Use sed with Amazon Linux compatible syntax
sed -i "s|KAFKA_ADVERTISED_LISTENERS:.*|KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://$EC2_PUBLIC_IP:9092|" docker-compose.yml

# Stop existing services gracefully
echo "Stopping existing services..."
docker-compose down --remove-orphans || true

# Clean up old containers and images (optional)
docker system prune -f || true

# Pull latest images
echo "Pulling latest images..."
docker-compose pull

# Create necessary directories
mkdir -p airflow/logs airflow/plugins spark/jobs spark/tests

# Set proper permissions
sudo chown -R 50000:50000 airflow/logs || true
chmod -R 755 airflow/

# Build and start services
echo "Starting services..."
docker-compose up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 60

# Check if services are running
echo "Checking service status..."
docker-compose ps

# Initialize Airflow database (only if not already initialized)
echo "Initializing Airflow..."
docker-compose exec -T airflow-webserver airflow db init || echo "DB already initialized"

# Create Airflow admin user
echo "Creating Airflow admin user..."
docker-compose exec -T airflow-webserver airflow users create \
    --username admin \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com \
    --password admin || echo "User already exists"

# Wait a bit more for Kafka to be fully ready
sleep 30

# Create Kafka topics
echo "Creating Kafka topics..."
docker-compose exec -T kafka kafka-topics.sh --create --topic spark-input --bootstrap-server localhost:9092 --partitions 3 --replication-factor 1 || echo "Topic already exists"
docker-compose exec -T kafka kafka-topics.sh --create --topic spark-output --bootstrap-server localhost:9092 --partitions 3 --replication-factor 1 || echo "Topic already exists"

# List created topics
echo "Listing Kafka topics..."
docker-compose exec -T kafka kafka-topics.sh --list --bootstrap-server localhost:9092

echo "Deployment completed successfully!"
echo "Services available at:"
echo "- Airflow UI: http://$EC2_PUBLIC_IP:8080 (admin/admin)"
echo "- Spark UI: http://$EC2_PUBLIC_IP:8081"
echo "- Kafka: $EC2_PUBLIC_IP:9092"
echo "- Zookeeper: $EC2_PUBLIC_IP:2181"

# Display service status
echo -e "\nService Status:"
docker-compose ps