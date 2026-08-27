#!/bin/bash
# vps-router.sh — 统一入口，逐级调用 modules/*
#
# 用法: sudo ./vps-router.sh <command> [args]
#   init  [--with-docker]  系统初始化: Swap / BBR / (可选 Docker)
#   nginx                 SNI 分流部署: 依赖 + 渲染 + stream 注入 + ufw 收口
#   cert                  wildcard 证书: 复用优先, 缺失才 acme.sh DNS-01 签发
#   tunnel                Chisel 反向隧道 (需 .env CHISEL_TUNNEL_ENABLED=true)
#   xray  [install|keys]  Xray Reality 节点部署 / x25519 密钥生成
#   deploy                组合: nginx -> cert -> tunnel -> xray (按 .env 开关)
#   all                   全量: init(不含docker) + deploy, docker 由 .env INIT_WITH_DOCKER 控制
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/common.sh"

usage() {
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

cmd="${1:-}"
if [ $# -gt 0 ]; then
    shift
fi

case "$cmd" in
    init)   exec bash modules/init.sh "$@" ;;
    nginx)  exec bash modules/nginx.sh "$@" ;;
    cert)   exec bash modules/cert.sh "$@" ;;
    tunnel) exec bash modules/tunnel.sh "$@" ;;
    xray)   exec bash modules/xray.sh "$@" ;;
    deploy) exec bash modules/deploy.sh "$@" ;;
    all)    exec bash modules/all.sh "$@" ;;
    -h|--help|help|"")
        usage
        [ -z "$cmd" ] && exit 1
        exit 0
        ;;
    *)
        usage
        die "Unknown command: $cmd"
        ;;
esac
