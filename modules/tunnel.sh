#!/bin/bash
# modules/tunnel.sh — Chisel 反向隧道服务端部署
# 由 .env CHISEL_TUNNEL_ENABLED=true 启用；nginx 保持 443 唯一公网入口，
# 家服 SNI 经 nginx 转发到回环反向监听（由隧道客户端建立）。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/common.sh"

require_root
require_debian_ubuntu
load_env
require_env DOMAIN_MAIN

CHISEL_VERSION="${CHISEL_VERSION:-1.11.8}"
CHISEL_PORT="${CHISEL_PORT:-9000}"
CHISEL_REVERSE_PORT="${CHISEL_REVERSE_PORT:-443}"
CHISEL_AUTH_FILE="${CHISEL_AUTH_FILE:-/etc/chisel/auth}"
# 证书来源默认取 modules/cert.sh 的落盘路径（可覆盖）
CHISEL_CERT_SOURCE="${CHISEL_CERT_SOURCE:-/etc/nginx/ssl/fullchain.cer}"
CHISEL_KEY_SOURCE="${CHISEL_KEY_SOURCE:-/etc/nginx/ssl/${DOMAIN_MAIN}.key}"

for var in CHISEL_AUTH CHISEL_CERT_SOURCE CHISEL_KEY_SOURCE; do
    if [ -z "${!var:-}" ]; then
        die "Missing required tunnel variable: $var"
    fi
done
for source_file in "$CHISEL_CERT_SOURCE" "$CHISEL_KEY_SOURCE"; do
    if [ ! -s "$source_file" ]; then
        die "Tunnel TLS source is missing or empty: $source_file"
    fi
done
if [ "$CHISEL_PORT" = "$CHISEL_REVERSE_PORT" ]; then
    die "Chisel control and reverse ports must differ."
fi

case "$(dpkg --print-architecture)" in
    amd64) asset_arch=amd64 ;;
    arm64) asset_arch=arm64 ;;
    *) die "Unsupported architecture: $(dpkg --print-architecture)" ;;
esac

if ! id chisel >/dev/null 2>&1; then
    useradd --system --home /var/lib/chisel --create-home --shell /usr/sbin/nologin chisel
fi
install -d -o root -g chisel -m 750 /etc/chisel

tmp_gz=$(mktemp)
tmp_bin=$(mktemp)
trap 'rm -f "$tmp_gz" "$tmp_bin"' EXIT
curl -fL "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/chisel_${CHISEL_VERSION}_linux_${asset_arch}.gz" -o "$tmp_gz"
gzip -dc "$tmp_gz" > "$tmp_bin"
install -o root -g root -m 755 "$tmp_bin" /usr/local/bin/chisel
/usr/local/bin/chisel --version

auth_tmp=$(mktemp)
env_tmp=$(mktemp)
trap 'rm -f "$tmp_gz" "$tmp_bin" "$auth_tmp" "$env_tmp"' EXIT
printf '%s\n' "$CHISEL_AUTH" > "$auth_tmp"
printf 'CHISEL_PORT=%s\n' "$CHISEL_PORT" > "$env_tmp"
install -o root -g chisel -m 640 "$auth_tmp" "$CHISEL_AUTH_FILE"
install -o root -g chisel -m 640 "$CHISEL_CERT_SOURCE" /etc/chisel/fullchain.pem
install -o root -g chisel -m 640 "$CHISEL_KEY_SOURCE" /etc/chisel/privkey.pem
install -o root -g chisel -m 640 "$env_tmp" /etc/chisel/server.env
install -o root -g root -m 644 templates/chisel-server.service /etc/systemd/system/chisel-server.service

systemctl daemon-reload
systemctl enable --now chisel-server
sleep 2
if ! systemctl is-active --quiet chisel-server; then
    die "chisel-server failed to start."
fi
if ! ss -tln | grep -qE ":${CHISEL_PORT}[[:space:]]"; then
    die "chisel control port is not listening: $CHISEL_PORT"
fi

ufw allow "${CHISEL_PORT}/tcp"
echo "[+] Tunnel server ready: control=${CHISEL_PORT}; reverse listener is managed by the authenticated client"
