# my-vps-router

VPS 中转路由的部署与维护脚本：nginx SNI 分流 + wildcard 证书 + Chisel 反向隧道 + Xray Reality 节点。

## 结构（统一入口，逐级调用）

```
vps-router.sh                 # 唯一入口：./vps-router.sh <command>
├── lib/common.sh             # 共享前置：root/OS 检查、.env 数据契约、apt 去重
├── modules/                  # 子功能，一个职责一个文件
│   ├── init.sh               #   swap / BBR / (--with-docker)
│   ├── nginx.sh              #   SNI 分流：依赖 + 渲染 + stream 注入 + ufw
│   ├── cert.sh               #   wildcard 证书（acme.sh DNS-01，复用优先）
│   ├── tunnel.sh             #   Chisel 反向隧道服务端
│   ├── xray.sh               #   Xray Reality 节点（install / keys）
│   ├── deploy.sh             #   组合：nginx → cert → tunnel → xray（按 .env 开关）
│   └── all.sh                #   全量：init（不含 docker）+ deploy，docker 由 INIT_WITH_DOCKER 控制
├── scripts/                  # 独立入口（acme cron / 模块直接调用，不经统一入口）
│   ├── detect_nginx_resolvers.sh
│   └── reload-certificate.sh # acme 续期回调：同步证书给 chisel 并 reload nginx
├── templates/                # 所有模板（envsubst 渲染）
│   ├── sni.conf.template     #   SNI 分流规则（node-*→本机 xray，其余→家服）
│   ├── chisel-server.service #   chisel systemd 单元
│   └── xray-server.json.template  # Reality inbound（listen 必须与 sni.conf 的 vps_node 一致）
├── tests/                    # 纯 grep/渲染断言，无需 root，本机可跑
└── docs/network-topology.md  # 网络拓扑与排障手册
```

## 常用命令

```bash
sudo ./vps-router.sh init --with-docker   # 新机初始化（swap/BBR/Docker）
sudo ./vps-router.sh all                   # 全量：init(无docker) + deploy，docker 看 INIT_WITH_DOCKER
sudo ./vps-router.sh deploy               # 一键：SNI 分流 + 证书 + 隧道 + xray（按开关）
sudo ./vps-router.sh nginx                # 只重部署 SNI 分流与防火墙
sudo ./vps-router.sh cert                 # 只处理证书（复用优先，缺失才签发）
sudo ./vps-router.sh tunnel               # 只部署 Chisel 隧道
./vps-router.sh xray keys                 # 生成 Reality x25519 密钥对（无需 root 场景除外）
bash tests/test_*.sh                      # 跑全部结构/模板测试
```

## 数据契约（.env）

所有默认值只在 `lib/common.sh` 的 `load_env()` 定义一次；各模块只校验自己需要的变量：

- 公共：`DOMAIN_MAIN`、`DOMAIN_HOME_TARGET`
- 证书（仅签发时必需）：`ACME_EMAIL`、`CF_Token`（`dns_cf` 不需要 Account ID）
- 隧道：`CHISEL_TUNNEL_ENABLED`（true 时 `DOMAIN_HOME_TARGET` 被覆盖为回环反向监听）、`CHISEL_AUTH`
- xray：`XRAY_ENABLED`、`XRAY_UUID`、`XRAY_PRIVATE_KEY`、`XRAY_SHORT_ID`、`XRAY_DEST`、`XRAY_SERVER_NAME`

复制 `.env.example` 为 `.env` 后填写；`.env` 永不提交。

## 证书归属（易混）

- **xray（VLESS-Reality）**：借用 dest 站点证书（默认 www.tesla.com），443 由 nginx 纯 TCP 透传 → **不需要本机证书**。
- **wildcard 证书**：唯一消费者是 tunnel 模式的 chisel TLS，由 `cert` 模块维护，续期经 `scripts/reload-certificate.sh` 同步。
