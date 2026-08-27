#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
unit="$repo_dir/templates/chisel-server.service"
tunnel="$repo_dir/modules/tunnel.sh"
deploy="$repo_dir/modules/deploy.sh"
common="$repo_dir/lib/common.sh"
cert="$repo_dir/modules/cert.sh"

for file in "$unit" "$tunnel" "$deploy" "$common" "$cert"; do
    if [ ! -s "$file" ]; then
        echo "[FAIL] missing tunnel deployment artifact: $file" >&2
        exit 1
    fi
done

# .env 数据契约集中在 lib/common.sh
grep -Fq 'CHISEL_TUNNEL_ENABLED="${CHISEL_TUNNEL_ENABLED:-false}"' "$common"
grep -Fq 'CHISEL_REVERSE_BIND="${CHISEL_REVERSE_BIND:-127.0.0.1}"' "$common"
grep -Fq 'CHISEL_REVERSE_PORT="${CHISEL_REVERSE_PORT:-9443}"' "$common"
grep -Fq 'DOMAIN_HOME_TARGET="${CHISEL_REVERSE_BIND}:${CHISEL_REVERSE_PORT}"' "$common"

# 组合命令逐级调用 tunnel；cert 模块负责续期回调注册
grep -Fq 'bash modules/tunnel.sh' "$deploy"
grep -Fq 'scripts/reload-certificate.sh' "$cert"
grep -Fq 'acme_domain_dir="$acme_home/${DOMAIN_MAIN}_ecc"' "$cert"
grep -Fq -- '--install-cert -d "$DOMAIN_MAIN" --ecc' "$cert"

# tunnel 模块自身的兜底默认与校验
grep -Fq 'CHISEL_VERSION="${CHISEL_VERSION:-1.11.8}"' "$tunnel"
grep -Fq 'chisel_${CHISEL_VERSION}_linux_${asset_arch}.gz' "$tunnel"
if grep -Fq 'systemctl disable --now nginx' "$tunnel"; then
    echo '[FAIL] tunnel mode must preserve Nginx as the public 443 owner' >&2
    exit 1
fi
if grep -Fq 'ufw allow "${CHISEL_REVERSE_PORT}/tcp"' "$tunnel"; then
    echo '[FAIL] loopback reverse listener must not be exposed by UFW' >&2
    exit 1
fi
grep -Fq 'ufw allow "${CHISEL_PORT}/tcp"' "$tunnel"
grep -Fq 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$unit"
grep -Fq -- '--reverse --port ${CHISEL_PORT}' "$unit"

echo '[PASS] tunnel deployment keeps Nginx on 443 and routes home SNI to a loopback reverse listener'
