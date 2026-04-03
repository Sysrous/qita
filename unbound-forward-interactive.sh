#!/bin/bash
#====================================================
# 名称: unbound-forward-interactive.sh
# 功能: 交互式配置 unbound 转发到非标端口 DNS（带默认值，按回车用默认，不自动）
# 用法: bash unbound-forward-interactive.sh （在 root 下运行）
# 系统: Debian / Ubuntu
#====================================================

set -e  # 出错停止

# =============== 默认值设置 ===============
DEFAULT_UPSTREAM_IP="8.8.8.8"
DEFAULT_UPSTREAM_PORT="5353"

# =============== 验证函数 ===============
valid_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        IFS='.' read -r a b c d <<< "$ip"
        [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ] 2>/dev/null && return 0
    fi
    return 1
}

valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# =============== 主输入流程 ===============
echo "💬 欢迎使用 unbound 非标端口 DNS 转发配置工具"
echo "💡 提示：直接回车将使用方括号内的默认值，不会自动执行"

# 输入上游 IP
while true; do
    printf "请输入上游 DNS 服务器 IP [%s]: " "$DEFAULT_UPSTREAM_IP"
    read -r UPSTREAM_INPUT_IP
    UPSTREAM_IP="${UPSTREAM_INPUT_IP:-$DEFAULT_UPSTREAM_IP}"

    if valid_ip "$UPSTREAM_IP"; then
        break
    else
        echo "❌ '$UPSTREAM_IP' 不是一个有效的 IP 地址，请重新输入。"
    fi
done

# 输入上游端口
while true; do
    printf "请输入上游端口 [%s]: " "$DEFAULT_UPSTREAM_PORT"
    read -r UPSTREAM_INPUT_PORT
    UPSTREAM_PORT="${UPSTREAM_INPUT_PORT:-$DEFAULT_UPSTREAM_PORT}"

    if valid_port "$UPSTREAM_PORT"; then
        break
    else
        echo "❌ '$UPSTREAM_PORT' 不是一个有效的端口号（1-65535），请重新输入。"
    fi
done

# 显示配置摘要
echo
echo "─────────────────────────────"
echo "✅ 即将配置："
echo "   上游 DNS: $UPSTREAM_IP:$UPSTREAM_PORT"
echo "   本地监听: 127.0.0.1:53"
echo "─────────────────────────────"
echo

# 必须用户手动确认 —— 这才是“不自动”的关键！
while true; do
    printf "📌 请确认是否继续？[y/N]: "
    read -r CONFIRM
    case "${CONFIRM:-n}" in
        y|Y|yes|YES)
            echo "🔄 开始配置..."
            break
            ;;
        n|N|no|NO)
            echo "🛑 已取消，未进行任何更改。"
            exit 0
            ;;
        *)
            echo "请输入 y 或 n"
            ;;
    esac
done

# ==================================================
# ✅ 以下才是真正的配置阶段（用户已确认）
# ==================================================

# 安装 unbound
if ! command -v unbound &> /dev/null; then
    echo "📦 正在安装 unbound..."
    apt update -qq && apt install -y unbound > /dev/null
else
    echo "✅ unbound 已安装"
fi

# 写入配置文件
UNBOUND_CONF="/etc/unbound/unbound.conf.d/forward-to-custom-dns.conf"
cat > "$UNBOUND_CONF" << EOF
# 由脚本生成：${UPSTREAM_IP}:${UPSTREAM_PORT}
server:
    interface: 127.0.0.1
    port: 53
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-not-query-localhost: no
    access-control: 127.0.0.1 allow
    msg-cache-size: 4m
    rrset-cache-size: 4m

stub-zone:
    name: "."
    stub-addr: ${UPSTREAM_IP}@${UPSTREAM_PORT}
EOF

echo "📝 配置已写入: $UNBOUND_CONF"

# 停止 systemd-resolved（如果启用）
if systemctl is-active --quiet systemd-resolved; then
    echo "⚠️ 停止 systemd-resolved（避免占用 53 端口）..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved > /dev/null 2>&1 || true
fi

# 重启 unbound
echo "🚀 启动 unbound 服务..."
systemctl stop unbound > /dev/null 2>&1 || true
systemctl enable unbound --now > /dev/null
sleep 2

# 检查状态
if ! systemctl is-active --quiet unbound; then
    echo "❌ unbound 启动失败！请运行 'journalctl -u unbound -n 30' 查看日志"
    exit 1
fi

# 设置 resolv.conf
echo "nameserver  127.0.0.1" > /etc/resolv.conf
echo "options edns0" >> /etc/resolv.conf
echo "🔧 已设置 /etc/resolv.conf 使用 127.0.0.1"

# 测试解析
if timeout 3 host google.com 127.0.0.1 >/dev/null 2>&1; then
    echo "🎉 配置成功！DNS 解析正常"
else
    echo "🟡 配置完成，但 DNS 测试失败，请检查上游服务器是否可达"
fi

echo
echo "✅ 所有操作已完成。"
