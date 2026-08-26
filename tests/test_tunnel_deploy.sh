#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
unit="$repo_dir/templates/chisel-server.service"
script="$repo_dir/scripts/deploy/tunnel/install.sh"
deploy="$repo_dir/deploy.sh"

for file in "$unit" "$script"; do
    if [ ! -s "$file" ]; then
        echo "[FAIL] missing tunnel deployment artifact: $file" >&2
        exit 1
    fi
done

grep -Fq 'CHISEL_TUNNEL_ENABLED="${CHISEL_TUNNEL_ENABLED:-false}"' "$deploy"
grep -Fq 'bash scripts/deploy/tunnel/install.sh' "$deploy"
grep -Fq 'reload-certificate.sh' "$deploy"
grep -Fq 'acme_domain_dir="$acme_home/${DOMAIN_MAIN}_ecc"' "$deploy"
grep -Fq -- '--install-cert -d "$DOMAIN_MAIN" --ecc' "$deploy"
grep -Fq 'CHISEL_VERSION="${CHISEL_VERSION:-1.11.8}"' "$script"
grep -Fq 'chisel_${CHISEL_VERSION}_linux_${asset_arch}.gz' "$script"
if grep -Fq 'systemctl disable --now nginx' "$script"; then
    echo '[FAIL] tunnel mode must preserve Nginx as the public 443 owner' >&2
    exit 1
fi
if grep -Fq 'ufw allow "${CHISEL_REVERSE_PORT}/tcp"' "$script"; then
    echo '[FAIL] loopback reverse listener must not be exposed by UFW' >&2
    exit 1
fi
grep -Fq 'CHISEL_REVERSE_BIND="${CHISEL_REVERSE_BIND:-127.0.0.1}"' "$deploy"
grep -Fq 'CHISEL_REVERSE_PORT="${CHISEL_REVERSE_PORT:-9443}"' "$deploy"
grep -Fq 'DOMAIN_HOME_TARGET="${CHISEL_REVERSE_BIND}:${CHISEL_REVERSE_PORT}"' "$deploy"
grep -Fq 'bash scripts/deploy/tunnel/install.sh' "$deploy"
grep -Fq 'nginx -t' "$deploy"
grep -Fq 'ufw allow "${CHISEL_PORT}/tcp"' "$script"
grep -Fq 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$unit"
grep -Fq -- '--reverse --port ${CHISEL_PORT}' "$unit"

echo '[PASS] tunnel deployment keeps Nginx on 443 and routes home SNI to a loopback reverse listener'
