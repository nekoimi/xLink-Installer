# xLink Docker

一个镜像运行 **Xray VLESS + REALITY + Vision、rathole-server（Noise）**。不包含 3x-ui、Caddy、数据库或服务器调试工具，不执行宿主机初始化。原来的 `install.sh` 保持独立。

```text
代理客户端 → VPS TCP 8443 → Xray REALITY → Internet
公网用户   → VPS TCP 443  → rathole → 内网 rathole-client → 内网应用
内网客户端 → VPS TCP 2333 → rathole Noise 隧道
```

REALITY 由 Xray 直接处理，无需 HTTP 反代或申请域名证书。443 保留给内网穿透；Xray 默认使用 8443。宿主机不能有其他程序占用映射端口。

## 快速启动

公网 Linux 服务器安装 Docker Engine 和 Compose 插件后：

```bash
git clone https://github.com/nekoimi/xLink-Installer.git
cd xLink-Installer/docker
cp .env.example .env
# 编辑 .env，至少将 PUBLIC_HOST 改为 VPS 的公网 IP 或直连 DNS 名称
docker compose pull
docker compose up -d
docker compose logs -f
```

示例镜像地址为 `ghcr.io/nekoimi/xlink-installer:latest`，需要 GitHub Actions 首次成功发布后才可拉取。Fork 仓库时将 `.env` 中的 `XLINK_IMAGE` 改为 `ghcr.io/<小写 owner>/<小写 repo>:latest`。私有镜像需要先使用具有 `read:packages` 权限的 GitHub token 执行 `docker login ghcr.io`。

只有 `PUBLIC_HOST` 必填，不带协议、路径或端口。云安全组放行 TCP **8443、2333、443**（自定义端口时以实际配置为准）。REALITY 目标默认使用 `www.microsoft.com:443`，部署前确认 VPS 可以连接该目标，支持 TLS 1.3 和 HTTP/2；按实际网络情况调整 `REALITY_SERVER_NAME` 和 `REALITY_TARGET`。服务器与代理客户端的系统时间应准确。

获取并导入 VLESS 链接：

```bash
docker compose exec xlink python3 /opt/xlink/app.py info
```

链接包含 UUID、REALITY 公钥、short ID、SNI 和 `xtls-rprx-vision`。使用支持 VLESS REALITY/Vision 的客户端。节点凭据不会写入容器启动日志。

首次运行自动生成并保存 UUID、REALITY 密钥、short ID、Noise 密钥和隧道 token。重启、重建及更新镜像都会复用数据卷中的身份信息。已有身份文件损坏时停止启动，不会悄悄生成新密钥。

## 配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PUBLIC_HOST` | 必填 | VPS 公网 IP 或直连 DNS，写入客户端链接/隧道示例 |
| `XRAY_PORT` | `8443` | Xray REALITY TCP 端口 |
| `RATHOLE_PORT` | `2333` | Noise 隧道 TCP 端口 |
| `REALITY_SERVER_NAME` | `www.microsoft.com` | REALITY 伪装目标的 TLS SNI |
| `REALITY_TARGET` | `<REALITY_SERVER_NAME>:443` | 实际 TLS 目标，格式为 `host:port`，IPv6 用 `[地址]:端口` |
| `TZ` | `Asia/Shanghai` | 容器时区 |
| `XLINK_IMAGE` | `ghcr.io/nekoimi/xlink-installer:latest` | Compose 使用的镜像，建议生产部署固定发布标签或 digest |

`XRAY_PORT` / `RATHOLE_PORT` 不能相同，也不能使用固定的内网穿透业务入口 443。Compose 自动按相同的宿主机/容器端口映射；手写 `docker run` 时也应保持一致，以便生成的链接可以直接使用。

修改 `.env` 后执行 `docker compose up -d` 重新创建容器。网络配置会重新生成，密钥保持不变。`PUBLIC_HOST` 使用 IPv6 时填原始 IP，不带方括号；程序会自动为客户端地址加括号。容器服务监听 IPv4，公网 IPv6 入口还取决于宿主机 Docker 的 IPv6 发布配置。

## 内网穿透客户端

从容器导出客户端配置：

```bash
docker compose cp xlink:/data/rathole/client.toml ./client.toml
chmod 600 client.toml
```

将文件安全复制到内网机器，使用 **rathole v0.5.0** 运行：

```bash
rathole --client client.toml
```

默认 `local_addr = "127.0.0.1:443"`，将公网 TCP 443 转发给内网同端口服务。可改为应用实际的可达 IP 和端口。如果需要按域名分流多个 HTTPS 应用，可在内网端自行部署 Caddy 等反向代理，业务域名解析到 VPS，证书通过 DNS-01 申请；Docker 服务端不参与 HTTPS 终止或证书签发。

服务端只有在客户端成功认证 `internal_https` 后才监听 TCP 443；客户端尚未接入时容器也可以是 healthy。这里只转发 TCP，不转发内网 HTTP/3 的 UDP 443。

## 数据和运维

Compose 使用命名卷 `xlink-data` 挂载到 `/data`，保存：

- `identity.json`：所有身份密钥和 token，权限 600。
- `vless.txt`：代理链接，权限 600。
- `xray.json`、`rathole/server.toml`、`rathole/client.toml`：自动生成的服务/客户端配置。

`xray.json` 和 rathole 配置由环境变量与身份文件自动生成，不应直接编辑。升级之前包含 Caddy 的 Docker 版本时，可直接复用原数据卷，节点及隧道身份保留；旧 Caddy 文件不再使用。

一个数据卷只供一个 xLink 容器使用。备份时停止容器，备份整个卷；恢复时挂载同一份数据。数据包含私钥和凭据，请勿提交到 Git。删除数据卷会使所有节点和隧道身份重新生成，`docker compose down -v` 会删除该卷。

```bash
docker compose ps
docker compose logs --tail=100 -f
docker compose pull
docker compose up -d
```

启动程序让两个服务前台运行并将日志输出到 Docker；任一服务退出都会停止整个容器，交给 `restart: unless-stopped` 重新启动。`docker stop` 会终止并等待子进程退出。健康检查仅验证 Xray 和 Noise 控制端口，不依赖内网客户端在线。Docker 的 unhealthy 状态本身不会触发 restart policy。

BBR、宿主机防火墙、NTP 等需要在宿主机配置。容器无需 `--privileged`、host 网络或 Docker socket；Compose 只保留绑定低端口所需的 `NET_BIND_SERVICE` 能力。

## 本地构建

```bash
docker build -t xlink:local ./docker
# 如果已在 docker/ 目录中，构建上下文使用 .
```

将 `.env` 的 `XLINK_IMAGE` 改为 `xlink:local` 即可通过 Compose 启动。镜像支持 Linux amd64/arm64；构建时下载固定版本且校验 SHA-256 的 Xray/rathole 二进制。只包含 Python 标准库启动管理程序、CA 证书、时区及必要动态库；不带 curl、编辑器或排障工具，也不带 Xray 地理数据库。

固定版本：Xray `v26.3.27`、rathole `v0.5.0`。升级 Xray/rathole 时需同步更新 `download.py` 的版本与两种架构的校验值，并验证 CLI 密钥输出兼容性。

## GitHub Actions / GHCR

仓库包含 `.github/workflows/docker.yml`：

- 推送到 `master` / `main` 且修改 Docker 或 workflow 文件时运行。
- 推送 `v*` 标签及手动执行时运行。
- Pull Request 执行构建和测试，不推送镜像。
- 测试通过后构建并推送 `linux/amd64` 和 `linux/arm64` 镜像。
- 默认分支生成 `latest`；分支、版本标签、提交 SHA 也有对应镜像标签。

使用 GitHub 自动提供的 `GITHUB_TOKEN`，发布 job 声明 `packages: write`，不需要配置个人 token。如果组织策略限制包发布，需要管理员在仓库/组织中允许对应权限。首次发布后如需匿名拉取，在 GitHub Packages 中将镜像可见性设置为 Public；包可能默认是 Private。

workflow 在发布前执行配置/持久化测试和真实 amd64 容器测试：REALITY 代理、Noise 隧道转发、重启身份保留、正常停止及子进程失败处理。测试使用 Python TLS 服务器和 CI 宿主机生成的临时证书，不依赖外部网站或公共证书签发。arm64 由多架构构建验证，不运行相同的通信测试。

```bash
python -m unittest discover -s docker/tests -v
docker build -t xlink:smoke ./docker
# 通信测试需要 Docker 和宿主机 openssl
python docker/tests/smoke.py xlink:smoke
```
