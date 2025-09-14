#!/bin/bash


# --- Configuration ---
# Set your target VM's IP address and root password here
IP="116.203.81.24"   # <-- Replace with your target VM IP
PASSWORD="qRKEJcPvuLku"   # <-- Replace with your target VM root password


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


# Test SSH connection first
echo "Testing SSH connection to $IP..."
if ! sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP" "echo 'SSH connection successful'"; then
  echo "ERROR: Failed to establish SSH connection to $IP"
  echo "Please check the IP address and password"
  exit 1
fi

echo "SSH connection successful. Proceeding with installation..."

sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no root@"$IP" bash <<'EOF'
# Update package list
apt-get update

# Install curl if not present
apt-get install -y curl

# Install Node.js (LTS)
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

# Install mnmagent globally with verbose logging
echo "Installing mnmagent..."
npm install -g @mnmsys/mnmagent --verbose
echo "mnmagent installation completed."

# Install Redis if not already installed
if ! command -v redis-server &> /dev/null; then
  if [ -f /etc/debian_version ]; then
    apt-get install -y redis-server
  elif [ -f /etc/redhat-release ]; then
    yum install -y redis
  elif [ -f /etc/alpine-release ]; then
    apk add --no-cache redis
  else
    echo "Unsupported OS for Redis installation. Please install Redis manually."
  fi
fi

# Randomize root password
NEWPASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
echo "root:$NEWPASS" | chpasswd
EOF

echo "Node.js and mnmagent installed on $IP. Root password randomized."