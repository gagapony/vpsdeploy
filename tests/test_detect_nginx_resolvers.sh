#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT

cat > "$fixture" <<'EOF'
# Generated resolver configuration
nameserver 127.0.0.53
nameserver 1.1.1.1
nameserver 2001:4860:4860::8888
options edns0
EOF

actual=$(bash "$repo_dir/scripts/detect_nginx_resolvers.sh" "$fixture")
expected='127.0.0.53 1.1.1.1 [2001:4860:4860::8888]'
if [ "$actual" != "$expected" ]; then
    echo "[FAIL] expected '$expected', got '$actual'" >&2
    exit 1
fi

printf '# no nameservers\n' > "$fixture"
if bash "$repo_dir/scripts/detect_nginx_resolvers.sh" "$fixture" >/dev/null 2>&1; then
    echo '[FAIL] resolver detection must fail when no nameserver is configured' >&2
    exit 1
fi

echo '[PASS] resolver detection handles IPv4, IPv6, fallbacks, and missing configuration'
