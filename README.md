# xLink-Installer

在公网 Linux 服务器上部署 [3x-ui](https://github.com/MHSanaei/3x-ui)、[Caddy](https://caddyserver.com/) 和 [rathole](https://github.com/rathole-org/rathole)：rathole 独占公网 TCP 443，VPS Caddy 在 TCP 9443 为面板/订阅提供 HTTPS。rathole 将原始 TCP 流量经 Noise 隧道转交内网 Caddy，由内网 Caddy 终止 HTTPS 并根据域名分流。

```text
公网用户 :443  → VPS rathole-server → Noise 隧道 → 内网 rathole-client → 内网 Caddy :443 → 应用
内网客户端 → VPS rathole-server :2333（默认隧道连接端口）
面板/订阅 → VPS Caddy :9443 → VPS 本机 3x-ui
```

## 特性

- 自动识别系统（Ubuntu/Debian、CentOS/RHEL/Rocky/Alma）
- 非交互安装固定版本且经过 SHA-256 校验的 3x-ui 安装脚本，跳过所有交互（含 SSL 证书询问），自动生成随机端口/路径/账号密码
- 新安装由 Caddy 统一终止 TLS；已有 3x-ui 若配置了证书，会自动使用 HTTPS 上游兼容现有配置
- 安装后自动回读面板真实端口与访问路径，并据此配置 Caddy（不再写死端口）
- 将面板绑定到 `127.0.0.1`，经 VPS Caddy 的 HTTPS `:9443` 访问
- 检查 Caddy 可执行文件和 `caddy.service`；缺少任一项时通过官方软件源在线安装。若发行版软件包仍未提供 unit，自动生成受限的 `/etc/systemd/system/caddy.service`，并设置开机自启
- 配置 Caddy 通过公网 TCP 80 的 HTTP-01 验证申请证书；xLink 使用独立配置片段，不覆盖已有站点
- 固定版本并校验 SHA-256 安装 rathole，使用 Noise NK 加密隧道；服务端由受限账户运行，通过 systemd 开机自启
- 面板与订阅使用**分开的两个域名**，各自反代到对应端口（面板默认 2053 / 订阅默认 2096，均自动回读）
- 自动放行防火墙 TCP 80、443、9443 和隧道端口（ufw / firewalld）
- 系统初始化优化：设置时区（默认 `Asia/Shanghai`）、启用 NTP 时间同步、提高文件句柄上限、优化网络内核参数
- 可选的 HTTP IP/未知域名兜底跳转（默认关闭）；公网 443 的未知 HTTPS 流量进入 rathole，不由 VPS Caddy 处理
- 启用 TCP BBR 加速
- 安装常用系统 / 网络 / 调试工具，方便排障
- 3x-ui 安装输出留存到仅 root 可读的 `/var/log/xlink-install.log`，出错时报告失败行号

## 前置条件

- 一台公网可访问的 Linux 服务器（root 权限）
- 一个已解析到本机公网 IPv4 的域名（A 记录）；当前生成的 rathole 配置监听 IPv4，不要只配置 AAAA
- 云服务器安全组已放行 TCP 80 / 443 / 9443 / 2333（自定义隧道端口时以实际值为准）
- 已将当前梯子/Xray 在公网 TCP 443 的入口迁到其他端口；脚本不会修改 3x-ui inbound 或其他 Caddy 配置
- 内网机器单独安装 rathole-client 和支持 DNS-01 的 Caddy（DNS 提供商模块/凭据由用户自行配置）

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
| `--rathole-port <端口>` | 内网 rathole-client 连接 VPS 的公网 TCP 端口，默认 `2333`；业务入口固定为 TCP 443 |
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

- 面板地址：`https://<面板域名>:9443/<随机路径>/`（脚本会在结尾打印完整地址，**路径不能省略**，否则 404）
- 订阅地址：`https://<订阅域名>:9443/<订阅路径>/`（需在 3x-ui『订阅设置』中开启订阅服务后生效）
- 登录凭据：3x-ui 安装时随机生成，脚本会尽力从安装日志中回显；也可运行 `x-ui` 查看当前设置
- 管理 3x-ui：终端运行 `x-ui`（查看/修改凭据、端口等）
- 查看 Caddy 日志：`journalctl -u caddy -f`
- Caddy 服务状态：`systemctl status caddy`（安装器会执行 `systemctl enable caddy`）
- rathole 服务状态：`systemctl status rathole`；日志：`journalctl -u rathole -f`
- rathole 服务端配置：`/etc/rathole/server.toml`（含私钥和 token，勿公开）
- 内网客户端示例：`/etc/rathole/client-example.toml`（仅 root 可读，含 token）
- Caddy 主配置：`/etc/caddy/Caddyfile`
- xLink 独立配置：`/etc/caddy/conf.d/xlink.caddy`
- 其他反代服务：在 `/etc/caddy/conf.d/` 新建独立的 `*.caddy` 文件，然后校验并重载 Caddy
- 安装日志：`/var/log/xlink-install.log`

## 内网客户端接入

脚本只安装公网 VPS 上的 rathole-server，不会连接或修改内网机器。安装完成后，以安全方式将 VPS 的 `/etc/rathole/client-example.toml` 复制到内网机器，替换其中 `REPLACE_WITH_VPS_IP_OR_DNS` 为 VPS 的公网 IP 或不经过 CDN 代理的 DNS 名称。示例的 `local_addr = "127.0.0.1:443"` 要与内网 Caddy 的监听地址一致；若 Caddy 在另一台内网机器上，填其可达的内网 IP。保持配置文件权限 `600`，然后在内网机器安装相同版本的 rathole 并运行 `rathole --client client.toml`（建议自行配置 systemd）。

内网 Caddy 负责申请并持有业务域名证书，需使用 DNS-01；普通 Caddy 安装包可能没有对应 DNS 提供商模块，需要按提供商另行准备。业务域名解析到 VPS 公网 IP。rathole 转发的是原始 TCP，不在 VPS 上解密 HTTPS；内网客户端尚未连接时，公网 TCP 443 虽可建立连接但业务不可用。服务端重跑不会轮换已有 Noise 密钥/token，也不会覆盖现有客户端示例。

## 后续增加 Caddy 反向代理服务

安装器会让 `/etc/caddy/Caddyfile` 自动加载 `/etc/caddy/conf.d/*.caddy`。后续服务应各自使用独立配置文件，不要修改由安装器管理的 `/etc/caddy/conf.d/xlink.caddy`。

首先将新域名解析到服务器，并让后端服务监听本机地址。例如后端运行在 `127.0.0.1:3000`，新建配置：

```bash
sudo nano /etc/caddy/conf.d/my-service.caddy
```

写入：

```caddyfile
http://service.example.com {
    redir https://service.example.com:9443{uri} 308
}

https://service.example.com:9443 {
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
    encode zstd gzip
    reverse_proxy 127.0.0.1:3000
}
```

Caddy 通过公网 80 的 HTTP-01 签发证书，不能在公网 443 使用 TLS-ALPN-01。WebSocket 通常不需要额外配置。若其他已有 Caddy 站点仍监听公网 443，必须先迁移到 9443，否则安装器会因 443 未释放而恢复原 Caddy 配置并停止。

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
https://secure-service.example.com:9443 {
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
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
    redir https://service.example.com:9443{uri} 308
}

https://service.example.com:9443 {
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
    reverse_proxy 127.0.0.1:3000
}
```

## 常用调试工具

脚本会安装以下工具：`curl` `wget` `vim` `nano` `tmux` `htop` `jq` `lsof` `socat` `traceroute` `mtr` `nmap` `tcpdump` `telnet` `iftop` `nload` `net-tools`(netstat) `iproute2`(ss) `dnsutils`/`bind-utils`(dig)。

## 注意事项

- VPS Caddy 的证书签发要求域名正确解析且公网 TCP 80 可访问；公网 443 专属于 rathole，与 VPS Caddy 的 ACME/TLS 无关。内网 Caddy 的业务证书通过 DNS-01 签发。
- 面板与订阅均绑定 `127.0.0.1`，仅经 VPS Caddy 的 HTTPS :9443 访问。**不要在云安全组放行 3x-ui 的本地面板/订阅端口**。
- `-p` / `--sub-port` 仅作为回读失败时的兜底端口；正常情况下脚本以 3x-ui 实际配置为准。
- 安装器只管理 `/etc/caddy/conf.d/xlink.caddy`，不会覆盖 Caddyfile 中已有的其他站点；首次运行会向主配置追加一次 `conf.d/*.caddy` 导入规则。
- 如显式启用 `--fallback-url`，新增 VPS Caddy 服务也应在自己的配置片段中写出 `http://域名` 到 `https://域名:9443` 的跳转规则，以免其 HTTP 请求落入全局兜底。
- 访问 VPS Caddy 需要明确指定 `:9443`；直接访问公网 443 始终进入 rathole。内网 Caddy 的 HTTP/3/QUIC（UDP 443）不通过此 TCP 隧道。
- 面板本身建议在 3x-ui 内进一步修改默认设置、开启更强的登录策略以提升安全性。

## 免责声明

本项目仅用于合法的网络调试与学习用途，请遵守所在国家/地区的法律法规。
