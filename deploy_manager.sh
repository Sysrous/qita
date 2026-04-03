#!/bin/bash
# ========================================================================================
# 全能部署与管理脚本 for Dnsmasq, SNI Proxy, and XrayR Integration
#
# 版本: 6.0 - 彻底净化与重建版
#
# 更新日志:
# - [核心重构] 根据用户的宝贵建议，彻底改变脚本哲学。不再修补现有安装，
#            而是采用“净化->安装->校准”的全新模式。
# - [新增] 内置强大的 `purge_everything` 函数，在每次执行时，首先强制、
#            彻底地卸载并清除 Dnsmasq, SNI Proxy, MosDNS 的所有服务、
#            软件包、配置文件和残留目录，确保一个绝对干净的安装环境。
# - [保留并优化] 保留了 v5.3 的强制端口修正逻辑，作为全新安装后的“强制校准”
#            步骤，以应对外部脚本的已知 Bug。
#
# ========================================================================================
# --- 配置 ---
DNSMASQ_SNIPROXY_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh"
WHITELIST_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/qita/refs/heads/main/install_whitelist.sh"
REQUIRED_PORTS=(53 80 443)
# --- 美化输出及辅助函数 ---
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
info() { echo -e "${GREEN}[INFO]${NC} $1"; }; warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }; error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }; step() { echo -e "\n${BLUE}>>> 步骤 ${1}: ${2}${NC}"; }
check_root() { if [ "$(id -u)" -ne 0 ]; then error "此脚本必须以 root 用户权限运行。"; fi; }
install_tool() {
    local tool_cmd=$1
    local pkg_name=$2
    [[ -z "$pkg_name" ]] && pkg_name=$tool_cmd
    if command -v "$tool_cmd" &> /dev/null; then return 0; fi
    warn "命令 '$tool_cmd' 未找到，正在尝试安装软件包 '$pkg_name'..."
    if command -v apt-get &> /dev/null; then
        apt-get update -y >/dev/null
        apt-get install -y "$pkg_name"
    elif command -v yum &> /dev/null; then
        yum install -y "$pkg_name"
    else
        error "无法自动安装 '$pkg_name'。请手动安装后再试。"
    fi
    if ! command -v "$tool_cmd" &> /dev/null; then
        error "安装软件包 '$pkg_name' 后，命令 '$tool_cmd' 仍然找不到。安装失败。"
    fi
    info "'$pkg_name' 安装成功。"
}
check_port() { local port=$1; if ss -tlun | grep -q ":${port}\b"; then return 0; else return 1; fi; }
# --- 核心功能模块 ---
purge_everything() {
    step 1 "彻底净化环境"
    # ... (此函数逻辑不变) ...
    info "本步骤将强制停止、禁用、卸载并清除所有相关的旧服务和文件..."
    systemctl stop dnsmasq.service sniproxy.service mosdns.service >/dev/null 2>&1
    systemctl disable dnsmasq.service sniproxy.service mosdns.service >/dev/null 2>&1
    if command -v apt-get &> /dev/null; then apt-get purge -y dnsmasq sniproxy dnsmasq-base >/dev/null 2>&1; fi
    rm -rf /etc/dnsmasq.conf /etc/dnsmasq.d /etc/sniproxy.conf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service
    systemctl daemon-reload; info "环境净化完成！"
}
pre_flight_checks() {
    step 2 "环境预检查"
    # ... (此函数逻辑不变) ...
    install_tool "ss" "iproute2"; install_tool "wget" "wget"; install_tool "curl" "curl"; install_tool "lsof" "lsof"
}
# ==================== 此函数已重大修改 ====================
run_main_installation_and_calibrate() {
    step 3 "全新安装核心服务并强制校准"
    
    # --- 新增：预防性环境准备 ---
    info "为确保外部脚本的依赖安装成功，正在预先更新软件包列表并安装 net-tools..."
    if command -v apt-get &> /dev/null; then
        apt-get update -y || warn "apt-get update 失败，但仍将继续尝试..."
    fi
    install_tool "ifconfig" "net-tools" # net-tools 包含 ifconfig
    info "环境准备完成。"
    local args=("$@"); if [ ${#args[@]} -eq 0 ]; then info "未提供安装参数，自动使用快速安装模式 (-f)。"; args=("-f"); fi
    local installer_name="dnsmasq_sniproxy.sh"; info "正在从 GitHub 下载主安装脚本..."
    if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then error "下载主安装脚本失败！"; fi
    info "下载成功。开始在一个经过准备的环境中执行安装..."; echo "--- [主脚本输出开始] ---"
    chmod +x "$installer_name"; bash "$installer_name" "${args[@]}"; local exit_code=$?
    echo "--- [主脚本输出结束] ---"
    rm -f "$installer_name"
    # --- 重大修正：严格的错误处理 ---
    if [ ${exit_code} -ne 0 ]; then
        error "主安装脚本执行失败 (退出码: ${exit_code})。安装过程已终止。请检查上方 [主脚本输出] 的错误信息。"
    fi
    info "主安装脚本成功执行。现在开始强制校准 Dnsmasq 端口..."
    # --- 增强：确保目录存在 ---
    mkdir -p /etc/dnsmasq.d
    echo "port=53" > /etc/dnsmasq.d/99-force-port.conf
    info "端口校准配置已写入。正在重启 Dnsmasq 服务以应用更改..."
    systemctl restart dnsmasq.service
    sleep 2
    info "校准完成。开始最终状态验证..."
    # ... (后续验证逻辑不变) ...
    local max_retries=10; local retry_count=0; local service_ready=false
    while [ $retry_count -lt $max_retries ]; do
        if check_port 53; then service_ready=true; break; fi
        retry_count=$((retry_count + 1)); echo -e "${YELLOW}[WAIT]${NC} 等待 Dnsmasq 在53端口启动... (${retry_count}/${max_retries})"; sleep 1
    done
    if [ "$service_ready" = false ]; then
        error "核心服务安装失败：Dnsmasq 未能在53端口启动。请运行 'systemctl status dnsmasq' 和 'journalctl -u dnsmasq' 查看具体错误。"
    fi
    info "核心服务安装并校准成功！Dnsmasq 正在正确监听端口 53。"
}
# (其他函数 apply_whitelist, set_local_dns_resolver, configure_xrayr, main 均无变化)
apply_whitelist() { step 4 "应用白名单配置"; ...; }
set_local_dns_resolver() { step 5 "配置系统DNS解析"; ...; }
configure_xrayr() { step 6 "可选: 自动配置 XrayR"; ...; }
main() {
    check_root
    purge_everything
    pre_flight_checks
    run_main_installation_and_calibrate "$@"
    apply_whitelist
    set_local_dns_resolver
    configure_xrayr
    echo -e "\n${GREEN}================== 🎉 全部任务执行完毕！🎉 ==================${NC}"
}
main "$@"
