#!/bin/bash


# --- Configuration ---
# Set your target VM's IP address and root password here
IP="49.12.39.156"   # <-- Replace with your target VM IP
PASSWORD="dneuqRCvLgaf"   # <-- Replace with your target VM root password


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

# Randomize root password
NEWPASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
echo "root:$NEWPASS" | chpasswd
EOF

echo "Node.js and mnmagent installed on $IP. Root password randomized."