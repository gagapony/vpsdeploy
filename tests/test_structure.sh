#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
entry="$repo_dir/vps-router.sh"
common="$repo_dir/lib/common.sh"

[ -s "$entry" ] || { echo "[FAIL] unified entry missing: vps-router.sh" >&2; exit 1; }
[ -s "$common" ] || { echo "[FAIL] shared lib missing: lib/common.sh" >&2; exit 1; }

# 统一入口必须分发到每个模块，且每个模块 source 共享 lib
for m in init nginx cert tunnel xray deploy all; do
    mod="$repo_dir/modules/$m.sh"
    [ -s "$mod" ] || { echo "[FAIL] missing module: modules/$m.sh" >&2; exit 1; }
    grep -Fq "modules/$m.sh" "$entry" || { echo "[FAIL] entry must dispatch to $m" >&2; exit 1; }
    grep -Fq 'lib/common.sh' "$mod" || { echo "[FAIL] $m must source lib/common.sh" >&2; exit 1; }
done

# 共享前置真实存在（root/OS 检查不再散落各脚本）
grep -Fq 'require_root()' "$common"
grep -Fq 'require_debian_ubuntu()' "$common"
grep -Fq 'load_env()' "$common"

# acme 续期回调的独立入口
[ -s "$repo_dir/scripts/reload-certificate.sh" ] || { echo "[FAIL] missing scripts/reload-certificate.sh" >&2; exit 1; }

# 旧的单体脚本/一次性脚本不允许回归
for gone in deploy.sh vps_init.sh sni.conf.template scripts/cf_panel_dns_migrate.py scripts/deploy; do
    if [ -e "$repo_dir/$gone" ]; then
        echo "[FAIL] legacy path still present: $gone" >&2
        exit 1
    fi
done

echo '[PASS] unified entry dispatches all modules; shared preflight centralized; legacy monoliths gone'
