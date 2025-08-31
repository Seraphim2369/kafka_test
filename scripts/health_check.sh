#!/bin/bash

echo "=== System Information ==="
cat /etc/os-release | head -2

echo -e "\n=== Memory Usage ==="
free -h

echo -e "\n=== Disk Usage ==="
df -h

echo -e "\n=== Docker Status ==="
systemctl status docker --no-pager

echo -e "\n=== Docker Compose Services ==="
docker compose ps

echo -e "\n=== Container Resource Usage ==="
docker stats --no-stream

echo -e "\n=== Kafka Topics ==="
docker compose exec -T kafka kafka-topics.sh --list --bootstrap-server localhost:9092 || echo "Kafka not ready"

echo -e "\n=== Service URLs ==="
EC2_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Airflow: http://$EC2_PUBLIC_IP:8080"
echo "Spark: http://$EC2_PUBLIC_IP:8081"
echo "Kafka: $EC2_PUBLIC_IP:9092"