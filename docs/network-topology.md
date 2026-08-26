# 网络转发拓扑

> 本文档记录 `*.528777.xyz` / `*.529777.xyz` 回家庭网络的转发拓扑。
> 标注 【实测】 的为排查时直接验证过的事实;标注 【待核对】 的来自 Homepage 历史配置,使用前请在现网再确认一次。

## 1. 概览

回家有 **两条入口**,最终都汇到家庭 Lucky:

| 路径 | 访问 URL | DNS 解析 | 走哪 | 适用场景 |
|---|---|---|---|---|
| **A 经中转** | `https://X.528777.xyz`(:443) | `*.528777.xyz` → 中转 `38.47.103.54` | 中转 nginx SNI 透传 → 家庭 `:8443` | `8443` 被封 / 要标准 `443` 端口 |
| **B 直连** | `https://X.529777.xyz:8443` | `529777.xyz` → 家庭 `115.44.240.7` | 直接连家庭公网 `:8443` | `8443` 未被封(更省一跳) |

```
   ┌─ 路径 A  经中转(:443,用于 8443 被封 / 要标准端口的网络) ──────┐
   │  https://lucky.528777.xyz                                          │
   │   → *.528777.xyz = 38.47.103.54:443  (中转 VPS, 固定公网)          │
   │   → 中转 nginx (ssl_preread 按 SNI 分流,纯 TCP 透传):              │
   │       *.528777.xyz        → 529777.xyz:8443   (→ 透传回家)         │
   │       default(其余)       → 127.0.0.1:8443    (xui_node→本地xray)  │
   │       (panel 面板路由已移除, 2026-08-21)                           │
   └──────────────────────────────────────────────────────┬─────────────┘
                                                          │ (命中 *.528777.xyz)
   ┌─ 路径 B  直连家庭(:8443,用于 8443 未被封的网络,更省一跳) ──┐
   │  https://lucky.529777.xyz:8443                                    │
   │   → 529777.xyz = 115.44.240.7:8443  (家庭公网, DDNS 动态!)        │
   └──────────────────────────────────────────────────────┬────────────┘
                                                          ▼
                            家庭公网 115.44.240.7:8443
                                                          │
                                                          ▼
                          家庭路由器:端口转发 8443 → 192.168.7.12:8443
                                                          ▼
                          家庭 Lucky(192.168.7.12, gdy666/lucky)
                          TLS 终结(证书 CN=529777.xyz)→ 按 SNI 转 LAN 服务
                                                          ▼
                          LAN 服务 192.168.7.x:port(komari / code / doc …)
```

> 核心思路:**两层 SNI 分流**。路径 A 时第一层在中转 VPS(只 TCP 透传、不持家庭私钥),第二层在家庭 Lucky(终结 TLS、按子域转内网);路径 B 跳过中转直连 Lucky。两条路径在家庭 Lucky 处汇合。
>
> 之所以保留两条入口:有些网络(公司、酒店、部分运营商)会封非标准端口,此时只能走路径 A 的标准 `443`;在 `8443` 可达的网络里走路径 B 更快、也不依赖中转 VPS。

## 2. 关键地址 / 域名

| 名称 | 值 | 说明 | 置信度 |
|---|---|---|---|
| 当前中转 VPS | `38.47.103.54` | 固定公网,nginx + xray + x-ui | 【实测】 |
| 旧中转 VPS | `38.207.174.90` | **已下线**,勿再用 | 【实测】 |
| 家庭公网 (DDNS) | `115.44.240.7` | 动态 IP,会变(曾为 `.75`/`.104`/`.108`) | 【实测】 |
| 主域名 | `528777.xyz` | 服务域名,子域 `*.528777.xyz` 都指向中转 → 走**路径 A** | 【实测】 |
| 家庭 DDNS 主机名 | `529777.xyz` | 解析到家庭动态公网 IP → 走**路径 B** | 【实测】 |
| `lucky.528777.xyz` | → `38.47.103.54` | Lucky 管理面板,经中转(路径 A)回家庭 | 【实测】 |
| `lucky.529777.xyz:8443` | → `115.44.240.7:8443` | Lucky 管理面板,直连(路径 B) | 【实测】 |

## 3. 数据流(以 Lucky 为例)

**路径 A — 经中转 `lucky.528777.xyz`(端口被封时用)**

1. 客户端解析 `lucky.528777.xyz` → `38.47.103.54`,连 `:443`。
2. 中转 nginx **不解 TLS**,只读 ClientHello 里的 SNI=`lucky.528777.xyz`。
3. 命中 `~*\.528777.xyz$` → `proxy_pass` 到 `529777.xyz:8443`。
4. nginx 运行时解析 `529777.xyz` → `115.44.240.7`,把整条 TCP 透传过去。
5. 家庭路由器把公网 `:8443` 转发到 `192.168.7.12:8443`(Lucky)。
6. Lucky 终结 TLS(持 `529777.xyz` 证书),按 SNI 转到 `192.168.7.12:16601`(Lucky 自身后台)或其它内网服务。
7. 客户端拿到 `HTTP/2 200`,响应头里 `rip: 192.168.7.12` 即家庭 Lucky。

**路径 B — 直连 `lucky.529777.xyz:8443`(端口未封时用)**

跳过上面的第 2~4 步:客户端解析 `529777.xyz` → `115.44.240.7`,直接连 `:8443` → 家庭路由器 → Lucky。第 5~7 步相同。比路径 A 少一跳、不依赖中转 VPS。

## 4. 中转 VPS(38.47.103.54)

> 中转只服务于**路径 A**;路径 B 不经过中转。

### 4.1 nginx stream SNI 路由(配置:`/etc/nginx/stream.d/sni.conf`)

```nginx
resolver 127.0.0.53 valid=60s ipv6=off;   # 运行时解析,防 DDNS 缓存旧 IP
resolver_timeout 5s;

map $ssl_preread_server_name $backend_name {
    ~*\.528777\.xyz$           529777.xyz:8443;   # 变量 → 走 resolver
    default                    xui_node;          # 本地 xray(8443)
}

upstream xui_node    { server 127.0.0.1:8443; }
upstream reject_hole { server 127.0.0.1:9; }

server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_pass $backend_name;
    access_log /var/log/nginx/stream-debug.log stream_debug;
}
```

> 2026-08-21 起 panel 面板路由(`local_panel`/58925)与 `vps-term`、`*.icloud.com` 自定义已从仓库模板移除；各 VPS 现网若有这些行,以仓库模板为准覆盖。

> 关键点:`home` 路由用变量 `529777.xyz:8443` 而不是静态 `upstream`,nginx 才会按 `resolver valid=60s` 周期性重新解析,DDNS 变 IP 后无需手动 reload。详见第 7 节。

### 4.2 中转上的其它服务【实测】

| 端口 | 进程 | 用途 |
|---|---|---|
| 22 | sshd | 管理 |
| 80 / 443 | nginx | 80 跳转 / 443 SNI 分流总入口 |
| 8443 | xray | 代理节点(VLESS-Reality,借用 dest 证书,无需本机证书) |
| 2096 / 58924 / 11111 / 62789 | x-ui 遗留 | 待迁移后清理(见 vps-maintain 迁移计划) |

### 4.3 证书 / 防火墙【实测】

- 2026-08-21 起 nginx 只做 stream/TCP passthrough,VLESS-Reality 借用 dest 站点证书,**本机不再需要 wildcard 证书**;acme.sh 块已从 deploy.sh 移除。如未来加 TLS 终结类服务再恢复。
- ufw:`deny incoming`,只放行 `22/tcp`、`443/tcp`。
- DNS 解析:systemd-resolved stub `127.0.0.53`(`/etc/resolv.conf`)。

## 5. 家庭网络

### 5.1 公网入口【实测】

- 出口 IP 动态,由 DDNS 维护到 `529777.xyz`(当前 `115.44.240.7`)。
- 对外只开 `:8443`(HTTPS),由家庭路由器转发到 `192.168.7.12` 上的 Lucky。
- 这是**路径 B** 的入口,也是**路径 A** 经中转透传回来的落点 —— 两条路径都在这里汇入 Lucky。

### 5.2 Lucky(家庭反向代理网关)【实测】

- 容器:`gdy666/lucky:latest`(版本 2.20.2),`docker`,**host 网络模式**,挂载 `./config:/goodluck`。
- 监听:`:16601`(HTTP/HTTPS 管理后台),另在 `:8443` 做 TLS 反向代理(持 `529777.xyz` 证书)。
- 模块:ssl / reverseproxy / portforward / ddns / stun / cloudflared / webdav / ftp / filebrowser / dlna / wol 等。
- Lucky 负责第二层 SNI 分流:把 `X.528777.xyz`(路径 A)或 `X.529777.xyz`(路径 B)转到对应内网 `192.168.7.x:port`。

### 5.3 LAN 设备 / 服务表【待核对 — 来自 Homepage 历史配置】

> 以下是 Homepage `settings.yaml` 历史快照里的映射,部分可能已变,使用前请核对。

| IP | 设备 / 服务 | 端口 |
|---|---|---|
| 192.168.7.1 | iKuai(主路由) | 80 |
| 192.168.7.2 | Proxmox VE | 8006 |
| 192.168.7.3 | OpenWrt(也是本机 DNS) | 80 / 9876(ddnsgo) |
| 192.168.7.10 | NAS 系:Emby / Moon / qBittorrent / Transmission / MP | 8096 / 10010 / 8085 / 9091 / 3000 |
| 192.168.7.12 | 家庭服务器:本 Pi 宿主 + Lucky + OpenClaw / HA / Doc / Tools / Code | 16601(Lucky) / 18789 / 8123 / 10030 / 10040 / 10001 |

> 已确认:Pi agent 运行在 `192.168.7.12`,本机 DNS 是 `192.168.7.3`。

### 5.4 Homepage 外链约定【待核对】

Homepage 用扩展参数同时给出两条入口,对应上面的两条路径:

```
http://192.168.7.12:16601#ext0=https://lucky.529777.xyz:8443#ext1=https://lucky.528777.xyz
```

- `ext0` = **路径 B**(直连家庭,`*.529777.xyz:8443`)
- `ext1` = **路径 A**(经中转,`*.528777.xyz`)

## 6. 两个域名 vs 两条路径(易混点)

- **`528777.xyz`** = 服务域,`*.528777.xyz` 在公网都解析到 **中转 VPS** → 走 **路径 A**(经中转,`443`)。
- **`529777.xyz`** = 家庭 DDNS,解析到 **家庭动态公网 IP** → 走 **路径 B**(直连,`8443`)。
- 中转内部(路径 A 第 3~4 步)也是用 `529777.xyz:8443` 去定位家庭,所以**两条路径最终都汇到家庭 `:8443`**。
- 选哪条看网络环境:`8443` 被封就走路径 A(标准 `443`);没封就直接走路径 B(少一跳、不依赖中转)。

## 7. 已知坑:nginx 缓存上游 DDNS 的旧 IP

**现象:** 家庭公网 IP 变了之后,**路径 A**(`*.528777.xyz`)全线 502 / 60s 超时;`nginx -t` 正常、家庭上游实际可达。路径 B(直连)不受影响,照常可用 —— 这也是它作为兜底入口的价值。

**根因:** 当 `upstream` 块里写的是域名时,nginx **只在启动 / reload 时解析一次**,之后一直用缓存的 IP。家庭是动态 IP,变了之后中转还在打旧地址。

**修复(已在中转 38.47.103.54 实施并验证):**

- 把 home 路由从静态 `upstream home_server { server 529777.xyz:8443; }` 改成变量 `529777.xyz:8443`;
- 顶部加 `resolver 127.0.0.53 valid=60s ipv6=off;` 与 `resolver_timeout 5s;`;
- 删除那个静态 `upstream`。
- 变量型 `proxy_pass` 命中域名时会走 `resolver` 周期性重解析,从此 DDNS 变 IP 无需手动重启 nginx。

**排查要点:**

- 看 `/var/log/nginx/stream-debug.log` 里的 `upstream=` 是不是旧 IP、`status=502`、`session_time≈60s`。
- 在中转上 `getent ahostsv4 529777.xyz` 对比日志里的 `upstream` IP 是否一致。
- 从中转测上游:`curl -kI https://529777.xyz:8443/`(应返回证书 CN=529777.xyz)。
- 回环自测:`curl -kI --resolve lucky.528777.xyz:443:127.0.0.1 https://lucky.528777.xyz/`。

## 8. 运维注意

- **安全:** 本次排障用过的 root 密码已在对话中出现,尽快更换。
- **仓库同步:** 现网 `sni.conf` 比仓库 `sni.conf.template` 多了 `vps-term`/`icloud`/`reject_hole`/`local_panel:8008` 等自定义,直接跑仓库 `deploy.sh` 会覆盖丢这些。需把仓库同步成现网现状后再作为可信源。
- **备份:** 本次改动前已备份为 `/etc/nginx/stream.d/sni.conf.bak.20260814-035344`。
# Tunnel entry mode

Set `CHISEL_TUNNEL_ENABLED=true` only on the relay that runs the Clover tunnel.
Chisel listens publicly on the TLS control port (default `9000`), while Clover
requests a loopback-only reverse listener:

```text
R:127.0.0.1:9443:127.0.0.1:8443
```

Nginx remains the sole public `443` owner. Its stream map sends managed home
service SNI (`*.528777.xyz`) to `127.0.0.1:9443`; `node-*` and the default branch
continue to local Xray on `127.0.0.1:8443`, preserving Reality camouflage SNI.
Port `9443` is never opened in UFW.

The tunnel control endpoint uses the wildcard certificate managed by this
repository. ACME renewal copies the renewed pair into `/etc/chisel/`, restarts
`chisel-server`, and reloads Nginx. Authentication remains in `.env` and
`/etc/chisel/auth`; it must never be committed.
