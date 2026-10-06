# Claude KVM 隔离环境

本项目在本机 libvirt 上创建一台专用于 Claude Code 的 Ubuntu 26.04 VM。宿主现有 Claude 安装与配置不参与运行。

## 架构

```text
agent 用户 / Claude Code
        │
        ▼
VM sing-box TUN ── libvirt 隔离网 ── 宿主 sing-box 守卫 ── 127.0.0.1:10812 ── 外网
        │                  │
        │                  └─ nwfilter 仅允许 DHCP、宿主代理端口；宿主可 SSH 进入 VM
        └─ 无 sudo、无宿主目录/密钥挂载、无显式代理环境变量
```

宿主代理守卫拒绝内网、环回、链路本地、metadata 和 IPv6 目标。VM 只有一张固定 MAC 的虚拟网卡，使用固定的 `EPYC-v4` CPU 模型；系统时区与 `10812` 当前出口的 `America/New_York` 一致。DNS 经 VM 的 TUN 发送 DoH，再通过宿主代理。VM 网络断开或代理服务失败时，libvirt 隔离网不会提供直连出口。

## 使用

需要 Linux x86_64、KVM、libvirt、virt-install、xorriso、Python 3、curl、jq、SSH，以及可用的宿主 SOCKS5 `127.0.0.1:10812`。

```bash
git clone https://github.com/pood1e/claude-code-sec-vm.git
cd claude-code-sec-vm
./claude-vm doctor
./claude-vm up
./claude-vm status
./claude-vm check
./claude-vm ssh
```

首次启动会下载并校验 Ubuntu Cloud Image 与 sing-box，然后在 VM 中安装 Claude Code；在 `status` 显示 `ready` 后执行 `check`。进入 VM 后在项目目录运行 `claude` 并按官方流程完成登录。项目代码应在 VM 内通过 Git 获取；SSH 不转发宿主 SSH agent。

`config.local.json` 可调整 VM 资源、上游端口与时区。VM 创建后改动配置，运行 `./claude-vm rebuild --yes` 重建；此操作会删除 VM 系统盘及其中的工作数据。`runtime/` 含 SSH 私钥、镜像缓存与生成配置，已被 Git 忽略。运行中的 VM 可用 `./claude-vm stop` 关闭，再用 `./claude-vm start` 启动。

## 遥测与隔离边界

VM 的 Claude Code 设置启用官方的 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`，并关闭主动反馈、官方插件市场自动安装和 WebFetch 预检。该开关会影响部分功能，例如 Remote Control。必要的登录与模型 API 请求仍需联网，不能保证这些请求完全不携带 VM 环境信息；固定虚拟硬件也不能让软件无法识别虚拟机。若在宿主浏览器完成登录，浏览器本身不在此隔离边界内。

本项目只改动自己的 libvirt 网络、过滤器、VM、镜像卷和宿主用户级 `claude-sandbox-proxy.service`；宿主默认路由与现有 Claude 不变。

实现依据：[Claude Code 安装](https://code.claude.com/docs/en/setup)、[Claude Code 数据使用与遥测开关](https://code.claude.com/docs/en/data-usage)、[libvirt 网络过滤器](https://libvirt.org/formatnwfilter.html)、[sing-box TUN](https://sing-box.sagernet.org/configuration/inbound/tun/)。
