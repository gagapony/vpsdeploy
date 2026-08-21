#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

DOMAIN_MAIN=example.com
DOMAIN_HOME_TARGET=home.example.net:8443
NGINX_RESOLVER='127.0.0.53 1.1.1.1 [2001:4860:4860::8888]'

sed \
    -e "s|\${DOMAIN_MAIN}|$DOMAIN_MAIN|g" \
    -e "s|\${DOMAIN_HOME_TARGET}|$DOMAIN_HOME_TARGET|g" \
    -e "s|\${NGINX_RESOLVER}|$NGINX_RESOLVER|g" \
    "$repo_dir/sni.conf.template" > "$rendered"

grep -Fq '~*\.example.com$            home.example.net:8443;' "$rendered"
grep -Fq 'resolver 127.0.0.53 1.1.1.1 [2001:4860:4860::8888] valid=60s ipv6=off;' "$rendered"
grep -Fq 'resolver_timeout 5s;' "$rendered"

if grep -Fq 'upstream home_server' "$rendered"; then
    echo '[FAIL] home target must not be resolved only when Nginx loads' >&2
    exit 1
fi
if grep -Fq 'local_panel' "$rendered" || grep -Fq 'panel.*' "$rendered"; then
    echo '[FAIL] panel/local_panel route must not exist after panel retirement' >&2
    exit 1
fi

grep -Fq 'proxy_pass $backend_name;' "$rendered"
echo '[PASS] SNI template uses runtime DNS and has no panel route'
