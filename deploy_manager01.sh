#!/bin/bash

# ========================================================================================
# 全能部署与管理脚本 for Dnsmasq, SNI Proxy, and XrayR Integration
#
# 版本: 2.4 - XrayR 自动配置版
#
# 功能:
# 1. [清理] 自动卸载旧版服务，内置 MosDNS 手动清理逻辑。
# 2. [预检] 检查端口，修复 systemd-resolved 占用，安装所有依赖 (包括 jq)。
# 3. [安装] 智能默认快速安装 (-f) Dnsmasq & SNI Proxy。
# 4. [配置] 自动安装并应用白名单。
# 5. [整合] 智能配置系统DNS。
# 6. [联动] (可选) 自动修改 XrayR 配置，使其使用本脚本部署的DNS服务。
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
install_tool() { local tool=$1; local pkg_name=$2; [[ -z "$pkg_name" ]] && pkg_name=$tool; if ! command -v "$tool" &> /dev/null; then return 0; fi; warn "命令 '$tool' 未找到，正在尝试安装软件包 '$pkg_name'..."; if command -v apt-get &> /dev/null; then apt-get update -y >/dev/null && apt-get install -y "$pkg_name"; elif command -v yum &> /dev/null; then yum install -y "$pkg_name"; else error "无法自动安装 '$pkg_name'。"; fi; info "'$tool' 安装成功。"; }
unprotect_resolv_conf() { if [ -f /etc/resolv.conf ] && lsattr /etc/resolv.conf | grep -q 'i'; then info "检测到 /etc/resolv.conf 被锁定，正在临时解锁..."; chattr -i /etc/resolv.conf; RESOLV_CONF_WAS_LOCKED=true; fi; }
protect_resolv_conf() { if [[ "$RESOLV_CONF_WAS_LOCKED" = true ]]; then info "操作完成，正在重新锁定 /etc/resolv.conf..."; chattr +i /etc/resolv.conf; RESOLV_CONF_WAS_LOCKED=false; fi; }
check_port() { local port=$1; if lsof -i:"$port" -sTCP:LISTEN -P -n &>/dev/null || lsof -i:"$port" -sUDP -P -n &>/dev/null; then return 0; else return 1; fi; }


# --- 核心功能模块 (与 v2.3 相同，为简洁省略部分代码) ---

uninstall_previous_services() {
    step 1 "清理旧版服务"
    # ... (代码与 v2.3 相同) ...
    if [[ -f "/etc/init.d/sniproxy" || -f "/etc/systemd/system/sniproxy.service" ]]; then info "检测到旧版 dnsmasq_sniproxy，将执行卸载..."; local installer_name="dnsmasq_sniproxy_uninstall.sh"; if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then warn "下载卸载脚本失败。"; else bash "$installer_name" -u; rm -f "$installer_name"; fi; fi
    if [[ -d "/etc/mosdns" || -f "/usr/local/bin/mosdns" || -f "/etc/systemd/system/mosdns.service" ]]; then info "检测到旧版 mosdns，尝试执行卸载..."; local installer_name="mosdns_uninstall.sh"; if curl -fsSL "$MOSDNS_INSTALLER_URL" -o "$installer_name"; then bash "$installer_name" uninstall; rm -f "$installer_name"; info "通过官方脚本卸载 MosDNS 成功。"; else warn "下载官方 MosDNS 卸载脚本失败，将执行强制手动清理。"; if systemctl is-active --quiet mosdns; then systemctl stop mosdns; fi; if systemctl is-enabled --quiet mosdns; then systemctl disable mosdns; fi; rm -f /etc/systemd/system/mosdns.service /usr/local/bin/mosdns; rm -rf /etc/mosdns; systemctl daemon-reload; info "MosDNS 手动清理完成。"; fi; fi
}

pre_flight_checks() {
    step 2 "环境预检查"
    install_tool "lsof"; install_tool "wget"; install_tool "curl"; install_tool "chattr" "e2fsprogs"
    install_tool "jq" # 新增：确保 jq 已安装，为 XrayR 配置做准备
    # ... (端口检查代码与 v2.3 相同) ...
    for port in "${REQUIRED_PORTS[@]}"; do if check_port "${port}"; then warn "检测到端口 ${port} 已被占用。"; process_info=$(lsof -i:"${port}" | awk 'NR>1 {print "  - 进程:", $1, "PID:", $2}'); if [[ "${port}" -eq 53 ]] && lsof -i:53 | grep -q 'systemd-resolve'; then info "端口被 'systemd-resolved' 占用，自动修复..."; sed -i -E 's/^#?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf; unprotect_resolv_conf; ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf; protect_resolv_conf; systemctl restart systemd-resolved.service; sleep 2; if check_port 53; then error "自动修复 systemd-resolved 失败！"; fi; info "成功释放53端口！"; else error "端口 ${port} 被未知程序占用：\n${process_info}"; fi; else info "端口 ${port} 可用。"; fi; done
}

run_main_installation() {
    step 3 "安装核心服务 (dnsmasq & sniproxy)"
    local args=("$@"); if [ ${#args[@]} -eq 0 ]; then info "未提供安装参数，自动使用快速安装模式 (-f)。"; args=("-f"); fi
    local installer_name="dnsmasq_sniproxy.sh"; info "正在下载主安装脚本..."; if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then error "下载主安装脚本失败！"; fi
    info "开始执行安装 (参数: ${args[*]})..."; echo "--- [主脚本输出开始] ---"; bash "$installer_name" "${args[@]}"; local exit_code=$?; echo "--- [主脚本输出结束] ---"
    if [ ${exit_code} -ne 0 ]; then error "主脚本执行失败 (退出码: ${exit_code})。"; fi
    if ! check_port 53; then error "安装后检测失败：53端口未被 Dnsmasq 监听。"; fi; info "核心服务安装并运行成功！"; rm -f "$installer_name"
}

apply_whitelist() {
    step 4 "应用白名单配置"
    # ... (代码与 v2.3 相同) ...
    info "正在下载并执行白名单安装脚本..."; local installer_name="install_whitelist.sh"; if ! wget --no-check-certificate -q -O "$installer_name" "$WHITELIST_INSTALLER_URL"; then error "下载白名单脚本失败: $WHITELIST_INSTALLER_URL"; fi; info "开始执行白名单脚本..."; echo "--- [白名单脚本输出开始] ---"; bash "$installer_name"; local exit_code=$?; echo "--- [白名单脚本输出结束] ---"; rm -f "$installer_name"; if [ $exit_code -ne 0 ]; then error "白名单脚本执行出错 (退出码: $exit_code)。"; fi; info "白名单配置成功！"
}

set_local_dns_resolver() {
    step 5 "配置系统DNS解析"
    # ... (代码与 v2.3 相同) ...
    info "正在将本机DNS永久指向 127.0.0.1 ..."; unprotect_resolv_conf
    if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null; then info "检测到 Netplan 配置..."; for file in /etc/netplan/*.yaml; do cp "$file" "${file}.bak_$(date +%F)"; done; sed -i 's/nameservers:.*/nameservers:\n          addresses: [127.0.0.1]/g' /etc/netplan/*.yaml; warn "Netplan 配置已修改。请手动运行 'sudo netplan apply'"; elif systemctl is-active --quiet systemd-resolved; then info "检测到 systemd-resolved 服务..."; cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak_$(date +%F); sed -i -E 's/^#?DNS=.*/DNS=127.0.0.1/' /etc/systemd/resolved.conf; sed -i -E 's/^#?FallbackDNS=.*/#FallbackDNS=/' /etc/systemd/resolved.conf; systemctl restart systemd-resolved; info "systemd-resolved 配置完成。"; elif command -v nmcli &> /dev/null && systemctl is-active --quiet NetworkManager; then info "检测到 NetworkManager..."; active_con=$(nmcli -t -f NAME,DEVICE connection show --active | head -n1 | cut -d: -f1); if [ -n "$active_con" ]; then info "正在修改活动连接: '$active_con'"; nmcli con mod "$active_con" ipv4.dns "127.0.0.1"; nmcli con mod "$active_con" ipv4.ignore-auto-dns yes; nmcli con up "$active_con" >/dev/null; info "NetworkManager 配置完成。"; else warn "未找到活动的 NetworkManager 连接。"; fi; else info "未检测到主流网络管理工具，将直接修改 /etc/resolv.conf"; warn "警告: 直接修改此文件可能不是永久性的。"; cp /etc/resolv.conf /etc/resolv.conf.bak_$(date +%F); echo "nameserver 127.0.0.1" > /etc/resolv.conf; info "/etc/resolv.conf 已修改。"; fi
    protect_resolv_conf; if grep -q "127.0.0.1" /etc/resolv.conf; then info "DNS配置成功！"; else warn "DNS配置可能未完全生效。"; fi
}


# --- 新增模块 ---
configure_xrayr() {
    step 6 "可选: 自动配置 XrayR"
    
    local XRAYR_DIR="/etc/XrayR"
    if ! [ -d "$XRAYR_DIR" ]; then
        info "未检测到 XrayR 安装目录 ($XRAYR_DIR)，跳过此步骤。"
        return
    fi
    
    info "检测到 XrayR，开始自动化配置..."
    
    # 目标DNS服务地址，即我们安装的 Dnsmasq
    local LOCAL_DNS_PORT="53"
    
    local ROUTE_FILE="$XRAYR_DIR/route.json"
    local DNS_FILE="$XRAYR_DIR/dns.json"
    
    # --- 1. 修改 route.json ---
    if [ -f "$ROUTE_FILE" ]; then
        info "正在处理 $ROUTE_FILE ..."
        local tmp_route=$(mktemp)
        # 逻辑：添加一条规则，将发往本地 DNS (127.0.0.1:53) 的流量强制直连。
        # 这可以防止 DNS 查询本身被代理，造成循环。
        # 我们先删除可能存在的旧规则，再添加到规则列表的顶部，确保最高优先级。
        jq --argjson port "$LOCAL_DNS_PORT" '
            .rules |= ([{
                "type": "field",
                "ip": ["127.0.0.1"],
                "port": $port,
                "outboundTag": "IPv4_out"
            }] + [.[] | select(.port != $port or .ip[0] != "127.0.0.1")])
        ' "$ROUTE_FILE" > "$tmp_route" && mv "$tmp_route" "$ROUTE_FILE"
        info "route.json 修改完成：已添加本地DNS直连规则。"
    else
        warn "未找到 $ROUTE_FILE，跳过。"
    fi
    
    # --- 2. 修改 dns.json ---
    if [ -f "$DNS_FILE" ]; then
        info "正在处理 $DNS_FILE ..."
        local tmp_dns=$(mktemp)
        # 逻辑：
        # 1. 将我们新部署的本地DNS (127.0.0.1:53) 作为首选DNS服务器。
        # 2. 清理掉所有其他的通用DNS服务器 (如 8.8.8.8, 1.1.1.1)。
        # 3. 保留那些为特定域名（如流媒体解锁）配置的特殊DNS服务器。
        jq --argjson port "$LOCAL_DNS_PORT" '
            .servers |= ([{
                "address": "127.0.0.1",
                "port": $port
            }] + [.[] | select(type == "object" and .domains != null)])
        ' "$DNS_FILE" > "$tmp_dns" && mv "$tmp_dns" "$DNS_FILE"
        info "dns.json 修改完成：已将 127.0.0.1:53 设为首选DNS。"
    else
        warn "未找到 $DNS_FILE，跳过。"
    fi

    # --- 3. 重启 XrayR ---
    if command -v xrayr &> /dev/null; then
        info "正在重启 XrayR 服务以应用配置..."
        xrayr restart
        info "XrayR 重启完成。"
    else
        warn "未找到 'xrayr' 命令，请手动重启 XrayR 服务。"
    fi
}

main() {
    check_root
    uninstall_previous_services
    pre_flight_checks
    run_main_installation "$@"
    apply_whitelist
    set_local_dns_resolver
    configure_xrayr
    
    echo -e "\n${GREEN}=====================================================${NC}"
    echo -e "${GREEN}          🎉 全部任务执行完毕！🎉          ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "您的 DNS & SNI Proxy 服务及白名单已安装配置完成。"
    echo -e "本机的DNS解析已指向 ${BLUE}127.0.0.1${NC}。"
    if [ -d "/etc/XrayR" ]; then
        echo -e "XrayR 已被自动配置，将使用此DNS服务进行解析。"
    fi
    echo -e "现在，请将您的其他设备（如Apple TV）的DNS服务器地址设置为本机的IP地址。"
}

main "$@"
