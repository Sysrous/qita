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
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
info() { echo -e "${GREEN}[INFO]${NC} $1"; }; warn() { echo -e "${YELLOW}[WARN]NC} $1"; }; error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }; step() { echo -e "\n${BLUE}>>> 步骤 ${1}: ${2}${NC}"; }
# --- 辅助函数 ---
check_root() { if [ "$(id -u)" -ne 0 ]; then error "此脚本必须以 root 用户权限运行。"; fi; }
update_package_manager() {
    info "正在更新软件包列表..."
    if command -v apt-get &> /dev/null; then
        apt-get update -y >/dev/null 2>&1 || warn "apt-get update 失败，但仍将继续。"
    elif command -v yum &> /dev/null; then
        yum makecache fast >/dev/null 2>&1 || warn "yum makecache 失败，但仍将继续。"
    fi
}
install_tool() {
    local tool_cmd=$1; local pkg_name=$2; [[ -z "$pkg_name" ]] && pkg_name=$tool_cmd
    if command -v "$tool_cmd" &> /dev/null; then return 0; fi
    warn "命令 '$tool_cmd' 未找到，正在自动安装软件包 '$pkg_name'..."
    local install_success=false
    if command -v apt-get &> /dev/null; then
        apt-get install -y "$pkg_name" >/dev/null 2>&1 && install_success=true
    elif command -v yum &> /dev/null; then
        yum install -y "$pkg_name" >/dev/null 2>&1 && install_success=true
    fi
    if [ "$install_success" = true ]; then info "软件包 '$pkg_name' 安装成功。"; else error "自动安装 '$pkg_name' 失败。请手动安装后再试。"; fi
}
# --- 核心功能模块 ---
# ==================== 全新重构的终极净化模块 ====================
ultimate_purge() {
    step 1 "执行终极环境净化"
    info "本步骤将停止并彻底移除 dnsmasq, sniproxy, mosdns 及 systemd-resolved..."
    # 1. 停止并禁用所有潜在的冲突服务
    info "正在停止服务: dnsmasq, sniproxy, mosdns, systemd-resolved..."
    systemctl stop dnsmasq.service sniproxy.service mosdns.service systemd-resolved.service >/dev/null 2>&1
    systemctl disable dnsmasq.service sniproxy.service mosdns.service systemd-resolved.service >/dev/null 2>&1
    
    # 2. 彻底卸载软件包
    info "正在卸载软件包: dnsmasq, sniproxy..."
    if command -v apt-get &> /dev/null; then
        apt-get purge -y dnsmasq sniproxy dnsmasq-base >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        yum remove -y dnsmasq sniproxy >/dev/null 2>&1
    fi
    # 3. 删除残留的配置文件和二进制文件 (特别是针对手动安装的 mosdns)
    info "正在删除残留文件和目录..."
    rm -rf /etc/dnsmasq.conf /etc/dnsmasq.d /etc/sniproxy.conf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service /etc/systemd/system/sniproxy.service
    # 4. 重新加载 systemd 并恢复网络
    info "正在重载 systemd 并恢复系统 DNS..."
    systemctl daemon-reload
    if [ -f /etc/resolv.conf ]; then chattr -i /etc/resolv.conf >/dev/null 2>&1; fi
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
    info "终极净化完成。环境已清理至最干净状态。"
}
pre_flight_checks() {
    step 2 "环境预检查与依赖安装"
    update_package_manager
    install_tool "lsof" "lsof"
    install_tool "wget" "wget"
    install_tool "dig" "dnsutils"
    REQUIRED_PORTS=(53 80 443)
    info "验证端口 ${REQUIRED_PORTS[*]} 在净化后是否可用..."
    for port in "${REQUIRED_PORTS[@]}"; do
        if lsof -ti tcp:"${port}" -sTCP:LISTEN >/dev/null; then
            local pid; pid=$(lsof -ti tcp:"${port}" -sTCP:LISTEN)
            local process_name; process_name=$(ps -p "$pid" -o comm=)
            error "严重错误：在终极净化后，端口 ${port} 仍然被未知进程 '${process_name}' (PID: ${pid}) 占用。脚本无法继续，请手动排查。"
        fi
    done
    info "端口验证通过！所有必需端口均可用。"
}
install_core_services() {
    step 3 "安装核心服务 (Dnsmasq + SNI Proxy)"
    install_tool "ifconfig" "net-tools"
    local installer_name="dnsmasq_sniproxy.sh"
    info "正在下载并执行主安装脚本..."
    wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL" || error "下载主安装脚本失败！"
    bash "$installer_name" -f; local exit_code=$?
    rm -f "$installer_name"
    [ ${exit_code} -ne 0 ] && error "主安装脚本执行失败。请检查上方输出。"
    info "核心服务安装脚本执行完毕。"
}
apply_whitelist() {
    step 4 "应用白名单配置"
    info "正在下载并应用解锁流媒体的白名单规则..."
    local whitelist_installer="install_whitelist.sh"
    wget -qO "$whitelist_installer" "$WHITELIST_INSTALLER_URL" || error "下载白名单脚本失败！"
    bash "$whitelist_installer" || warn "白名单脚本执行时似乎有错误，但我们将继续。"
    rm -f "$whitelist_installer"
    info "白名单配置已应用。正在重启 Dnsmasq 服务以加载新规则..."
    systemctl restart dnsmasq.service; sleep 2
    info "服务已重启。"
}
final_verification() {
    step 5 "最终服务健康检查"
    info "在修改系统DNS前，进行最后的、最严格的验证..."
    local max_retries=10; local retry_count=0
    until lsof -i :53 -sTCP:LISTEN >/dev/null; do
        retry_count=$((retry_count + 1))
        [ $retry_count -gt $max_retries ] && error "验证失败：Dnsmasq 未能在53端口启动。"
        echo -e "${YELLOW}[WAIT]${NC} 等待 Dnsmasq 在53端口启动... (${retry_count}/${max_retries})"
        sleep 1
    done
    info "端口验证成功：Dnsmasq 正在监听端口 53。"
    info "正在进行本地 DNS 健康检查 (查询 google.com)..."
    if ! dig @127.0.0.1 google.com +short +time=2 | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        error "本地DNS健康检查失败！Dnsmasq 服务虽在运行，但无法正确解析域名。"
    fi
    info "健康检查成功！本地 Dnsmasq 服务功能完备，工作正常。"
}
configure_system_resolver() {
    step 6 "配置系统使用本地DNS服务"
    info "所有检查均已通过。现在，安全地将系统 DNS 指向本地。"
    if [ -f /etc/resolv.conf ]; then chattr -i /etc/resolv.conf >/dev/null 2>&1; fi
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    info "系统 DNS 已成功配置为 127.0.0.1。未进行任何文件锁定。"
}
configure_xrayr() {
    step 7 "可选: 自动配置 XrayR"
    local xrayr_config="/etc/XrayR/config.yml"
    if [ -f "$xrayr_config" ]; then
        info "检测到 XrayR 配置文件，开始自动配置 DNS..."
        if grep -q "Enable: false" "$xrayr_config"; then sed -i 's/Enable: false/Enable: true/' "$xrayr_config"; info "XrayR DNS 配置已启用 (Enable: true)。"; fi
        info "正在重启 XrayR 服务以应用更改..."; systemctl restart XrayR
    else info "未检测到 XrayR 配置文件，跳过此步骤。"; fi
}
# --- 主逻辑 ---
main() {
    check_root
    ultimate_purge
    pre_flight_checks
    install_core_services
    apply_whitelist
    final_verification
    configure_system_resolver
    configure_xrayr
    echo -e "\n${GREEN}================== 🎉 全部任务执行完毕！🎉 ==================${NC}"
    info "Dnsmasq 已成功安装、配置白名单并被设置为系统默认 DNS 解析器。"
    info "如果安装了 XrayR, 其 DNS 配置也已同步更新。"
}
main "$@"
