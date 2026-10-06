# Claude 隔离虚机

本项目在 Linux x86_64 或 Apple Silicon macOS 上创建专用于 Claude Code 的 Ubuntu 26.04 VM。宿主现有 Claude 安装与配置不参与运行。

## 架构

```text
VM agent / Claude Code → sing-box TUN → 隔离网络 → 宿主 sing-box 守卫
                                         ├─ RFC1918 私网 → 宿主直连
                                         └─ 公网 → 宿主 SOCKS5 127.0.0.1:10813
```

Linux 使用 libvirt/KVM 独立网络和 nwfilter，只允许 VM 连接宿主守卫端口。macOS 使用 QEMU/HVF 的受限用户网络，仅向 VM 开放代理转发和宿主本地 SSH 入口。VM 内的 `agent` 用户没有 sudo 权限；没有宿主目录或密钥挂载，也不设置显式代理环境变量。

私网放行范围为 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`，走宿主当前路由，包括已连接的私网 VPN。环回、链路本地、metadata、CGNAT 等地址仍被拦截。私网访问支持单播 TCP/UDP；ICMP、广播和局域网自动发现不经过 SOCKS。局域网域名解析未配置，使用 IP 地址访问。

## 安装和使用

Linux 需要 KVM、libvirt、virt-install、xorriso、Python 3、curl、jq 和 SSH。macOS 仅支持 Apple Silicon，通过 Homebrew 安装依赖：

```bash
brew install python qemu sing-box xorriso
```

两种宿主都需要可用的 SOCKS5 `127.0.0.1:10813`。`config.local.json` 可设置实际端口、出口时区和 VM 资源。

```bash
git clone https://github.com/pood1e/claude-code-sec-vm.git
cd claude-code-sec-vm
./claude-vm doctor
./claude-vm up
./claude-vm status
./claude-vm check
./claude-vm ssh
```

首次启动会下载并校验 Ubuntu Cloud Image 与 sing-box，在 VM 中安装 Claude Code。`status` 显示 `ready` 后运行 `check`；进入 VM 后在项目目录执行 `claude`，按官方流程登录。项目代码在 VM 内通过 Git 获取。SSH 不转发宿主 SSH agent。

运行中的 VM 用 `./claude-vm stop` 关闭，再用 `./claude-vm start` 启动。macOS 宿主重启后需要运行 `start`。创建 VM 后修改 `config.local.json` 或 VM 内启动配置，需要运行 `./claude-vm rebuild --yes`；该命令会删除 VM 系统盘及工作数据。`runtime/` 保存 SSH 私钥、镜像和生成配置，已被 Git 忽略。

## 隔离边界

VM 的 Claude Code 设置启用官方 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`，关闭主动反馈、官方插件市场自动安装和 WebFetch 预检；部分功能如 Remote Control 会受影响。必要的登录与模型 API 请求仍需联网，不能保证完全不携带 VM 环境信息。Linux 暴露虚拟 `EPYC-v4` CPU；macOS 的 HVF 使用宿主 CPU 类型。两者都能被识别为虚拟机。若通过宿主浏览器登录，浏览器不在隔离边界内。

实现依据：[Claude Code 安装](https://code.claude.com/docs/en/setup)、[数据使用](https://code.claude.com/docs/en/data-usage)、[libvirt 网络过滤](https://libvirt.org/formatnwfilter.html)、[QEMU 受限用户网络](https://www.qemu.org/docs/master/system/qemu-manpage.html)、[sing-box 路由规则](https://sing-box.sagernet.org/configuration/route/rule/)。
