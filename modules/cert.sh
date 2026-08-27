#!/bin/bash
# modules/cert.sh — wildcard 证书维护（acme.sh + Cloudflare DNS-01）
# 唯一消费者是 tunnel 模式（chisel TLS）；xray Reality 借用 dest 站点证书，不经本模块。
# 逻辑：磁盘已有非空证书则复用；缺失才要求 ACME_EMAIL/CF_Token 并签发。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/common.sh"

require_root
require_debian_ubuntu
load_env
require_env DOMAIN_MAIN

cert_key="/etc/nginx/ssl/${DOMAIN_MAIN}.key"
cert_chain="/etc/nginx/ssl/fullchain.cer"
mkdir -p /etc/nginx/ssl

if [ -s "$cert_key" ] && [ -s "$cert_chain" ]; then
    echo "[*] Reusing existing certificate files; no issuance requested."
else
    # 缺证书时这两个变量才是必需的（fail fast）
    require_env ACME_EMAIL CF_Token

    if [ ! -d "$HOME/.acme.sh" ]; then
        echo "[*] Installing acme.sh..."
        curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
    fi
    if [ ! -f "$HOME/.acme.sh/acme.sh.env" ]; then
        die "acme.sh environment not found ($HOME/.acme.sh/acme.sh.env)."
    fi
    # shellcheck disable=SC1091
    source "$HOME/.acme.sh/acme.sh.env"

    echo "[*] No installed certificate found; requesting ${DOMAIN_MAIN} & *.${DOMAIN_MAIN}"
    "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf \
        -d "${DOMAIN_MAIN}" -d "*.${DOMAIN_MAIN}" --server letsencrypt
    "$HOME/.acme.sh/acme.sh" --install-cert -d "${DOMAIN_MAIN}" \
        --key-file "$cert_key" --fullchain-file "$cert_chain" \
        --reloadcmd "bash $(pwd)/scripts/reload-certificate.sh '$cert_key' '$cert_chain'"
fi

# 校验证书文件真实落盘且非空，避免入口服务拿着空证书启动
for f in "$cert_key" "$cert_chain"; do
    if [ ! -s "$f" ]; then
        die "Certificate file missing or empty: $f"
    fi
done

# 复用证书时也要刷新已有 ACME 安装记录，否则旧 reloadcmd 仍会 reload nginx，
# tunnel 模式续期后不会把新证书同步给 chisel。
acme_home="$HOME/.acme.sh"
acme_domain_dir="$acme_home/${DOMAIN_MAIN}_ecc"
if [ -x "$acme_home/acme.sh" ] && [ -f "$acme_domain_dir/${DOMAIN_MAIN}.conf" ]; then
    "$acme_home/acme.sh" --install-cert -d "$DOMAIN_MAIN" --ecc \
        --key-file "$cert_key" --fullchain-file "$cert_chain" \
        --reloadcmd "bash $(pwd)/scripts/reload-certificate.sh '$cert_key' '$cert_chain'"
fi

echo "[+] Certificate ready: $cert_key / $cert_chain"
