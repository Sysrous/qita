#!/bin/bash
# dnsmasq → mosdns 迁移脚本 v1.0
# 适用于：已装 dnsmasq + sniproxy 的机器

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] 请使用 root 执行！" && exit 1

echo -e "${yellow}======================================${plain}"
echo -e "${yellow}    dnsmasq → mosdns 迁移脚本 v1.0${plain}"
echo -e "${yellow}======================================${plain}"
echo -e "[${yellow}Warning${plain}] 本脚本将卸载 dnsmasq，安装 mosdns 替代，sniproxy 保持不变"
echo ""
read -p "内部DNS端口（默认 53，回车跳过）: " INTERNAL_PORT
INTERNAL_PORT=${INTERNAL_PORT:-53}
read -p "解锁DNS端口（默认 10053，回车跳过）: " UNLOCK_PORT
UNLOCK_PORT=${UNLOCK_PORT:-10053}
echo ""
echo -e "内部DNS端口 : ${yellow}$INTERNAL_PORT${plain}（仅本机访问）"
echo -e "解锁DNS端口 : ${yellow}$UNLOCK_PORT${plain}（对外开放）"
echo ""
read -p "确认迁移？(y/n): " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "已取消" && exit 0

if [[ -f /etc/redhat-release ]]; then PKG="yum"
elif grep -Eqi "debian|ubuntu|raspbian" /etc/issue || grep -Eqi "debian|ubuntu" /proc/version; then PKG="apt"
else echo -e "[${red}Error${plain}] 不支持的系统！" && exit 1; fi

get_ip() {
    local IP=$(ip addr | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
        | grep -vE '^(192\.168|172\.(1[6-9]|2[0-9]|3[0-2])|10\.|127\.|255\.|0\.)' | head -1)
    [[ -z $IP ]] && IP=$(curl -s -4 --connect-timeout 5 ipv4.icanhazip.com)
    [[ -z $IP ]] && IP=$(curl -s --connect-timeout 5 ipinfo.io/ip)
    echo "$IP"
}

echo -e "[${green}Info${plain}] 检测公网IP..."
publicip=$(get_ip)
[[ -z $publicip ]] && echo -e "[${red}Error${plain}] 无法获取公网IP！" && exit 1
echo -e "[${green}Info${plain}] 公网IP: ${yellow}$publicip${plain}"

# 卸载 dnsmasq
echo -e "[${green}Info${plain}] 停止并卸载 dnsmasq..."
systemctl stop dnsmasq &>/dev/null || true
systemctl disable dnsmasq &>/dev/null || true
mkdir -p /tmp/dnsmasq_backup
[[ -f /etc/dnsmasq.conf ]] && cp /etc/dnsmasq.conf /tmp/dnsmasq_backup/
[[ -d /etc/dnsmasq.d ]] && cp -r /etc/dnsmasq.d /tmp/dnsmasq_backup/
[[ $PKG == "apt" ]] && apt-get remove -y dnsmasq dnsmasq-base > /dev/null 2>&1 || yum remove -y dnsmasq > /dev/null 2>&1 || true
echo -e "[${green}Info${plain}] dnsmasq 已卸载，配置备份至 /tmp/dnsmasq_backup ✅"

# 清理旧 mosdns
systemctl stop mosdns &>/dev/null || true
if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved && systemctl disable systemd-resolved
fi
rm -rf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service
systemctl daemon-reload
mkdir -p /etc/mosdns

for dep in curl wget unzip; do
    command -v $dep &>/dev/null || { [[ $PKG == "apt" ]] && apt-get install -y $dep > /dev/null 2>&1 || yum install -y $dep > /dev/null 2>&1; }
done

ARCH=$(uname -m)
case $ARCH in
    x86_64)  PLAT="amd64" ;;
    aarch64) PLAT="arm64" ;;
    armv7l)  PLAT="arm-7" ;;
    *) echo -e "[${red}Error${plain}] 不支持的架构" && exit 1 ;;
esac

MOSDNS_VER="v5.3.1"
echo -e "[${green}Info${plain}] 下载 MosDNS $MOSDNS_VER ($PLAT)..."
wget -q -O /tmp/mosdns.zip "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-${PLAT}.zip"
unzip -qo /tmp/mosdns.zip -d /usr/local/bin
chmod +x /usr/local/bin/mosdns
rm -f /tmp/mosdns.zip
echo -e "[${green}Info${plain}] MosDNS 安装完成！"

# 域名列表：优先复用旧 dnsmasq 配置
echo -e "[${green}Info${plain}] 处理流媒体域名列表..."
: > /etc/mosdns/unlock-domains.txt
SRC=""
[[ -f /etc/dnsmasq.d/custom_netflix.conf ]] && SRC="/etc/dnsmasq.d/custom_netflix.conf"
[[ -z $SRC && -f /tmp/dnsmasq_backup/dnsmasq.d/custom_netflix.conf ]] && SRC="/tmp/dnsmasq_backup/dnsmasq.d/custom_netflix.conf"

if [[ -n $SRC ]]; then
    echo -e "[${green}Info${plain}] 从旧 dnsmasq 配置提取域名..."
    grep '^address=' "$SRC" | sed 's|address=/\(.*\)/.*|\1|' | while read domain; do
        echo "domain:${domain}" >> /etc/mosdns/unlock-domains.txt
    done
fi

if [[ ! -s /etc/mosdns/unlock-domains.txt ]]; then
    echo -e "[${yellow}Warning${plain}] 旧配置不可用，重新下载域名列表..."
    wget -q -O /tmp/proxy-domains.txt "https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/proxy-domains.txt"
    while IFS= read -r domain; do
        [[ -z "$domain" || "$domain" == \#* ]] && continue
        echo "domain:${domain}" >> /etc/mosdns/unlock-domains.txt
    done < /tmp/proxy-domains.txt
    rm -f /tmp/proxy-domains.txt
fi

DOMAIN_COUNT=$(wc -l < /etc/mosdns/unlock-domains.txt)
echo -e "[${green}Info${plain}] 共加载 ${yellow}$DOMAIN_COUNT${plain} 条流媒体域名"

printf '\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00' > /etc/mosdns/cache.dump

cat > /etc/mosdns/config.yaml << EOF
log:
  level: error

plugins:
  - tag: cache
    type: cache
    args:
      size: 20480
      lazy_cache_ttl: 259200
      dump_file: /etc/mosdns/cache.dump
      dump_interval: 600

  - tag: unlock_domains
    type: domain_set
    args:
      files:
        - /etc/mosdns/unlock-domains.txt

  - tag: forward_normal
    type: forward
    args:
      concurrent: 3
      upstreams:
        - addr: "https://8.8.8.8/dns-query"
        - addr: "https://1.1.1.1/dns-query"
        - addr: "8.8.8.8"
        - addr: "1.1.1.1"

  - tag: set_unlock_ip
    type: sequence
    args:
      - exec: set_resp_ip $publicip

  - tag: sequence_unlock
    type: sequence
    args:
      - exec: \$cache
      - matches: has_resp
        exec: accept
      - matches: qtype 28
        exec: reject 3
      - matches: "qname \$unlock_domains"
        exec: \$set_unlock_ip
      - matches: has_resp
        exec: accept
      - exec: \$forward_normal
      - exec: \$cache

  - tag: sequence_internal
    type: sequence
    args:
      - exec: \$cache
      - matches: has_resp
        exec: accept
      - exec: \$forward_normal
      - exec: \$cache

  - tag: udp_server_internal
    type: udp_server
    args:
      entry: sequence_internal
      listen: "127.0.0.1:${INTERNAL_PORT}"

  - tag: tcp_server_internal
    type: tcp_server
    args:
      entry: sequence_internal
      listen: "127.0.0.1:${INTERNAL_PORT}"

  - tag: udp_server_unlock
    type: udp_server
    args:
      entry: sequence_unlock
      listen: "0.0.0.0:${UNLOCK_PORT}"

  - tag: tcp_server_unlock
    type: tcp_server
    args:
      entry: sequence_unlock
      listen: "0.0.0.0:${UNLOCK_PORT}"
EOF

# 更新 sniproxy（去掉80端口）
if command -v sniproxy &>/dev/null || [[ -f /etc/sniproxy.conf ]]; then
    echo -e "[${green}Info${plain}] 更新 sniproxy 配置（仅保留443）..."
    cat > /etc/sniproxy.conf << 'SNIEOF'
user daemon
pidfile /var/run/sniproxy.pid
error_log {
    syslog daemon
    priority notice
}
listen 443 {
    proto tls
    table https_hosts
}
table https_hosts {
    .* *:443
}
SNIEOF
    systemctl restart sniproxy &>/dev/null || true
    echo -e "[${green}Info${plain}] sniproxy 配置已更新 ✅"
else
    echo -e "[${yellow}Warning${plain}] 未检测到 sniproxy，跳过"
fi

cat > /etc/systemd/system/mosdns.service << 'SVCEOF'
[Unit]
Description=MosDNS
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
SVCEOF

echo -e "[${green}Info${plain}] 修改系统DNS → 127.0.0.1..."
[[ -f /etc/resolv.conf ]] && cp /etc/resolv.conf /tmp/resolv.conf.backup
chattr -i /etc/resolv.conf &>/dev/null || true
rm -f /etc/resolv.conf
echo 'nameserver 127.0.0.1' > /etc/resolv.conf
chattr +i /etc/resolv.conf

systemctl daemon-reload && systemctl enable mosdns && systemctl restart mosdns
sleep 2
ss -ulpn | grep -qE ":($INTERNAL_PORT|$UNLOCK_PORT) " && echo -e "[${green}Info${plain}] MosDNS 端口监听正常 ✅" || { echo -e "[${red}Error${plain}] 启动异常！journalctl -u mosdns -n 30"; exit 1; }

config_fw() {
    local port=$1
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=${port}/tcp &>/dev/null
        firewall-cmd --permanent --add-port=${port}/udp &>/dev/null
        firewall-cmd --reload &>/dev/null
    elif command -v ufw &>/dev/null && ufw status | grep -q active; then
        ufw allow ${port}/tcp &>/dev/null; ufw allow ${port}/udp &>/dev/null
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport ${port} -j ACCEPT &>/dev/null || true
        iptables -I INPUT -p udp --dport ${port} -j ACCEPT &>/dev/null || true
    fi
}
config_fw $UNLOCK_PORT
config_fw 443

echo ""
echo -e "${green}================================================${plain}"
echo -e "${green}  🎉 迁移完成！dnsmasq → mosdns${plain}"
echo -e "${green}================================================${plain}"
echo -e " 公网IP      : ${yellow}$publicip${plain}"
echo -e " 内部DNS     : ${yellow}127.0.0.1:$INTERNAL_PORT${plain}（仅本机）"
echo -e " 解锁DNS     : ${yellow}0.0.0.0:$UNLOCK_PORT${plain}（对外开放）"
echo -e " sniproxy    : ${yellow}443${plain}（SNI透明转发）"
echo -e " 流媒体域名  : ${yellow}$DOMAIN_COUNT${plain} 条"
echo -e " dnsmasq备份 : ${yellow}/tmp/dnsmasq_backup${plain}"
echo -e "${green}================================================${plain}"
echo -e "  dig @$publicip -p $UNLOCK_PORT netflix.com  # 应返回 $publicip"
echo -e "  dig @127.0.0.1 -p $INTERNAL_PORT baidu.com  # 应返回真实IP"
