# ----------------------------------------------------------
#  自适应防火墙封装
#  1. 有宝塔 → 走宝塔 API（/www/server/panel/script/bt-firewall）
#  2. 无宝塔 → 走 ufw(Debian/Ubuntu) 或 iptables(CentOS)
# ----------------------------------------------------------

# ---- 1. 检测宝塔是否存在并启用防火墙插件 ----
BT_PANEL="/www/server/panel"
BT_FIREWALL_SCRIPT="$BT_PANEL/script/bt-firewall"
HAVE_BT=false
if [ -d "$BT_PANEL" ] && [ -x "$BT_FIREWALL_SCRIPT" ]; then
    # 再确认数据库里存在 firewall_rules 表
    sqlite3 "$BT_PANEL/data/firewall.db" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name='firewall_rules';" | grep -q firewall_rules && HAVE_BT=true
fi

# ---- 2. 检测系统发行版 ----
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS=$(uname -s)
fi

# ---- 3. 定义 add_or_update_rule 函数 ----
add_or_update_rule(){
    local ip="$1"          # 可以是单 IP 或 CIDR
    local position="$2"    # 宝塔忽略，ufw 用

    if $HAVE_BT; then
        # 宝塔：先删后加，避免重复
        $BT_FIREWALL_SCRIPT del "$ip" >/dev/null 2>&1   # 不存在也不报错
        $BT_FIREWALL_SCRIPT add "$ip"   &&  \
        log_message "已添加宝塔黑名单：$ip"
        return
    fi

    # ---------- 无宝塔分支 ----------
    case "$OS" in
        ubuntu|debian)
            # 用 ufw
            if ufw status | grep -qE "DENY.*$ip"; then
                rule_num=$(ufw status numbered | grep -E "$ip" | awk -F'[][]' '{print $2}' | head -n1)
                [ -n "$rule_num" ] && { ufw --force delete "$rule_num"; log_message "更新 ufw 规则：$ip"; }
            fi
            if [ -n "$position" ]; then
                ufw insert "$position" deny from "$ip" to any
            else
                ufw deny from "$ip" to any
            fi
            ;;
        centos|rhel|fedora|almalinux|rocky)
            # 用 iptables（CentOS 7）或 nftables（CentOS 8+/Rocky/Alma）
            if command -v nft >/dev/null; then
                # nftables
                table=$(nft list tables | awk '/inet filter/{print $2; exit}')
                if [ -z "$table" ]; then
                    nft add table inet filter
                    nft add chain inet filter input '{ type filter hook input priority 0; policy accept; }'
                fi
                # 先删
                nft delete rule inet filter input ip saddr "$ip" drop 2>/dev/null || true
                nft add rule inet filter input ip saddr "$ip" drop
            else
                # iptables
                iptables -D INPUT -s "$ip" -j DROP 2>/dev/null || true
                iptables -I INPUT -s "$ip" -j DROP
            fi
            log_message "已添加 iptables/nftables 黑名单：$ip"
            ;;
        *)
            log_message "未识别的系统：$OS ，跳过 $ip"
            ;;
    esac
}

# ---- 4. 统一 reload 函数（主程序末尾调用） ----
reload_firewall(){
    if $HAVE_BT; then
        # 宝塔会自动重载，无需额外操作
        log_message "已通知宝塔重载防火墙"
    else
        case "$OS" in
            ubuntu|debian) ufw reload ;;
            centos|rhel|fedora|almalinux|rocky)
                if command -v nft >/dev/null; then
                    # nftables 持久化（若未安装则跳过）
                    command -v nft-save >/dev/null && nft-save > /etc/sysconfig/nftables.conf
                else
                    # iptables 持久化
                    iptables-save > /etc/sysconfig/iptables
                fi
                ;;
        esac
        log_message "已重载系统防火墙"
    fi
}