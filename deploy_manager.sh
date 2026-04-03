#!/bin/bash

# ========================================================================================
# 全能部署与管理脚本 for Dnsmasq & SNI Proxy
#
# 版本: 2.3 - 智能默认与健壮卸载版
#
# 功能:
# 1. [清理] 自动卸载旧版服务，内置 MosDNS 手动清理逻辑以防卸载脚本失效。
# 2. [预检] 检查端口，修复 systemd-resolved 占用问题。
# 3. [安装] 当无参数时，自动触发快速安装 (-f)，避免静默失败。
# 4. [配置] 自动安装并应用白名单配置。
# 5. [整合] 智能配置系统DNS，并能自动处理 chattr 锁定的 /etc/resolv.conf 文件。
# ========================================================================================

# --- 配置 ---
DNSMASQ_SNIPROXY_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh"
WHITELIST_INSTALLER_URL="https://dl.xinluc.com/install_whitelist.sh"
MOSDNS_INSTALLER_URL="https://usgitdmit01.xinluc.com/https://github.com/Sysrous/dnsmasq_sniproxy_install/raw/master/mosdnsall_install.sh"
REQUIRED_PORTS=(53 80 443)

# --- 美化输出及辅助函数 (为简洁省略，与之前版本相同) ---
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
info() { echo -e "${GREEN}[INFO]${NC} $1"; }; warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }; error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }; step() { echo -e "\n${BLUE}>>> 步骤 ${1}: ${2}${NC}"; }
RESOLV_CONF_WAS_LOCKED=false
check_root() { if [ "$(id -u)" -ne 0 ]; then error "此脚本必须以 root 用户权限运行。"; fi; }
install_tool() { local tool=$1; local pkg_name=$2; [[ -z "$pkg_name" ]] && pkg_name=$tool; if ! command -v "$tool" &> /dev/null; then warn "命令 '$tool' 未找到，正在尝试安装软件包 '$pkg_name'..."; if command -v apt-get &> /dev/null; then apt-get update -y >/dev/null && apt-get install -y "$pkg_name"; elif command -v yum &> /dev/null; then yum install -y "$pkg_name"; else error "无法自动安装 '$pkg_name'。"; fi; info "'$tool' 安装成功。"; fi; }
unprotect_resolv_conf() { if [ -f /etc/resolv.conf ] && lsattr /etc/resolv.conf | grep -q 'i'; then info "检测到 /etc/resolv.conf 被锁定，正在临时解锁..."; chattr -i /etc/resolv.conf; RESOLV_CONF_WAS_LOCKED=true; fi; }
protect_resolv_conf() { if [[ "$RESOLV_CONF_WAS_LOCKED" = true ]]; then info "操作完成，正在重新锁定 /etc/resolv.conf..."; chattr +i /etc/resolv.conf; RESOLV_CONF_WAS_LOCKED=false; fi; }
check_port() { local port=$1; if lsof -i:"$port" -sTCP:LISTEN -P -n &>/dev/null || lsof -i:"$port" -sUDP -P -n &>/dev/null; then return 0; else return 1; fi; }


# --- 核心功能模块 ---

uninstall_previous_services() {
    step 1 "清理旧版服务"
    
    # 清理 dnsmasq_sniproxy
    if [[ -f "/etc/init.d/sniproxy" || -f "/etc/systemd/system/sniproxy.service" ]]; then 
        info "检测到旧版 dnsmasq_sniproxy，将执行卸载..."
        local installer_name="dnsmasq_sniproxy_uninstall.sh"
        if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then 
            warn "下载卸载脚本失败。"
        else 
            bash "$installer_name" -u; rm -f "$installer_name"
        fi
    fi

    # 清理 MosDNS (强化版)
    if [[ -d "/etc/mosdns" || -f "/usr/local/bin/mosdns" || -f "/etc/systemd/system/mosdns.service" ]]; then
        info "检测到旧版 mosdns，尝试执行卸载..."
        
        # 优先尝试官方卸载脚本
        local installer_name="mosdns_uninstall.sh"
        if curl -fsSL "$MOSDNS_INSTALLER_URL" -o "$installer_name"; then
            bash "$installer_name" uninstall
            rm -f "$installer_name"
            info "通过官方脚本卸载 MosDNS 成功。"
        else
            warn "下载官方 MosDNS 卸载脚本失败(URL可能已失效)，将执行强制手动清理。"
            if systemctl is-active --quiet mosdns; then
                info "正在停止 MosDNS 服务..."
                systemctl stop mosdns
            fi
            if systemctl is-enabled --quiet mosdns; then
                info "正在禁用 MosDNS 服务..."
                systemctl disable mosdns
            fi
            
            info "正在删除 MosDNS 相关文件..."
            rm -f /etc/systemd/system/mosdns.service
            rm -f /usr/local/bin/mosdns
            rm -rf /etc/mosdns
            
            systemctl daemon-reload
            info "MosDNS 手动清理完成。"
        fi
    fi
}

pre_flight_checks() {
    step 2 "环境预检查"
    install_tool "lsof"; install_tool "wget"; install_tool "curl"; install_tool "chattr" "e2fsprogs"
    for port in "${REQUIRED_PORTS[@]}"; do if check_port "${port}"; then warn "检测到端口 ${port} 已被占用。"; process_info=$(lsof -i:"${port}" | awk 'NR>1 {print "  - 进程:", $1, "PID:", $2}'); if [[ "${port}" -eq 53 ]] && lsof -i:53 | grep -q 'systemd-resolve'; then info "端口被 'systemd-resolved' 占用，自动修复..."; sed -i -E 's/^#?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf; unprotect_resolv_conf; ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf; protect_resolv_conf; systemctl restart systemd-resolved.service; sleep 2; if check_port 53; then error "自动修复 systemd-resolved 失败！"; fi; info "成功释放53端口！"; else error "端口 ${port} 被未知程序占用：\n${process_info}"; fi; else info "端口 ${port} 可用。"; fi; done
}

run_main_installation() {
    step 3 "安装核心服务 (dnsmasq & sniproxy)"
    
    # --- 关键修复：处理默认参数 ---
    local args=("$@")
    if [ ${#args[@]} -eq 0 ]; then
        info "未提供安装参数，自动使用默认的快速安装模式 (-f)。"
        args=("-f")
    fi
    
    local installer_name="dnsmasq_sniproxy.sh"
    info "正在下载主安装脚本..."
    if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then
        error "下载主安装脚本失败！"
    fi
    
    info "开始执行安装 (参数: ${args[*]})..."
    echo "--- [主脚本输出开始] ---"
    bash "$installer_name" "${args[@]}"
    local exit_code=$?
    echo "--- [主脚本输出结束] ---"
    
    if [ ${exit_code} -ne 0 ]; then error "主脚本执行失败 (退出码: ${exit_code})。"; fi
    
    # 验证 Dnsmasq 是否真的在监听53端口
    if ! check_port 53; then
        error "安装后检测失败：53端口未被 Dnsmasq 监听。安装过程可能出现问题。"
    fi
    info "核心服务安装并运行成功！"
    rm -f "$installer_name"
}

apply_whitelist() {
    step 4 "应用白名单配置"
    info "正在下载并执行白名单安装脚本..."
    local installer_name="install_whitelist.sh"
    if ! wget --no-check-certificate -q -O "$installer_name" "$WHITELIST_INSTALLER_URL"; then error "下载白名单脚本失败: $WHITELIST_INSTALLER_URL"; fi
    info "开始执行白名单脚本..."; echo "--- [白名单脚本输出开始] ---"; bash "$installer_name"; local exit_code=$?; echo "--- [白名单脚本输出结束] ---"; rm -f "$installer_name"; if [ $exit_code -ne 0 ]; then error "白名单脚本执行出错 (退出码: $exit_code)。"; fi
    info "白名单配置成功！"
}

set_local_dns_resolver() {
    step 5 "配置系统DNS解析"
    info "正在将本机DNS永久指向 127.0.0.1 ..."; unprotect_resolv_conf
    if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null; then info "检测到 Netplan 配置..."; for file in /etc/netplan/*.yaml; do cp "$file" "${file}.bak_$(date +%F)"; done; sed -i 's/nameservers:.*/nameservers:\n          addresses: [127.0.0.1]/g' /etc/netplan/*.yaml; warn "Netplan 配置已修改。请手动运行 'sudo netplan apply'"; elif systemctl is-active --quiet systemd-resolved; then info "检测到 systemd-resolved 服务..."; cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak_$(date +%F); sed -i -E 's/^#?DNS=.*/DNS=127.0.0.1/' /etc/systemd/resolved.conf; sed -i -E 's/^#?FallbackDNS=.*/#FallbackDNS=/' /etc/systemd/resolved.conf; systemctl restart systemd-resolved; info "systemd-resolved 配置完成。"; elif command -v nmcli &> /dev/null && systemctl is-active --quiet NetworkManager; then info "检测到 NetworkManager..."; active_con=$(nmcli -t -f NAME,DEVICE connection show --active | head -n1 | cut -d: -f1); if [ -n "$active_con" ]; then info "正在修改活动连接: '$active_con'"; nmcli con mod "$active_con" ipv4.dns "127.0.0.1"; nmcli con mod "$active_con" ipv4.ignore-auto-dns yes; nmcli con up "$active_con" >/dev/null; info "NetworkManager 配置完成。"; else warn "未找到活动的 NetworkManager 连接。"; fi; else info "未检测到主流网络管理工具，将直接修改 /etc/resolv.conf"; warn "警告: 直接修改此文件可能不是永久性的。"; cp /etc/resolv.conf /etc/resolv.conf.bak_$(date +%F); echo "nameserver 127.0.0.1" > /etc/resolv.conf; info "/etc/resolv.conf 已修改。"; fi
    protect_resolv_conf; if grep -q "127.0.0.1" /etc/resolv.conf; then info "DNS配置成功！"; else warn "DNS配置可能未完全生效。"; fi
}

main() {
    check_root
    uninstall_previous_services
    pre_flight_checks
    run_main_installation "$@"
    apply_whitelist
    set_local_dns_resolver
    echo -e "\n${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          🎉 全部任务执行完毕！🎉          ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "您的 DNS & SNI Proxy 服务及白名单已安装配置完成。"
    echo -e "本机的DNS解析已指向 ${BLUE}127.0.0.1${NC}。"
    echo -e "现在，请将您的其他设备（如Apple TV）的DNS服务器地址设置为本机的IP地址。"
}

main "$@"