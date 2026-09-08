# xLink-Installer

一键在 Linux 服务器上部署 [3x-ui](https://github.com/MHSanaei/3x-ui) 面板，并用 [Caddy](https://caddyserver.com/) 做反向代理、自动申请 HTTPS 证书，通过域名访问。

## 特性

- 自动识别系统（Ubuntu/Debian、CentOS/RHEL/Rocky/Alma）
- 非交互安装固定版本且经过 SHA-256 校验的 3x-ui 安装脚本，跳过所有交互（含 SSL 证书询问），自动生成随机端口/路径/账号密码
- 新安装由 Caddy 统一终止 TLS；已有 3x-ui 若配置了证书，会自动使用 HTTPS 上游兼容现有配置
- 安装后自动回读面板真实端口与访问路径，并据此配置 Caddy（不再写死端口）
- 将面板绑定到 `127.0.0.1`，只能经 Caddy 的 HTTPS 访问，避免明文直连暴露
- 安装并配置 Caddy 反向代理，自动签发 Let's Encrypt 证书；xLink 使用独立配置片段，不覆盖已有站点
- 面板与订阅使用**分开的两个域名**，各自反代到对应端口（面板默认 2053 / 订阅默认 2096，均自动回读）
- 自动放行防火墙 80/443（ufw / firewalld）
- 系统初始化优化：设置时区（默认 `Asia/Shanghai`）、启用 NTP 时间同步、提高文件句柄上限、优化网络内核参数
- 可选的 HTTP IP/未知域名兜底跳转（默认关闭，避免影响后续新增站点）；未知 HTTPS 请求直接拒绝握手
- 启用 TCP BBR 加速
- 安装常用系统 / 网络 / 调试工具，方便排障
- 3x-ui 安装输出留存到仅 root 可读的 `/var/log/xlink-install.log`，出错时报告失败行号

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
| `--fallback-url <URL>` | 通过 HTTP 用 IP/未知域名访问时的跳转地址，默认 `none`（关闭） |
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
- Caddy 主配置：`/etc/caddy/Caddyfile`
- xLink 独立配置：`/etc/caddy/conf.d/xlink.caddy`
- 其他反代服务：在 `/etc/caddy/conf.d/` 新建独立的 `*.caddy` 文件，然后校验并重载 Caddy
- 安装日志：`/var/log/xlink-install.log`

## 后续增加 Caddy 反向代理服务

安装器会让 `/etc/caddy/Caddyfile` 自动加载 `/etc/caddy/conf.d/*.caddy`。后续服务应各自使用独立配置文件，不要修改由安装器管理的 `/etc/caddy/conf.d/xlink.caddy`。

首先将新域名解析到服务器，并让后端服务监听本机地址。例如后端运行在 `127.0.0.1:3000`，新建配置：

```bash
sudo nano /etc/caddy/conf.d/my-service.caddy
```

写入：

```caddyfile
service.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3000
}
```

Caddy 会自动申请 HTTPS 证书，并将 HTTP 请求升级到 HTTPS。WebSocket 通常不需要额外配置。

保存后依次格式化、校验并平滑重载：

```bash
sudo caddy fmt --overwrite /etc/caddy/conf.d/my-service.caddy
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

只有校验成功后才应执行重载。可使用以下命令确认状态和查看日志：

```bash
sudo systemctl status caddy --no-pager
sudo journalctl -u caddy -e --no-pager
```

如果后端自身使用自签名 HTTPS，可配置 HTTPS 上游。仅应对本机或可信内网服务跳过证书校验：

```caddyfile
secure-service.example.com {
    reverse_proxy https://127.0.0.1:8443 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
```

如果安装 xLink 时显式设置了 `--fallback-url`，还应为新服务声明 HTTP 跳转，防止其 HTTP 请求进入全局兜底：

```caddyfile
http://service.example.com {
    redir https://service.example.com{uri} 308
}

service.example.com {
    reverse_proxy 127.0.0.1:3000
}
```

## 常用调试工具

脚本会安装以下工具：`curl` `wget` `vim` `nano` `tmux` `htop` `jq` `lsof` `socat` `traceroute` `mtr` `nmap` `tcpdump` `telnet` `iftop` `nload` `net-tools`(netstat) `iproute2`(ss) `dnsutils`/`bind-utils`(dig)。

## 注意事项

- 证书签发要求域名已正确解析且 80/443 可从公网访问，否则会失败。使用订阅域名时，面板与订阅两个域名都要解析到本机。
- 面板与订阅均已绑定 `127.0.0.1`，仅经 Caddy 的 HTTPS 访问。**请不要在云安全组放行面板/订阅端口**，以免绕过 HTTPS 明文暴露。
- `-p` / `--sub-port` 仅作为回读失败时的兜底端口；正常情况下脚本以 3x-ui 实际配置为准。
- 安装器只管理 `/etc/caddy/conf.d/xlink.caddy`，不会覆盖 Caddyfile 中已有的其他站点；首次运行会向主配置追加一次 `conf.d/*.caddy` 导入规则。
- 如显式启用 `--fallback-url`，新增服务也应在自己的配置片段中写出 `http://域名` 到 HTTPS 的跳转规则，以免其 HTTP 请求落入全局兜底；保持默认关闭则可继续使用 Caddy 的自动 HTTPS 跳转。
- HTTPS 必须先完成 TLS 握手才能返回 HTTP 跳转。未知域名或 IP 没有可信证书，因此 HTTPS 直连会被拒绝，而不会执行兜底 302。
- 面板本身建议在 3x-ui 内进一步修改默认设置、开启更强的登录策略以提升安全性。

## 免责声明

本项目仅用于合法的网络调试与学习用途，请遵守所在国家/地区的法律法规。
