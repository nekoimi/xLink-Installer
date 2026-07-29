# xLink-Installer

一键在 Linux 服务器上部署 [3x-ui](https://github.com/MHSanaei/3x-ui) 面板，并用 [Caddy](https://caddyserver.com/) 做反向代理、自动申请 HTTPS 证书，通过域名访问。

## 特性

- 自动识别系统（Ubuntu/Debian、CentOS/RHEL/Rocky/Alma）
- 非交互安装 3x-ui（`XUI_NONINTERACTIVE=1`），跳过所有交互（含 SSL 证书询问，不再生成多余的 IP 自签证书），自动生成随机端口/路径/账号密码
- 强制面板/订阅以明文 HTTP 监听本地（清空 3x-ui 内证书配置），TLS 统一由 Caddy 处理，避免反代失败
- 安装后自动回读面板真实端口与访问路径，并据此配置 Caddy（不再写死端口）
- 将面板绑定到 `127.0.0.1`，只能经 Caddy 的 HTTPS 访问，避免明文直连暴露
- 安装并配置 Caddy 反向代理，自动签发 Let's Encrypt 证书
- 面板与订阅使用**分开的两个域名**，各自反代到对应端口（面板默认 2053 / 订阅默认 2096，均自动回读）
- 自动放行防火墙 80/443（ufw / firewalld）
- 系统初始化优化：设置时区（默认 `Asia/Shanghai`）、启用 NTP 时间同步、提高文件句柄上限、优化网络内核参数
- 直接用服务器 IP（或未知域名）访问时，自动 302 跳转到指定地址（默认百度），避免暴露真实服务
- 启用 TCP BBR 加速
- 安装常用系统 / 网络 / 调试工具，方便排障
- 全程日志留存到 `/var/log/xlink-install.log`，出错时报告失败行号

## 前置条件

- 一台公网可访问的 Linux 服务器（root 权限）
- 一个已解析到本机公网 IP 的域名（A / AAAA 记录）
- 云服务器安全组已放行 80 / 443 端口

## 在线一键安装

无需 clone 仓库，直接从 GitHub 拉取脚本执行。

以 root 用户运行（交互式，可传参，安装过程中会询问域名）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nekoimi/xLink-Installer/master/install.sh) -d panel.example.com -s sub.example.com
```

使用 sudo 时，请先下载再执行（`sudo` 下进程替换可能无法读取脚本）：

```bash
curl -fsSL https://raw.githubusercontent.com/nekoimi/xLink-Installer/master/install.sh -o install.sh
sudo bash install.sh -d panel.example.com -s sub.example.com
```

全自动非交互安装（不再询问，需用参数指定域名）：

```bash
curl -fsSL https://raw.githubusercontent.com/nekoimi/xLink-Installer/master/install.sh -o install.sh
sudo bash install.sh -d panel.example.com -s sub.example.com -y
```

> 从网络直接执行脚本存在风险，建议先 [查看脚本内容](https://github.com/nekoimi/xLink-Installer/blob/master/install.sh) 再运行。

## 使用（clone 到本地）

```bash
git clone https://github.com/nekoimi/xLink-Installer.git
cd xLink-Installer
sudo bash install.sh -d panel.example.com -s sub.example.com
```

### 参数

| 参数 | 说明 |
| --- | --- |
| `-d, --domain <域名>` | 面板访问域名（必填） |
| `-s, --sub-domain <域名>` | 订阅访问域名，需与面板域名分开（留空则跳过订阅代理） |
| `-p, --port <端口>` | 面板本地端口，默认 `2053`（通常自动回读，仅作兜底） |
| `--sub-port <端口>` | 订阅本地端口，默认 `2096`（通常自动回读，仅作兜底） |
| `--tz <时区>` | 系统时区，默认 `Asia/Shanghai` |
| `--fallback-url <URL>` | 直接用 IP/未知域名访问时的跳转地址，默认 `https://www.baidu.com`，填 `none` 关闭 |
| `--no-bbr` | 不启用 BBR |
| `-y, --yes` | 非交互模式，使用默认值 |
| `-h, --help` | 帮助 |

### 示例

```bash
# 交互式，会依次询问面板/订阅域名
sudo bash install.sh -d panel.example.com

# 全自动，面板与订阅分开两个域名
sudo bash install.sh -d panel.example.com -s sub.example.com -y
```

## 部署完成后

- 面板地址：`https://<面板域名>/<随机路径>/`（脚本会在结尾打印完整地址，**路径不能省略**，否则 404）
- 订阅地址：`https://<订阅域名>/<订阅路径>/`（需在 3x-ui『订阅设置』中开启订阅服务后生效）
- 登录凭据：3x-ui 安装时随机生成，脚本会尽力从安装日志中回显；也可运行 `x-ui` 查看当前设置
- 管理 3x-ui：终端运行 `x-ui`（查看/修改凭据、端口等）
- 查看 Caddy 日志：`journalctl -u caddy -f`
- Caddy 配置文件：`/etc/caddy/Caddyfile`
- 安装日志：`/var/log/xlink-install.log`

## 常用调试工具

脚本会安装以下工具：`curl` `wget` `vim` `nano` `tmux` `htop` `jq` `lsof` `socat` `traceroute` `mtr` `nmap` `tcpdump` `telnet` `iftop` `nload` `net-tools`(netstat) `iproute2`(ss) `dnsutils`/`bind-utils`(dig)。

## 注意事项

- 证书签发要求域名已正确解析且 80/443 可从公网访问，否则会失败。使用订阅域名时，面板与订阅两个域名都要解析到本机。
- 面板与订阅均已绑定 `127.0.0.1`，仅经 Caddy 的 HTTPS 访问。**请不要在云安全组放行面板/订阅端口**，以免绕过 HTTPS 明文暴露。
- `-p` / `--sub-port` 仅作为回读失败时的兜底端口；正常情况下脚本以 3x-ui 实际配置为准。
- 面板本身建议在 3x-ui 内进一步修改默认设置、开启更强的登录策略以提升安全性。

## 免责声明

本项目仅用于合法的网络调试与学习用途，请遵守所在国家/地区的法律法规。
