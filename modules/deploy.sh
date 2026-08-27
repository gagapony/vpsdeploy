#!/bin/bash
# modules/deploy.sh — 组合命令：nginx -> cert -> tunnel(可选) -> xray(可选)
# 逐级调用各子模块；每级独立完成自己的前置校验，可单独执行也可组合。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/common.sh"

require_root
require_debian_ubuntu
load_env

bash modules/nginx.sh
bash modules/cert.sh
if [ "$CHISEL_TUNNEL_ENABLED" = "true" ]; then
    bash modules/tunnel.sh
fi
if [ "$XRAY_ENABLED" = "true" ]; then
    bash modules/xray.sh install
fi

echo "[+] Deployment complete!"
