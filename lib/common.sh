#!/bin/bash
# lib/common.sh — 各 module 共享的前置检查与 .env 数据契约（本文件不直接执行）
#
# 约定：每个使用方（vps-router.sh / modules/*.sh）在顶部自行计算 REPO_DIR 后 source 本文件：
#   REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # modules/ 下
#   REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # 入口
# load_env 后统一 cd 到仓库根，模块内相对路径(.env/templates/scripts)均可直接使用。

APT_UPDATED=0

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

require_root() {
    [ "$EUID" -eq 0 ] || die "Please run this command as root."
}

# 仅支持 Debian / Ubuntu
require_debian_ubuntu() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
    else
        OS_ID="unknown"
    fi
    if [ "$OS_ID" != "debian" ] && [ "$OS_ID" != "ubuntu" ]; then
        die "Unsupported OS: ${OS_ID}. This project only supports Debian and Ubuntu."
    fi
    echo "[*] Detected OS: ${PRETTY_NAME:-$OS_ID}"
}

# .env 数据契约：加载 + 全模块统一默认值。
# 所有 CHISEL_*/XRAY_* 默认值只在此处定义一次（tunnel.sh 内部另有自身兜底默认）。
load_env() {
    cd "$REPO_DIR"
    [ -f .env ] || die ".env file not found under $REPO_DIR"
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a

    CHISEL_TUNNEL_ENABLED="${CHISEL_TUNNEL_ENABLED:-false}"
    CHISEL_PORT="${CHISEL_PORT:-9000}"
    CHISEL_REVERSE_BIND="${CHISEL_REVERSE_BIND:-127.0.0.1}"
    CHISEL_REVERSE_PORT="${CHISEL_REVERSE_PORT:-9443}"
    # Tunnel 模式下家服目标固定为回环反向监听（覆盖 .env 里的 DOMAIN_HOME_TARGET）
    if [ "$CHISEL_TUNNEL_ENABLED" = "true" ]; then
        DOMAIN_HOME_TARGET="${CHISEL_REVERSE_BIND}:${CHISEL_REVERSE_PORT}"
    fi

    XRAY_ENABLED="${XRAY_ENABLED:-false}"
    XRAY_DEST="${XRAY_DEST:-www.tesla.com:443}"
    XRAY_SERVER_NAME="${XRAY_SERVER_NAME:-www.tesla.com}"
    # all 命令的 docker 开关（默认不装，手动 init 可用 --with-docker）
    INIT_WITH_DOCKER="${INIT_WITH_DOCKER:-false}"
}

# fail fast：校验 .env 必填变量
require_env() {
    local missing=() var
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required variables in .env: ${missing[*]}"
    fi
}

# apt-get update 全流程只执行一次
apt_update_once() {
    if [ "$APT_UPDATED" -eq 0 ]; then
        apt-get update
        APT_UPDATED=1
    fi
}
