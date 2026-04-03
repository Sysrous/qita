#!/bin/bash

SCAN_MODE="1"
FW_TOOL=""

log_ui() {
    echo -e "\n================ $1 ================\n"
}
log_info() {
    echo "[INFO] $1"
}
log_warn() {
    echo "[WARN] $1"
}
log_crit() {
    echo "[CRITICAL] $1"
}

clear_stdin() {
    while read -t 0.01 -n 1; do :; done
}


check_and_install_dependencies() {
    log_ui "1. 依赖检查与安装"
    local missing_pkgs=()
    local pkg_manager=""
    local install_cmd=""
    local update_cmd=""
    
    if command -v apt-get &> /dev/null; then
        pkg_manager="apt"; update_cmd="sudo apt-get update"; install_cmd="sudo apt-get install -y"
    elif command -v yum &> /dev/null; then
        pkg_manager="yum"; install_cmd="sudo yum install -y"
    elif command -v dnf &> /dev/null; then
        pkg_manager="dnf"; install_cmd="sudo dnf install -y"
    else
        log_warn "无法识别的包管理器。请手动安装: nmap, curl, iproute2"
        log_crit "请按回车键退出..."; read -r; return 1
    fi

    if ! command -v nmap &> /dev/null; then log_warn "'nmap' 未安装。"; missing_pkgs+=("nmap"); fi
    if ! command -v curl &> /dev/null; then log_warn "'curl' 未安装。"; missing_pkgs+=("curl"); fi
    
    local iproute_pkg="iproute2"
    if [ "$pkg_manager" == "yum" ] || [ "$pkg_manager" == "dnf" ]; then iproute_pkg="iproute"; fi
    if ! command -v ss &> /dev/null || ! command -v ip &> /dev/null; then
        log_warn "'ss' 或 'ip' (来自 $iproute_pkg) 未安装。"
        if ! [[ " ${missing_pkgs[*]} " =~ " ${iproute_pkg} " ]]; then missing_pkgs+=("$iproute_pkg"); fi
    fi

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_crit "脚本缺少以下必要的依赖: ${missing_pkgs[*]}"
        clear_stdin
        read -p "是否要自动安装这些依赖? (y/N): " choice
        case "$choice" in 
            y|Y )
                log_info "正在安装依赖... (这可能需要几分钟)"
                if [ -n "$update_cmd" ]; then
                    log_info "正在运行: $update_cmd"; eval "$update_cmd"
                    if [ $? -ne 0 ]; then log_crit "包列表更新失败。"; return 1; fi
                fi
                local packages_to_install=$(printf "%s " "${missing_pkgs[@]}")
                log_info "正在运行: $install_cmd $packages_to_install"
                if eval "$install_cmd $packages_to_install"; then
                    log_info "✅ 依赖安装成功。"
                else
                    log_crit "依赖安装失败。"; return 1
                fi
                ;;
            * )
                log_crit "用户拒绝安装。脚本无法继续。"; return 1
                ;;
        esac
    else
        log_info "✅ 所有核心依赖 (nmap, curl, ss, ip) 均已满足。"
    fi
    return 0
}


get_local_ips() {
    log_info "正在获取本地IP地址..."
    IPV4_ADDRESSES=$(ip -4 addr show | grep -oP 'inet 10\.\d{1,3}\d{1,3}\d{1,3}/\d+' | cut -d' ' -f2)
    IPV6_ADDRESSES=$(ip -6 addr show | grep -oP 'inet6 (240e|2408):[\S]+/\d+' | cut -d' ' -f2)
    ALL_IPS_JSON="["
    if [ -n "$IPV4_ADDRESSES" ]; then
        for ip in $IPV4_ADDRESSES; do ALL_IPS_JSON+="\"$ip\","; done
    fi
    if [ -n "$IPV6_ADDRESSES" ]; then
        for ip in $IPV6_ADDRESSES; do ALL_IPS_JSON+="\"$ip\","; done
    fi
    ALL_IPS_JSON+="\"127.0.0.1/8\", \"::1/128\"]"
    ALL_IPS_JSON=$(echo "$ALL_IPS_JSON" | sed 's/,]/]/')
}


detect_and_select_firewall() {
    log_ui "2. 防火墙工具检测与选择"
    local has_nft=0; local has_firewalld=0; local has_iptables=0; local recommended_tool="none"
    if command -v nft &> /dev/null; then has_nft=1; fi
    if command -v iptables &> /dev/null; then has_iptables=1; fi
    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then has_firewalld=1; fi
    if [ $has_nft -eq 1 ]; then recommended_tool="nftables";
    elif [ $has_firewalld -eq 1 ]; then recommended_tool="firewalld";
    elif [ $has_iptables -eq 1 ]; then recommended_tool="iptables";
    fi
    if [ "$recommended_tool" == "none" ]; then
        log_crit "未检测到任何可用的防火墙工具 (nft, firewalld, iptables)!"; FW_TOOL="unknown"; return 1
    fi
    log_info "系统检测到可用的防火墙工具:"
    local menu_options=()
    local recommended_choice_num=0
    local current_choice_num=1
    if [ $has_nft -eq 1 ]; then
        menu_options+=("nftables"); if [ "$recommended_tool" == "nftables" ]; then recommended_choice_num=$current_choice_num; fi
        current_choice_num=$((current_choice_num + 1))
    fi
    if [ $has_firewalld -eq 1 ]; then
        menu_options+=("firewalld"); if [ "$recommended_tool" == "firewalld" ]; then recommended_choice_num=$current_choice_num; fi
        current_choice_num=$((current_choice_num + 1))
    fi
    if [ $has_iptables -eq 1 ]; then
        menu_options+=("iptables"); if [ "$recommended_tool" == "iptables" ]; then recommended_choice_num=$current_choice_num; fi
        current_choice_num=$((current_choice_num + 1))
    fi
    local exit_choice_num=$current_choice_num
    menu_options+=("退出")
    echo "请选择您希望本次操作使用的防火墙工具:"
    for i in "${!menu_options[@]}"; do
        local display_text="  [$((i+1))] ${menu_options[$i]}"
        if [ "$((i+1))" -eq "$recommended_choice_num" ]; then display_text+=" (推荐)"; fi
        echo "$display_text"
    done
    clear_stdin
    read -p "请输入选择 [1-$exit_choice_num] (默认: $recommended_choice_num): " user_choice
    if [ -z "$user_choice" ]; then user_choice=$recommended_choice_num; fi
    if ! [[ "$user_choice" =~ ^[0-9]+$ ]] || [ "$user_choice" -lt 1 ] || [ "$user_choice" -gt "$exit_choice_num" ]; then
        log_warn "无效输入 '$user_choice'。"; FW_TOOL="unknown"; return 1
    fi
    local selected_tool=${menu_options[$((user_choice-1))]}
    if [ "$selected_tool" == "退出" ]; then
        log_info "用户选择退出。防火墙操作将不可用。"; FW_TOOL="unknown"; return 1
    fi
    FW_TOOL="$selected_tool"
    log_info "✅ 用户选择使用: $FW_TOOL"
    return 0
}


block_port() {
    local proto=$1; local port=$2; log_warn "正在尝试封堵 $proto 端口 $port ..."
    case "$FW_TOOL" in
        nftables) nft insert rule inet filter input $proto dport $port counter reject; log_info "已使用 nftables 封堵 $proto:$port";;
        firewalld) firewall-cmd --zone=public --add-rich-rule="rule family='ipv4' port port='$port' protocol='$proto' reject" --permanent; firewall-cmd --zone=public --add-rich-rule="rule family='ipv6' port port='$port' protocol='$proto' reject" --permanent; firewall-cmd --reload; log_info "已使用 firewalld 封堵 $proto:$port (已重载)";;
        iptables) iptables -I INPUT 1 -p $proto --dport $port -j REJECT; ip6tables -I INPUT 1 -p $proto --dport $port -j REJECT; log_info "已使用 iptables (v4/v6) 封堵 $proto:$port";;
        *) log_crit "未知的防火墙工具，无法自动封堵 $proto:$port"; return 1;;
    esac
    return 0
}

test_with_curl() {
    local ip=$1; local port=$2; local result_http=""; local result_https=""
    result_http=$(curl -s -m 3 -k -L --insecure "http://$ip:$port" 2>/dev/null)
    result_https=$(curl -s -m 3 -k -L --insecure "https://$ip:$port" 2>/dev/null)
    if [[ -n "$result_http" ]] || [[ -n "$result_https" ]]; then return 0; else return 1; fi
}

SUSPICIOUS_PROTO_KEYWORDS="http|https|tls|ssl|nginx|apache|iis|proxy|socks|vnc|rpc|cdn"
SUSPICIOUS_SERVICES=()

run_scan() {
    log_ui "开始扫描开放端口..."
    local open_ports
    open_ports=$(ss -tlpn | grep LISTEN | awk '{print $4}' | sed 's/.*://' | sort -u)
    if [ -z "$open_ports" ]; then
        log_info "未发现任何 TCP 监听端口。"
        return
    fi
    log_info "发现的监听端口: $open_ports"
    local ports_list=$(echo "$open_ports" | tr '\n' ',' | sed 's/,$//')
    local nmap_cmd="nmap -sV -p $ports_list 127.0.0.1"
    if [ "$SCAN_MODE" == "2" ]; then
        log_info "使用 'nice' (低优先级) 运行 Nmap"
        nmap_cmd="nice -n 19 $nmap_cmd"
    fi
    log_info "正在执行 Nmap 版本扫描..."
    log_info "命令: $nmap_cmd"
    local output_file
    output_file=$(mktemp)
    eval $nmap_cmd > "$output_file" 2>&1 &
    local nmap_pid=$!
    local spinner="-\\|/"
    local i=0
    local wait_message=""
    tput civis -- invisible
    while ps -p $nmap_pid > /dev/null; do
        if [ -n "$wait_message" ]; then
            printf "\r%s" "$wait_message"
        else
            printf "\r[INFO] 正在扫描... %s  " "${spinner:$i:1}"
            i=$(((i + 1) % 4))
        fi
        if read -s -n 1 -t 0.1; then
            wait_message="[WARN] 扫描正在后台运行, 请等待 Please Wait...     "
        fi
    done
    tput cnorm -- normal
    printf "\r%${COLUMNS:-80}s\r" " " 
    wait $nmap_pid
    local nmap_exit_code=$?
    local nmap_output
    nmap_output=$(cat "$output_file")
    rm "$output_file"
    if [ $nmap_exit_code -ne 0 ]; then
        log_crit "Nmap 执行失败 (Exit code: $nmap_exit_code)。"
        log_warn "输出: $nmap_output"
        return 1
    fi
    log_info "Nmap 扫描完成。正在分析结果..."
    while read -r line; do
        local port_proto=$(echo "$line" | awk '{print $1}')
        local port=$(echo "$port_proto" | cut -d'/' -f1)
        local proto=$(echo "$port_proto" | cut -d'/' -f2)
        local state=$(echo "$line" | awk '{print $2}')
        local service=$(echo "$line" | awk '{print $3}')
        local version=$(echo "$line" | awk '{print $4}')
        if [ "$state" == "open" ]; then
            log_info "检查端口 $port/$proto (服务: $service)..."
            local is_suspicious=0; local reason=""; local blocked="false"
            if test_with_curl "127.0.0.1" "$port"; then
                is_suspicious=1; reason="[CURL Test Failed] 端口 $port 响应了 HTTP/HTTPS (curl) 请求。"
            fi
            if echo "$service" | grep -qiE "$SUSPICIOUS_PROTO_KEYWORDS"; then
                is_suspicious=1
                if [ -z "$reason" ]; then reason="[Nmap-sV Failed] 端口 $port 运行可疑服务: $service"; fi
            fi
            if [ $is_suspicious -eq 1 ]; then
                if [[ ( "$port" == "22" && "$service" == "ssh" ) || \
                      ( "$port" == "80" && "$service" == "http" ) || \
                      ( "$port" == "443" && "$service" == "https" ) ]]; then
                    log_info "端口 $port/$proto ($service) 是已知安全服务，已忽略。"
                    is_suspicious=0
                fi
            fi
            if [ $is_suspicious -eq 1 ]; then
                log_crit "发现可疑端口: $port/$proto"
                log_warn "原因: $reason"
                clear_stdin
                read -p "  -> 是否要立即封堵 $port/$proto? (y/N): " choice
                case "$choice" in 
                    y|Y )
                        if block_port "$proto" "$port"; then
                            blocked="true"
                        else
                            blocked='"failed"'
                        fi
                        ;;
                    * )
                        blocked="false"
                        log_info "用户选择不封堵。"
                        ;;
                esac
                local service_json
                service_json=$(printf '{"port": "%s", "protocol": "%s", "service_name": "%s", "service_version": "%s", "reason": "%s", "blocked": %s}' \
                                "$port" "$proto" "$service" "$version" "$reason" "$blocked")
                SUSPICIOUS_SERVICES+=("$service_json")
            fi
        fi
    done < <(echo "$nmap_output" | grep -E '^[0-9]+/(tcp|udp)')
}


send_report() {
    local REPORT_URL="http://netreport.leikwanhost.com/report"
    local suspicious_json="["
    if [ ${#SUSPICIOUS_SERVICES[@]} -gt 0 ]; then
        suspicious_json+=$(IFS=,; echo "${SUSPICIOUS_SERVICES[*]}")
    fi
    suspicious_json+="]"
    
    local json_payload
    json_payload=$(cat <<EOF
{
    "hostname": "$(hostname)",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "local_ips": $ALL_IPS_JSON,
    "firewall_tool": "$FW_TOOL",
    "suspicious_services": $suspicious_json
}
EOF
)
    curl -s -o /dev/null -w "%{http_code}" \
         -X POST \
         -H "Content-Type: application/json" \
         -H "Accept: application/json" \
         -d "$json_payload" \
         "$REPORT_URL" > /dev/null 2>&1
}


display_scan_summary() {
    log_ui "扫描结果摘要"
    
    if [ ${#SUSPICIOUS_SERVICES[@]} -eq 0 ]; then
        log_info "✅ 恭喜！本次扫描未发现可疑服务。"
        return
    fi
    
    log_crit "本次扫描发现了 ${#SUSPICIOUS_SERVICES[@]} 个可疑服务，详情如下："
    echo "" # 换行
    
    printf "%-12s | %-20s | %-10s | %s\n" "端口 (Port)" "服务 (Service)" "状态 (Blocked)" "风险原因 (Reason)"
    echo "--------------------------------------------------------------------------------"
    
    for json in "${SUSPICIOUS_SERVICES[@]}"; do
        local port=$(echo "$json" | grep -oP '"port": "\K[^"]*')
        local proto=$(echo "$json" | grep -oP '"protocol": "\K[^"]*')
        local service_name=$(echo "$json" | grep -oP '"service_name": "\K[^"]*')
        local blocked=$(echo "$json" | grep -oP '"blocked": \K[^,}]+' | tr -d '"')
        local reason=$(echo "$json" | grep -oP '"reason": "\K[^"]*')

        printf "%-12s | %-20s | %-10s | %s\n" "$port/$proto" "$service_name" "$blocked" "$reason"
    done
    
    echo "--------------------------------------------------------------------------------"
    log_warn "请检查以上列表。如需封堵, 请重新运行扫描或使用 [2] 手动封堵。"
    echo "" # 换行
}

auto_block_summary_findings() {
    log_ui "执行: 自动封堵摘要"
    
    local updated_count=0
    for i in "${!SUSPICIOUS_SERVICES[@]}"; do
        local json_item="${SUSPICIOUS_SERVICES[$i]}"
        local blocked_status=$(echo "$json_item" | grep -oP '"blocked": \K[^,}]+' | tr -d '"')
        
        if [ "$blocked_status" == "false" ]; then
            local port=$(echo "$json_item" | grep -oP '"port": "\K[^"]*')
            local proto=$(echo "$json_item" | grep -oP '"protocol": "\K[^"]*')
            
            log_info "正在自动封堵 $port/$proto..."
            local new_blocked_status=""
            
            if block_port "$proto" "$port"; then
                new_blocked_status="true"
            else
                new_blocked_status='"failed"'
            fi
            
            SUSPICIOUS_SERVICES[$i]=$(echo "$json_item" | sed "s/\"blocked\": false/\"blocked\": $new_blocked_status/")
            updated_count=$((updated_count + 1))
        fi
    done
    
    log_info "自动封堵完成。共更新了 $updated_count 个项目的状态。"
}


# --- 7. 独立功能 (V2) ---
manual_block_port() {
    log_ui "手动封堵端口"; local port; local proto
    clear_stdin
    read -p "请输入要封堵的端口号 (e.g., 12345): " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then log_warn "无效的端口号 '$port'。"; return 1; fi
    clear_stdin
    read -p "请输入协议 [tcp] 或 udp (默认tcp): " proto
    if [ "$proto" == "udp" ]; then proto="udp"; else proto="tcp"; fi
    log_info "准备封堵 $proto:$port ..."; block_port "$proto" "$port"
}

add_ipv6_whitelist() {
    log_ui "添加 IPv6 白名单"; local ip_address
    clear_stdin
    read -p "请输入要加入白名单的 IPv6 地址 (例如 240e:xxx...): " ip_address
    if [ -z "$ip_address" ]; then log_warn "未提供 IP 地址。"; return 1; fi
    if ! [[ "$ip_address" == *":"* ]]; then log_warn "无效的 IPv6 地址格式。"; return 1; fi
    log_info "正在将 IPv6: $ip_address 加入白名单..."
    case "$FW_TOOL" in
        nftables) nft insert rule inet filter input ip6 saddr $ip_address counter accept; log_info "已使用 nftables (inet filter) 添加白名单";;
        firewalld) firewall-cmd --zone=public --add-rich-rule="rule family='ipv6' source address='$ip_address' accept" --permanent; firewall-cmd --reload; log_info "已使用 firewalld (rich rule) 添加白名单并重载";;
        iptables) if command -v ip6tables &> /dev/null; then ip6tables -I INPUT 1 -s $ip_address -j ACCEPT; log_info "已使用 ip6tables (v6) 添加白名单"; else log_warn "未找到 ip6tables 命令"; return 1; fi;;
        *) log_crit "未知的防火墙工具"; return 1;;
    esac
    return 0
}


# --- 8. 任务编排与主菜单 (V9) ---
# (此函数不变)
run_full_scan_task() {
    log_ui "执行: 安全扫描与保存";
    SUSPICIOUS_SERVICES=()
    ALL_IPS_JSON=""
    
    clear_stdin
    read -p "请选择扫描模式 [1] 全力扫描, [2] 低占用后台扫描 (默认1): " choice
    if [ "$choice" == "2" ]; then SCAN_MODE="2"; else SCAN_MODE="1"; fi
    
    get_local_ips; 
    log_info "获取到的IPs (用于报告): $ALL_IPS_JSON"
    
    run_scan
    
    display_scan_summary
    
    if [ ${#SUSPICIOUS_SERVICES[@]} -gt 0 ]; then
        echo "请选择后续操作:"
        echo "  [1] 自动封堵摘要中的所有 'false' 端口"
        echo "  [2] 稍后手动处理 (将按原样保存)"
        
        clear_stdin
        read -p "请输入选择 [1-2] (默认 2): " summary_choice
        
        case "$summary_choice" in
            1)
                auto_block_summary_findings
                log_info "自动封堵已执行。保存更新后的状态..."
                ;;
            *)
                log_info "选择手动处理。将按原样保存..."
                ;;
        esac
    fi
    
    send_report
    
    log_info "扫描任务完成。"
    clear_stdin
    read -p "请按回车键返回主菜单..."
}

interactive_menu() {
    while true; do
        log_ui "3. 主机安全自查工具 - 主菜单"
        echo "  [1] 运行安全扫描与保存 (Scan & Save)"
        echo "  [2] 手动封堵端口 (Manual Block)"
        echo "  [3] 添加IPv6白名单 (Add IPv6 Whitelist)"
        echo "  [4] 退出 (Exit)"
        echo ""
        clear_stdin
        read -p "请选择操作 [1-4]: " choice
        case "$choice" in
            1) run_full_scan_task;;
            2) manual_block_port;;
            3) add_ipv6_whitelist;;
            4. | 4) log_info "退出。"; break;;
            *) log_warn "无效选项 '$choice'。";;
        esac
    done
}

main() {
    if [ "$EUID" -ne 0 ]; then
        echo "[CRITICAL] 错误: 此脚本需要 root (sudo) 权限来安装依赖和管理防火墙。"
        echo "[WARN] 请使用 'sudo bash zicha.sh' 运行。"
        exit 1
    fi
    
    trap "tput cnorm -- normal; stty echo; log_warn '用户中断'; echo; exit 1" SIGINT
    
    log_ui "获取最新安全措施 - 初始化..."
    
    if ! check_and_install_dependencies; then
        log_crit "依赖检查失败或用户中止。脚本退出。"
        tput cnorm -- normal; stty echo; exit 1
    fi
    if ! detect_and_select_firewall; then
        log_crit "未选择防火墙工具或用户中止。脚本无法继续。"
        tput cnorm -- normal; stty echo; exit 1
    fi
    
    interactive_menu
    tput cnorm -- normal
    stty echo
    log_ui "脚本执行完毕。"
}


main
