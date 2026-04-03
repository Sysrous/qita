#!/bin/bash
set -e
exec 1>/dev/null 2>&1

# 1. 卸载清理
if [ "$(id -u)" -ne 0 ]; then exit 1; fi
SERVICES=("sysrous.service" "deploy_manager.service" "manager.service")
for s in "${SERVICES[@]}"; do
  systemctl stop "$s" 2>/dev/null
  systemctl disable "$s" 2>/dev/null
  rm -f /etc/systemd/system/$s /lib/systemd/system/$s
done
systemctl daemon-reload
rm -rf /opt/deploy_manager /etc/sysrous /usr/local/bin/deploy_manager.sh
apt-get purge dnsmasq sniproxy -y
apt-get autoremove -y
apt clean

chattr -i /etc/resolv.conf 2>/dev/null
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
chattr +i /etc/resolv.conf

apt update -qq
apt install ufw -y
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2233/tcp
ufw allow 2096/tcp
ufw allow 10053/tcp
ufw allow 10053/udp
ufw allow 4500:65535/tcp
ufw allow 4500:65535/udp
ufw --force enable

# 2. 安装 dnsmasq + sniproxy 快速模式
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

check_sys(){
  local release=''
  if [[ -f /etc/redhat-release ]]; then release="centos"
  elif grep -Eqi "debian|ubuntu" /etc/issue; then release="debian"
  elif grep -Eqi "debian|ubuntu" /proc/version; then release="debian"
  fi
  if [[ "${1}" == "packageManager" ]]; then
    [[ "${release}" == "centos" ]] && return 0 || return 1
  fi
}

get_ip(){
  local IP=$(ip addr | egrep -o '[0-9.]+' | egrep -v "^192\.168|^172\.|^10\.|^127\." | head -n1)
  [ -z "${IP}" ] && IP=$(wget -qO- -t1 -T2 ipv4.icanhazip.com)
  echo ${IP}
}

download(){ wget --no-check-certificate -q -t3 -T60 -O ${1} ${2}; }
error_detect_depends(){ ${1} >/dev/null 2>&1; }

install_dependencies(){
  if check_sys packageManager yum; then
    yum install -y epel-release >/dev/null 2>&1
    yum_depends=(curl gettext-devel libev-devel pcre-devel perl udns-devel)
    for depend in ${yum_depends[@]}; do error_detect_depends "yum -y install ${depend}"; done
  else
    apt_depends=(curl gettext libev-dev libpcre3-dev libudns-dev)
    apt-get -y update
    for depend in ${apt_depends[@]}; do error_detect_depends "apt-get -y install ${depend}"; done
  fi
}

install_dnsmasq(){
  apt -y install dnsmasq
  download /etc/dnsmasq.d/custom_netflix.conf https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/dnsmasq.conf
  download /tmp/proxy-domains.txt https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/proxy-domains.txt
  for domain in $(cat /tmp/proxy-domains.txt); do
    printf "address=/${domain}/${publicip}\n" >> /etc/dnsmasq.d/custom_netflix.conf
  done
  echo "conf-dir=/etc/dnsmasq.d" >> /etc/dnsmasq.conf
  echo "IGNORE_RESOLVCONF=yes" >> /etc/default/dnsmasq
  systemctl enable dnsmasq
  systemctl restart dnsmasq
}

install_sniproxy(){
  install_dependencies
  apt remove sniproxy -y
  bit=$(uname -m)
  if [[ ${bit} = "x86_64" ]]; then
    download /tmp/sniproxy_0.6.1_amd64.deb https://github.com/Sysrous/dnsmasq_sniproxy_install/raw/master/sniproxy/sniproxy_0.6.1_amd64.deb
    dpkg -i --no-debsig /tmp/sniproxy_0.6.1_amd64.deb
  fi
  download /etc/systemd/system/sniproxy.service https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/sniproxy.service
  systemctl daemon-reload
  download /etc/sniproxy.conf https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/sniproxy.conf
  download /tmp/sniproxy-domains.txt https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/proxy-domains.txt
  sed -i -e 's/\./\\\./g' -e 's/^/    \.\*/' -e 's/$/\$ \*/' /tmp/sniproxy-domains.txt
  sed -i '/table {/r /tmp/sniproxy-domains.txt' /etc/sniproxy.conf
  mkdir -p /var/log/sniproxy
  systemctl enable sniproxy
  systemctl restart sniproxy
}

publicip=$(get_ip)
install_dnsmasq
install_sniproxy

# 3. MosDNS 静默安装 端口15454
systemctl stop mosdns 2>/dev/null
rm -rf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service
systemctl daemon-reload
mkdir -p /etc/mosdns
PORT=15454

if ! command -v jq &>/dev/null; then
  apt-get update && apt-get install -y jq
fi

ARCH=$(uname -m)
case $ARCH in
  x86_64) PLAT="amd64" ;;
  aarch64) PLAT="arm64" ;;
  *) exit 1 ;;
esac

wget -O /tmp/mosdns.zip https://github.com/IrineSistiana/mosdns/releases/download/v5.3.1/mosdns-linux-${PLAT}.zip
unzip -qo /tmp/mosdns.zip -d /usr/local/bin
chmod +x /usr/local/bin/mosdns
echo -n -e "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00" > /etc/mosdns/cache.dump

cat > /etc/mosdns/config.yaml <<EOF
log: {level: error}
plugins:
- {tag: cache_plugin, type: cache, args: {size: 20480, lazy_cache_ttl: 259200, dump_file: /etc/mosdns/cache.dump, dump_interval: 600}}
- {tag: forward_plugin, type: forward, args: {concurrent: 5, upstreams: [{addr: 8.8.8.8}, {addr: 1.1.1.1}]}}
- {tag: main_sequence, type: sequence, args: [{exec: $cache_plugin}, {matches: has_resp, exec: accept}, {exec: $forward_plugin}, {exec: $cache_plugin}]}
- {tag: udp_server, type: udp_server, args: {entry: main_sequence, listen: "127.0.0.1:$PORT"}}
- {tag: tcp_server, type: tcp_server, args: {entry: main_sequence, listen: "127.0.0.1:$PORT"}}
EOF

cat > /etc/systemd/system/mosdns.service <<EOF
[Unit]
Description=MosDNS
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/mosdns start -c /etc/mosdns/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/max_log.conf <<EOF
[Journal]
SystemMaxUse=10M
MaxRetentionSec=2h
EOF

systemctl daemon-reload
systemctl restart systemd-journald
systemctl enable mosdns
systemctl restart mosdns

ROUTE_FILE="/etc/XrayR/route.json"
DNS_FILE="/etc/XrayR/dns.json"
if [ -f "$ROUTE_FILE" ]; then
  tmp=$(mktemp)
  jq --arg p "$PORT" '.rules = [{"type":"field","ip":["127.0.0.1"],"port":($p|tonumber),"outboundTag":"IPv4_out"}] + [.rules[]]' "$ROUTE_FILE" > "$tmp" && mv "$tmp" "$ROUTE_FILE"
fi
if [ -f "$DNS_FILE" ]; then
  tmp=$(mktemp)
  jq --arg p "$PORT" '.servers = [{"address":"127.0.0.1","port":($p|tonumber)}] + [.servers[]]' "$DNS_FILE" > "$tmp" && mv "$tmp" "$DNS_FILE"
fi

xrayr restart 2>/dev/null || systemctl restart XrayR 2>/dev/null

# 最后只输出极简状态
clear
echo "=== 执行完成 ==="
echo -n "ipset: "
command -v ipset >/dev/null && echo "已安装" || echo "未安装"
echo -n "ufw:  "
ufw status | grep -q "active" && echo "已启用" || echo "未启用"
echo -n "mosdns: "
systemctl is-active mosdns | grep -q "active" && echo "运行中" || echo "异常"
echo -n "XrayR:  "
(systemctl is-active XrayR || systemctl is-active xrayr) | grep -q "active" && echo "运行中" || echo "异常"
echo "================"
