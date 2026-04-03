#!/bin/bash

# ========================================================================================
# 全能部署与管理脚本 for Dnsmasq, SNI Proxy, and XrayR Integration
#
# 版本: 2.5 - 智能DNS端口修正版
#
# 功能:
# 1. [清理] 自动卸载旧版服务，内置 MosDNS 手动清理逻辑。
# 2. [预检] 检查端口，修复 systemd-resolved 占用，安装所有依赖 (包括 jq)。
# 3. [安装] 智能默认快速安装 (-f) Dnsmasq & SNI Proxy。
# 4. [配置] 自动安装并应用白名单。
# 5. [整合] 智能配置系统DNS。
# 6. [联动] (可选) 自动修改 XrayR 配置：
#    - 设置本地DNS (127.0.0.1:53) 为主DNS。
#    - 保留解锁规则，并将其DNS端口从 10053 自动修正为 53。
# ========================================================================================

# --- 配置 ---
DNSMASQ_SNIPROXY_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh"
WHITELIST_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/qita/refs/heads/main/install_whitelist.sh"
MOSDNS_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/qita/refs/heads/main/mosdnsall_install.sh"
REQUIRED_PORTS=(53 80 443)

# --- 美化输出及辅助函数 ---
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
info() { echo -e "${GREEN}[INFO]${NC} $1"; }; warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }; error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }; step() { echo -e "\n${BLUE}>>> 步骤 ${1}: ${2}${NC}"; }
RESOLV_CONF_WAS_LOCKED=false
check_root() { if [ "$(id -u)" -ne 0 ]; then error "此脚本必须以 root 用户权限运行。"; fi; }
install_tool() { local tool=$1; local pkg_name=$2; [[ -z "$pkg_name" ]] && pkg_name=$tool; if ! command -v "$tool" &> /dev/null; then return 0; fi; warn "命令 '$tool' 未找到，正在尝试安装软件包 '$pkg_name'..."; if command -v apt-get &> /dev/null; then apt-get update -y >/dev/null && apt-get install -y "$pkg_name"; elif command -v yum &> /dev/null; then yum install -y "$pkg_name"; else error "无法自动安装 '$pkg_name'。"; fi; info "'$tool' 安装成功。"; }
unprotect_resolv_conf() { if [ -f /etc/resolv.conf ] && lsattr /etc/resolv.conf | grep -q 'i'; then info "检测到 /etc/resolv.conf 被锁定，正在临时解锁..."; chattr -i /etc/resolv.conf; RESOLV_CONF_WAS_LOCKED=true; fi; }
protect_resolv_conf() { if [[ "$RESOLV_CONF_WAS_LOCKED" = true ]]; then info "操作完成，正在重新锁定 /etc/resolv.conf..."; chattr +i /etc/resolv.conf; RESOLV_CONF_WAS_LOCKED=false; fi; }
check_port() { local port=$1; if lsof -i:"$port" -sTCP:LISTEN -P -n &>/dev/null || lsof -i:"$port" -sUDP -P -n &>/dev/null; then return 0; else return 1; fi; }
# --- 核心功能模块 ---
uninstall_previous_services() {
    step 1 "清理旧版服务 (全程自动)"
    if [[ -f "/etc/init.d/sniproxy" || -f "/etc/systemd/system/sniproxy.service" ]]; then
        info "检测到旧版 dnsmasq_sniproxy，将自动执行卸载..."
        local installer_name="dnsmasq_sniproxy_uninstall.sh"
        if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then
            warn "下载卸载脚本失败。"
        else
            echo "y" | bash "$installer_name" -u; info "已自动确认并完成卸载。"; rm -f "$installer_name"
        fi
    fi
    if [[ -d "/etc/mosdns" || -f "/usr/local/bin/mosdns" || -f "/etc/systemd/system/mosdns.service" ]]; then
        info "检测到旧版 mosdns，尝试执行卸载..."; local installer_name="mosdns_uninstall.sh"
        if curl -fsSL "$MOSDNS_INSTALLER_URL" -o "$installer_name"; then
            bash "$installer_name" uninstall; rm -f "$installer_name"; info "通过官方脚本卸载 MosDNS 成功。"
        else
            warn "下载官方 MosDNS 卸载脚本失败，将执行强制手动清理。"
            if systemctl is-active --quiet mosdns; then systemctl stop mosdns; fi; if systemctl is-enabled --quiet mosdns; then systemctl disable mosdns; fi
            rm -f /etc/systemd/system/mosdns.service /usr/local/bin/mosdns; rm -rf /etc/mosdns; systemctl daemon-reload; info "MosDNS 手动清理完成。"
        fi
    fi
}
pre_flight_checks() {
    step 2 "环境预检查"
    install_tool "lsof"; install_tool "wget"; install_tool "curl"; install_tool "chattr" "e2fsprogs"; install_tool "jq"
    for port in "${REQUIRED_PORTS[@]}"; do
        if check_port "${port}"; then
            warn "检测到端口 ${port} 已被占用。"; process_info=$(lsof -i:"${port}" | awk 'NR>1 {print "  - 进程:", $1, "PID:", $2}')
            if [[ "${port}" -eq 53 ]] && lsof -i:53 | grep -q 'systemd-resolve'; then
                info "端口被 'systemd-resolved' 占用，自动修复..."; sed -i -E 's/^#?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
                unprotect_resolv_conf; ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf; protect_resolv_conf
                systemctl restart systemd-resolved.service; sleep 2
                if check_port 53; then error "自动修复 systemd-resolved 失败！"; fi; info "成功释放53端口！"
            else error "端口 ${port} 被未知程序占用：\n${process_info}"; fi
        else info "端口 ${port} 可用。"; fi
    done
}
run_main_installation() {
    step 3 "安装核心服务 (dnsmasq & sniproxy)"
    local args=("$@"); if [ ${#args[@]} -eq 0 ]; then info "未提供安装参数，自动使用快速安装模式 (-f)。"; args=("-f"); fi
    local installer_name="dnsmasq_sniproxy.sh"; info "正在下载主安装脚本..."
    if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then error "下载主安装脚本失败！"; fi
    info "开始执行安装 (参数: ${args[*]})..."; echo "--- [主脚本输出开始] ---"
    bash "$installer_name" "${args[@]}"; local exit_code=$?; echo "--- [主脚本输出结束] ---"
    if [ ${exit_code} -ne 0 ]; then error "主脚本执行失败 (退出码: ${exit_code})。"; fi
    rm -f "$installer_name"
    # ==================== 关键修正部分 ====================
    info "核心服务安装命令已执行，开始循环检测服务状态..."
    local max_retries=10
    local retry_count=0
    local service_ready=false
    while [ $retry_count -lt $max_retries ]; do
        if check_port 53; then
            service_ready=true
            break
        fi
        retry_count=$((retry_count + 1))
        echo -e "${YELLOW}[WAIT]${NC} Dnsmasq服务启动中，等待1秒后重试... (${retry_count}/${max_retries})"
        sleep 1
    done
    if [ "$service_ready" = false ]; then
        error "安装后检测失败：等待 ${max_retries} 秒后，53端口仍未被 Dnsmasq 监听。"
    fi
    info "核心服务安装并运行成功！"
    # =======================================================
}
apply_whitelist() {
    step 4 "应用白名单配置"
    info "正在下载并执行白名单安装脚本..."; local installer_name="install_whitelist.sh"
    if ! wget --no-check-certificate -q -O "$installer_name" "$WHITELIST_INSTALLER_URL"; then error "下载白名单脚本失败: $WHITELIST_INSTALLER_URL"; fi
    info "开始执行白名单脚本..."; echo "--- [白名单脚本输出开始] ---"; bash "$installer_name"; local exit_code=$?; echo "--- [白名单脚本输出结束] ---"
    rm -f "$installer_name"; if [ $exit_code -ne 0 ]; then error "白名单脚本执行出错 (退出码: $exit_code)。"; fi
    info "白名单配置成功！"
}
set_local_dns_resolver() {
    step 5 "配置系统DNS解析"
    info "正在将本机DNS永久指向 127.0.0.1 ..."; unprotect_resolv_conf
    # ... (此函数内容不变) ...
    if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null; then
        info "检测到 Netplan 配置..."; for file in /etc/netplan/*.yaml; do cp "$file" "${file}.bak_$(date +%F)"; done
        sed -i 's/nameservers:.*/nameservers:\n          addresses: [127.0.0.1]/g' /etc/netplan/*.yaml
        warn "Netplan 配置已修改。请手动运行 'sudo netplan apply'"
    elif systemctl is-active --quiet systemd-resolved; then
        info "检测到 systemd-resolved 服务..."; cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak_$(date +%F)
        sed -i -E 's/^#?DNS=.*/DNS=127.0.0.1/' /etc/systemd/resolved.conf; sed -i -E 's/^#?FallbackDNS=.*/#FallbackDNS=/' /etc/systemd/resolved.conf
        systemctl restart systemd-resolved; info "systemd-resolved 配置完成。"
    elif command -v nmcli &> /dev/null && systemctl is-active --quiet NetworkManager; then
        info "检测到 NetworkManager..."; active_con=$(nmcli -t -f NAME,DEVICE connection show --active | head -n1 | cut -d: -f1)
        if [ -n "$active_con" ]; then
            info "正在修改活动连接: '$active_con'"; nmcli con mod "$active_con" ipv4.dns "127.0.0.1"; nmcli con mod "$active_con" ipv4.ignore-auto-dns yes
            nmcli con up "$active_con" >/dev/null; info "NetworkManager 配置完成。"
        else warn "未找到活动的 NetworkManager 连接。"; fi
    else
        info "未检测到主流网络管理工具，将直接修改 /etc/resolv.conf"; warn "警告: 直接修改此文件可能不是永久性的。"
        cp /etc/resolv.conf /etc/resolv.conf.bak_$(date +%F); echo "nameserver 127.0.0.1" > /etc/resolv.conf; info "/etc/resolv.conf 已修改。"
    fi
    protect_resolv_conf; if grep -q "127.0.0.1" /etc/resolv.conf; then info "DNS配置成功！"; else warn "DNS配置可能未完全生效。"; fi
}
configure_xrayr() {
    step 6 "可选: 自动配置 XrayR"
    # ... (此函数内容不变) ...
    local XRAYR_DIR="/etc/XrayR"; if ! [ -d "$XRAYR_DIR" ]; then info "未检测到 XrayR 安装目录 ($XRAYR_DIR)，跳过此步骤。"; return; fi
    info "检测到 XrayR，开始自动化配置..."; local TARGET_DNS_PORT="53"; local ROUTE_FILE="$XRAYR_DIR/route.json"; local DNS_FILE="$XRAYR_DIR/dns.json"
    if [ -f "$ROUTE_FILE" ]; then
        info "正在处理 $ROUTE_FILE ..."; local tmp_route=$(mktemp)
        jq --argjson port "$TARGET_DNS_PORT" '.rules |= ([{"type": "field","ip": ["127.0.0.1"],"port": $port,"outboundTag": "IPv4_out"}] + [.[] | select(.port != $port or .ip[0] != "127.0.0.1")])' "$ROUTE_FILE" > "$tmp_route" && mv "$tmp_route" "$ROUTE_FILE"
        info "route.json 修改完成：已添加本地DNS直连规则。"
    else warn "未找到 $ROUTE_FILE，跳过。"; fi
    if [ -f "$DNS_FILE" ]; then
        info "正在处理 $DNS_FILE ..."; local tmp_dns=$(mktemp)
        jq --argjson target_port "$TARGET_DNS_PORT" '.servers = ([{"address": "127.0.0.1","port": $target_port}] + (.servers | map(select(type == "object" and .domains != null) | (.port |= if . == 10053 then $target_port else . end))))' "$DNS_FILE" > "$tmp_dns" && mv "$tmp_dns" "$DNS_FILE"
        info "dns.json 修改完成：已设 127.0.0.1:53 为首选，并修正解锁DNS端口。"
    else warn "未找到 $DNS_FILE，跳过。"; fi
    if command -v xrayr &> /dev/null; then info "正在重启 XrayR 服务以应用配置..."; xrayr restart; info "XrayR 重启完成。"; else warn "未找到 'xrayr' 命令，请手动重启 XrayR 服务。"; fi
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
    if [ -d "/etc/XrayR" ]; then echo -e "XrayR 已被自动配置，将使用此DNS服务进行解析。"; fi
    echo -e "现在，请将您的其他设备（如Apple TV）的DNS服务器地址设置为本机的IP地址。"
}
main "$@"
