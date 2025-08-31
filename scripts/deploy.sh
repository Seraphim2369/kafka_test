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

# Get EC2 Public IP with fallback
EC2_PUBLIC_IP=$(curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")

if [ -z "$EC2_PUBLIC_IP" ]; then
    echo "Warning: Could not retrieve EC2 public IP, using localhost"
    EC2_PUBLIC_IP="localhost"
fi

echo "Using IP: $EC2_PUBLIC_IP"

# Backup original file
cp docker-compose.yml docker-compose.yml.backup

# Create a clean docker-compose.yml with proper indentation
cat > docker-compose.yml << EOF
services:
  zookeeper:
    image: wurstmeister/zookeeper:3.4.6
    ports:
      - "2181:2181"
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    deploy:
      resources:
        limits:
          memory: 256M

  kafka:
    image: wurstmeister/kafka:2.12-2.2.1
    ports:
      - "9092:9092"
    environment:
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://$EC2_PUBLIC_IP:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_HEAP_OPTS: "-Xmx256M -Xms128M"
      KAFKA_JVM_PERFORMANCE_OPTS: "-XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35"
    depends_on:
      - zookeeper
    deploy:
      resources:
        limits:
          memory: 512M

  postgres:
    image: postgres:13
    environment:
      POSTGRES_USER: airflow
      POSTGRES_PASSWORD: airflow
      POSTGRES_DB: airflow
    volumes:
      - postgres_db_volume:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    deploy:
      resources:
        limits:
          memory: 256M

  airflow-webserver:
    image: apache/airflow:2.7.1-python3.11
    environment:
      AIRFLOW__CORE__EXECUTOR: LocalExecutor
      AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
      AIRFLOW__CORE__FERNET_KEY: ''
      AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: 'true'
      AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
      AIRFLOW__API__AUTH_BACKENDS: 'airflow.api.auth.backend.basic_auth'
    volumes:
      - ./airflow/dags:/opt/airflow/dags
      - ./airflow/logs:/opt/airflow/logs
      - ./airflow/plugins:/opt/airflow/plugins
      - ./spark:/opt/spark
    ports:
      - "8080:8080"
    command: webserver
    depends_on:
      - postgres
    deploy:
      resources:
        limits:
          memory: 512M

  airflow-scheduler:
    image: apache/airflow:2.7.1-python3.11
    environment:
      AIRFLOW__CORE__EXECUTOR: LocalExecutor
      AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://airflow:airflow@postgres/airflow
      AIRFLOW__CORE__FERNET_KEY: ''
      AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: 'true'
      AIRFLOW__CORE__LOAD_EXAMPLES: 'false'
    volumes:
      - ./airflow/dags:/opt/airflow/dags
      - ./airflow/logs:/opt/airflow/logs
      - ./airflow/plugins:/opt/airflow/plugins
      - ./spark:/opt/spark
    command: scheduler
    depends_on:
      - postgres
    deploy:
      resources:
        limits:
          memory: 512M

  spark-master:
    image: bitnami/spark:3.4
    environment:
      - SPARK_MODE=master
      - SPARK_RPC_AUTHENTICATION_ENABLED=no
      - SPARK_RPC_ENCRYPTION_ENABLED=no
      - SPARK_LOCAL_STORAGE_ENCRYPTION_ENABLED=no
      - SPARK_SSL_ENABLED=no
    ports:
      - "8081:8080"
      - "7077:7077"
    volumes:
      - ./spark:/opt/spark-apps
    deploy:
      resources:
        limits:
          memory: 512M

  spark-worker:
    image: bitnami/spark:3.4
    environment:
      - SPARK_MODE=worker
      - SPARK_MASTER_URL=spark://spark-master:7077
      - SPARK_WORKER_MEMORY=512M
      - SPARK_WORKER_CORES=1
      - SPARK_RPC_AUTHENTICATION_ENABLED=no
      - SPARK_RPC_ENCRYPTION_ENABLED=no
      - SPARK_LOCAL_STORAGE_ENCRYPTION_ENABLED=no
      - SPARK_SSL_ENABLED=no
    volumes:
      - ./spark:/opt/spark-apps
    depends_on:
      - spark-master
    deploy:
      resources:
        limits:
          memory: 512M

volumes:
  postgres_db_volume:
EOF

echo "Created clean docker-compose.yml with IP: $EC2_PUBLIC_IP"

# Validate the YAML
python3 -c "
import yaml
try:
    with open('docker-compose.yml', 'r') as f:
        yaml.safe_load(f)
    print('✓ YAML syntax is valid')
except yaml.YAMLError as e:
    print(f'✗ YAML Error: {e}')
    exit(1)
" || exit 1

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