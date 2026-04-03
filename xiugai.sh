#!/bin/bash

# 检查是否为 root
if [ "$(id -u)" != "0" ]; then
    echo "请以 root 用户运行"
    exit 1
fi

# 1. 安装依赖 jq (处理 JSON 必须)
if ! command -v jq &> /dev/null; then
    echo "正在安装 jq 以处理配置文件..."
    apt-get update && apt-get install -y jq || yum install -y jq
fi

# 2. 自动探测 MosDNS 端口
MOSDNS_CONF="/etc/mosdns/config.yaml"
if [ ! -f "$MOSDNS_CONF" ]; then
    echo "找不到 MosDNS 配置文件 $MOSDNS_CONF"
    exit 1
fi

# 从配置文件提取端口 (匹配 listen: "127.0.0.1:XXXX" 格式)
PORT=$(grep -E 'listen: "127.0.0.1:[0-9]+"' $MOSDNS_CONF | head -n 1 | grep -oE '[0-9]+')

if [ -z "$PORT" ]; then
    # 尝试匹配无引号格式
    PORT=$(grep -E 'listen: 127.0.0.1:[0-9]+' $MOSDNS_CONF | head -n 1 | grep -oE '[0-9]+')
fi

if [ -z "$PORT" ]; then
    echo "无法自动探测 MosDNS 端口，请手动输入："
    read -p "端口号: " PORT
fi

echo "检测到 MosDNS 端口为: $PORT"

# 定义文件路径
ROUTE_FILE="/etc/XrayR/route.json"
DNS_FILE="/etc/XrayR/dns.json"

# --- 3. 修改 route.json ---
if [ -f "$ROUTE_FILE" ]; then
    echo "正在处理 $ROUTE_FILE ..."
    # 逻辑：删除已存在的 127.0.0.1 直连规则防止重复，然后插入到 rules 数组第一位
    # 保证它在 block 规则之前执行
    tmp_route=$(mktemp)
    jq --arg port "$PORT" '
        .rules |= ([{
            "type": "field",
            "ip": ["127.0.0.1"],
            "port": ($port | tonumber),
            "outboundTag": "IPv4_out"
        }] + [.[] | select(.port != ($port | tonumber) or .ip[0] != "127.0.0.1")])
    ' "$ROUTE_FILE" > "$tmp_route" && mv "$tmp_route" "$ROUTE_FILE"
    echo "route.json 修改完成。"
else
    echo "未找到 $ROUTE_FILE，跳过。"
fi

# --- 4. 修改 dns.json ---
if [ -f "$DNS_FILE" ]; then
    echo "正在处理 $DNS_FILE ..."
    # 逻辑：
    # 1. 过滤掉所有纯 IP 字符串 (如 8.8.8.8, 1.1.1.1, localhost)
    # 2. 过滤掉旧的 127.0.0.1 对象配置
    # 3. 保留带有 "domains" 的配置项 (流媒体解锁)
    # 4. 把新的 MosDNS 配置插到第一位
    tmp_dns=$(mktemp)
    jq --arg port "$PORT" '
        .servers |= ([{
            "address": "127.0.0.1",
            "port": ($port | tonumber)
        }] + [.[] | select(
            (type == "object" and .domains != null) 
        )])
    ' "$DNS_FILE" > "$tmp_dns" && mv "$tmp_dns" "$DNS_FILE"
    echo "dns.json 修改完成。"
else
    echo "未找到 $DNS_FILE，跳过。"
fi

# 5. 重启 XrayR
echo "正在重启 XrayR..."
xrayr restart

echo "------------------------------------------------"
echo "✅ 任务完成！"
echo "1. MosDNS 端口 $PORT 已加入 route.json 直连白名单。"
echo "2. dns.json 已清理普通 DNS，保留了解锁 DNS 并优先使用 MosDNS。"
echo "------------------------------------------------"
