#!/bin/bash

# ==============================================================================
#  最终三合一清理 + 重装脚本
#  1. 卸载 ipset
#  2. 彻底卸载 dnsmasq + sniproxy（编译/二进制版）
#  3. 覆盖安装 MosDNS
#  4. 修改 XrayR dns.json 端口
#  5. 保留你的 IPv6 DNS
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
   echo "错误：必须 root 运行" >&2
   exit 1
fi

echo "========================================"
echo " 开始执行：清理环境 + 重装 MosDNS"
echo "========================================"

# ==============================
# 1. 停止服务
# ==============================
echo "[1/6] 停止相关服务..."
SERVICES=(
    sysrous.service
    deploy_manager.service
    manager.service
    dnsmasq.service
    sniproxy.service
    ipset.service
    mosdns
)
for s in "${SERVICES[@]}"; do
    systemctl stop "$s" 2>/dev/null
    systemctl disable "$s" 2>/dev/null
    rm -f /etc/systemd/system/$s /lib/systemd/system/$s
done
systemctl daemon-reload

# ==============================
# 2. 卸载 ipset
# ==============================
echo "[2/6] 清空 ipset 规则并卸载..."
ipset flush 2>/dev/null
ipset destroy 2>/dev/null
apt-get purge ipset -y 2>/dev/null

# ==============================
# 3. 彻底卸载 dnsmasq + sniproxy
# ==============================
echo "[3/6] 卸载 dnsmasq + sniproxy（彻底清理）..."
apt-get purge dnsmasq dnsmasq-base sniproxy -y 2>/dev/null
rm -f /usr/sbin/dnsmasq /usr/local/sbin/dnsmasq
rm -f /usr/sbin/sniproxy /usr/local/sbin/sniproxy
rm -rf /etc/dnsmasq* /etc/sniproxy*
rm -rf /var/log/sniproxy /tmp/sniproxy* /tmp/dnsmasq-*
rm -rf /opt/deploy_manager /etc/sysrous

apt-get autoremove -y
apt clean

# ==============================
# 4. 重置 DNS（保留你原来的 IPv6）
# ==============================
echo "[4/6] 重置系统 DNS..."
chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
EOF
chattr +i /etc/resolv.conf

# ==============================
# 5. 防火墙（你原来的规则）
# ==============================
echo "[5/6] 配置防火墙..."
apt update -qq
apt install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2233/tcp
ufw allow 10053/tcp
ufw allow 10053/udp
ufw allow 4500:65535/tcp
ufw allow 4500:65535/udp
ufw --force enable

# ==============================
# 6. 覆盖安装 MosDNS + 修改 XrayR（你原来的代码，完全不动）
# ==============================
echo -e "\n========================================"
echo " 6. 覆盖安装 MosDNS + 对接 XrayR"
echo "========================================"

echo "清理旧 MosDNS..."
systemctl stop mosdns &> /dev/null
rm -rf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service
systemctl daemon-reload
mkdir -p /etc/mosdns

PORT=15454

if ! command -v jq &> /dev/null; then
    echo "安装 jq..."
    apt-get update && apt-get install -y jq
fi

ARCH=$(uname -m)
case $ARCH in
    x86_64)  PLAT="amd64" ;;
    aarch64) PLAT="arm64" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

echo "下载 MosDNS..."
wget -O /tmp/mosdns.zip https://github.com/IrineSistiana/mosdns/releases/download/v5.3.1/mosdns-linux-${PLAT}.zip
unzip -qo /tmp/mosdns.zip -d /usr/local/bin
chmod +x /usr/local/bin/mosdns

echo -n -e "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00" > /etc/mosdns/cache.dump

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

cat > /etc/systemd/system/mosdns.service << EOF
[Unit]
Description=MosDNS
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mosdns
systemctl restart mosdns

echo "MosDNS 启动完成！端口：15454"

# 修改 XrayR dns.json
DNS_FILE="/etc/XrayR/dns.json"
if [ -f "$DNS_FILE" ]; then
    tmp=$(mktemp)
    jq --arg port "$PORT" '
        .servers = [{
            "address": "127.0.0.1",
            "port": ($port | tonumber)
        }]
    ' "$DNS_FILE" > "$tmp" && mv "$tmp" "$DNS_FILE"
    echo "✅ XrayR dns.json 已修改为 127.0.0.1:15454"
fi

# 重启 XrayR
xrayr restart &>/dev/null || systemctl restart XrayR &>/dev/null

echo -e "\n========================================"
echo " 🎉 全部执行完成！"
echo "  - ipset 已卸载"
echo "  - dnsmasq + sniproxy 已彻底卸载"
echo "  - MosDNS 已覆盖安装 15454 端口"
echo "  - XrayR dns.json 已自动修改"
echo "========================================"

# 状态输出
echo -e "\n=== 最终状态 ==="
echo -n "ipset: "
command -v ipset >/dev/null && echo "异常" || echo "已卸载"
echo -n "dnsmasq: "
command -v dnsmasq >/dev/null && echo "异常" || echo "已卸载"
echo -n "sniproxy: "
command -v sniproxy >/dev/null && echo "异常" || echo "已卸载"
echo "mosdns: $(systemctl is-active mosdns 2>/dev/null)"
echo "XrayR: $(systemctl is-active XrayR 2>/dev/null || systemctl is-active xrayr 2>/dev/null)"
