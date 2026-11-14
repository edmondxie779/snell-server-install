# VPS 脚本

## Snell 一键安装

给新手准备的 Snell 安装脚本：全自动分配端口、生成密码、配置开机自启，装完直接给你一行可以粘贴到 Surge 的配置。

### 第一步：在 VPS 上运行安装命令

连上你的 VPS 终端，复制下面这整行命令粘贴并回车：

```bash
curl -fL --retry 2 https://raw.githubusercontent.com/edmondxie779/vps-scripts/main/install-snell.sh -o install-snell.sh && sudo sh install-snell.sh
```

> 如果你是用 `root` 账号登录的，或者机器上没有 `sudo`（比如 Alpine），把最后面的 `sudo sh` 改成 `sh` 就行。

运行后会按顺序问你两个问题：

1. **选哪个版本？**（不清楚就直接按回车，默认装 **v5**）
   - **v5（推荐）**：当前最稳的版本，绝大多数 Surge 都能直接用，支持 QUIC 加速。
   - **v6（测试版）**：新版协议，需要把手机/电脑上的 Surge 也升到最新版才连得上；中间如果问 `mode`，直接回车选默认的就行。
   - **v4（老版本）**：如果你的 Surge 很久没更新，连不上 v5 就选这个。
2. **确认安装**：输入 `yes` 回车，等几十秒就装好了。

### 第二步：把节点加到 Surge 并开放端口

安装完成后，屏幕中间会打印一行类似下面这样的内容：

```text
我的VPS = snell, 1.2.3.4, 23456, psk=xxxxxx, version=5
```

1. **只复制两条分割线中间那一行**（不要把标题和边框也复制进去），粘贴到 Surge 配置的 `[Proxy]` 下面。
2. **去云厂商后台放行端口**（阿里云、腾讯云、AWS、甲骨文、Vultr 等）：在网页控制台的「安全组 / 防火墙」里，把屏幕提示的那个端口号同时放行 **TCP 和 UDP**。脚本只能改机器里面的配置，改不到云厂商网页后台，这一步漏了就会连不上。
3. 在 Surge 里点一下节点测试连通性，能通就可以正常使用了。

> 节点那一行里带着你的密码，不要截图或公开分享给别人。

### 支持哪些 VPS？

- **系统**：Ubuntu 22.04+、Debian 11+、AlmaLinux 8+、Rocky Linux 8+、CentOS Stream 9+、Alpine Linux 3.16+
- **架构**：常见的 Intel / AMD（x86_64）和 ARM64 机器都支持
- **不支持**：纯 IPv6 的机器、普通 Docker 容器
- **NAT VPS 提醒**：装完以后，需要把输出节点里的端口改成商家给你分配的外部转发端口

### 以后想重装或换版本怎么办？

不用先卸载，把上面的安装命令**再跑一遍**就行：

- 脚本会自动把旧配置备份到 `/var/backups/snell/`，原来的端口和密码都会保留。
- 如果新版本不小心启动失败，脚本会自动还原回原来的版本和配置，不会把正在用的节点搞坏。
- **小提醒**：如果以前装过 v4/v5 且开过 `obfs=http` 混淆，升级到 v6 时脚本会提醒你 v6 不再支持混淆，确认后会自动帮你去掉再继续升；如果从 v6 降回 v4/v5，以前手动加过 v6 专用参数的话脚本会提醒你先删掉。

### 装完以后怎么查看状态或重启？

**查看保存的节点配置（忘了那一行可以随时看）：**

```bash
sudo cat /etc/snell/surge-proxy.txt
```

**Ubuntu / Debian / AlmaLinux / Rocky / CentOS 系统：**

```bash
sudo systemctl status snell --no-pager   # 看运行状态
sudo systemctl restart snell             # 重启 Snell
sudo journalctl -u snell -n 50 --no-pager # 看最近日志
```

**Alpine Linux 系统：**

```bash
rc-service snell status                  # 看运行状态
rc-service snell restart                 # 重启 Snell
tail -n 50 /var/log/snell/snell.log      # 看最近日志
```

> 如果是 root 登录且没有 `sudo`，上面命令里的 `sudo` 都可以直接去掉。

### 进阶用法（可选）

如果不想交互问答，可以直接在命令后面带参数指定版本：

```bash
sudo sh install-snell.sh --version 6 --yes   # 直接安装 v6
sudo sh install-snell.sh --version 4 --yes   # 直接安装 v4
```

脚本只从 Surge 官方（`dl.nssurge.com`）下载程序，不会开启自动更新。更多协议细节可参考 [Snell 官方说明](https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell)。
