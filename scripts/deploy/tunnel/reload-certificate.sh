#!/bin/bash
set -euo pipefail

cert_key=${1:?certificate key path required}
cert_chain=${2:?certificate chain path required}

if systemctl is-enabled --quiet chisel-server 2>/dev/null; then
    install -o root -g chisel -m 640 "$cert_key" /etc/chisel/privkey.pem
    install -o root -g chisel -m 640 "$cert_chain" /etc/chisel/fullchain.pem
    systemctl restart chisel-server
elif systemctl is-active --quiet nginx 2>/dev/null; then
    systemctl reload nginx
fi
