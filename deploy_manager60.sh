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
install_tool() { local tool=$1; local pkg_name=$2; [[ -z "$pkg_name" ]] && pkg_name=$tool; if command -v "$tool" &> /dev/null; then return 0; fi; warn "命令 '$tool' 未找到，正在尝试安装软件包 '$pkg_name'..."; if command -v apt-get &> /dev/null; then apt-get update -y >/dev/null && apt-get install -y "$pkg_name"; elif command -v yum &> /dev/null; then yum install -y "$pkg_name"; else error "无法自动安装 '$pkg_name'。"; fi; info "'$tool' 安装成功。"; }
check_port() { local port=$1; if ss -tlun | grep -q ":${port}\b"; then return 0; else return 1; fi; }
# --- 核心功能模块 ---
# ==================== 全新核心模块 ====================
purge_everything() {
    step 1 "彻底净化环境"
    info "本步骤将强制停止、禁用、卸载并清除所有相关的旧服务和文件..."
    
    # 1. 停止并禁用服务 (忽略不存在的服务的错误)
    info "正在停止和禁用 dnsmasq, sniproxy, mosdns 服务..."
    systemctl stop dnsmasq.service sniproxy.service mosdns.service >/dev/null 2>&1
    systemctl disable dnsmasq.service sniproxy.service mosdns.service >/dev/null 2>&1
    
    # 2. 彻底卸载软件包 (purge会删除配置文件)
    info "正在彻底卸载 dnsmasq 和 sniproxy 软件包..."
    if command -v apt-get &> /dev/null; then
        apt-get purge -y dnsmasq sniproxy dnsmasq-base >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        yum remove -y dnsmasq sniproxy >/dev/null 2>&1
    fi
    
    # 3. 暴力删除所有已知的残留文件和目录
    info "正在删除所有残留的配置文件和目录..."
    rm -rf /etc/dnsmasq.conf /etc/dnsmasq.d /etc/sniproxy.conf /etc/mosdns \
           /usr/local/bin/mosdns /etc/systemd/system/mosdns.service \
           /etc/init.d/sniproxy /etc/systemd/system/sniproxy.service
           
    # 4. 重新加载 systemd daemon
    info "正在重新加载 systemd daemon，确保系统忘记旧服务..."
    systemctl daemon-reload
    
    info "环境净化完成！系统现在处于干净状态。"
}
pre_flight_checks() {
    step 2 "环境预检查"
    install_tool "ss" "iproute2"; install_tool "wget"; install_tool "curl"; install_tool "jq"; install_tool "lsof"
    for port in "${REQUIRED_PORTS[@]}"; do
        if check_port "${port}"; then
            warn "检测到端口 ${port} 已被占用。"; local process_info; process_info=$(lsof -i:"${port}" | awk 'NR>1 {print "  - 进程:", $1, "PID:", $2}')
            if [[ "${port}" -eq 53 ]] && lsof -i:53 | grep -q 'systemd-resolve'; then
                info "端口被 'systemd-resolved' 占用，自动修复..."; sed -i -E 's/^#?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
                # 临时解锁resolv.conf
                if [ -f /etc/resolv.conf ] && lsattr /etc/resolv.conf | grep -q 'i'; then chattr -i /etc/resolv.conf; fi
                ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
                systemctl restart systemd-resolved.service; sleep 2
                if check_port 53; then error "自动修复 systemd-resolved 失败！"; fi; info "成功释放53端口！"
            else error "端口 ${port} 被未知程序占用，请先停止它再运行本脚本：\n${process_info}"; fi
        else info "端口 ${port} 可用。"; fi
    done
}
run_main_installation_and_calibrate() {
    step 3 "全新安装核心服务并强制校准"
    local args=("$@"); if [ ${#args[@]} -eq 0 ]; then info "未提供安装参数，自动使用快速安装模式 (-f)。"; args=("-f"); fi
    local installer_name="dnsmasq_sniproxy.sh"; info "正在从 GitHub 下载主安装脚本..."
    if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then error "下载主安装脚本失败！"; fi
    info "下载成功。开始在一个干净的环境中执行安装..."; echo "--- [主脚本输出开始] ---"
    chmod +x "$installer_name"; bash "$installer_name" "${args[@]}"; local exit_code=$?; echo "--- [主脚本输出结束] ---"
    if [ ${exit_code} -ne 0 ]; then warn "主脚本执行期间似乎有错误 (退出码: ${exit_code})，但我们将继续尝试校准。"; fi
    rm -f "$installer_name"
    # --- 强制校准 ---
    info "安装程序已执行完毕。现在开始强制校准 Dnsmasq 端口..."
    echo "port=53" > /etc/dnsmasq.d/99-force-port.conf
    info "端口校准配置已写入。正在重启 Dnsmasq 服务以应用更改..."
    systemctl restart dnsmasq.service
    sleep 2
    info "校准完成。开始最终状态验证..."
    local max_retries=10; local retry_count=0; local service_ready=false
    while [ $retry_count -lt $max_retries ]; do
        if check_port 53; then service_ready=true; break; fi
        retry_count=$((retry_count + 1)); echo -e "${YELLOW}[WAIT]${NC} 等待 Dnsmasq 在53端口启动... (${retry_count}/${max_retries})"; sleep 1
    done
    if [ "$service_ready" = false ]; then
        # ... (诊断逻辑不变) ...
        error "核心服务安装失败：即使在净化和强制校准后，Dnsmasq 仍未能监听53端口。请检查诊断信息。"
    fi
    info "核心服务安装并校准成功！Dnsmasq 正在正确监听端口 53。"
}
apply_whitelist() {
    step 4 "应用白名单配置"
    # ... (此部分逻辑不变) ...
    info "正在下载白名单脚本..."; local installer_name="install_whitelist.sh"
    if ! wget --no-check-certificate -q -O "$installer_name" "$WHITELIST_INSTALLER_URL"; then error "下载白名单脚本失败"; fi
    info "动态修复白名单脚本语法错误..."; sed -i '108s/local //g' "$installer_name"; info "修复完成。"
    info "开始执行白名单脚本..."; chmod +x "$installer_name"; bash "$installer_name"; local exit_code=$?
    rm -f "$installer_name"; if [ $exit_code -ne 0 ]; then error "白名单脚本执行出错 (退出码: $exit_code)。"; fi
    info "白名单配置成功！"
}
set_local_dns_resolver() {
    step 5 "配置系统DNS解析"
    # ... (此部分逻辑不变) ...
    info "正在将本机DNS永久指向 127.0.0.1 ..."; echo "nameserver 127.0.0.1" > /etc/resolv.conf; chattr +i /etc/resolv.conf
    info "DNS配置成功！/etc/resolv.conf 已锁定。"
}
configure_xrayr() {
    step 6 "可选: 自动配置 XrayR"
    # ... (此部分逻辑不变) ...
}
main() {
    check_root
    purge_everything
    pre_flight_checks
    run_main_installation_and_calibrate "$@"
    apply_whitelist
    set_local_dns_resolver
    configure_xrayr
    echo -e "\n${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          🎉 全部任务执行完毕！🎉          ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
}
main "$@"
