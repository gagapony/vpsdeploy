#!/bin/bash
# modules/all.sh — 全量部署：init -> nginx -> cert -> tunnel(可选) -> xray(可选)
# 子模块由 .env 开关驱动：CHISEL_TUNNEL_ENABLED / XRAY_ENABLED；
# Docker 仅当 .env INIT_WITH_DOCKER=true 才装（默认不装）。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/common.sh"

require_root
require_debian_ubuntu
load_env

if [ "${INIT_WITH_DOCKER:-false}" = "true" ]; then
    bash modules/init.sh --with-docker
else
    bash modules/init.sh
fi
bash modules/deploy.sh

echo "[+] Full deployment complete!"
