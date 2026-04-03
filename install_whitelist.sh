#!/bin/bash
# ==============================================================================
# 全自动防火墙白名单部署脚本 v3.2 (终极可靠版 + 静默模式)
#
# 新增特性:
#   - 支持静默模式。使用 `bash -s` 或 `bash --silent` 运行以隐藏过程输出。
# ==============================================================================

# 如果任何命令失败，立即退出脚本
set -e

# --- 全局变量与模式设置 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
MAIN_SCRIPT_URL="https://dl.xinluc.com/update_whitelist.sh"
MAIN_SCRIPT_PATH="/usr/local/bin/update_whitelist.sh"
REQUIRED_PKGS="cron wget ipset iptables-persistent"

# 解析静默模式参数
SILENT_MODE=false
if [[ "$1" == "-s" || "$1" == "--silent" ]]; then
    SILENT_MODE=true
fi

# --- 函数定义 ---

# 日志函数，根据静默模式决定是否输出
log() {
    if ! $SILENT_MODE; then
        echo -e "$@"
    fi
}

# 错误函数，总是输出到 stderr
log_error() {
    echo -e "${RED}[错误]${NC} $1" >&2
}

# 函数：仅在需要时调用，用于重建一个干净、稳定的软件源
configure_apt_sources_and_update() {
    log "${YELLOW}--- 启动系统环境修复模式 ---${NC}"
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法找到 /etc/os-release，无法确定操作系统。"
        exit 1
    fi

    . /etc/os-release
    local CODENAME="$VERSION_CODENAME"
    local COMPONENTS="main contrib non-free"
    if [[ "$CODENAME" == "bookworm" ]]; then COMPONENTS="$COMPONENTS non-free-firmware"; fi

    log "正在备份并清理旧的软件源配置..."
    local backup_dir="/etc/apt/sources.list.bak_$(date +%F-%T)"
    mkdir -p "$backup_dir"
    [ -f /etc/apt/sources.list ] && mv /etc/apt/sources.list "$backup_dir/" &>/dev/null
    if [ -d /etc/apt/sources.list.d ] && [ "$(ls -A /etc/apt/sources.list.d)" ]; then
        mkdir -p "$backup_dir/sources.list.d"
        mv /etc/apt/sources.list.d/* "$backup_dir/sources.list.d/" &>/dev/null
    fi
    log "旧配置已备份至: $backup_dir"

    log "正在写入新的精简版软件源配置..."
    cat <<EOF > /etc/apt/sources.list
# 由部署脚本于 $(date) 自动生成 (v3.2 安全修复模式)
deb http://deb.debian.org/debian/ $CODENAME $COMPONENTS
deb http://security.debian.org/debian-security $CODENAME-security $COMPONENTS
deb http://deb.debian.org/debian/ $CODENAME-updates $COMPONENTS
EOF
    
    log "正在强制清理并更新 APT 缓存..."
    rm -rf /var/lib/apt/lists/*
    
    local apt_update_opts="-qq"
    $SILENT_MODE || apt_update_opts="" # 如果不是静默模式，则不清空选项
    apt-get update $apt_update_opts < /dev/null

    log "${GREEN}✅ APT 环境已刷新。${NC}"
}


# --- 主程序开始 ---

if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以 root 身份运行。"
   exit 1
fi

log "--- 步骤 1/4: 检查全部所需依赖... ---"
deps_missing=false
for pkg in $REQUIRED_PKGS; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
        log "${YELLOW}⚠️ 依赖 '$pkg' 未安装。${NC}"
        deps_missing=true
    fi
done

if $deps_missing; then
    if ! command -v apt-get &> /dev/null; then
        log_error "依赖缺失，但系统不是 Debian/Ubuntu，无法自动修复。"
        exit 1
    fi
    configure_apt_sources_and_update
    log "正在一次性安装所有缺失的依赖..."
    export DEBIAN_FRONTEND=noninteractive
    
    local apt_install_opts="-y"
    $SILENT_MODE && apt_install_opts="-y -qq" # 静默模式下使用-qq
    apt-get install $apt_install_opts $REQUIRED_PKGS < /dev/null

    log "${GREEN}✅ 所有依赖已安装完毕。${NC}"
else
    log "${GREEN}✅ 全部依赖 ('cron', 'wget', 'ipset', 'iptables-persistent') 已满足。${NC}"
fi

log "--- 步骤 2/4: 下载并设置主更新脚本... ---"
# wget -q 本身就是静默的
wget -q -O "$MAIN_SCRIPT_PATH" "$MAIN_SCRIPT_URL"
chmod +x "$MAIN_SCRIPT_PATH"
log "主脚本已下载至 $MAIN_SCRIPT_PATH"

log "--- 步骤 3/4: 首次运行脚本以应用防火墙规则... ---"
# 在静默模式下，也让主脚本静默运行
if $SILENT_MODE; then
    "$MAIN_SCRIPT_PATH" &>/dev/null
else
    "$MAIN_SCRIPT_PATH"
fi


log "--- 步骤 4/4: 设置定时任务... ---"
(crontab -l 2>/dev/null | grep -Fv "$MAIN_SCRIPT_PATH"; echo "*/5 * * * * ${MAIN_SCRIPT_PATH} >/dev/null 2>&1") | crontab -
log "定时任务已设置为每5分钟更新一次。"

# 最终的成功信息，无论何种模式都会显示
echo -e "\n${GREEN}✅ 部署成功: 白名单系统已正确配置并启动。${NC}"
