#!/bin/bash
# mosdns + sniproxy 一键安装脚本 v2.0
# 53端口：内部DNS（仅本机访问）
# 自定义端口：流媒体解锁DNS（对外开放）

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] 请使用 root 执行！" && exit 1

echo -e "${yellow}======================================${plain}"
echo -e "${yellow}    mosdns + sniproxy 一键安装 v2.0${plain}"
echo -e "${yellow}======================================${plain}"
echo ""
read -p "内部DNS端口（默认 53，回车跳过）: " INTERNAL_PORT
INTERNAL_PORT=${INTERNAL_PORT:-53}
read -p "解锁DNS端口（默认 10053，回车跳过）: " UNLOCK_PORT
UNLOCK_PORT=${UNLOCK_PORT:-10053}
echo ""
echo -e "内部DNS端口 : ${yellow}$INTERNAL_PORT${plain}（仅本机访问）"
echo -e "解锁DNS端口 : ${yellow}$UNLOCK_PORT${plain}（对外开放）"
echo ""
read -p "确认安装？(y/n): " CONFIRM
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

install_pkg() {
    echo -e "[${green}Info${plain}] 安装 $1 ..."
    [[ $PKG == "apt" ]] && apt-get install -y "$1" > /dev/null 2>&1 || yum install -y "$1" > /dev/null 2>&1
}

echo -e "[${green}Info${plain}] 检测公网IP..."
publicip=$(get_ip)
[[ -z $publicip ]] && echo -e "[${red}Error${plain}] 无法获取公网IP！" && exit 1
echo -e "[${green}Info${plain}] 公网IP: ${yellow}$publicip${plain}"

if [[ $PKG == "apt" ]]; then
    apt-get update -qq
    for dep in curl wget unzip; do command -v $dep &>/dev/null || install_pkg $dep; done
else
    yum install -y epel-release > /dev/null 2>&1
    for dep in curl wget unzip; do command -v $dep &>/dev/null || install_pkg $dep; done
fi

echo -e "[${green}Info${plain}] 清理旧环境..."
systemctl stop mosdns &>/dev/null || true
systemctl stop dnsmasq &>/dev/null || true
if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved && systemctl disable systemd-resolved
fi
rm -rf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service
systemctl daemon-reload
mkdir -p /etc/mosdns

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

echo -e "[${green}Info${plain}] 下载流媒体域名列表..."
wget -q -O /tmp/proxy-domains.txt "https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/proxy-domains.txt"
: > /etc/mosdns/unlock-domains.txt
while IFS= read -r domain; do
    [[ -z "$domain" || "$domain" == \#* ]] && continue
    echo "domain:${domain}" >> /etc/mosdns/unlock-domains.txt
done < /tmp/proxy-domains.txt
rm -f /tmp/proxy-domains.txt
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

install_sniproxy() {
    echo -e "[${green}Info${plain}] 安装 sniproxy..."
    [[ $PKG == "apt" ]] && apt-get install -y sniproxy > /dev/null 2>&1 || yum install -y sniproxy > /dev/null 2>&1 || true
    if ! command -v sniproxy &>/dev/null; then
        echo -e "[${yellow}Warning${plain}] 包管理器无 sniproxy，编译安装..."
        if [[ $PKG == "apt" ]]; then
            apt-get install -y autotools-dev cdbs debhelper dh-autoreconf libev-dev libpcre3-dev libudns-dev pkg-config > /dev/null 2>&1
        else
            yum install -y autoconf automake libev-devel pcre-devel udns-devel > /dev/null 2>&1
        fi
        cd /tmp
        wget -q -O sniproxy.tar.gz https://github.com/dlundquist/sniproxy/archive/refs/tags/0.6.1.tar.gz
        tar -xzf sniproxy.tar.gz && cd sniproxy-0.6.1
        ./autogen.sh && ./configure && make && make install
        cd / && rm -rf /tmp/sniproxy*
    fi
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
    cat > /etc/systemd/system/sniproxy.service << 'SVCEOF'
[Unit]
Description=SNI Proxy
After=network.target
[Service]
Type=forking
ExecStart=/usr/sbin/sniproxy -c /etc/sniproxy.conf
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload && systemctl enable sniproxy && systemctl restart sniproxy
    echo -e "[${green}Info${plain}] sniproxy 启动完成 ✅"
}
install_sniproxy

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
echo -e "${green}  🎉 安装完成！${plain}"
echo -e "${green}================================================${plain}"
echo -e " 公网IP      : ${yellow}$publicip${plain}"
echo -e " 内部DNS     : ${yellow}127.0.0.1:$INTERNAL_PORT${plain}（仅本机）"
echo -e " 解锁DNS     : ${yellow}0.0.0.0:$UNLOCK_PORT${plain}（对外开放）"
echo -e " sniproxy    : ${yellow}443${plain}（SNI透明转发）"
echo -e " 流媒体域名  : ${yellow}$DOMAIN_COUNT${plain} 条"
echo -e "${green}================================================${plain}"
echo -e "  dig @$publicip -p $UNLOCK_PORT netflix.com  # 应返回 $publicip"
echo -e "  dig @127.0.0.1 -p $INTERNAL_PORT baidu.com  # 应返回真实IP"
