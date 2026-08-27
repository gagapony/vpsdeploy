#!/bin/bash
# modules/init.sh — 系统初始化: Swap / BBR / (可选 Docker)
# nginx 安装不在此处，由 modules/nginx.sh 自动补装（避免两处重复装同一组件）
# 用法: ./vps-router.sh init [--with-docker]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/common.sh"

require_root
require_debian_ubuntu

WITH_DOCKER=0
for arg in "$@"; do
    case "$arg" in
        --with-docker)
            WITH_DOCKER=1
            ;;
        -h|--help)
            echo "Usage: ./vps-router.sh init [--with-docker]"
            exit 0
            ;;
        *)
            die "Unknown option: $arg (see --help)"
            ;;
    esac
done

# --------------------------------------------------
# 1. Swap（根分区 1/10，上限 2GB）
# --------------------------------------------------
echo -e "\n>>> [1/3] Configuring Swap space (1/10 of disk, max 2GB)..."
if swapon --show | grep -q "^/swapfile"; then
    echo "[OK] Swap file already exists. Skipping creation."
else
    total_mb=$(df -m --output=size / | tail -n 1 | tr -d ' ')
    swap_mb=$(( ${total_mb:-0} / 10 ))
    if [ "$swap_mb" -gt 2048 ]; then
        swap_mb=2048
    fi

    if [ "$swap_mb" -lt 128 ]; then
        echo "[WARN] Disk too small (${total_mb:-unknown}MB total, calculated swap ${swap_mb}MB < 128MB). Skipping swap creation."
    else
        # 检查磁盘剩余空间（swap 大小 + 512MB 余量）
        avail_mb=$(df -m --output=avail / | tail -n 1 | tr -d ' ')
        if [ "${avail_mb:-0}" -lt $(( swap_mb + 512 )) ]; then
            die "Not enough disk space for a ${swap_mb}MB swapfile (available: ${avail_mb}MB)."
        fi

        # fallocate 优先（快）；部分文件系统上 fallocate 的 swap 无法启用，则回退 dd
        swap_ok=0
        if fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
            chmod 600 /swapfile
            if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
                swap_ok=1
            else
                rm -f /swapfile
            fi
        fi
        if [ "$swap_ok" -eq 0 ]; then
            dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=progress
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
        fi

        # fstab 持久化，防重复条目
        if ! grep -q "^/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        echo "[OK] Swap configuration completed successfully (${swap_mb}MB)."
    fi
fi

# --------------------------------------------------
# 2. BBR 拥塞控制
# --------------------------------------------------
echo -e "\n>>> [2/3] Enabling BBR congestion control..."
if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "[OK] BBR is already enabled. Skipping configuration."
else
    # 检查内核是否支持 BBR（失败不致命，仅警告后继续）
    modprobe tcp_bbr 2>/dev/null || true
    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -qw "bbr"; then
        echo "[WARN] Kernel does not support BBR. Skipping BBR configuration."
    else
        # 独立配置文件，幂等且不污染 /etc/sysctl.conf
        cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        sysctl --system > /dev/null

        if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
            echo "[OK] BBR enabled successfully."
        else
            echo "[WARN] Failed to enable BBR. Please check your kernel configuration."
        fi
    fi
fi

# --------------------------------------------------
# 3. Docker & Docker Compose（可选，--with-docker 才安装）
# --------------------------------------------------
if [ "$WITH_DOCKER" -eq 1 ]; then
    echo -e "\n>>> [3/3] Installing Docker and Docker Compose..."
    if command -v docker >/dev/null 2>&1; then
        echo "[OK] Docker is already installed. Skipping installation."
    else
        # Docker 仓库需要发行版 codename（如 bookworm / noble）
        if [ -z "${VERSION_CODENAME:-}" ]; then
            die "Cannot detect distro codename (VERSION_CODENAME missing in /etc/os-release)."
        fi

        # Remove older versions if they exist (ignoring errors if not found)
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

        apt_update_once
        apt-get install -y ca-certificates curl

        # Docker 官方 GPG key（按发行版选 debian / ubuntu 路径）
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} \
          ${VERSION_CODENAME} stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        systemctl enable --now docker

        if systemctl is-active --quiet docker; then
            echo "[OK] Docker and Docker Compose have been installed and are currently running."
            docker --version
            docker compose version
        else
            die "Docker installed but failed to start. Check logs with: systemctl status docker"
        fi
    fi
else
    echo -e "\n>>> [3/3] Docker installation skipped (run with --with-docker to install)."
fi

echo -e "\n=== Init completed successfully! ==="
