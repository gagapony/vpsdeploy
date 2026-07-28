#!/bin/bash
# vps_init.sh - VPS 初始化脚本（Swap / BBR / Nginx / 可选 Docker）
# 仅支持 Debian / Ubuntu，需 root 运行
# 用法: bash vps_init.sh [--with-docker]
set -euo pipefail

# --------------------------------------------------
# 0. 参数解析与前置检查
# --------------------------------------------------
WITH_DOCKER=0
for arg in "$@"; do
    case "$arg" in
        --with-docker)
            WITH_DOCKER=1
            ;;
        -h|--help)
            echo "Usage: bash vps_init.sh [--with-docker]"
            echo "  --with-docker   Also install Docker Engine and Docker Compose plugin (skipped by default)"
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $arg (see --help)"
            exit 1
            ;;
    esac
done

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run this script as root (e.g., sudo bash vps_init.sh)"
  exit 1
fi

# 系统检测：仅支持 Debian / Ubuntu
if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
else
    OS_ID="unknown"
fi
if [ "$OS_ID" != "debian" ] && [ "$OS_ID" != "ubuntu" ]; then
    echo "[ERROR] Unsupported OS: ${OS_ID}. This script only supports Debian and Ubuntu."
    exit 1
fi

echo "=== Starting Server Initialization (${PRETTY_NAME:-$OS_ID}) ==="

# --------------------------------------------------
# 1. Configure 2GB Swap Space
# --------------------------------------------------
echo -e "\n>>> [1/4] Configuring 2GB Swap space..."
if swapon --show | grep -q "^/swapfile"; then
    echo "[OK] Swap file already exists. Skipping creation."
else
    # 检查磁盘剩余空间（至少预留 2.5GB）
    avail_mb=$(df -m --output=avail / | tail -n 1 | tr -d ' ')
    if [ "${avail_mb:-0}" -lt 2560 ]; then
        echo "[ERROR] Not enough disk space for a 2GB swapfile (available: ${avail_mb}MB)."
        exit 1
    fi

    # fallocate 优先（快）；部分文件系统上 fallocate 的 swap 无法启用，则回退 dd
    swap_ok=0
    if fallocate -l 2G /swapfile 2>/dev/null; then
        chmod 600 /swapfile
        if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
            swap_ok=1
        else
            rm -f /swapfile
        fi
    fi
    if [ "$swap_ok" -eq 0 ]; then
        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
    fi

    # Add to fstab for persistent mount on reboot, preventing duplicate entries
    if ! grep -q "^/swapfile" /etc/fstab; then
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
    # 检查内核是否支持 BBR（BBR 失败不致命，仅警告后继续）
    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -qw "bbr"; then
        echo "[WARN] Kernel does not support BBR. Skipping BBR configuration."
    else
        # 写入独立配置文件，幂等且不会污染 /etc/sysctl.conf
        cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system > /dev/null

        # Verify BBR status
        if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
            echo "[OK] BBR enabled successfully."
        else
            echo "[WARN] Failed to enable BBR. Please check your kernel configuration."
        fi
    fi
fi

# --------------------------------------------------
# 3. Install Nginx & Stream Module
# --------------------------------------------------
echo -e "\n>>> [3/4] Installing Nginx and Stream module..."
# Update apt package lists
apt-get update -y

# Install Nginx and the Stream dynamic module (包名在 Debian / Ubuntu 中一致)
apt-get install -y nginx libnginx-mod-stream

# Enable Nginx to start on boot and start it immediately
systemctl enable --now nginx

# Verify Nginx status
if systemctl is-active --quiet nginx; then
    echo "[OK] Nginx and Stream module have been installed and are currently running."
else
    echo "[ERROR] Nginx installed but failed to start. Check logs with: systemctl status nginx"
    exit 1
fi

# --------------------------------------------------
# 4. Install Docker & Docker Compose（可选，--with-docker 才安装）
# --------------------------------------------------
if [ "$WITH_DOCKER" -eq 1 ]; then
    echo -e "\n>>> [4/4] Installing Docker and Docker Compose..."
    if command -v docker >/dev/null 2>&1; then
        echo "[OK] Docker is already installed. Skipping installation."
    else
        # Docker 仓库需要发行版 codename（如 bookworm / noble）
        if [ -z "${VERSION_CODENAME:-}" ]; then
            echo "[ERROR] Cannot detect distro codename (VERSION_CODENAME missing in /etc/os-release)."
            exit 1
        fi

        # Remove older versions if they exist (ignoring errors if not found)
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

        # Install prerequisites for adding Docker repository
        apt-get update -y
        apt-get install -y ca-certificates curl

        # Add Docker's official GPG key safely（按实际发行版选择 debian / ubuntu 路径）
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        # Set up the Docker repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} \
          ${VERSION_CODENAME} stable" | \
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
            exit 1
        fi
    fi
else
    echo -e "\n>>> [4/4] Docker installation skipped (run with --with-docker to install)."
fi

echo -e "\n=== Server deployment completed successfully! ==="
