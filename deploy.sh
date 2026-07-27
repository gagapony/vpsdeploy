#!/bin/bash
# 遇到错误立刻退出，但会避开手动处理的逃逸点
set -e

if [ ! -f ".env" ]; then
    echo "[错误] 找不到 .env 文件！"
    exit 1
fi

# 导出环境变量给 envsubst 使用
set -a
source .env
set +a

# [优化 1]：多系统包管理器兼容，自动检测并安装 envsubst
if ! command -v envsubst >/dev/null 2>&1; then
    echo "[*] 正在安装 envsubst 工具..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y gettext-base
    elif command -v yum >/dev/null 2>&1; then
        yum install -y gettext
    else
        echo "[错误] 无法识别的包管理器，请手动安装含有 envsubst 的 gettext 包。"
        exit 1
    fi
fi

echo "[*] 创建 Nginx 配置与证书目录..."
mkdir -p /etc/nginx/stream.d
mkdir -p /etc/nginx/conf.d
mkdir -p /etc/nginx/ssl

echo "[*] 正在基于环境变量渲染 Nginx 配置文件..."
# 严格限制 envsubst 只替换这三个变量，防止误伤 Nginx 原生变量 (如 $host, $remote_addr)
envsubst '${DOMAIN_MAIN} ${DOMAIN_HOME_TARGET} ${PANEL_REAL_PORT}' < sni.conf.template > /etc/nginx/stream.d/sni.conf
envsubst '${DOMAIN_MAIN} ${PANEL_REAL_PORT}' < panel.conf.template > /etc/nginx/conf.d/panel.conf

if [ ! -d "$HOME/.acme.sh" ]; then
    echo "[*] 正在安装 acme.sh..."
    curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
fi
source "$HOME/.acme.sh/acme.sh.env"

echo "[*] 开始申请证书: ${DOMAIN_MAIN} & *.${DOMAIN_MAIN}"
# [优化 2]：增加 || true 容错处理。当证书未过期跳过时，不会触发 set -e 导致脚本中断
~/.acme.sh/acme.sh --issue --dns dns_cf \
    -d "${DOMAIN_MAIN}" -d "*.${DOMAIN_MAIN}" \
    --server letsencrypt || echo "[*] 证书已存在且未过期，跳过重新申请..."

echo "[*] 安装证书到 Nginx 目录..."
# 此处同样增加 || true 容错
~/.acme.sh/acme.sh --install-cert -d "${DOMAIN_MAIN}" -d "*.${DOMAIN_MAIN}" \
    --key-file       /etc/nginx/ssl/${DOMAIN_MAIN}.key  \
    --fullchain-file /etc/nginx/ssl/fullchain.cer \
    --reloadcmd      "systemctl reload nginx" || echo "[*] 证书安装操作完成。"

# [优化 3]：增强 Nginx stream 模块存在性检测，防止多次重复注入
if ! grep -qE "include\s+/etc/nginx/stream.d/.*\.conf;" /etc/nginx/nginx.conf; then
    echo "[*] 正在向 nginx.conf 注入 stream 模块..."
    cat << 'INNER_EOF' >> /etc/nginx/nginx.conf

# --- Auto injected by deploy script ---
stream {
    include /etc/nginx/stream.d/*.conf;
}
INNER_EOF
else
    echo "[*] stream 模块已存在于 nginx.conf，跳过注入。"
fi

echo "[*] 测试并重启 Nginx..."
nginx -t
systemctl restart nginx
echo "[+] 部署完成！"
