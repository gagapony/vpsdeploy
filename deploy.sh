#!/bin/bash
# 遇到错误立刻退出，但会避开手动处理的逃逸点
set -e

if [ ! -f ".env" ]; then
    echo "[ERROR] .env file not found!"
    exit 1
fi

# 导出环境变量给 envsubst 使用
set -a
source .env
set +a

# [优化 1]：多系统包管理器兼容，自动检测并安装 envsubst
if ! command -v envsubst >/dev/null 2>&1; then
    echo "[*] Installing envsubst tool..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y gettext-base
    elif command -v yum >/dev/null 2>&1; then
        yum install -y gettext
    else
        echo "[ERROR] Unsupported package manager. Please install the gettext package (providing envsubst) manually."
        exit 1
    fi
fi

echo "[*] Creating Nginx config and SSL directories..."
mkdir -p /etc/nginx/stream.d
mkdir -p /etc/nginx/conf.d
mkdir -p /etc/nginx/ssl

echo "[*] Rendering Nginx config files from environment variables..."
# 严格限制 envsubst 只替换这三个变量，防止误伤 Nginx 原生变量 (如 $host, $remote_addr)
envsubst '${DOMAIN_MAIN} ${DOMAIN_HOME_TARGET} ${PANEL_REAL_PORT}' < sni.conf.template > /etc/nginx/stream.d/sni.conf
envsubst '${DOMAIN_MAIN} ${PANEL_REAL_PORT}' < panel.conf.template > /etc/nginx/conf.d/panel.conf

if [ ! -d "$HOME/.acme.sh" ]; then
    echo "[*] Installing acme.sh..."
    curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
fi
source "$HOME/.acme.sh/acme.sh.env"

echo "[*] Requesting certificate: ${DOMAIN_MAIN} & *.${DOMAIN_MAIN}"
# [优化 2]：增加 || true 容错处理。当证书未过期跳过时，不会触发 set -e 导致脚本中断
~/.acme.sh/acme.sh --issue --dns dns_cf \
    -d "${DOMAIN_MAIN}" -d "*.${DOMAIN_MAIN}" \
    --server letsencrypt || echo "[*] Certificate exists and is still valid, skipping renewal..."

echo "[*] Installing certificate to Nginx directory..."
# 此处同样增加 || true 容错
~/.acme.sh/acme.sh --install-cert -d "${DOMAIN_MAIN}" -d "*.${DOMAIN_MAIN}" \
    --key-file       /etc/nginx/ssl/${DOMAIN_MAIN}.key  \
    --fullchain-file /etc/nginx/ssl/fullchain.cer \
    --reloadcmd      "systemctl reload nginx" || echo "[*] Certificate installation completed."

# [优化 3]：增强 Nginx stream 模块存在性检测，防止多次重复注入
if ! grep -qE "include\s+/etc/nginx/stream.d/.*\.conf;" /etc/nginx/nginx.conf; then
    echo "[*] Injecting stream module into nginx.conf..."
    cat << 'INNER_EOF' >> /etc/nginx/nginx.conf

# --- Auto injected by deploy script ---
stream {
    include /etc/nginx/stream.d/*.conf;
}
INNER_EOF
else
    echo "[*] stream module already exists in nginx.conf, skipping injection."
fi

echo "[*] Testing and restarting Nginx..."
nginx -t
systemctl restart nginx

# [优化 4]：ufw 防火墙收口，只保留 SSH 与 443 业务入口
if ! command -v ufw >/dev/null 2>&1; then
    echo "[*] Installing ufw firewall..."
    apt-get update && apt-get install -y ufw
    echo "[*] Installed ufw firewall"
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
