#!/usr/bin/env python3
# cf_node_dns.py — DNS 统一 node- 前缀：node-<bare> = VPS 服务(SNI 分流到本地 xray)
# 幂等：已有 node- 记录跳过；裸名记录改删；panel- 旧别名保留（回滚用，最后清理）
import json
import os
import sys
import urllib.error
import urllib.request

DOMAIN = os.environ["DOMAIN_MAIN"]
H = {"Authorization": "Bearer " + os.environ["CF_Token"], "Content-Type": "application/json"}
RENAMES = {
    "de-akile": "node-de-akile", "de-panstar": "node-de-panstar",
    "hk-vmiss": "node-hk-vmiss", "hk-vmiss-dc2": "node-hk-vmiss-dc2",
    "hk-yunyou": "node-hk-yunyou", "jp-panstar": "node-jp-panstar",
    "us-zgo": "node-us-zgo",
}


def req(method, url, data=None):
    body = None if data is None else json.dumps(data).encode()
    r = urllib.request.Request(url, data=body, headers=H, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as x:
            return json.load(x)
    except urllib.error.HTTPError as e:
        raise SystemExit(e.read().decode())


def main():
    zid = req("GET", f"https://api.cloudflare.com/client/v4/zones?name={DOMAIN}")["result"][0]["id"]
    by = {r["name"]: r for r in req("GET", f"https://api.cloudflare.com/client/v4/zones/{zid}/dns_records?per_page=200")["result"]}
    for bare, new in RENAMES.items():
        old = f"{bare}.{DOMAIN}"
        nn = f"{new}.{DOMAIN}"
        src = by.get(old) or by.get(f"panel-{bare}.{DOMAIN}")
        if not src:
            print(f"MISS  {old}")
            continue
        if nn in by:
            print(f"OK    {nn}")
        else:
            payload = {"type": src["type"], "content": src["content"], "ttl": src["ttl"], "proxied": src["proxied"], "name": nn}
            req("POST", f"https://api.cloudflare.com/client/v4/zones/{zid}/dns_records", payload)
            print(f"CREATE {nn} -> {src['content']}")
        if old in by:
            req("DELETE", f"https://api.cloudflare.com/client/v4/zones/{zid}/dns_records/{by[old]['id']}")
            print(f"DEL    bare {old}")


if __name__ == "__main__":
    main()
