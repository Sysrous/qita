#!/usr/bin/env bash
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"

#############################################
# 基础信息
#############################################
get_opsy() {
  [ -f /etc/redhat-release ] && awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
  [ -f /etc/os-release ] && awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
  [ -f /etc/lsb-release ] && awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
}
virt_check() {
  virtualx=$(dmesg 2>/dev/null)
  if command -v dmidecode &>/dev/null; then
    sys_manu=$(dmidecode -s system-manufacturer 2>/dev/null)
    sys_product=$(dmidecode -s system-product-name 2>/dev/null)
    sys_ver=$(dmidecode -s system-version 2>/dev/null)
  else
    sys_manu=""; sys_product=""; sys_ver=""
  fi
  if grep -qa docker /proc/1/cgroup 2>/dev/null; then
    virtual="Docker"
  elif grep -qa lxc /proc/1/cgroup 2>/dev/null; then
    virtual="Lxc"
  elif [[ -f /proc/user_beancounters ]]; then
    virtual="OpenVZ"
  elif [[ "$virtualx" == *kvm-clock* ]]; then
    virtual="KVM"
  elif [[ "$virtualx" == *"VMware Virtual Platform"* ]]; then
    virtual="VMware"
  elif [[ "$virtualx" == *VirtualBox* ]]; then
    virtual="VirtualBox"
  elif [[ -e /proc/xen ]]; then
    virtual="Xen"
  elif [[ "$sys_manu" == *"Microsoft Corporation"* ]] && [[ "$sys_product" == *"Virtual Machine"* ]]; then
    virtual="Hyper-V"
  else
    virtual="Dedicated母鸡"
  fi
}
get_system_info() {
  cname=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
  opsy=$(get_opsy)
  arch=$(uname -m)
  kern=$(uname -r)
  virt_check
}

#############################################
# 功能函数
#############################################
bbr(){
  if uname -r | grep -Eq '^5\.|^[6-9]\.'; then
    echo -e "${Info} 当前内核 $(uname -r) 已 ≥5.x，无需重装 BBR！"
  else
    wget -N --no-check-certificate http://sh.nekoneko.cloud/bbr/bbr.sh -O bbr.sh && bash bbr.sh
  fi
}

# 合并：TCP调优 + 内核转发 + 系统资源限制
all_in_one_tune(){
  echo -e "${Info} 开始执行网络与系统综合优化……"

  # 清旧值
  sed -i '/^net\.ipv4\.tcp_no_metrics_save/d;/^net\.ipv4\.tcp_ecn/d;/^net\.ipv4\.tcp_mtu_probing/d;/^net\.ipv4\.tcp_sack/d;/^net\.ipv4\.tcp_fack/d;/^net\.ipv4\.tcp_window_scaling/d;/^net\.ipv4\.tcp_adv_win_scale/d;/^net\.ipv4\.tcp_moderate_rcvbuf/d;/^net\.ipv4\.tcp_rmem/d;/^net\.ipv4\.tcp_wmem/d;/^net\.core\.rmem_max/d;/^net\.core\.wmem_max/d;/^net\.ipv4\.udp_rmem_min/d;/^net\.ipv4\.udp_wmem_min/d;/^net\.core\.default_qdisc/d;/^net\.ipv4\.tcp_congestion_control/d;/^net\.ipv4\.ip_forward/d;/^net\.ipv4\.conf\.all\.route_localnet/d;/^net\.ipv4\.conf\.all\.forwarding/d;/^net\.ipv4\.conf\.default\.forwarding/d;/^net\.ipv6\.conf\.all\.forwarding/d;/^net\.ipv6\.conf\.default\.forwarding/d;/^fs\.file-max/d;/^vm\.swappiness/d;/^vm\.overcommit_memory/d' /etc/sysctl.conf

  # 写入新值
  cat >> /etc/sysctl.conf <<-'EOF'
# =============== 网络与系统综合优化 ===============
fs.file-max = 6815744
vm.swappiness = 10
vm.overcommit_memory = 1
net.core.default_qdisc = fq
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
# ================================================
EOF
  sysctl -p && sysctl --system
  echo -e "${Info} 内核参数已重载！"

  # 文件句柄 & ulimit
  echo "1048576" > /proc/sys/fs/file-max
  ulimit -SHn 1048576 && ulimit -c unlimited
  cat > /etc/security/limits.conf <<-'EOF'
root     soft   nofile    1048576
root     hard   nofile    1048576
root     soft   nproc     1048576
root     hard   nproc     1048576
root     soft   core      1048576
root     hard   core      1048576
root     hard   memlock   unlimited
root     soft   memlock   unlimited
*        soft   nofile    1048576
*        hard   nofile    1048576
*        soft   nproc     1048576
*        hard   nproc     1048576
*        soft   core      1048576
*        hard   core      1048576
*        hard   memlock   unlimited
*        soft   memlock   unlimited
EOF
  grep -q "ulimit -SHn" /etc/profile || echo "ulimit -SHn 1048576" >> /etc/profile
  grep -q "pam_limits.so" /etc/pam.d/common-session || echo "session required pam_limits.so" >> /etc/pam.d/common-session

  # systemd
  sed -i '/^DefaultTimeoutStartSec/d;/^DefaultTimeoutStopSec/d;/^DefaultRestartSec/d;/^DefaultLimitCORE/d;/^DefaultLimitNOFILE/d;/^DefaultLimitNPROC/d' /etc/systemd/system.conf
  cat >> /etc/systemd/system.conf <<-'EOF'
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=infinity
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
  systemctl daemon-reload
  echo -e "${Info} 系统资源限制已更新！"
}

banping(){
  sed -i '/^net\.ipv4\.icmp_echo_ignore_all/d;/^net\.ipv4\.icmp_echo_ignore_broadcasts/d' /etc/sysctl.conf
  echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
  echo "net.ipv4.icmp_echo_ignore_broadcasts=1" >> /etc/sysctl.conf
  sysctl -p && echo -e "${Info} ICMP 已屏蔽！"
}

unbanping(){
  sed -i 's/^net\.ipv4\.icmp_echo_ignore_all=1/net.ipv4.icmp_echo_ignore_all=0/;s/^net\.ipv4\.icmp_echo_ignore_broadcasts=1/net.ipv4.icmp_echo_ignore_broadcasts=0/' /etc/sysctl.conf
  sysctl -p && echo -e "${Info} ICMP 已开放！"
}

#############################################
# 菜单
#############################################
menu(){
  echo -e "
${Green_font_prefix}1.${Font_color_suffix} 安装BBR原版内核(≥5.x跳过)
${Green_font_prefix}2.${Font_color_suffix} 网络与系统综合优化（TCP+转发+资源限制）
${Green_font_prefix}3.${Font_color_suffix} 屏蔽ICMP
${Green_font_prefix}4.${Font_color_suffix} 开放ICMP
"
get_system_info
echo -e "当前系统: ${Font_color_suffix}$opsy ${Green_font_prefix}$virtual${Font_color_suffix} $arch ${Green_font_prefix}$kern${Font_color_suffix}
"
  read -t 6 -p "请输入数字 [1-4] (6秒无操作将自动执行综合优化): " num
  case "${num:-2}" in     # 默认值2
    1) bbr ;;
    2) all_in_one_tune ;;
    3) banping ;;
    4) unbanping ;;
    *) echo -e "${Error} 无效选择，自动执行综合优化！"; all_in_one_tune ;;
  esac
}

clear
menu
