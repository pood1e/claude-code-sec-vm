# claude-code-sec-vm

隔离运行不可信 AI 编程客户端的远端 Kali 开发 VM。目标宿主由 `.env.local` 的 `REMOTE_HOST` 指定，使用 KVM/libvirt；Kali VM 通过宿主机**按 VM 作用域**的 sing-box TProxy 透明出站，VM 内不跑代理、不设置代理环境变量。

## 架构

```text
local laptop ──ssh/vnc──> ${REMOTE_HOST}
                              │
                              ├─ host normal egress：不改、不走 ldp
                              ├─ host sing-box TProxy：只匹配 ${LAN_BRIDGE} + ${DEV_IP}
                              │
                              └─ ccsvm-lan bridge ${LAN_HOST_IP} on ${LAN_CIDR}
                                           │
                                      kali-dev ${DEV_IP}
                                      default via ${LAN_HOST_IP}
```

- `kali-dev`：唯一 VM，Kali 开发环境；可选启用 XFCE + VNC；`dev` 用户可 sudo，`agent` 用户无 sudo。用户名称是 VM 内固定角色名，不是宿主机用户名。
- VM 内不运行代理；不使用 `HTTP_PROXY/ALL_PROXY`。
- 宿主机不启用 TUN `auto_route`，不改宿主默认路由，不拦截宿主 `OUTPUT`；只有来自 `${LAN_BRIDGE}` 且源地址为 `${DEV_IP}` 的 VM TCP/UDP 会被 TProxy。
- 默认出口：`foreign_clean`，由 `config/secrets/sing-box-outbounds.local.json` 提供真实链式出站；DNS 由 sing-box `hijack-dns` 处理。
- 默认隔离：阻断 RFC1918、metadata、IPv6、Docker socket、SSH agent forwarding。
- 时区：默认按 `config/egress.policy.yaml` 中 `timezone.foreign_clean` 设置；也可用 `make foreign-clean-refresh` 根据当前 `foreign_clean` 出口 IP 自动刷新。

## Quickstart

```bash
cp .env.example .env.local
cp ansible/inventory.example.ini ansible/inventory.ini
mkdir -p config/secrets
```

编辑：

- `.env.local`：填写 `REMOTE_HOST`、`SSH_PUBLIC_KEY_PATH`、VM 资源；不要提交真实用户名、宿主地址或本地网段。
- `config/secrets/sing-box-outbounds.local.json`：真实 sing-box 出站链，ignored，禁止提交。
- `config/egress.policy.yaml`：如需手动更改国外出口时区，改 `timezone.foreign_clean`；如需跟随当前出口，运行 `make foreign-clean-refresh`。

执行：

```bash
make doctor
# 如远端缺依赖：make host-bootstrap
make up
make transparent-enable   # 需要远程宿主 sudo；只影响 Kali VM 作用域
make egress-check
```

如果只想分步：

```bash
make host-transparent-enable
make kali-transparent-enable
make host-transparent-status
```

刷新 `foreign_clean` 出口时区：

```bash
make foreign-clean-refresh
```

该命令会在 Kali VM 内通过透明出口请求 `FOREIGN_TIMEZONE_URL`，把返回的 IANA timezone 写入 `config/egress.policy.yaml`，再应用到 Kali 并运行 `egress-check`。默认端点可在 `.env.local` 中覆盖。

关闭透明网关：

```bash
make host-transparent-disable
```

## VNC 远程桌面

推荐使用 VNC：

```bash
make vnc-enable          # 在 Kali 内安装/启动 TigerVNC
make host-vnc-expose     # nftables 直转发 ${HOST_VNC_BIND}:${HOST_VNC_PORT} -> Kali:${GUEST_VNC_PORT}
make host-vnc-status
```

`host-vnc-expose` 在远程宿主机上安装持久化 `DNAT + SNAT` 规则；回包作为已建立连接放行，不改变 VM 的透明出站策略。在本机终端运行时会触发远程 sudo 交互；在非交互自动化中需要远程 sudo 已免密。

VNC 密码保存在本机 ignored 文件：

```text
runtime/vnc-password.txt
```

macOS Retina 下不要使用 Homebrew 的 `/opt/homebrew/bin/vncviewer`，它会触发 TigerVNC/FLTK 的 HiDPI 1/4 屏问题。使用上游官方 `.dmg` 安装的 App：

```bash
open -a "$HOME/Applications/TigerVNC.app" --args -RemoteResize=0 -PreferredEncoding=ZRLE -CompressLevel=6 -QualityLevel=6 "${HOST_VNC_BIND:-<remote-host-or-lan-ip>}"
```

密码读取 `runtime/vnc-password.txt`。默认 VNC 桌面固定为 `1440x900`，拒绝客户端自动改尺寸。

## sing-box 出站配置

当前默认使用宿主 sing-box 做透明网关；`make import-xray` 只用于把已有 Xray 出站链转换为 sing-box outbounds 文件，不作为运行时 bridge。

```bash
make import-xray
```

生成/维护：

```text
config/secrets/sing-box-outbounds.local.json
```

典型链路：

```text
foreign_clean: shadowsocks -> detour -> LOS: vless/reality
domestic:      shadowsocks -> detour -> LOS: vless/reality
```

## 常用命令

```bash
make ssh                 # 以 dev 用户进入 Kali
make ssh-agent           # 以 agent 用户进入 Kali，无 sudo
make transparent-enable  # 启用宿主 VM 作用域透明代理 + 配置 Kali 默认路由
make egress-check        # 验证无显式代理、透明出站、隔离和时区
make snapshot SNAPSHOT=clean
make restore SNAPSHOT=clean
make destroy             # 删除 VM、网络、运行态，保留下载镜像
PURGE=1 make destroy     # 同时删除镜像缓存
make check               # 本地静态校验
```

## 安全约束

- 不提交 `.env.local`、`config/secrets/*`、镜像、seed ISO、运行态。
- 不转发本机 SSH agent：所有 SSH/VNC 入口都设置 `ForwardAgent=no`。
- 不挂载宿主目录、不暴露 Docker socket、不把宿主密钥注入 VM。
- `make up` 会把 `ccsvm-lan` 和 `ccsvm-kali-dev` 设置为 libvirt autostart，宿主重启后 Kali 自动启动。
- 宿主透明网关只安装 `ccsvm-sing-box.service` 和 `ccsvm-transparent-gateway.service`，不改变宿主默认出口。
- `make egress-check` 验证默认路由经 `${LAN_HOST_IP}`、无代理环境变量、HTTPS 透明出站、metadata/内网阻断、隔离和时区。

## 文件说明

- `Makefile`：统一入口。
- `scripts/`：本地编排、远端 libvirt 操作、透明网关、配置渲染和验收检查。
- `config/egress.policy.yaml`：可提交的出口策略与时区策略。
- `config/secrets/sing-box-outbounds.local.json`：ignored 的真实代理出站配置。
- `ansible/host-bootstrap.yml`：远端宿主依赖安装。

## 运行 Claude Code 的建议

进入 VM 后使用低权限用户：

```bash
make ssh-agent
```

在 `agent` 用户内安装/运行客户端。不要把宿主 SSH 私钥、长期 token 或项目密钥复制进去；需要访问代码时优先使用临时 Git 凭据或只读 deploy key。
