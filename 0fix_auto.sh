#!/bin/bash

echo "========================================"
echo " 开始执行：清理环境 + 重装 MosDNS"
echo "========================================"

# 1. 停止服务
echo "[1/6] 停止相关服务..."
SERVICES=(
    sysrous.service deploy_manager.service manager.service
    dnsmasq.service sniproxy.service ipset.service mosdns
)
for s in "${SERVICES[@]}"; do
    systemctl stop "$s" 2>/dev/null
    systemctl disable "$s" 2>/dev/null
    rm -f /etc/systemd/system/$s /lib/systemd/system/$s 2>/dev/null
done
systemctl daemon-reload 2>/dev/null

# 2. 彻底卸载 ipset
echo "[2/6] 清空 ipset 规则并彻底卸载..."
ipset flush 2>/dev/null
ipset destroy 2>/dev/null
apt-get remove --purge ipset -y 2>/dev/null
apt-get autoremove --purge -y 2>/dev/null
rm -f /usr/sbin/ipset /sbin/ipset /usr/local/sbin/ipset 2>/dev/null
hash -r 2>/dev/null

# 3. 卸载 dnsmasq + sniproxy
echo "[3/6] 卸载 dnsmasq + sniproxy（彻底清理）..."
apt-get purge dnsmasq dnsmasq-base sniproxy -y 2>/dev/null
rm -rf \
    /usr/sbin/dnsmasq /usr/local/sbin/dnsmasq \
    /usr/sbin/sniproxy /usr/local/sbin/sniproxy \
    /etc/dnsmasq* /etc/sniproxy* /var/log/sniproxy \
    /tmp/sniproxy* /tmp/dnsmasq-* \
    /opt/deploy_manager /etc/sysrous 2>/dev/null

apt-get autoremove -y 2>/dev/null
apt clean 2>/dev/null

# 4. 重置 DNS
echo "[4/6] 重置系统 DNS..."
chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
EOF
chattr +i /etc/resolv.conf 2>/dev/null

# 5. 防火墙
echo "[5/6] 配置防火墙..."
apt update -qq 2>/dev/null
apt install ufw -y 2>/dev/null
ufw default deny incoming 2>/dev/null
ufw default allow outgoing 2>/dev/null
ufw allow 22/tcp 2>/dev/null
ufw allow 80/tcp 2>/dev/null
ufw allow 443/tcp 2>/dev/null
ufw allow 2233/tcp 2>/dev/null
ufw allow 10053/tcp 2>/dev/null
ufw allow 10053/udp 2>/dev/null
ufw allow 4500:65535/tcp 2>/dev/null
ufw allow 4500:65535/udp 2>/dev/null
ufw --force enable 2>/dev/null

# 6. 安装 MosDNS
echo "[6/6] 覆盖安装 MosDNS + 对接 XrayR..."

systemctl stop mosdns 2>/dev/null
rm -rf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service 2>/dev/null
systemctl daemon-reload 2>/dev/null
mkdir -p /etc/mosdns 2>/dev/null

PORT=15454

if ! command -v jq &>/dev/null; then
    apt-get update -y 2>/dev/null
    apt-get install -y jq 2>/dev/null
fi

ARCH=$(uname -m)
case $ARCH in
    x86_64)  PLAT="amd64" ;;
    aarch64) PLAT="arm64" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

wget -q -O /tmp/mosdns.zip https://github.com/IrineSistiana/mosdns/releases/download/v5.3.1/mosdns-linux-${PLAT}.zip 2>/dev/null
unzip -qo /tmp/mosdns.zip -d /usr/local/bin 2>/dev/null
chmod +x /usr/local/bin/mosdns 2>/dev/null

echo -n -e "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00" > /etc/mosdns/cache.dump 2>/dev/null

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

sed -i "s/DNS_PORT/$PORT/g" /etc/mosdns/config.yaml 2>/dev/null

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

systemctl daemon-reload 2>/dev/null
systemctl enable mosdns 2>/dev/null
systemctl restart mosdns 2>/dev/null

DNS_FILE="/etc/XrayR/dns.json"
if [ -f "$DNS_FILE" ]; then
    tmp=$(mktemp)
    jq --arg port "$PORT" '.servers = [{"address":"127.0.0.1","port":($port|tonumber)}]' "$DNS_FILE" > "$tmp" && mv "$tmp" "$DNS_FILE" 2>/dev/null
fi

xrayr restart 2>/dev/null || systemctl restart XrayR 2>/dev/null

echo ""
echo "========================================"
echo "🎉 全部执行完成！"
echo "========================================"
echo ""
echo "=== 最终状态 ==="

if command -v ipset >/dev/null 2>&1; then
    echo "ipset: 未卸载（异常）"
else
    echo "ipset: 已卸载（正常）"
fi

if command -v dnsmasq >/dev/null 2>&1; then
    echo "dnsmasq: 未卸载（异常）"
else
    echo "dnsmasq: 已卸载（正常）"
fi

if command -v sniproxy >/dev/null 2>&1; then
    echo "sniproxy: 未卸载（异常）"
else
    echo "sniproxy: 已卸载（正常）"
fi

mosdns_status=$(systemctl is-active mosdns 2>/dev/null)
if [ "$mosdns_status" = "active" ]; then
    echo "mosdns: active (正常)"
else
    echo "mosdns: inactive (异常)"
fi

xrayr_status=$(systemctl is-active XrayR 2>/dev/null || systemctl is-active xrayr 2>/dev/null)
if [ "$xrayr_status" = "active" ]; then
    echo "XrayR: active (正常)"
else
    echo "XrayR: inactive (异常)"
fi
