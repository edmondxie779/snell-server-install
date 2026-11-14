# VPS 脚本

## Snell 一键安装

安装 Surge 官方 **Snell Server**，支持 **v4 (`4.1.1`) / v5 (`5.0.1`，默认) / v6 (`6.0.0` Beta)**，自动分配端口与随机密钥，支持备份重装与失败回滚。

### 快速使用

```bash
curl -fL --retry 2 https://raw.githubusercontent.com/edmondxie779/vps-scripts/main/install-snell.sh -o install-snell.sh && sudo sh install-snell.sh
```

> 使用 root 登录（如无 `sudo` 的 Alpine）可将末尾改为 `sh install-snell.sh`。

常用参数（可选）：

```bash
sudo sh install-snell.sh --version 6 --mode default   # 安装 v6（mode: default / unshaped / unsafe-raw）
sudo sh install-snell.sh --version 4 --yes            # 安装 v4 并跳过确认
```

安装完成后，将终端输出的节点行复制到 Surge 配置的 `[Proxy]` 段，并在**云厂商安全组放行对应端口（TCP + UDP）**。

### 支持范围

- **系统**：Debian 11+、Ubuntu 22.04+、AlmaLinux 8+、Rocky Linux 8+、CentOS Stream 9+、Alpine Linux 3.16+（OpenRC，缺 `bash`/`gcompat` 自动补齐）
- **架构**：x86_64 / ARM64
- **要求**：公网 IPv4、systemd 或 OpenRC（不支持普通 Docker 容器与纯 IPv6 VPS）

### 重装与跨版本切换

再次运行脚本即可备份重装，默认保留原端口、密钥与兼容配置，启动失败自动回滚：

- **v4 / v5 → v6**：检测到 `obfs` 时会在提示确认后自动移除该配置再升级。
- **v6 → v4 / v5**：若配置含 `mode`、`dns-ip-preference` 或多地址 `listen`，需先手动移除后再降级。

### 常用路径与命令

| 内容 | 路径 |
| --- | --- |
| 程序 | `/usr/local/bin/snell-server` |
| 配置 | `/etc/snell/snell-server.conf` |
| 节点行 | `/etc/snell/surge-proxy.txt` |
| 服务 | `/etc/systemd/system/snell.service`（systemd） / `/etc/init.d/snell`（OpenRC） |
| 备份 | `/var/backups/snell/` |

```bash
# 查看节点配置
sudo cat /etc/snell/surge-proxy.txt

# systemd（Debian / Ubuntu / AlmaLinux / Rocky / CentOS Stream）
sudo systemctl status snell --no-pager
sudo systemctl restart snell
sudo journalctl -u snell -n 50 --no-pager

# OpenRC（Alpine Linux）
rc-service snell status
rc-service snell restart
tail -n 50 /var/log/snell/snell.log
```

### 本地测试

```bash
shellcheck install-snell.sh
python3 -m unittest -v tests/test_installer.py
```

参考：[Snell 发布说明](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell) · [Surge 配置格式](https://manual.nssurge.com/policies/snell.html)
