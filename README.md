# VPS 脚本

## Snell 一键安装

给新手用的 Snell 安装脚本：支持 **v4 / v5 / v6**，全自动配端口、密码、开机自启与系统防火墙持久化。

### 1. 一键安装

连上 VPS 粘贴运行（`root` 用户或 Alpine 把 `sudo sh` 改成 `sh`）：

```bash
curl -fL --retry 2 https://raw.githubusercontent.com/edmondxie779/vps-scripts/main/install-snell.sh -o install-snell.sh && sudo sh install-snell.sh
```

按提示完成两步即可：
- **选版本**：不懂直接回车默认装 **v5**；想用新版选 **v6**（Surge 需更新到最新版）；老版本 Surge 选 **v4**。
- **确认安装**：输入 `yes` 回车，等几十秒完成。

### 2. 加到 Surge

装完后复制屏幕输出的那一行配置（类似下面这样），粘贴到 Surge 的 `[Proxy]` 下：

```text
我的VPS = snell, 1.2.3.4, 23456, psk=xxxxxx, version=5
```

> **必须做一步**：系统内部防火墙（`UFW` / `firewalld` / `iptables` / `nftables`）脚本已自动放行并保存，但**云厂商网页后台（安全组/防火墙）**仍需你手动放行该端口的 **TCP + UDP**，否则连不上。

### 支持环境

- **系统**：Ubuntu 22.04+、Debian 11+、AlmaLinux / Rocky 8+、CentOS Stream 9+、Alpine 3.16+
- **架构**：x86_64、ARM64（不支持纯 IPv6 和普通 Docker；NAT VPS 需改用商家转发端口）

### 重装、换版本或清理旧版

直接**再跑一遍上面的安装命令**即可：
- **之前装过其他脚本的 Snell**：会自动检测并备份到 `/var/backups/snell/`，确认后卸载旧版再全新安装。
- **之前用本脚本装过**：可选「保留原端口和密码升级」或「卸载后全新安装」，升级失败会自动回滚。

### 常用命令

```bash
sudo cat /etc/snell/surge-proxy.txt          # 查看保存的节点配置
sudo systemctl status snell --no-pager       # 查看状态（Alpine 用 rc-service snell status）
sudo systemctl restart snell                 # 重启服务（Alpine 用 rc-service snell restart）
sudo cat /var/log/snell-install.log          # 查看安装日志
sudo sh install-snell.sh --uninstall         # 备份并彻底卸载 Snell
```

进阶免交互参数：`--version 4|5|6`、`--clean`（强制卸载旧版重装）、`--yes`（自动确认）。官方协议说明见 [Snell 文档](https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell)。
