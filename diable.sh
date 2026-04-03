#!/bin/bash
# ==============================================================================
# 防火墙迁移与整合脚本 v2.0
#
# 更新日志:
# v2.0: 增加SSH端口自动检测功能，无需手动配置，提高安全性。
#
# 功能:
# 1. 从 UFW + iptables 的混合状态安全迁移到纯 iptables + ipset 管理。
# 2. 自动检测当前SSH端口并将其与备用端口一起开放。
# 3. 对指定的公共服务端口（如 XrayR）对所有来源开放。
# 4. 确保白名单规则 (DNS, Web) 得到正确应用。
# 5. 彻底禁用 UFW 以避免冲突。
# 6. 持久化新的、统一的防火墙规则集。
# ==============================================================================

# --- 配置区 (请根据您的需求确认) ---
# 1. 备用的SSH端口 (脚本会自动检测主SSH端口, 这里只需填写备用端口)
BACKUP_SSH_PORT="2233"
# 2. 对【任何IP】都开放的其他 TCP 端口范围 (例如: XrayR)
PORT_RANGE_ANYWHERE_TCP="5000:65535"
# 3. 对【任何IP】都开放的其他 UDP 端口范围 (例如: XrayR)
PORT_RANGE_ANYWHERE_UDP="5000:65535"
# 4. 仅对【白名单IP】开放的端口 (由 ipset 管理)
PORTS_WHITELIST="53 80 443"
# 5. ipset 集合的名称 (必须与您的 update_whitelist.sh 脚本中的名称一致)
SET_NAME="rpc_whitelist"

# --- 脚本主逻辑 ---
set -e # 如果任何命令失败，则立即退出

# 定义颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }

# 检查root权限
if [[ $EUID -ne 0 ]]; then
   log_error "此脚本必须以 root 身份运行。"
   exit 1
fi

# 检查核心命令是否存在
for cmd in iptables ipset iptables-save netfilter-persistent grep awk; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "核心命令 '$cmd' 未找到。请确保核心工具已安装。"
        exit 1
    fi
done

log_info "--- 步骤 1/6: 自动检测 SSH 端口... ---"
# 从sshd_config中查找未被注释的Port配置
DETECTED_SSH_PORT=$(grep -i "^ *Port" /etc/ssh/sshd_config | grep -v "^#" | awk '{print $2}')
if [[ -z "$DETECTED_SSH_PORT" ]]; then
    DETECTED_SSH_PORT="22" # 如果没有找到，则使用SSH默认端口22
    log_warn "未在 /etc/ssh/sshd_config 中找到明确的Port配置，将使用默认端口 22。"
else
    log_info "成功检测到当前SSH端口为: ${YELLOW}${DETECTED_SSH_PORT}${NC}"
fi

# 智能合并主SSH端口和备用端口
PORTS_ANYWHERE_TCP="$DETECTED_SSH_PORT"
if [[ "$DETECTED_SSH_PORT" != "$BACKUP_SSH_PORT" ]]; then
    PORTS_ANYWHERE_TCP="$PORTS_ANYWHERE_TCP $BACKUP_SSH_PORT"
fi
log_info "将对任何人开放以下SSH端口: ${YELLOW}${PORTS_ANYWHERE_TCP}${NC}"


log_info "--- 步骤 2/6: 检查并创建 ipset 集合... ---"
if ! ipset list -n | grep -q "^${SET_NAME}$"; then
    log_warn "ipset 集合 '${SET_NAME}' 不存在。正在创建..."
    ipset create "${SET_NAME}" hash:ip
    log_info "集合已创建。请记得运行一次白名单更新脚本来填充IP。"
else
    log_info "ipset 集合 '${SET_NAME}' 已存在。"
fi

log_info "--- 步骤 3/6: 建立新的、统一的 iptables 规则集... ---"
log_warn "临时将 INPUT 策略设置为 ACCEPT 以防断连..."
iptables -P INPUT ACCEPT
ip6tables -P INPUT ACCEPT

log_info "正在清空所有旧的 IPv4 和 IPv6 规则..."
iptables -F && iptables -X
ip6tables -F && ip6tables -X

log_info "正在构建新的防火墙规则..."
# --- 构建规则 (通用部分) ---
build_rules() {
    local ipt_cmd=$1
    # 1. 允许本地回环接口和已建立的连接
    $ipt_cmd -A INPUT -i lo -j ACCEPT
    $ipt_cmd -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # 2. 开放自动检测的SSH端口和备用端口
    for port in $PORTS_ANYWHERE_TCP; do
        $ipt_cmd -A INPUT -p tcp --dport "$port" -j ACCEPT
    done
    # 3. 开放指定的TCP/UDP端口范围 (XrayR)
    if [ -n "$PORT_RANGE_ANYWHERE_TCP" ]; then
        $ipt_cmd -A INPUT -p tcp --dport "$PORT_RANGE_ANYWHERE_TCP" -j ACCEPT
    fi
    if [ -n "$PORT_RANGE_ANYWHERE_UDP" ]; then
        $ipt_cmd -A INPUT -p udp --dport "$PORT_RANGE_ANYWHERE_UDP" -j ACCEPT
    fi
}

# --- 应用 IPv4 规则 ---
build_rules iptables
# 专门为IPv4添加白名单规则
for port in $PORTS_WHITELIST; do
    iptables -A INPUT -p tcp -m set --match-set "${SET_NAME}" src --dport "$port" -j ACCEPT
    iptables -A INPUT -p udp -m set --match-set "${SET_NAME}" src --dport "$port" -j ACCEPT
done
# 设置IPv4默认策略
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# --- 应用 IPv6 规则 (不包含ipset) ---
build_rules ip6tables
# 设置IPv6默认策略
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT ACCEPT

log_info "${GREEN}✅ 新的防火墙规则集已成功应用。${NC}"

log_info "--- 步骤 4/6: 禁用 UFW 服务... ---"
if ufw status | grep -q "Status: active"; then
    log_warn "检测到 UFW 正在运行，现在将禁用它..."
    ufw disable
    log_info "${GREEN}✅ UFW 已成功禁用，冲突源已移除。${NC}"
else
    log_info "UFW 已经是禁用状态，无需操作。"
fi

log_info "--- 步骤 5/6: 持久化新的 iptables 规则... ---"
netfilter-persistent save
log_info "${GREEN}✅ 所有规则已保存，将在系统重启后自动加载。${NC}"

log_info "--- 步骤 6/6: 最终状态检查 ---"
echo "--- 当前 IPv4 规则 (iptables -L -n -v) ---"
iptables -L -n -v --line-numbers
echo "-------------------------------------------"

echo -e "\n${GREEN}🎉 防火墙迁移完成！系统现在由 iptables + ipset 统一管理。${NC}"
echo -e "${YELLOW}请检查上面的规则列表，确保所有您需要的端口（特别是SSH）都已正确配置。${NC}"
