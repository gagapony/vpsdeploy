#!/bin/bash
set -euo pipefail

CHISEL_VERSION="${CHISEL_VERSION:-1.11.8}"
CHISEL_PORT="${CHISEL_PORT:-9000}"
CHISEL_REVERSE_PORT="${CHISEL_REVERSE_PORT:-443}"
CHISEL_AUTH_FILE="${CHISEL_AUTH_FILE:-/etc/chisel/auth}"
CHISEL_CERT_SOURCE="${CHISEL_CERT_SOURCE:-}"
CHISEL_KEY_SOURCE="${CHISEL_KEY_SOURCE:-}"

for var in CHISEL_AUTH CHISEL_CERT_SOURCE CHISEL_KEY_SOURCE; do
    if [ -z "${!var:-}" ]; then
        echo "[ERROR] Missing required tunnel variable: $var" >&2
        exit 1
    fi
done
for source_file in "$CHISEL_CERT_SOURCE" "$CHISEL_KEY_SOURCE"; do
    if [ ! -s "$source_file" ]; then
        echo "[ERROR] Tunnel TLS source is missing or empty: $source_file" >&2
        exit 1
    fi
done
if [ "$CHISEL_PORT" = "$CHISEL_REVERSE_PORT" ]; then
    echo "[ERROR] Chisel control and reverse ports must differ." >&2
    exit 1
fi

case "$(dpkg --print-architecture)" in
    amd64) asset_arch=amd64 ;;
    arm64) asset_arch=arm64 ;;
    *) echo "[ERROR] Unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

if ! id chisel >/dev/null 2>&1; then
    useradd --system --home /var/lib/chisel --create-home --shell /usr/sbin/nologin chisel
fi
install -d -o root -g chisel -m 750 /etc/chisel

tmp_gz=$(mktemp)
tmp_bin=$(mktemp)
trap 'rm -f "$tmp_gz" "$tmp_bin"' EXIT
curl -fL "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/chisel_${CHISEL_VERSION}_linux_${asset_arch}.gz" -o "$tmp_gz"
gzip -dc "$tmp_gz" > "$tmp_bin"
install -o root -g root -m 755 "$tmp_bin" /usr/local/bin/chisel
/usr/local/bin/chisel --version

auth_tmp=$(mktemp)
env_tmp=$(mktemp)
trap 'rm -f "$tmp_gz" "$tmp_bin" "$auth_tmp" "$env_tmp"' EXIT
printf '%s\n' "$CHISEL_AUTH" > "$auth_tmp"
printf 'CHISEL_PORT=%s\n' "$CHISEL_PORT" > "$env_tmp"
install -o root -g chisel -m 640 "$auth_tmp" "$CHISEL_AUTH_FILE"
install -o root -g chisel -m 640 "$CHISEL_CERT_SOURCE" /etc/chisel/fullchain.pem
install -o root -g chisel -m 640 "$CHISEL_KEY_SOURCE" /etc/chisel/privkey.pem
install -o root -g chisel -m 640 "$env_tmp" /etc/chisel/server.env
install -o root -g root -m 644 templates/chisel-server.service /etc/systemd/system/chisel-server.service

systemctl daemon-reload
systemctl enable --now chisel-server
sleep 2
if ! systemctl is-active --quiet chisel-server; then
    echo "[ERROR] chisel-server failed to start." >&2
    exit 1
fi
if ! ss -tln | grep -qE ":${CHISEL_PORT}[[:space:]]"; then
    echo "[ERROR] chisel control port is not listening: $CHISEL_PORT" >&2
    exit 1
fi

ufw allow "${CHISEL_PORT}/tcp"
echo "[+] Tunnel server ready: control=${CHISEL_PORT}; reverse listener is managed by the authenticated client"
