#!/usr/bin/env bash
#
# xLink-Installer
# 自动化部署 3x-ui 面板 + Caddy 反向代理（自动 HTTPS）
# 支持 Ubuntu/Debian 与 CentOS/RHEL 系列
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 全局变量与常量
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="xLink-Installer"
readonly PANEL_PORT_DEFAULT=2053
readonly SUB_PORT_DEFAULT=2096
readonly XUI_INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly LOG_FILE="/var/log/xlink-install.log"
readonly XUI_DB="/etc/x-ui/x-ui.db"
readonly XUI_BIN="/usr/local/x-ui/x-ui"
# 官方安装脚本安装结束后写入的凭据文件（printf %q 转义、可 source、权限 600）
readonly XUI_RESULT_ENV="/etc/x-ui/install-result.env"

# 运行时变量（由参数或交互填充）
DOMAIN=""                        # 面板域名
SUB_DOMAIN=""                    # 订阅域名（与面板域名分开）
PANEL_PORT="${PANEL_PORT_DEFAULT}"
SUB_PORT="${SUB_PORT_DEFAULT}"
ENABLE_BBR=1
ASSUME_YES=0

# 从 3x-ui 实际配置回读的结果
XUI_PORT=""      # 面板真实监听端口
XUI_PATH=""      # 面板 webBasePath（访问路径）
XUI_LISTEN=""    # 面板监听地址
XUI_SUB_PORT=""      # 订阅真实端口
XUI_SUB_PATH=""      # 订阅路径 subPath
XUI_SUB_LISTEN=""    # 订阅监听地址
XUI_SUB_ENABLE=""    # 订阅是否启用
XUI_USER=""          # 面板用户名（从 install-result.env 回读）
XUI_PASS=""          # 面板密码（从 install-result.env 回读）

# 系统探测结果
OS_FAMILY=""   # debian | rhel
PKG_MGR=""     # apt | dnf | yum
ARCH=""

# 颜色
readonly C_RESET='\033[0m'
readonly C_INFO='\033[0;36m'
readonly C_OK='\033[0;32m'
readonly C_WARN='\033[0;33m'
readonly C_ERR='\033[0;31m'

# ---------------------------------------------------------------------------
# 日志辅助
# ---------------------------------------------------------------------------
log()  { printf "${C_INFO}[*]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_OK}[+]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_WARN}[!]${C_RESET} %s\n" "$*"; }
err()  { printf "${C_ERR}[x]${C_RESET} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 参数解析 / 使用说明
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${SCRIPT_NAME} - 一键部署 3x-ui + Caddy 自动 HTTPS 反向代理

用法:
  sudo bash install.sh [选项]

选项:
  -d, --domain <域名>     面板访问域名（必填，例如 panel.example.com）
  -s, --sub-domain <域名> 订阅访问域名（与面板域名分开，例如 sub.example.com）
  -p, --port <端口>       3x-ui 面板本地端口（默认 ${PANEL_PORT_DEFAULT}，通常自动回读）
      --sub-port <端口>   3x-ui 订阅本地端口（默认 ${SUB_PORT_DEFAULT}，通常自动回读）
      --no-bbr            不启用 BBR 加速
  -y, --yes               非交互模式，使用默认值不再询问
  -h, --help              显示本帮助

示例:
  sudo bash install.sh -d panel.example.com -s sub.example.com
  sudo bash install.sh -d panel.example.com -s sub.example.com -y
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)     DOMAIN="${2:-}"; shift 2 ;;
            -s|--sub-domain) SUB_DOMAIN="${2:-}"; shift 2 ;;
            -p|--port)       PANEL_PORT="${2:-}"; shift 2 ;;
            --sub-port)      SUB_PORT="${2:-}"; shift 2 ;;
            --no-bbr)        ENABLE_BBR=0; shift ;;
            -y|--yes)        ASSUME_YES=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            *) die "未知参数: $1（使用 -h 查看帮助）" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 前置检查与系统探测
# ---------------------------------------------------------------------------
require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 权限运行（sudo bash install.sh ...）"
}

detect_system() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，不支持的系统"
    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-} ${ID_LIKE:-}" in
        *debian*|*ubuntu*) OS_FAMILY="debian"; PKG_MGR="apt" ;;
        *rhel*|*centos*|*fedora*|*rocky*|*almalinux*)
            OS_FAMILY="rhel"
            if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
            ;;
        *) die "不支持的发行版: ${ID:-unknown}（仅支持 Debian/Ubuntu 与 RHEL/CentOS 系列）" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) warn "未识别的架构 $(uname -m)，继续尝试" ;;
    esac

    ok "系统: ${PRETTY_NAME:-$ID}  |  包管理器: ${PKG_MGR}  |  架构: ${ARCH:-unknown}"
}

validate_config() {
    if [[ -z "${DOMAIN}" ]]; then
        [[ "${ASSUME_YES}" -eq 1 ]] && die "非交互模式下必须通过 -d 指定面板域名"
        read -rp "请输入面板访问域名 (例如 panel.example.com): " DOMAIN
    fi
    [[ -n "${DOMAIN}" ]] || die "面板域名不能为空"
    is_valid_domain "${DOMAIN}" || die "面板域名格式不合法: ${DOMAIN}"

    if [[ -z "${SUB_DOMAIN}" && "${ASSUME_YES}" -ne 1 ]]; then
        read -rp "请输入订阅访问域名 (与面板分开, 留空则跳过订阅代理): " SUB_DOMAIN
    fi
    if [[ -n "${SUB_DOMAIN}" ]]; then
        is_valid_domain "${SUB_DOMAIN}" || die "订阅域名格式不合法: ${SUB_DOMAIN}"
        [[ "${SUB_DOMAIN}" != "${DOMAIN}" ]] || die "订阅域名必须与面板域名不同"
    else
        warn "未提供订阅域名，将只配置面板反向代理"
    fi

    [[ "${PANEL_PORT}" =~ ^[0-9]+$ ]] || die "面板端口必须为数字: ${PANEL_PORT}"
    [[ "${SUB_PORT}"   =~ ^[0-9]+$ ]] || die "订阅端口必须为数字: ${SUB_PORT}"

    warn "请确认下列域名的 A/AAAA 记录均已解析到本机公网 IP，否则证书申请会失败："
    warn "  面板: ${DOMAIN}${SUB_DOMAIN:+   订阅: ${SUB_DOMAIN}}"
    if [[ "${ASSUME_YES}" -ne 1 ]]; then
        read -rp "确认继续安装? [y/N]: " reply
        [[ "${reply}" =~ ^[Yy]$ ]] || die "已取消"
    fi
}

is_valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# ---------------------------------------------------------------------------
# 包管理封装
# ---------------------------------------------------------------------------
pkg_update() {
    case "${PKG_MGR}" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
        dnf) dnf makecache -y || true ;;
        yum) yum makecache -y || true ;;
    esac
}

pkg_install() {
    # 用法: pkg_install pkg1 pkg2 ...；单个包失败不中断整体
    local pkgs=("$@") p
    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" 2>/dev/null || {
                warn "批量安装出现失败，逐个重试"
                for p in "${pkgs[@]}"; do
                    DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" 2>/dev/null || warn "跳过无法安装的包: $p"
                done
            }
            ;;
        dnf|yum)
            "${PKG_MGR}" install -y "${pkgs[@]}" 2>/dev/null || {
                warn "批量安装出现失败，逐个重试"
                for p in "${pkgs[@]}"; do
                    "${PKG_MGR}" install -y "$p" 2>/dev/null || warn "跳过无法安装的包: $p"
                done
            }
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 常用系统 / 网络 / 调试工具
# ---------------------------------------------------------------------------
install_common_tools() {
    log "安装常用系统、网络、调试工具..."
    local common=(curl wget vim nano tmux htop unzip tar jq lsof socat traceroute mtr nmap tcpdump telnet iftop nload)
    local debian_extra=(net-tools iproute2 dnsutils ca-certificates gnupg sqlite3)
    local rhel_extra=(net-tools iproute bind-utils ca-certificates sqlite)

    if [[ "${OS_FAMILY}" == "debian" ]]; then
        pkg_install "${common[@]}" "${debian_extra[@]}"
    else
        # RHEL 系需要 EPEL 才能安装 htop/iftop/nload/mtr 等
        pkg_install epel-release || warn "EPEL 安装失败，部分工具可能不可用"
        pkg_install "${common[@]}" "${rhel_extra[@]}"
    fi
    ok "常用工具安装完成"
}

# ---------------------------------------------------------------------------
# 3x-ui 安装（非交互）
# ---------------------------------------------------------------------------
install_xui() {
    if command -v x-ui >/dev/null 2>&1; then
        ok "检测到 3x-ui 已安装，跳过安装步骤"
        return 0
    fi
    log "使用官方脚本非交互安装 3x-ui..."
    # 官方脚本支持 XUI_NONINTERACTIVE=1 或 stdin 非 TTY 时自动非交互安装，
    # 并生成随机端口 / webBasePath / 用户名 / 密码。全程输出留存到日志便于取回凭据。
    #
    # 关键：SSL 证书处理
    #   - 交互模式下证书菜单默认是选项 2（为 IP 签发 Let's Encrypt 证书），即用户提到的“多余的 IP 证书”。
    #   - 非交互模式按 XUI_SSL_MODE 映射：domain->1 / ip->2 / none|空->4(跳过，不生成任何证书)。
    #   这里显式设 XUI_SSL_MODE=none，确保面板以明文 HTTP 监听、绝不生成 IP 自签证书，TLS 全部交给 Caddy。
    #   XUI_DB_TYPE=sqlite 固定使用 sqlite（默认），避免落到 postgres 分支。
    local tmp="/tmp/3xui-install.$$.sh"
    curl -Ls "${XUI_INSTALL_URL}" -o "${tmp}" || die "下载 3x-ui 安装脚本失败"
    XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none XUI_DB_TYPE=sqlite \
        bash "${tmp}" </dev/null 2>&1 | tee -a "${LOG_FILE}"
    rm -f "${tmp}"
    # 安装日志含随机密码，收紧权限
    chmod 600 "${LOG_FILE}" 2>/dev/null || true

    command -v x-ui >/dev/null 2>&1 || die "3x-ui 安装失败，请查看 ${LOG_FILE}"
    systemctl is-active --quiet x-ui || { systemctl start x-ui || true; }
    ok "3x-ui 安装完成"
}

# ---------------------------------------------------------------------------
# 回读 3x-ui 真实配置（端口 / 路径 / 监听地址 / 凭据）
# 官方新装会随机生成这些值，必须回读后才能正确配置 Caddy。
# 优先读官方写出的 /etc/x-ui/install-result.env（干净可 source），
# 面板端口/路径/账号密码以它为准；订阅相关键与兜底以 sqlite settings 表为准。
# ---------------------------------------------------------------------------
read_xui_settings() {
    # 1) 官方凭据文件（含 XUI_PANEL_PORT / XUI_WEB_BASE_PATH / XUI_USERNAME / XUI_PASSWORD ...）
    if [[ -f "${XUI_RESULT_ENV}" ]]; then
        # 在子 shell 中 source，避免污染当前环境；仅取需要的字段
        local _port _path _user _pass
        _port="$( set +u; . "${XUI_RESULT_ENV}" >/dev/null 2>&1; printf '%s' "${XUI_PANEL_PORT:-}" )"
        _path="$( set +u; . "${XUI_RESULT_ENV}" >/dev/null 2>&1; printf '%s' "${XUI_WEB_BASE_PATH:-}" )"
        _user="$( set +u; . "${XUI_RESULT_ENV}" >/dev/null 2>&1; printf '%s' "${XUI_USERNAME:-}" )"
        _pass="$( set +u; . "${XUI_RESULT_ENV}" >/dev/null 2>&1; printf '%s' "${XUI_PASSWORD:-}" )"
        [[ -n "${_port}" ]] && XUI_PORT="${_port}"
        [[ -n "${_path}" ]] && XUI_PATH="${_path}"
        XUI_USER="${_user}"
        XUI_PASS="${_pass}"
    fi

    # 2) sqlite settings 表：补齐面板端口/路径/监听 + 订阅相关键
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${XUI_DB}" ]]; then
        db_read() { sqlite3 "${XUI_DB}" "SELECT value FROM settings WHERE key='$1' LIMIT 1;" 2>/dev/null || true; }
        [[ -n "${XUI_PORT}" ]] || XUI_PORT="$(db_read webPort)"
        [[ -n "${XUI_PATH}" ]] || XUI_PATH="$(db_read webBasePath)"
        XUI_LISTEN="$(db_read webListen)"
        XUI_SUB_PORT="$(db_read subPort)"
        XUI_SUB_PATH="$(db_read subPath)"
        XUI_SUB_LISTEN="$(db_read subListen)"
        XUI_SUB_ENABLE="$(db_read subEnable)"
    fi
    # 端口回读失败时退回到传入值，避免中断
    [[ -n "${XUI_PORT}" ]] || { XUI_PORT="${PANEL_PORT}"; warn "未能回读面板端口，使用 ${PANEL_PORT}"; }
    PANEL_PORT="${XUI_PORT}"
    [[ -n "${XUI_SUB_PORT}" ]] || XUI_SUB_PORT="${SUB_PORT}"
    SUB_PORT="${XUI_SUB_PORT}"
    # webBasePath / subPath 归一化为形如 /path/
    XUI_PATH="$(normalize_path "${XUI_PATH}")"
    XUI_SUB_PATH="$(normalize_path "${XUI_SUB_PATH}")"
    ok "面板配置: 端口=${PANEL_PORT} 路径=${XUI_PATH:-/} 监听=${XUI_LISTEN:-0.0.0.0}"
    if [[ -n "${SUB_DOMAIN}" ]]; then
        ok "订阅配置: 端口=${SUB_PORT} 路径=${XUI_SUB_PATH:-/} 监听=${XUI_SUB_LISTEN:-0.0.0.0} 启用=${XUI_SUB_ENABLE:-未知}"
        [[ "${XUI_SUB_ENABLE}" == "true" ]] || warn "3x-ui 订阅服务未启用，订阅域名暂不可用；请在面板『订阅设置』中开启后生效"
    fi
}

# 将路径归一化为 /path/ 形式（空则保持空）
normalize_path() {
    local p="$1"
    [[ -z "${p}" ]] && { printf ''; return; }
    [[ "${p}" == /* ]] || p="/${p}"
    [[ "${p}" == */ ]] || p="${p}/"
    printf '%s' "${p}"
}

# ---------------------------------------------------------------------------
# 将面板/订阅监听地址绑定到 127.0.0.1，避免绕过 Caddy 的明文直连暴露
#
# 非交互安装（XUI_SSL_MODE=none）时官方脚本不会主动绑定本地（云镜像需保持公网可达），
# 面板默认监听 0.0.0.0，故这里必须自行收紧。
# 面板监听用官方 CLI `x-ui setting -listenIP`（与官方脚本一致，最稳），sqlite 仅作兜底/订阅。
# ---------------------------------------------------------------------------
db_upsert() {
    # 用法: db_upsert <key> <value>
    local key="$1" val="$2"
    command -v sqlite3 >/dev/null 2>&1 && [[ -f "${XUI_DB}" ]] || return 1
    if [[ -n "$(sqlite3 "${XUI_DB}" "SELECT 1 FROM settings WHERE key='${key}' LIMIT 1;" 2>/dev/null)" ]]; then
        sqlite3 "${XUI_DB}" "UPDATE settings SET value='${val}' WHERE key='${key}';" 2>/dev/null || return 1
    else
        sqlite3 "${XUI_DB}" "INSERT INTO settings (key,value) VALUES ('${key}','${val}');" 2>/dev/null || return 1
    fi
}

db_get() { sqlite3 "${XUI_DB}" "SELECT value FROM settings WHERE key='$1' LIMIT 1;" 2>/dev/null || true; }

bind_xui_localhost() {
    local changed=0

    # 面板：优先官方 CLI，失败再退回 sqlite
    if [[ "${XUI_LISTEN}" != "127.0.0.1" ]]; then
        log "将面板监听地址绑定到 127.0.0.1..."
        if [[ -x "${XUI_BIN}" ]] && "${XUI_BIN}" setting -listenIP "127.0.0.1" >/dev/null 2>&1; then
            changed=1
        elif db_upsert webListen "127.0.0.1"; then
            changed=1
        else
            warn "未能绑定面板监听地址，请在面板设置中手动改为 127.0.0.1，并确保安全组不放行面板端口"
        fi
    fi

    # 订阅：无官方 CLI 直接项，best-effort 写 sqlite subListen（订阅默认未启用，启用后生效）
    if [[ -n "${SUB_DOMAIN}" && "${XUI_SUB_LISTEN}" != "127.0.0.1" ]]; then
        log "将订阅监听地址绑定到 127.0.0.1..."
        db_upsert subListen "127.0.0.1" && changed=1 \
            || warn "未能绑定订阅监听地址，启用订阅后请在面板设置中手动改为 127.0.0.1"
    fi

    # TLS 由 Caddy 统一终止，面板须以明文 HTTP 监听本地。
    # 非交互 XUI_SSL_MODE=none 不会生成证书；但若为“已存在的旧安装”，可能残留证书配置，
    # 会导致 Caddy 反代 http 失败。此处只做检测告警，不擅自清空既有配置。
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${XUI_DB}" ]]; then
        if [[ -n "$(sqlite3 "${XUI_DB}" "SELECT 1 FROM settings WHERE key IN ('webCertFile','webKeyFile') AND value<>'' LIMIT 1;" 2>/dev/null)" ]]; then
            warn "检测到面板已配置 TLS 证书，Caddy 反代明文 HTTP 可能失败；请在面板『面板设置』中清空证书路径后重启 x-ui"
        fi
    fi

    if [[ "${changed}" -eq 1 ]]; then
        systemctl restart x-ui || warn "重启 x-ui 失败，请手动 systemctl restart x-ui"
        sleep 1
        # 回读确认
        if command -v sqlite3 >/dev/null 2>&1 && [[ -f "${XUI_DB}" ]]; then
            XUI_LISTEN="$(db_get webListen)"
            [[ -n "${SUB_DOMAIN}" ]] && XUI_SUB_LISTEN="$(db_get subListen)"
        fi
    fi

    [[ "${XUI_LISTEN}" == "127.0.0.1" ]] && ok "面板已绑定 127.0.0.1" \
        || warn "面板监听为 ${XUI_LISTEN:-未知}，请确认已绑定 127.0.0.1，并确保安全组不放行面板端口"
    if [[ -n "${SUB_DOMAIN}" ]]; then
        [[ "${XUI_SUB_LISTEN}" == "127.0.0.1" ]] && ok "订阅已绑定 127.0.0.1" \
            || warn "订阅监听为 ${XUI_SUB_LISTEN:-未知}，启用订阅后请确认绑定 127.0.0.1，并确保安全组不放行订阅端口"
    fi
}

# ---------------------------------------------------------------------------
# Caddy 安装
# ---------------------------------------------------------------------------
install_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        ok "检测到 Caddy 已安装，跳过安装步骤"
        return 0
    fi
    log "安装 Caddy..."
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        pkg_install debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        pkg_update
        pkg_install caddy
    else
        pkg_install 'dnf-command(copr)' || true
        "${PKG_MGR}" copr enable -y @caddy/caddy || warn "copr 启用失败，尝试直接安装"
        pkg_install caddy
    fi
    command -v caddy >/dev/null 2>&1 || die "Caddy 安装失败"
    ok "Caddy 安装完成"
}

# ---------------------------------------------------------------------------
# Caddy 反向代理配置（自动 HTTPS）
# ---------------------------------------------------------------------------
configure_caddy() {
    log "写入 Caddy 配置: ${CADDYFILE}"
    mkdir -p "$(dirname "${CADDYFILE}")"
    [[ -f "${CADDYFILE}" ]] && cp -a "${CADDYFILE}" "${CADDYFILE}.bak.$(date +%s)"

    {
        echo "# 由 ${SCRIPT_NAME} 生成"
        caddy_site_block "${DOMAIN}" "${PANEL_PORT}"
        if [[ -n "${SUB_DOMAIN}" ]]; then
            echo ""
            caddy_site_block "${SUB_DOMAIN}" "${SUB_PORT}"
        fi
    } > "${CADDYFILE}"

    caddy validate --config "${CADDYFILE}" --adapter caddyfile \
        || die "Caddyfile 校验失败，请检查配置"

    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy || die "Caddy 启动失败，请查看 journalctl -u caddy"
    ok "Caddy 已启动并将自动为 ${DOMAIN}${SUB_DOMAIN:+ 、${SUB_DOMAIN}} 申请证书"
}

# 生成单个 Caddy 站点块：<域名> 反代到 127.0.0.1:<端口>
caddy_site_block() {
    local domain="$1" port="$2"
    cat <<EOF
${domain} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:${port} {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
    }
}
EOF
}

# ---------------------------------------------------------------------------
# 健康检查：确认端口已在监听
# ---------------------------------------------------------------------------
wait_for_port() {
    local port="$1" label="$2" i
    log "等待${label}端口 ${port} 就绪..."
    for i in $(seq 1 15); do
        if ss -ltn 2>/dev/null | grep -q ":${port}\b" \
           || curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${port}"; then
            ok "${label}端口 ${port} 已在监听"
            return 0
        fi
        sleep 1
    done
    warn "未检测到${label}端口 ${port} 监听，Caddy 可能返回 502；请检查 'x-ui status' 与端口设置"
}

wait_for_panel() {
    wait_for_port "${PANEL_PORT}" "面板"
    if [[ -n "${SUB_DOMAIN}" && "${XUI_SUB_ENABLE}" == "true" ]]; then
        wait_for_port "${SUB_PORT}" "订阅"
    fi
}

# ---------------------------------------------------------------------------
# 防火墙配置：放行 80 / 443
# ---------------------------------------------------------------------------
configure_firewall() {
    log "配置防火墙放行 80/443..."
    if command -v ufw >/dev/null 2>&1 && ufw status >/dev/null 2>&1; then
        ufw allow 80/tcp   >/dev/null 2>&1 || true
        ufw allow 443/tcp  >/dev/null 2>&1 || true
        ufw allow 443/udp  >/dev/null 2>&1 || true   # HTTP/3
        ok "已通过 ufw 放行 80/443"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=http    >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-service=https   >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=443/udp    >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ok "已通过 firewalld 放行 80/443"
    else
        warn "未检测到启用的防火墙(ufw/firewalld)，请自行确认云厂商安全组已放行 80/443"
    fi
}

# ---------------------------------------------------------------------------
# 启用 TCP BBR
# ---------------------------------------------------------------------------
enable_bbr() {
    [[ "${ENABLE_BBR}" -eq 1 ]] || { log "已跳过 BBR 配置"; return 0; }
    log "启用 TCP BBR..."
    local conf=/etc/sysctl.d/99-xlink-bbr.conf
    cat > "${conf}" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        ok "BBR 已启用"
    else
        warn "BBR 未生效，可能内核版本过低(<4.9)，重启后可再确认"
    fi
}

# ---------------------------------------------------------------------------
# 完成提示
# ---------------------------------------------------------------------------
print_summary() {
    local ip cred_hint
    ip="$(curl -s4 --max-time 5 ifconfig.me || echo '你的服务器IP')"
    # 优先用官方 install-result.env 回读到的账号密码；缺失时再从日志尽力取回
    if [[ -n "${XUI_USER}" || -n "${XUI_PASS}" ]]; then
        cred_hint="用户名: ${XUI_USER:-未知}"$'\n'"密码: ${XUI_PASS:-未知}"
    else
        cred_hint="$(grep -aiE 'username|password|用户名|密码' "${LOG_FILE}" 2>/dev/null | tail -n 6 || true)"
    fi

    cat <<EOF

${C_OK}============================================================${C_RESET}
 ${SCRIPT_NAME} 部署完成
${C_OK}============================================================${C_RESET}
  面板访问地址 : https://${DOMAIN}${XUI_PATH:-/}
  面板代理目标 : 127.0.0.1:${PANEL_PORT}  (监听 ${XUI_LISTEN:-0.0.0.0})
EOF

    if [[ -n "${SUB_DOMAIN}" ]]; then
        cat <<EOF
  订阅访问地址 : https://${SUB_DOMAIN}${XUI_SUB_PATH:-/}
  订阅代理目标 : 127.0.0.1:${SUB_PORT}  (监听 ${XUI_SUB_LISTEN:-0.0.0.0}, 启用=${XUI_SUB_ENABLE:-未知})
EOF
    fi

    cat <<EOF
  服务器 IP    : ${ip}

  管理 3x-ui   : 运行命令  x-ui
  查看面板凭据 : x-ui  ->  查看当前面板设置
  Caddy 日志   : journalctl -u caddy -f
  Caddy 配置   : ${CADDYFILE}
  安装日志     : ${LOG_FILE}
EOF

    if [[ -n "${cred_hint}" ]]; then
        printf "\n  面板登录凭据(安装时随机生成，也可运行 x-ui 查看)：\n%s\n" "${cred_hint}"
    fi

    cat <<EOF

  提示:
   - 访问地址已包含随机路径 ${XUI_PATH:-/}，缺少路径会返回 404
   - 首次访问 https 需等待证书签发(通常几秒~1分钟)
   - 请为所有域名(面板${SUB_DOMAIN:+、订阅})都配置解析并确保安全组放行 80/443
   - 面板已绑定 ${XUI_LISTEN:-0.0.0.0}；若非 127.0.0.1，请勿在安全组放行面板/订阅端口${SUB_DOMAIN:+
   - 订阅需在 3x-ui『订阅设置』中开启后方可使用}
${C_OK}============================================================${C_RESET}

EOF
}

# ---------------------------------------------------------------------------
# 错误处理与日志
# ---------------------------------------------------------------------------
on_error() {
    local line="$1"
    err "安装在第 ${line} 行中断。查看日志: ${LOG_FILE}"
    err "排查命令: 'x-ui status'、'journalctl -u caddy -e'"
}

setup_logging() {
    touch "${LOG_FILE}" 2>/dev/null || true
    log "安装日志: ${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    require_root
    trap 'on_error "${LINENO}"' ERR
    setup_logging
    detect_system
    validate_config

    pkg_update
    install_common_tools
    enable_bbr
    install_xui
    read_xui_settings
    bind_xui_localhost
    install_caddy
    wait_for_panel
    configure_caddy
    configure_firewall
    print_summary
}

main "$@"
