#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run this script as root (e.g., sudo bash setup.sh)"
  exit 1
fi

echo "=== Starting Ubuntu 24.04 Server Initialization ==="

# --------------------------------------------------
# 1. Configure 2GB Swap Space
# --------------------------------------------------
echo -e "\n>>> [1/4] Configuring 2GB Swap space..."
if swapon --show | grep -q "^/swapfile"; then
    echo "[OK] Swap file already exists. Skipping creation."
else
    # Create a 2GB swap file
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress

    # Set correct permissions (crucial for security)
    chmod 600 /swapfile

    # Format and enable the swap space
    mkswap /swapfile
    swapon /swapfile

    # Add to fstab for persistent mount on reboot, preventing duplicate entries
    if ! grep -q "/swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo "[OK] Swap configuration completed successfully."
fi

# --------------------------------------------------
# 2. Enable BBR (Bottleneck Bandwidth and RTT)
# --------------------------------------------------
echo -e "\n>>> [2/4] Enabling BBR congestion control..."
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "[OK] BBR is already enabled. Skipping configuration."
else
    # Append kernel configurations to sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    # Apply the new sysctl parameters
    sysctl -p

    # Verify BBR status
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "[OK] BBR enabled successfully."
    else
        echo "[ERROR] Failed to enable BBR. Please check your kernel configuration."
    fi
fi

# --------------------------------------------------
# 3. Install Nginx & Stream Module
# --------------------------------------------------
echo -e "\n>>> [3/4] Installing Nginx and Stream module..."
# Update apt package lists
apt-get update -y

# Install Nginx and the Stream dynamic module
apt-get install -y nginx libnginx-mod-stream

# Enable Nginx to start on boot and start it immediately
systemctl enable --now nginx

# Verify Nginx status
if systemctl is-active --quiet nginx; then
    echo "[OK] Nginx and Stream module have been installed and are currently running."
else
    echo "[ERROR] Nginx installed but failed to start. Check logs with: systemctl status nginx"
fi

# --------------------------------------------------
# 4. Install Docker & Docker Compose
# --------------------------------------------------
echo -e "\n>>> [4/4] Installing Docker and Docker Compose..."
if command -v docker >/dev/null 2>&1; then
    echo "[OK] Docker is already installed. Skipping installation."
else
    # Remove older versions if they exist (ignoring errors if not found)
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Install prerequisites for adding Docker repository
    apt-get update -y
    apt-get install -y ca-certificates curl

    # Add Docker's official GPG key safely
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Set up the Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker Engine, containerd, and Compose plugin
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable and start Docker service
    systemctl enable --now docker

    # Verify Docker status
    if systemctl is-active --quiet docker; then
        echo "[OK] Docker and Docker Compose have been installed and are currently running."
        # Optional: Print versions to log
        docker --version
        docker compose version
    else
        echo "[ERROR] Docker installed but failed to start. Check logs with: systemctl status docker"
    fi
fi

echo -e "\n=== Server deployment completed successfully! ==="
