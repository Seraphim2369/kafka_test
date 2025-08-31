#!/bin/bash
set -e

echo "Setting up environment on Amazon Linux..."

# Update the system
sudo yum update -y

# Install Docker
sudo yum install docker -y

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker

# Add ec2-user to docker group
sudo usermod -a -G docker ec2-user

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Create symbolic link for easier access
sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Install Git (if not already installed)
sudo yum install git -y

# Install Python 3.11 and pip (Amazon Linux 2023)
if grep -q "Amazon Linux 2023" /etc/os-release; then
    sudo yum install python3.11 python3.11-pip -y
    sudo alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1
else
    # For Amazon Linux 2
    sudo amazon-linux-extras install python3.8 -y
    sudo yum install python3-pip -y
fi

# Install additional utilities
sudo yum install htop curl wget telnet nc -y

# Verify installation
echo "Checking installations..."
docker --version
docker-compose --version
python3 --version
git --version

echo "Environment setup completed!"
echo "Please log out and log back in for docker group changes to take effect."