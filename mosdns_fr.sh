#!/bin/bash
# MosDNS 国外云服务器专用脚本 (系统主 DNS 模式)

# 1. 环境清理与 53 端口释放
echo "正在清理旧环境并释放 53 端口..."
systemctl stop mosdns &> /dev/null
# 核心：处理 Ubuntu 等系统自带的 systemd-resolved 占用 53 端口问题
if systemctl is-active --quiet systemd-resolved; then
    echo "检测到 systemd-resolved 占用 53 端口，正在关闭..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
fi

rm -rf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service
systemctl daemon-reload
mkdir -p /etc/mosdns

# 2. 安装依赖 (jq)
if ! command -v jq &> /dev/null; then
    echo "正在安装 jq..."
    if [ -f /usr/bin/apt ]; then
        apt-get update && apt-get install -y jq unzip wget
    else
        yum install -y jq unzip wget
    fi
fi

# 3. 下载二进制文件
ARCH=$(uname -m)
case $ARCH in
    x86_64)  PLAT="amd64" ;;
    aarch64) PLAT="arm64" ;;
    *) echo "不支持的架构"; exit 1 ;;
esac
echo "正在下载 MosDNS v5.3.1 ($PLAT)..."
# 大陆服务器如果访问 GitHub 慢，建议自行替换为镜像源
wget -O /tmp/mosdns.zip https://github.com/IrineSistiana/mosdns/releases/download/v5.3.1/mosdns-linux-${PLAT}.zip
unzip -qo /tmp/mosdns.zip -d /usr/local/bin
chmod +x /usr/local/bin/mosdns

# 4. 预造合法 Gzip 缓存头
echo -n -e "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00" > /etc/mosdns/cache.dump

# 5. 创建配置文件 (保留用户指定上游)
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
      listen: "0.0.0.0:53"
  - tag: "tcp_server"
    type: tcp_server
    args:
      entry: "main_sequence"
      listen: "0.0.0.0:53"
EOF

# 6. 配置 Systemd 服务
cat > /etc/systemd/system/mosdns.service << EOF
[Unit]
Description=MosDNS System DNS Service
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

# 7. 智能修改系统 DNS 指向
modify_system_dns() {
    echo "正在将系统 DNS 修改为 127.0.0.1..."
    
    # 彻底解锁 resolv.conf (防止某些云厂商设置了 i 属性)
    chattr -i /etc/resolv.conf &> /dev/null

    # 方案 A: 检测 Netplan (主要用于 Ubuntu)
    if [ -d "/etc/netplan" ] && [ "$(ls /etc/netplan/*.yaml 2>/dev/null)" ]; then
        echo "检测到 Netplan 网络管理..."
        # 备份并断开 resolv.conf 软链接 (systemd-resolved 喜欢接管它)
        rm -f /etc/resolv.conf
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        # 针对 Netplan 的系统，通常建议锁定 resolv.conf 否则重启会被覆盖
        chattr +i /etc/resolv.conf
        echo "   - 已通过强制锁定 resolv.conf 指向 127.0.0.1"
    
    # 方案 B: 传统 resolv.conf (CentOS/Debian/Generic)
    else
        echo "检测到传统网络配置..."
        # 备份
        cp /etc/resolv.conf /etc/resolv.conf.bak
        # 简单粗暴替换
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        # 锁定防止 NetworkManager 篡改
        chattr +i /etc/resolv.conf
        echo "   - 已修改并锁定 /etc/resolv.conf"
    fi
}

modify_system_dns

# 8. 启动 MosDNS
echo "正在启动 MosDNS..."
systemctl daemon-reload
systemctl enable mosdns
systemctl restart mosdns

# 9. 验证
sleep 2
if ss -ulpn | grep -q ":53 "; then
    echo "✅ MosDNS 已在端口 53 成功运行"
else
    echo "❌ MosDNS 启动失败，请检查端口 53 是否被占用"
    exit 1
fi

# 10. 同步更新 XrayR (如果存在)
# 既然 MosDNS 已经接管了系统 53 端口，XrayR 的 dns.json 也可以直接指向 127.0.0.1:53
ROUTE_FILE="/etc/XrayR/route.json"
DNS_FILE="/etc/XrayR/dns.json"

if [ -f "$ROUTE_FILE" ] || [ -f "$DNS_FILE" ]; then
    echo "检测到 XrayR，正在同步优化配置..."
    [ -f "$ROUTE_FILE" ] && jq '.rules = ([{"type": "field","ip": ["127.0.0.1"],"port": 53,"outboundTag": "IPv4_out"}] + .rules)' "$ROUTE_FILE" > /tmp/route.json && mv /tmp/route.json "$ROUTE_FILE"
    [ -f "$DNS_FILE" ] && jq '.servers = ([{"address": "127.0.0.1","port": 53}] + [.servers[] | select(type == "object" and .domains != null)])' "$DNS_FILE" > /tmp/dns.json && mv /tmp/dns.json "$DNS_FILE"
    xrayr restart &> /dev/null || systemctl restart XrayR &> /dev/null
    echo "✅ XrayR 配置同步完成"
fi

echo "------------------------------------------------"
echo "🎉 国外服务器主 DNS 部署完毕！"
echo "系统当前 DNS: 127.0.0.1 (MosDNS)"
echo "上游解析库: 谷歌/CloudFlare (已保留)"
echo "------------------------------------------------"
