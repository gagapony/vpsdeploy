#!/bin/bash
set -e

if [ ! -f ".env" ]; then
    echo "[错误] 找不到 .env 文件！"
    exit 1
fi

# 导出环境变量给 envsubst 使用
set -a
source .env
set +a

if ! command -v envsubst >/dev/null 2>&1; then
    echo "[*] 正在安装 envsubst 工具..."
    apt-get update && apt-get install -y gettext-base
fi

echo "[*] 创建 Nginx 配置与证书目录..."
mkdir -p /etc/nginx/stream.d
mkdir -p /etc/nginx/conf.d
mkdir -p /etc/nginx/ssl

echo "[*] 正在基于环境变量渲染 Nginx 配置文件..."
envsubst '${DOMAIN_MAIN} ${DOMAIN_HOME_TARGET} ${PANEL_REAL_PORT}' < sni.conf.template > /etc/nginx/stream.d/sni.conf
envsubst '${DOMAIN_MAIN} ${PANEL_REAL_PORT}' < panel.conf.template > /etc/nginx/conf.d/panel.conf

if [ ! -d "$HOME/.acme.sh" ]; then
    echo "[*] 正在安装 acme.sh..."
    curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
fi
source "$HOME/.acme.sh/acme.sh.env"

echo "[*] 开始申请证书: ${DOMAIN_MAIN} & *.${DOMAIN_MAIN}"
~/.acme.sh/acme.sh --issue --dns dns_cf \
    -d "${DOMAIN_MAIN}" -d "*.${DOMAIN_MAIN}" \
    --server letsencrypt

echo "[*] 安装证书到 Nginx 目录..."
~/.acme.sh/acme.sh --install-cert -d "${DOMAIN_MAIN}" -d "*.${DOMAIN_MAIN}" \
    --key-file       /etc/nginx/ssl/${DOMAIN_MAIN}.key  \
    --fullchain-file /etc/nginx/ssl/fullchain.cer \
    --reloadcmd      "systemctl reload nginx"

if ! grep -q "include /etc/nginx/stream.d/\*.conf;" /etc/nginx/nginx.conf; then
    echo "[*] 正在向 nginx.conf 注入 stream 模块..."
    cat << 'INNER_EOF' >> /etc/nginx/nginx.conf

# --- Auto injected by deploy script ---
stream {
    include /etc/nginx/stream.d/*.conf;
}
INNER_EOF
fi

echo "[*] 测试并重启 Nginx..."
nginx -t
systemctl restart nginx
echo "[+] 部署完成！"
