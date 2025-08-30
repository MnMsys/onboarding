#!/bin/bash

# Usage: ./install_mnmagent.sh <IP_ADDRESS> <ROOT_PASSWORD>

IP="$1"
PASSWORD="$2"

if [ -z "$IP" ] || [ -z "$PASSWORD" ]; then
  echo "Usage: $0 <IP_ADDRESS> <ROOT_PASSWORD>"
  exit 1
fi


# Install sshpass if not present
if ! command -v sshpass &> /dev/null; then
  echo "sshpass not found. Attempting to install sshpass..."
  if [ -f /etc/debian_version ]; then
    sudo apt-get update && sudo apt-get install -y sshpass
  elif [ -f /etc/redhat-release ]; then
    sudo yum install -y epel-release && sudo yum install -y sshpass
  elif [ -f /etc/alpine-release ]; then
    sudo apk add --no-cache sshpass
  else
    echo "Unsupported OS. Please install sshpass manually."
    exit 1
  fi
  if ! command -v sshpass &> /dev/null; then
    echo "Failed to install sshpass. Please install it manually."
    exit 1
  fi
fi

sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'EOF'
# Update package list
apt-get update

# Install curl if not present
apt-get install -y curl

# Install Node.js (LTS)
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

# Install mnmagent globally
npm install -g @mnmsys/mnmagent
EOF

echo "Node.js and mnmagent installed on $IP"