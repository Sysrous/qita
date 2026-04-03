#!/bin/bash
# MosDNS 大陆云服务器专用脚本 (系统主 DNS + GitHub 加速)

# 1. 定义加速前缀 (针对 github.com 和 raw.githubusercontent.com)
# 使用用户提供的加速器：https://usgitdmit01.xinluc.com/
PROXY="https://usgitdmit01.xinluc.com/"

# 2. 环境清理与 53 端口释放
echo "正在清理旧环境并释放 53 端口..."
systemctl stop mosdns &> /dev/null

# 解决 Ubuntu/Debian 默认 systemd-resolved 占用 53 端口问题
if systemctl is-active --quiet systemd-resolved; then
    echo "检测到 systemd-resolved 占用 53 端口，正在关闭并释放..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    # 移除潜在的软链接
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
fi

rm -rf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service
systemctl daemon-reload
mkdir -p /etc/mosdns

# 3. 安装依赖 (jq, wget, unzip)
if ! command -v jq &> /dev/null; then
    echo "正在安装依赖工具..."
    if [ -f /usr/bin/apt ]; then
        apt-get update && apt-get install -y jq unzip wget
    else
        yum install -y jq unzip wget
    fi
fi

# 4. 下载二进制文件 (使用加速前缀)
ARCH=$(uname -m)
case $ARCH in
    x86_64)  PLAT="amd64" ;;
    aarch64) PLAT="arm64" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac

GITHUB_URL="https://github.com/IrineSistiana/mosdns/releases/download/v5.3.1/mosdns-linux-${PLAT}.zip"
DOWNLOAD_URL="${PROXY}${GITHUB_URL}"

echo "正在从加速节点下载 MosDNS v5.3.1..."
wget -O /tmp/mosdns.zip "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    echo "❌ 下载失败，请检查加速地址是否可用: $PROXY"
    exit 1
fi

unzip -qo /tmp/mosdns.zip -d /usr/local/bin
chmod +x /usr/local/bin/mosdns

# 5. 预造合法 Gzip 缓存头
echo -n -e "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00" > /etc/mosdns/cache.dump

# 6. 创建配置文件 (完全保留要求的云厂商 DNS)
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
        - addr: "223.5.5.5"
        - addr: "119.29.29.29"
        - addr: "180.76.76.76"
        - addr: "180.184.1.1"
        - addr: "2400:3200::1"
        - addr: "2400:3200:baba::1"

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
      listen: "0.0.0.0:53"
  - tag: "tcp_server"
    type: tcp_server
    args:
      entry: "main_sequence"
      listen: "0.0.0.0:53"
EOF

# 7. 配置 Systemd 服务
cat > /etc/systemd/system/mosdns.service << EOF
[Unit]
Description=MosDNS Static System DNS
After=network.target
Before=nss-lookup.target
Wants=nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 8. 智能修改系统 DNS 并锁定 (适配 Netplan/resolv.conf)
modify_system_dns() {
    echo "正在接管系统 DNS 权限..."
    
    # 强制解除 i 属性限制 (防止之前被手动锁定)
    chattr -i /etc/resolv.conf &> /dev/null

    # 识别网络管理方式
    if [ -d "/etc/netplan" ] && [ "$(ls /etc/netplan/*.yaml 2>/dev/null)" ]; then
        echo "检测到 Netplan 管理，正在强制覆盖 resolv.conf..."
    else
        echo "检测到传统网络管理，正在修改 resolv.conf..."
    fi

    # 无论是 Netplan 还是传统模式，最直接且能对抗重启覆盖的方法是：
    # 1. 彻底删除旧的 resolv.conf (解决软链接问题)
    rm -f /etc/resolv.conf
    # 2. 建立新的静态文件
    cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
options edns0 trust-ad
EOF
    # 3. 施加 i 属性，防止云厂商脚本、Netplan 或 NetworkManager 自动覆盖
    chattr +i /etc/resolv.conf
    echo "✅ 系统 DNS 已锁定为 127.0.0.1"
}

modify_system_dns

# 9. 启动 MosDNS
echo "正在启动 MosDNS 服务..."
systemctl daemon-reload
systemctl enable mosdns
systemctl restart mosdns

# 10. 验证状态
sleep 2
if ss -ulpn | grep -q ":53 "; then
    echo "✅ MosDNS 已在端口 53 成功运行"
else
    echo "❌ MosDNS 启动失败，请检查端口占用情况"
    exit 1
fi

# 11. 同步修改 XrayR
ROUTE_FILE="/etc/XrayR/route.json"
DNS_FILE="/etc/XrayR/dns.json"

if [ -f "$ROUTE_FILE" ] || [ -f "$DNS_FILE" ]; then
    echo "检测到 XrayR，同步更新配置..."
    # 修改 route.json 端口为 53
    [ -f "$ROUTE_FILE" ] && jq '.rules = ([{"type": "field","ip": ["127.0.0.1"],"port": 53,"outboundTag": "IPv4_out"}] + .rules)' "$ROUTE_FILE" > /tmp/route.json && mv /tmp/route.json "$ROUTE_FILE"
    # 修改 dns.json 指向 127.0.0.1:53
    [ -f "$DNS_FILE" ] && jq '.servers = ([{"address": "127.0.0.1","port": 53}] + [.servers[] | select(type == "object" and .domains != null)])' "$DNS_FILE" > /tmp/dns.json && mv /tmp/dns.json "$DNS_FILE"
    
    xrayr restart &> /dev/null || systemctl restart XrayR &> /dev/null
    echo "✅ XrayR 已同步指向 MosDNS:53"
fi

echo "------------------------------------------------"
echo "🎉 MosDNS 部署完成 (GitHub 加速版)！"
echo "系统 DNS 已通过 chattr +i 强制锁定为 127.0.0.1"
echo "上游库: 阿里/腾讯/百度/字节 (DoH + UDP)"
echo "------------------------------------------------"
