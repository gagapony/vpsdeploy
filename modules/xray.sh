#!/bin/bash
# modules/xray.sh — Xray Reality 节点部署
# VLESS-Reality 借用 dest 站点（默认 www.tesla.com）证书，本机无需证书；
# 仅监听 127.0.0.1:8443（与 sni.conf.template 的 vps_node upstream 对应），
# 公网流量一律经 nginx 443 SNI 分流进入，ufw 不放行 8443。
#
# 用法:
#   ./vps-router.sh xray install   安装 xray-core 并渲染配置（默认）
#   ./vps-router.sh xray keys      生成 Reality x25519 密钥对
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/common.sh"

require_root
require_debian_ubuntu
load_env

XRAY_CONFIG="/usr/local/etc/xray/config.json"
# listen/port 必须与 templates/sni.conf.template 的 vps_node upstream 一致
XRAY_LISTEN="127.0.0.1"
XRAY_PORT="8443"

cmd="${1:-install}"

case "$cmd" in
    keys)
        xray_bin="$(command -v xray || true)"
        if [ -z "$xray_bin" ] && [ -x /usr/local/bin/xray ]; then
            xray_bin=/usr/local/bin/xray
        fi
        if [ -z "$xray_bin" ]; then
            die "xray not installed; run: ./vps-router.sh xray install"
        fi
        echo "[*] Reality x25519 keypair:"
        "$xray_bin" x25519
        echo "[*] Private key  -> .env 的 XRAY_PRIVATE_KEY"
        echo "    Public key   -> 客户端链接的 pbk= 参数；shortId 可用: openssl rand -hex 8"
        exit 0
        ;;
    install) ;;
    *)
        die "Unknown xray subcommand: $cmd (install | keys)"
        ;;
esac

require_env XRAY_UUID XRAY_PRIVATE_KEY XRAY_SHORT_ID

# --------------------------------------------------
# 1. 安装 xray-core（官方 Xray-install，含 systemd 单元与 geo 数据）
# --------------------------------------------------
if ! command -v xray >/dev/null 2>&1 && [ ! -x /usr/local/bin/xray ]; then
    echo "[*] Installing xray-core via official installer..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
[ -x /usr/local/bin/xray ] || die "xray binary not found after install."
/usr/local/bin/xray version | head -n 1

# --------------------------------------------------
# 2. 渲染 Reality 配置
# --------------------------------------------------
if [ -s "$XRAY_CONFIG" ]; then
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak"
    echo "[*] Backed up existing config: ${XRAY_CONFIG}.bak"
fi
echo "[*] Rendering xray config from environment variables..."
envsubst '${XRAY_UUID} ${XRAY_PRIVATE_KEY} ${XRAY_SHORT_ID} ${XRAY_DEST} ${XRAY_SERVER_NAME}' \
    < templates/xray-server.json.template > "$XRAY_CONFIG"

# --------------------------------------------------
# 3. 启动并验证（8443 仅回环，公网一律走 nginx 443）
# --------------------------------------------------
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
    die "xray failed to start. Check: journalctl -u xray -e"
fi
if ! ss -tln | grep -qE "${XRAY_LISTEN}:${XRAY_PORT}[[:space:]]"; then
    die "xray is not listening on ${XRAY_LISTEN}:${XRAY_PORT}."
fi

echo "[+] Xray Reality node ready: ${XRAY_LISTEN}:${XRAY_PORT} (via nginx 443, dest=${XRAY_DEST})"
echo "    客户端链接 pbk 使用 XRAY_PRIVATE_KEY 对应的公钥（./vps-router.sh xray keys 可重新生成）"
