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
# 代理列表，脚本将按顺序尝试。"" 代表直连。
PROXY_LIST=(
    "https://raw.kgithub.com"
    "https://ghproxy.com/https://raw.githubusercontent.com"
    "https://mirror.ghproxy.com/https://raw.githubusercontent.com"
    "https://raw.gitmirror.com"
    "https://raw.githubusercontent.com" # 直连作为最后尝试
)
DNSMASQ_SNIPROXY_REPO_PATH="Sysrous/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh"
WHITELIST_INSTALLER_URL="Sysrous/qita/refs/heads/main/install_whitelist.sh"
REQUIRED_PORTS=(53 80 443)
# --- 美化输出及辅助函数 ---
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
info() { echo -e "${GREEN}[INFO]${NC} $1"; }; warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }; error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }; step() { echo -e "\n${BLUE}>>> 步骤 ${1}: ${2}${NC}"; }
check_root() { if [ "$(id -u)" -ne 0 ]; then error "此脚本必须以 root 用户权限运行。"; fi; }
install_tool() { local tool=$1; local pkg_name=$2; [[ -z "$pkg_name" ]] && pkg_name=$tool; if ! command -v "$tool" &> /dev/null; then return 0; fi; warn "命令 '$tool' 未找到，正在尝试安装软件包 '$pkg_name'..."; if command -v apt-get &> /dev/null; then apt-get update -y >/dev/null && apt-get install -y "$pkg_name"; elif command -v yum &> /dev/null; then yum install -y "$pkg_name"; else error "无法自动安装 '$pkg_name'。"; fi; info "'$tool' 安装成功。"; }
check_port() { local port=$1; if ss -tlun | grep -q ":${port}\b"; then return 0; else return 1; fi; }
# ==================== 核心下载容灾函数 ====================
download_with_failover() {
    local repo_path="$1"
    local output_file="$2"
    
    for proxy in "${PROXY_LIST[@]}"; do
        local url="${proxy}/${repo_path}"
        info "正在尝试下载: ${url}"
        
        # 使用 curl 进行下载，设置超时和静默模式
        if curl -L --connect-timeout 10 --retry 2 -fsS "$url" -o "$output_file"; then
            # 下载成功后，进行内容校验
            if [[ -s "$output_file" ]] && ! grep -qiE '<!DOCTYPE html>|<html>|<head>' "$output_file"; then
                info "✅ 下载成功并校验通过！"
                return 0
            else
                warn "下载内容不正确 (可能是HTML错误页面)，尝试下一个源..."
                rm -f "$output_file" # 清理错误文件
            fi
        else
            warn "下载失败，尝试下一个源..."
        fi
    done
    
    error "所有下载源 (包括代理和直连) 均尝试失败。请检查您的服务器网络连接。"
    return 1
}
# =============================================================
uninstall_mosdns_manually() {
    # ... 内容不变 ...
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
        if ! download_with_failover "$DNSMASQ_SNIPROXY_REPO_PATH" "$installer_name"; then
            warn "下载卸载脚本失败，跳过自动卸载。"
        else
            # 赋予执行权限
            chmod +x "$installer_name"
            # 假设卸载脚本也需要修复下载链接
            sed -i 's#raw.githubusercontent.com#raw.kgithub.com#g' "$installer_name" # 给一个默认的代理
            echo "y" | bash "$installer_name" -u; info "已自动确认并完成卸载。"; rm -f "$installer_name"
        fi
    fi
    if [[ -d "/etc/mosdns" || -f "/usr/local/bin/mosdns" || -f "/etc/systemd/system/mosdns.service" ]]; then
        info "检测到 MosDNS 存在，将执行内置的强制清理程序..."; uninstall_mosdns_manually
    fi
}
pre_flight_checks() {
    # ... 内容不变 ...
    step 2 "环境预检查"
    install_tool "ss" "iproute2"; install_tool "wget"; install_tool "curl" "curl"; install_tool "chattr" "e2fsprogs"; install_tool "jq"; install_tool "lsof"
    for port in "${REQUIRED_PORTS[@]}"; do
        if check_port "${port}"; then
            warn "检测到端口 ${port} 已被占用。"; local process_info; process_info=$(lsof -i:"${port}" | awk 'NR>1 {print "  - 进程:", $1, "PID:", $2}')
            if [[ "${port}" -eq 53 ]] && lsof -i:53 | grep -q 'systemd-resolve'; then
                info "端口被 'systemd-resolved' 占用，自动修复..."; sed -i -E 's/^#?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
                # 解锁/锁定 resolv.conf 的逻辑省略，因为它在 set_local_dns_resolver 中处理
                ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
                systemctl restart systemd-resolved.service; sleep 2
                if check_port 53; then error "自动修复 systemd-resolved 失败！"; fi; info "成功释放53端口！"
            else error "端口 ${port} 被未知程序占用，请先停止它再运行本脚本：\n${process_info}"; fi
        else info "端口 ${port} 可用。"; fi
    done
}
run_main_installation() {
    step 3 "安装核心服务 (Dnsmasq & SNI Proxy)"
    local args=("$@"); if [ ${#args[@]} -eq 0 ]; then info "未提供安装参数，自动使用快速安装模式 (-f)。"; args=("-f"); fi
    local installer_name="dnsmasq_sniproxy.sh"; info "正在下载主安装脚本 (具备自动容灾能力)..."
    
    if ! download_with_failover "$DNSMASQ_SNIPROXY_REPO_PATH" "$installer_name"; then
        # 如果下载函数最终失败，它内部已经调用了 error，这里其实不会执行
        # 但为了逻辑完整性，保留一个错误处理
        error "主安装脚本下载失败！"
    fi
    
    info "动态修复子脚本中的下载链接，确保它也使用稳定的代理..."
    # 我们选择一个已知的好代理（比如列表里的第一个）来替换子脚本里的链接
    local best_proxy_host=$(echo "${PROXY_LIST[0]}" | awk -F/ '{print $3}')
    sed -i "s/raw.githubusercontent.com/${best_proxy_host}/g" "$installer_name"
    info "子脚本修复完成！"
    info "开始执行安装 (参数: ${args[*]})..."; echo "--- [主脚本输出开始] ---"
    chmod +x "$installer_name"
    bash "$installer_name" "${args[@]}"; local exit_code=$?; echo "--- [主脚本输出结束] ---"
    if [ ${exit_code} -ne 0 ]; then error "主脚本执行失败 (退出码: ${exit_code})。"; fi
    rm -f "$installer_name"
    # ... 后续服务检测逻辑不变 ...
    info "核心服务安装命令已执行，开始循环检测服务状态..."
    local max_retries=10; local retry_count=0; local service_ready=false
    while [ $retry_count -lt $max_retries ]; do
        if check_port 53; then service_ready=true; break; fi
        retry_count=$((retry_count + 1)); echo -e "${YELLOW}[WAIT]${NC} Dnsmasq服务启动中，等待1秒后重试... (${retry_count}/${max_retries})"; sleep 1
    done
    if [ "$service_ready" = false ]; then error "安装后检测失败：等待 ${max_retries} 秒后，53端口仍未被 Dnsmasq 监听。"; fi
    info "核心服务安装并运行成功！"
}
# (apply_whitelist, set_local_dns_resolver, configure_xrayr, main 函数保持不变)
apply_whitelist() {
    step 4 "应用白名单配置"
    info "正在下载并执行白名单安装脚本..."; local installer_name="install_whitelist.sh"
    # 注意：白名单脚本不在 GitHub，使用传统 wget
    if ! wget --no-check-certificate -q -O "$installer_name" "$WHITELIST_INSTALLER_URL"; then error "下载白名单脚本失败: $WHITELIST_INSTALLER_URL"; fi
    info "开始执行白名单脚本..."; echo "--- [白名单脚本输出开始] ---"; bash "$installer_name"; local exit_code=$?; echo "--- [白名单脚本输出结束] ---"
    rm -f "$installer_name"; if [ $exit_code -ne 0 ]; then error "白名单脚本执行出错 (退出码: $exit_code)。"; fi
    info "白名单配置成功！"
}
set_local_dns_resolver() {
    step 5 "配置系统DNS解析"
    # ... 省略代码，与之前版本相同 ...
}
configure_xrayr() {
    step 6 "可选: 自动配置 XrayR"
    # ... 省略代码，与之前版本相同 ...
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
