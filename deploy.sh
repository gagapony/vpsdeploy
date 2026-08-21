#!/bin/bash
# deploy.sh - Nginx SNI 分流 + SSL 证书部署
# 仅支持 Debian / Ubuntu，需 root 运行
set -euo pipefail

# --------------------------------------------------
# 0. 前置检查
# --------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Please run this script as root."
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
echo "[*] Detected OS: ${PRETTY_NAME:-$OS_ID}"

if [ ! -f ".env" ]; then
    echo "[ERROR] .env file not found! (run this script from the project directory)"
    exit 1
fi

# 部署文件检查
for required_file in sni.conf.template scripts/detect_nginx_resolvers.sh; do
    if [ ! -f "$required_file" ]; then
        echo "[ERROR] Required file not found: $required_file (run this script from the project directory)"
        exit 1
    fi
done

# 导出环境变量给 envsubst 使用
set -a
source .env
set +a

# 校验必需变量，缺失立即中止（fail fast）
missing_vars=()
for var in DOMAIN_MAIN DOMAIN_HOME_TARGET; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done
if [ ${#missing_vars[@]} -gt 0 ]; then
    echo "[ERROR] Missing required variables in .env: ${missing_vars[*]}"
    exit 1
fi

# apt-get update 只执行一次
APT_UPDATED=0
apt_update_once() {
    if [ "$APT_UPDATED" -eq 0 ]; then
        apt-get update
        APT_UPDATED=1
    fi
}

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
echo "[*] Creating Nginx config directories..."
mkdir -p /etc/nginx/stream.d /etc/nginx/conf.d

# Variable-based stream proxy targets need an explicit resolver. Use the host's
# active resolver so DDNS changes are picked up without reloading Nginx.
if ! NGINX_RESOLVER=$(bash scripts/detect_nginx_resolvers.sh /etc/resolv.conf); then
    echo "[ERROR] No nameserver found in /etc/resolv.conf; cannot configure runtime DNS resolution."
    exit 1
fi
export NGINX_RESOLVER

echo "[*] Rendering Nginx config files from environment variables..."
# 严格限制 envsubst 只替换这几个变量，防止误伤 Nginx 原生变量 (如 $host, $remote_addr)
envsubst '${DOMAIN_MAIN} ${DOMAIN_HOME_TARGET} ${NGINX_RESOLVER}' < sni.conf.template > /etc/nginx/stream.d/sni.conf
rm -f /etc/nginx/conf.d/panel.conf

# 渲染结果校验：文件必须非空
for conf in /etc/nginx/stream.d/sni.conf; do
    if [ ! -s "$conf" ]; then
        echo "[ERROR] Rendered config is empty: $conf"
        exit 1
    fi
done

# --------------------------------------------------
# 3. SSL 证书
# --------------------------------------------------
# 目前 nginx 只做 stream/TCP passthrough，不在本机终结 TLS；旧 panel
# 面板入口已移除，因此不再申请/安装本机 wildcard 证书。

# --------------------------------------------------
# 4. 注入 stream 块并重启 Nginx
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
    echo "[ERROR] Nginx config test failed. Nginx left untouched (old config still running)."
    if [ "$NGINX_CONF_BACKED_UP" -eq 1 ]; then
        cp /etc/nginx/nginx.conf.bak.deploy /etc/nginx/nginx.conf
        echo "[*] Restored nginx.conf from backup."
    fi
    exit 1
fi

# 已在运行则 reload（零中断），未运行则 start
if systemctl is-active --quiet nginx; then
    systemctl reload nginx
    echo "[*] Nginx reloaded."
else
    systemctl start nginx
    echo "[*] Nginx started."
fi

# --------------------------------------------------
# 5. ufw 防火墙收口，只保留 SSH 与 443 业务入口
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

echo "[+] Deployment complete!"
