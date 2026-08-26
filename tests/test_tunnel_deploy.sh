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
grep -Fq 'CHISEL_VERSION="${CHISEL_VERSION:-1.11.8}"' "$script"
grep -Fq 'chisel_${CHISEL_VERSION}_linux_${asset_arch}.gz' "$script"
grep -Fq 'systemctl disable --now nginx' "$script"
grep -Fq 'ufw allow "${CHISEL_PORT}/tcp"' "$script"
grep -Fq 'ufw allow "${CHISEL_REVERSE_PORT}/tcp"' "$script"
grep -Fq 'AmbientCapabilities=CAP_NET_BIND_SERVICE' "$unit"
grep -Fq -- '--reverse --port ${CHISEL_PORT}' "$unit"

echo '[PASS] tunnel deployment installs chisel, retires nginx stream, and opens required ports'
