#!/bin/bash
set -e

echo "Starting deployment on Amazon Linux..."

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "Script directory: $SCRIPT_DIR"
echo "Project directory: $PROJECT_DIR"

# Change to project directory
cd "$PROJECT_DIR"

# Verify docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    echo "Error: docker-compose.yml not found in $PROJECT_DIR"
    echo "Contents of current directory:"
    ls -la
    exit 1
fi

# Update IP address in docker-compose.yml
EC2_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Using EC2 Public IP: $EC2_PUBLIC_IP"

# Backup original file
cp docker-compose.yml docker-compose.yml.backup

# Use sed with Amazon Linux compatible syntax
sed -i "s|KAFKA_ADVERTISED_LISTENERS:.*|      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://$EC2_PUBLIC_IP:9092|" docker-compose.yml

echo "Updated docker-compose.yml with IP: $EC2_PUBLIC_IP"

# Verify the change was made
echo "Checking updated configuration:"
grep "KAFKA_ADVERTISED_LISTENERS" docker-compose.yml

# Stop existing services gracefully
echo "Stopping existing services..."
docker compose down --remove-orphans || true

# Clean up old containers and images (optional)
docker system prune -f || true

# Pull latest images
echo "Pulling latest images..."
docker compose pull

# Create necessary directories
mkdir -p airflow/logs airflow/plugins spark/jobs spark/tests

# Set proper permissions for Airflow
sudo chown -R 50000:50000 airflow/logs 2>/dev/null || {
    echo "Warning: Could not set airflow permissions. Continuing..."
    chmod -R 755 airflow/ || true
}

# Build and start services
echo "Starting services..."
docker compose up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 60

# Check if services are running
echo "Checking service status..."
docker compose ps

# Initialize Airflow database (only if not already initialized)
echo "Initializing Airflow..."
docker compose exec -T airflow-webserver airflow db init 2>/dev/null || echo "DB already initialized or service not ready"

# Create Airflow admin user
echo "Creating Airflow admin user..."
docker compose exec -T airflow-webserver airflow users create \
    --username admin \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com \
    --password admin 2>/dev/null || echo "User already exists or service not ready"

# Wait a bit more for Kafka to be fully ready
sleep 30

# Create Kafka topics
echo "Creating Kafka topics..."
docker compose exec -T kafka kafka-topics.sh --create --topic spark-input --bootstrap-server localhost:9092 --partitions 3 --replication-factor 1 2>/dev/null || echo "Topic already exists"
docker compose exec -T kafka kafka-topics.sh --create --topic spark-output --bootstrap-server localhost:9092 --partitions 3 --replication-factor 1 2>/dev/null || echo "Topic already exists"

# List created topics
echo "Listing Kafka topics..."
docker compose exec -T kafka kafka-topics.sh --list --bootstrap-server localhost:9092 2>/dev/null || echo "Kafka not ready yet"

echo "Deployment completed successfully!"
echo "Services available at:"
echo "- Airflow UI: http://$EC2_PUBLIC_IP:8080 (admin/admin)"
echo "- Spark UI: http://$EC2_PUBLIC_IP:8081"
echo "- Kafka: $EC2_PUBLIC_IP:9092"
echo "- Zookeeper: $EC2_PUBLIC_IP:2181"

# Display service status
echo -e "\nService Status:"
docker compose ps

# Show logs if any service failed
echo -e "\nRecent logs for failed services:"
docker compose logs --tail=20