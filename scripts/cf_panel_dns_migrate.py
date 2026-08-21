#!/usr/bin/env python3
import json
import os
import urllib.error
import urllib.request

DOMAIN = os.environ["DOMAIN_MAIN"]
TOKEN = os.environ["CF_Token"]
HEADERS = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}
ACTIVE_RENAMES = {
    "panel-de-akile": "de-akile",
    "panel-de-panstar": "de-panstar",
    "panel-hk-vmiss": "hk-vmiss",
    "panel-hk-vmiss-dc2": "hk-vmiss-dc2",
    "panel-hk-yunyou": "hk-yunyou",
    "panel-jp-panstar": "jp-panstar",
    "panel-us-zgo": "us-zgo",
}
STALE = {"panel-hk-datawave", "panel-sg-datawave"}


def req(method, url, data=None):
    body = None if data is None else json.dumps(data).encode()
    r = urllib.request.Request(url, data=body, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            out = json.load(resp)
    except urllib.error.HTTPError as e:
        raise SystemExit(e.read().decode())
    if not out.get("success"):
        raise SystemExit(json.dumps(out, indent=2))
    return out


def main():
    zone = req("GET", f"https://api.cloudflare.com/client/v4/zones?name={DOMAIN}")["result"][0]["id"]
    recs = req("GET", f"https://api.cloudflare.com/client/v4/zones/{zone}/dns_records?per_page=200")["result"]
    by_name = {r["name"]: r for r in recs}
    print("# create/ensure active non-panel records")
    for old_short, new_short in ACTIVE_RENAMES.items():
        old = f"{old_short}.{DOMAIN}"
        new = f"{new_short}.{DOMAIN}"
        src = by_name.get(old)
        if not src:
            print(f"MISS old {old}")
            continue
        payload = {k: src[k] for k in ["type", "content", "ttl", "proxied"] if k in src}
        payload["name"] = new
        if new in by_name:
            dst = by_name[new]
            changed = any(dst.get(k) != payload.get(k) for k in ["type", "content", "ttl", "proxied"])
            if changed:
                req("PUT", f"https://api.cloudflare.com/client/v4/zones/{zone}/dns_records/{dst['id']}", payload)
                print(f"UPDATE {new} -> {payload['content']}")
            else:
                print(f"OK     {new} -> {payload['content']}")
        else:
            req("POST", f"https://api.cloudflare.com/client/v4/zones/{zone}/dns_records", payload)
            print(f"CREATE {new} -> {payload['content']}")
    print("# delete stale datawave panel records")
    for old_short in sorted(STALE):
        old = f"{old_short}.{DOMAIN}"
        r = by_name.get(old)
        if not r:
            print(f"ABSENT {old}")
        else:
            req("DELETE", f"https://api.cloudflare.com/client/v4/zones/{zone}/dns_records/{r['id']}")
            print(f"DELETE {old} -> {r['content']}")


if __name__ == "__main__":
    main()
