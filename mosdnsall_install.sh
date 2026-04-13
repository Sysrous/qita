#!/bin/bash
# MosDNS & XrayR 智能联动终极脚本

# 1. 环境彻底清理
echo "正在清理旧环境..."
systemctl stop mosdns &> /dev/null
rm -rf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service
systemctl daemon-reload
mkdir -p /etc/mosdns

# 2. 交互输入端口
read -p "请输入 MosDNS 自定义端口 (默认 15454): " PORT
PORT=${PORT:-15454}

# 3. 安装依赖 (jq)
if ! command -v jq &> /dev/null; then
    echo "正在安装 jq 处理 JSON 配置文件..."
    if [ -f /usr/bin/apt ]; then
        apt-get update && apt-get install -y jq
    else
        yum install -y jq
    fi
fi

# 4. 下载二进制文件
ARCH=$(uname -m)
case $ARCH in
    x86_64)  PLAT="amd64" ;;
    aarch64) PLAT="arm64" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac
echo "正在下载 MosDNS v5.3.1 ($PLAT)..."
wget -O /tmp/mosdns.zip https://github.com/IrineSistiana/mosdns/releases/download/v5.3.1/mosdns-linux-${PLAT}.zip
unzip -qo /tmp/mosdns.zip -d /usr/local/bin
chmod +x /usr/local/bin/mosdns

# 5. 预造合法 Gzip 缓存头，消除 ERROR 日志
echo -n -e "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00" > /etc/mosdns/cache.dump

# 6. 创建静默双栈配置文件
cat > /etc/mosdns/config.yaml << 'EOF'
log:
  level: error

plugins:
  - tag: "cache_plugin"
    type: cache
    args:
      size: 20480
      lazy_cache_ttl: 259200
      dump_file: "/etc/mosdns/cache.dump"
      dump_interval: 600

  - tag: "forward_plugin"
    type: forward
    args:
      concurrent: 5
      upstreams:
        - addr: "8.8.8.8"
        - addr: "1.1.1.1"
        - addr: "2001:4860:4860::8888"
        - addr: "2606:4700:4700::1111"

  - tag: "main_sequence"
    type: sequence
    args:
      - exec: $cache_plugin
      - matches: has_resp
        exec: accept
      - exec: $forward_plugin
      - exec: $cache_plugin

  - tag: "udp_server"
    type: udp_server
    args:
      entry: "main_sequence"
      listen: "127.0.0.1:DNS_PORT"
  - tag: "tcp_server"
    type: tcp_server
    args:
      entry: "main_sequence"
      listen: "127.0.0.1:DNS_PORT"
EOF

sed -i "s/DNS_PORT/$PORT/g" /etc/mosdns/config.yaml

# 7. 配置 Systemd 服务
cat > /etc/systemd/system/mosdns.service << EOF
[Unit]
Description=MosDNS Static Silent Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml
Restart=always
RestartSec=5
StandardOutput=append:/var/log/mosdns.log
StandardError=append:/var/log/mosdns.log

[Install]
WantedBy=multi-user.target
EOF

# 8. 配置日志 2 小时自动清理策略
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/max_log.conf << EOF
[Journal]
SystemMaxUse=10M
MaxRetentionSec=2h
EOF

# 9. 启动 MosDNS 并检测状态
echo "正在启动 MosDNS..."
systemctl daemon-reload
systemctl restart systemd-journald
systemctl enable mosdns
systemctl restart mosdns

sleep 3
if systemctl is-active --quiet mosdns; then
    echo "✅ MosDNS 已正常启动 (127.0.0.1:$PORT)"
else
    echo "❌ MosDNS 启动失败，请检查配置。"
    exit 1
fi

# 修改 dns.json: 保留流媒体解锁并置顶 MosDNS
if [ -f "$DNS_FILE" ]; then
    tmp_dns=$(mktemp)
    jq --arg port "$PORT" '
        .servers = ([{
            "address": "127.0.0.1",
            "port": ($port | tonumber)
        }] + [.servers[] | select(type == "object" and .domains != null)])
        | .tag = "dns_inbound"
    ' "$DNS_FILE" > "$tmp_dns" && mv "$tmp_dns" "$DNS_FILE"
    echo "   - dns.json 修改完成 (仅本地MosDNS + 解锁配置已保留)。"
fi
# 11. 重启 XrayR 并检测状态
echo "正在重启 XrayR..."
xrayr restart &> /dev/null || systemctl restart XrayR &> /dev/null

sleep 3
if systemctl is-active --quiet XrayR || systemctl is-active --quiet xrayr; then
    echo "✅ XrayR 已正常启动并对接 MosDNS。"
else
    echo "⚠️ XrayR 启动状态异常，请手动执行 'xrayr log' 查看原因。"
fi

echo "------------------------------------------------"
echo "🎉 所有流程已处理完毕！"
echo "DNS 缓存: 已开启 (3天乐观缓存)"
echo "IPv6 支持: 已开启"
echo "日志清理: 已开启 (2小时强制清理)"
echo "------------------------------------------------"
