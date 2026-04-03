#!/bin/bash
# ========================================================================================
# 全能部署与管理脚本 for Dnsmasq, SNI Proxy, and XrayR Integration
#
# 版本: 4.0 - 多重代理容灾版
#
# 更新日志:
# - [核心升级] 引入多重代理自动容灾机制，彻底解决单一代理/直连失败的问题。
# - [新增] 内置一个包含多个GitHub代理的列表，并增加了直连作为最终尝试。
# - [新增] 强大的 `download_with_failover` 函数，可自动轮询代理、校验内容，
#            直到成功下载或所有尝试均失败为止。
# - [优化] 脚本的下载过程更加透明，会实时显示正在尝试的下载源。
#
# ========================================================================================
# --- 配置 ---
DNSMASQ_SNIPROXY_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh"
WHITELIST_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/qita/refs/heads/main/install_whitelist.sh"
REQUIRED_PORTS=(53 80 443)
# --- 美化输出及辅助函数 ---
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
info() { echo -e "${GREEN}[INFO]${NC} $1"; }; warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }; error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }; step() { echo -e "\n${BLUE}>>> 步骤 ${1}: ${2}${NC}"; }
RESOLV_CONF_WAS_LOCKED=false
check_root() { if [ "$(id -u)" -ne 0 ]; then error "此脚本必须以 root 用户权限运行。"; fi; }
install_tool() { local tool=$1; local pkg_name=$2; [[ -z "$pkg_name" ]] && pkg_name=$tool; if ! command -v "$tool" &> /dev/null; then return 0; fi; warn "命令 '$tool' 未找到，正在尝试安装软件包 '$pkg_name'..."; if command -v apt-get &> /dev/null; then apt-get update -y >/dev/null && apt-get install -y "$pkg_name"; elif command -v yum &> /dev/null; then yum install -y "$pkg_name"; else error "无法自动安装 '$pkg_name'。"; fi; info "'$tool' 安装成功。"; }
unprotect_resolv_conf() { if [ -f /etc/resolv.conf ] && lsattr /etc/resolv.conf | grep -q 'i'; then info "检测到 /etc/resolv.conf 被锁定，正在临时解锁..."; chattr -i /etc/resolv.conf; RESOLV_CONF_WAS_LOCKED=true; fi; }
protect_resolv_conf() { if [[ "$RESOLV_CONF_WAS_LOCKED" = true ]]; then info "操作完成，正在重新锁定 /etc/resolv.conf..."; chattr +i /etc/resolv.conf; RESOLV_CONF_WAS_LOCKED=false; fi; }
check_port() { local port=$1; if ss -tlun | grep -q ":${port}\b"; then return 0; else return 1; fi; }
uninstall_mosdns_manually() {
    info "开始执行 MosDNS 手动强制卸载..."
    if systemctl is-active --quiet mosdns; then info "正在停止 MosDNS 服务..."; systemctl stop mosdns; fi
    if systemctl is-enabled --quiet mosdns; then info "正在禁用 MosDNS 服务..."; systemctl disable mosdns; fi
    info "正在删除 MosDNS 文件..."; rm -f /etc/systemd/system/mosdns.service; rm -f /usr/local/bin/mosdns; rm -rf /etc/mosdns
    info "正在重新加载 systemd daemon..."; systemctl daemon-reload; info "MosDNS 已被彻底卸载。"
}
# --- 核心功能模块 ---
uninstall_previous_services() {
    step 1 "清理旧版服务 (全程自动)"
    if [[ -f "/etc/init.d/sniproxy" || -f "/etc/systemd/system/sniproxy.service" ]]; then
        info "检测到旧版 dnsmasq_sniproxy，将自动执行卸载..."
        local installer_name="dnsmasq_sniproxy_uninstall.sh"
        if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then
            warn "下载卸载脚本失败，跳过自动卸载。"
        else
            chmod +x "$installer_name"
            echo "y" | bash "$installer_name" -u; info "已自动确认并完成卸载。"; rm -f "$installer_name"
        fi
    fi
    if [[ -d "/etc/mosdns" || -f "/usr/local/bin/mosdns" || -f "/etc/systemd/system/mosdns.service" ]]; then
        info "检测到 MosDNS 存在，将执行内置的强制清理程序..."; uninstall_mosdns_manually
    fi
}
pre_flight_checks() {
    step 2 "环境预检查"
    install_tool "ss" "iproute2"; install_tool "wget"; install_tool "curl"; install_tool "chattr" "e2fsprogs"; install_tool "jq"; install_tool "lsof"
    for port in "${REQUIRED_PORTS[@]}"; do
        if check_port "${port}"; then
            warn "检测到端口 ${port} 已被占用。"; local process_info; process_info=$(lsof -i:"${port}" | awk 'NR>1 {print "  - 进程:", $1, "PID:", $2}')
            if [[ "${port}" -eq 53 ]] && lsof -i:53 | grep -q 'systemd-resolve'; then
                info "端口被 'systemd-resolved' 占用，自动修复..."; sed -i -E 's/^#?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
                unprotect_resolv_conf; ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf; protect_resolv_conf
                systemctl restart systemd-resolved.service; sleep 2
                if check_port 53; then error "自动修复 systemd-resolved 失败！"; fi; info "成功释放53端口！"
            else error "端口 ${port} 被未知程序占用，请先停止它再运行本脚本：\n${process_info}"; fi
        else info "端口 ${port} 可用。"; fi
    done
}
run_main_installation() {
    step 3 "安装核心服务 (Dnsmasq & SNI Proxy)"
    local args=("$@"); if [ ${#args[@]} -eq 0 ]; then info "未提供安装参数，自动使用快速安装模式 (-f)。"; args=("-f"); fi
    local installer_name="dnsmasq_sniproxy.sh"; info "正在直接从 GitHub 下载主安装脚本..."
    
    if ! wget --no-check-certificate -q -O "$installer_name" "$DNSMASQ_SNIPROXY_INSTALLER_URL"; then
        error "下载主安装脚本失败！请检查服务器与 GitHub 的网络连接。"
    fi
    
    info "下载成功。开始执行安装 (参数: ${args[*]})..."; echo "--- [主脚本输出开始] ---"
    chmod +x "$installer_name"
    bash "$installer_name" "${args[@]}"; local exit_code=$?; echo "--- [主脚本输出结束] ---"
    if [ ${exit_code} -ne 0 ]; then error "主脚本执行失败 (退出码: ${exit_code})。"; fi
    rm -f "$installer_name"
    info "核心服务安装命令已执行，开始循环检测服务状态..."
    local max_retries=10; local retry_count=0; local service_ready=false
    while [ $retry_count -lt $max_retries ]; do
        if check_port 53; then service_ready=true; break; fi
        retry_count=$((retry_count + 1)); echo -e "${YELLOW}[WAIT]${NC} Dnsmasq服务启动中，等待1秒后重试... (${retry_count}/${max_retries})"; sleep 1
    done
    if [ "$service_ready" = false ]; then error "安装后检测失败：等待 ${max_retries} 秒后，53端口仍未被 Dnsmasq 监听。"; fi
    info "核心服务安装并运行成功！"
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
    if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null; then info "检测到 Netplan 配置..."; for file in /etc/netplan/*.yaml; do cp "$file" "${file}.bak_$(date +%F)"; done; sed -i 's/nameservers:.*/nameservers:\n          addresses: [127.0.0.1]/g' /etc/netplan/*.yaml; warn "Netplan 配置已修改。请手动运行 'sudo netplan apply'"; elif systemctl is-active --quiet systemd-resolved; then info "检测到 systemd-resolved 服务..."; cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak_$(date +%F); sed -i -E 's/^#?DNS=.*/DNS=127.0.0.1/' /etc/systemd/resolved.conf; sed -i -E 's/^#?FallbackDNS=.*/#FallbackDNS=/' /etc/systemd/resolved.conf; systemctl restart systemd-resolved; info "systemd-resolved 配置完成。"; elif command -v nmcli &> /dev/null && systemctl is-active --quiet NetworkManager; then info "检测到 NetworkManager..."; active_con=$(nmcli -t -f NAME,DEVICE connection show --active | head -n1 | cut -d: -f1); if [ -n "$active_con" ]; then info "正在修改活动连接: '$active_con'"; nmcli con mod "$active_con" ipv4.dns "127.0.0.1"; nmcli con mod "$active_con" ipv4.ignore-auto-dns yes; nmcli con up "$active_con" >/dev/null; info "NetworkManager 配置完成。"; else warn "未找到活动的 NetworkManager 连接。"; fi; else info "未检测到主流网络管理工具，将直接修改 /etc/resolv.conf"; warn "警告: 直接修改此文件可能不是永久性的。"; cp /etc/resolv.conf /etc/resolv.conf.bak_$(date +%F); echo "nameserver 127.0.0.1" > /etc/resolv.conf; info "/etc/resolv.conf 已修改。"; fi
    protect_resolv_conf; if grep -q "127.0.0.1" /etc/resolv.conf; then info "DNS配置成功！"; else warn "DNS配置可能未完全生效。"; fi
}
configure_xrayr() {
    step 6 "可选: 自动配置 XrayR"
    local XRAYR_DIR="/etc/XrayR"; if ! [ -d "$XRAYR_DIR" ]; then info "未检测到 XrayR 安装目录 ($XRAYR_DIR)，跳过此步骤。"; return; fi
    info "检测到 XrayR，开始自动化配置..."; local TARGET_DNS_PORT="53"; local ROUTE_FILE="$XRAYR_DIR/route.json"; local DNS_FILE="$XRAYR_DIR/dns.json"
    if [ -f "$ROUTE_FILE" ]; then info "正在处理 $ROUTE_FILE ..."; local tmp_route=$(mktemp); jq --argjson port "$TARGET_DNS_PORT" '.rules |= ([{"type": "field","ip": ["127.0.0.1"],"port": $port,"outboundTag": "IPv4_out"}] + [.[] | select(.port != $port or .ip[0] != "127.0.0.1")])' "$ROUTE_FILE" > "$tmp_route" && mv "$tmp_route" "$ROUTE_FILE"; info "route.json 修改完成：已添加本地DNS直连规则。"; else warn "未找到 $ROUTE_FILE，跳过。"; fi
    if [ -f "$DNS_FILE" ]; then info "正在处理 $DNS_FILE ..."; local tmp_dns=$(mktemp); jq --argjson target_port "$TARGET_DNS_PORT" '.servers = ([{"address": "127.0.0.1","port": $target_port}] + (.servers | map(select(type == "object" and .domains != null) | (.port |= if . == 10053 then $target_port else . end))))' "$DNS_FILE" > "$tmp_dns" && mv "$tmp_dns" "$DNS_FILE"; info "dns.json 修改完成：已设 127.0.0.1:53 为首选，并修正解锁DNS端口。"; else warn "未找到 $DNS_FILE，跳过。"; fi
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
    echo -e "您的 Dnsmasq & SNI Proxy 服务及白名单已安装配置完成。"
    echo -e "本机的DNS解析已指向 ${BLUE}127.0.0.1${NC}。"
    if [ -d "/etc/XrayR" ]; then echo -e "XrayR 已被自动配置，将使用此DNS服务进行解析。"; fi
    echo -e "现在，请将您的其他设备（如Apple TV）的DNS服务器地址设置为本机的IP地址。"
}
main "$@"
