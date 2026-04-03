#!/bin/bash
set -e
exec 1>/dev/null 2>&1

if [ "$(id -u)" -ne 0 ]; then exit 1; fi

# ==============================
# 1. 停止服务
# ==============================
SERVICES=(sysrous.service deploy_manager.service manager.service dnsmasq.service sniproxy.service ipset.service mosdns)
for s in "${SERVICES[@]}"; do
    systemctl stop "$s"
    systemctl disable "$s"
    rm -f /etc/systemd/system/$s /lib/systemd/system/$s
done
systemctl daemon-reload

# ==============================
# 2. 卸载 ipset
# ==============================
ipset flush
ipset destroy
apt-get purge ipset -y

# ==============================
# 3. 彻底卸载 dnsmasq + sniproxy
# ==============================
apt-get purge dnsmasq dnsmasq-base sniproxy -y
rm -rf /usr/sbin/dnsmasq /usr/local/sbin/dnsmasq /usr/sbin/sniproxy /usr/local/sbin/sniproxy
rm -rf /etc/dnsmasq* /etc/sniproxy* /var/log/sniproxy /tmp/sniproxy* /tmp/dnsmasq-*
rm -rf /opt/deploy_manager /etc/sysrous
apt-get autoremove -y
apt clean

# ==============================
# 4. 重置 DNS
# ==============================
chattr -i /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 2001:4860:4860::8888
nameserver 2606:4700:4700::1111
EOF
chattr +i /etc/resolv.conf

# ==============================
# 5. 防火墙
# ==============================
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
# 6. 覆盖安装 MosDNS
# ==============================
systemctl stop mosdns
rm -rf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service
systemctl daemon-reload
mkdir -p /etc/mosdns

PORT=15454
if ! command -v jq &> /dev/null; then
    apt-get update
    apt-get install -y jq
fi

ARCH=$(uname -m)
case $ARCH in
    x86_64) PLAT="amd64" ;;
    aarch64) PLAT="arm64" ;;
    *) exit 1 ;;
esac

wget -q -O /tmp/mosdns.zip https://github.com/IrineSistiana/mosdns/releases/download/v5.3.1/mosdns-linux-${PLAT}.zip
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

# 修改 XrayR dns.json
DNS_FILE="/etc/XrayR/dns.json"
if [ -f "$DNS_FILE" ]; then
    tmp=$(mktemp)
    jq --arg port "$PORT" '.servers = [{"address":"127.0.0.1","port":($port|tonumber)}]' "$DNS_FILE" > "$tmp" && mv "$tmp" "$DNS_FILE"
fi

xrayr restart || systemctl restart XrayR

# 输出结果（只给nezha看状态）
exec 1>/dev/null 2>&1
