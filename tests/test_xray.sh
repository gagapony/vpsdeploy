#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tpl="$repo_dir/templates/xray-server.json.template"
mod="$repo_dir/modules/xray.sh"
sni="$repo_dir/templates/sni.conf.template"
deploy="$repo_dir/modules/deploy.sh"
common="$repo_dir/lib/common.sh"

for file in "$tpl" "$mod" "$sni" "$deploy" "$common"; do
    if [ ! -s "$file" ]; then
        echo "[FAIL] missing xray artifact: $file" >&2
        exit 1
    fi
done

# 模板占位符与模块渲染变量一一对应
for var in XRAY_UUID XRAY_PRIVATE_KEY XRAY_SHORT_ID XRAY_DEST XRAY_SERVER_NAME; do
    grep -Fq "\${$var}" "$tpl"
    grep -Fq "\${$var}" "$mod" || {
        echo "[FAIL] module must render template variable: $var" >&2
        exit 1
    }
done
grep -Fq 'XRAY_DEST="${XRAY_DEST:-www.tesla.com:443}"' "$common"
grep -Fq 'XRAY_SERVER_NAME="${XRAY_SERVER_NAME:-www.tesla.com}"' "$common"

# Reality 节点形态：借用 dest 证书、回环监听、与 nginx SNI 分流对接
grep -Fq '"security": "reality"' "$tpl"
grep -Fq '"listen": "127.0.0.1"' "$tpl"
grep -Fq 'upstream vps_node    { server 127.0.0.1:8443; }' "$sni"
grep -Fq 'XRAY_LISTEN="127.0.0.1"' "$mod"
grep -Fq 'XRAY_PORT="8443"' "$mod"

# xray 不得自行开防火墙端口：公网只从 nginx 443 进
if grep -Fq 'ufw allow' "$mod"; then
    echo '[FAIL] xray must not open firewall ports; traffic enters via nginx 443' >&2
    exit 1
fi

# deploy 按 XRAY_ENABLED 开关逐级调用
grep -Fq '"$XRAY_ENABLED" = "true"' "$deploy"
grep -Fq 'bash modules/xray.sh install' "$deploy"

echo '[PASS] xray Reality node: loopback-only, template-driven, gated by XRAY_ENABLED'
