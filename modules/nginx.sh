#!/bin/bash
# modules/nginx.sh — SNI 分流部署：依赖安装 + 模板渲染 + stream 注入 + ufw 收口
# nginx 纯 TCP 透传（不持家庭私钥、不终结 TLS），证书不为本模块依赖。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_DIR/lib/common.sh"

require_root
require_debian_ubuntu
load_env
require_env DOMAIN_MAIN DOMAIN_HOME_TARGET

for required_file in templates/sni.conf.template scripts/detect_nginx_resolvers.sh; do
    if [ ! -f "$required_file" ]; then
        die "Required file not found: $required_file"
    fi
done

# --------------------------------------------------
# 1. 依赖安装（Debian / Ubuntu 统一走 apt-get）
# --------------------------------------------------
echo "[*] Installing cron tool..."
if ! command -v crontab >/dev/null 2>&1; then
    apt_update_once
    if ! apt-get install -y cron; then
        echo "[WARN] Failed to install cron; acme.sh auto-renewal may not work."
    fi
fi
systemctl enable --now cron 2>/dev/null || echo "[WARN] Failed to enable cron service."

if ! command -v envsubst >/dev/null 2>&1; then
    echo "[*] Installing envsubst tool (gettext-base)..."
    apt_update_once
    apt-get install -y gettext-base
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "[*] Installing curl..."
    apt_update_once
    apt-get install -y curl
fi

# nginx 缺失时自动补装
if ! command -v nginx >/dev/null 2>&1; then
    echo "[*] Nginx not found, installing..."
    apt_update_once
    apt-get install -y nginx
fi
if ! dpkg -s libnginx-mod-stream >/dev/null 2>&1; then
    echo "[*] Installing Nginx stream module..."
    apt_update_once
    apt-get install -y libnginx-mod-stream || \
        echo "[WARN] libnginx-mod-stream install failed; if 'nginx -t' reports an unknown 'stream' directive, install the stream module manually."
fi
systemctl enable nginx >/dev/null 2>&1 || true

# --------------------------------------------------
# 2. 渲染 Nginx 配置
# --------------------------------------------------
echo "[*] Creating Nginx config and SSL directories..."
mkdir -p /etc/nginx/stream.d /etc/nginx/conf.d /etc/nginx/ssl

# Variable-based stream proxy targets need an explicit resolver. Use the host's
# active resolver so DDNS changes are picked up without reloading Nginx.
if ! NGINX_RESOLVER=$(bash scripts/detect_nginx_resolvers.sh /etc/resolv.conf); then
    die "No nameserver found in /etc/resolv.conf; cannot configure runtime DNS resolution."
fi
export NGINX_RESOLVER

echo "[*] Rendering Nginx stream config from environment variables..."
# Tunnel 模式下 DOMAIN_HOME_TARGET 已在 load_env 中被覆盖为回环反向监听
envsubst '${DOMAIN_MAIN} ${DOMAIN_HOME_TARGET} ${NGINX_RESOLVER}' < templates/sni.conf.template > /etc/nginx/stream.d/sni.conf
rm -f /etc/nginx/conf.d/panel.conf

if [ ! -s /etc/nginx/stream.d/sni.conf ]; then
    die "Rendered config is empty: /etc/nginx/stream.d/sni.conf"
fi

# --------------------------------------------------
# 3. 注入 stream 块并重启 Nginx
# --------------------------------------------------
NGINX_CONF_BACKED_UP=0
if ! grep -qE "include\s+/etc/nginx/stream.d/.*\.conf;" /etc/nginx/nginx.conf; then
    echo "[*] Injecting stream module into nginx.conf (backup: /etc/nginx/nginx.conf.bak.deploy)..."
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.deploy
    NGINX_CONF_BACKED_UP=1
    cat << 'INNER_EOF' >> /etc/nginx/nginx.conf

# --- Auto injected by deploy script ---
stream {
    include /etc/nginx/stream.d/*.conf;
}
INNER_EOF
else
    echo "[*] stream module already exists in nginx.conf, skipping injection."
fi

echo "[*] Testing Nginx configuration..."
if ! nginx -t; then
    echo "[ERROR] Nginx config test failed. Nginx left untouched (old config still running)." >&2
    if [ "$NGINX_CONF_BACKED_UP" -eq 1 ]; then
        cp /etc/nginx/nginx.conf.bak.deploy /etc/nginx/nginx.conf
        echo "[*] Restored nginx.conf from backup."
    fi
    exit 1
fi

if systemctl is-active --quiet nginx; then
    systemctl reload nginx
    echo "[*] Nginx reloaded."
else
    systemctl enable --now nginx
    echo "[*] Nginx started."
fi

# --------------------------------------------------
# 4. ufw 防火墙收口，只保留 SSH 与 443 业务入口
# --------------------------------------------------
if ! command -v ufw >/dev/null 2>&1; then
    echo "[*] Installing ufw firewall..."
    apt_update_once
    apt-get install -y ufw
fi

echo "[*] Configuring firewall: allowing only 22/tcp (SSH) and 443/tcp (main traffic entry)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# 只留这两扇门，其他全部封死！
ufw allow 22/tcp   # SSH，给自己留的后门
ufw allow 443/tcp  # 所有的业务流量总入口
ufw --force enable
ufw status verbose

echo "[+] Nginx SNI routing deployed."
