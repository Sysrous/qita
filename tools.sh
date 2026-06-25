#!/usr/bin/env bash

# ==============================================================================
# Linux 网络与系统综合优化调整工具 (极限性能榨干与内存保护版)
# 支持带宽档位: 500M, 800M, 1G, 1.5G, 2G, 2.5G, 3G, 5G, 10G, 100G
# ==============================================================================

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Yellow_font_prefix="\033[33m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warning="${Yellow_font_prefix}[警告]${Font_color_suffix}"

# 全局榨干模式标识
FORCE_SQUEEZE="false"

# 必须以 root 用户运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${Error} 此脚本必须以 root 用户运行！" 
   exit 1
fi

#############################################
# 系统基础信息检测
#############################################
get_opsy() {
  [ -f /etc/redhat-release ] && awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
  [ -f /etc/os-release ] && awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
  [ -f /etc/lsb-release ] && awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
  echo "Unknown Linux"
}

virt_check() {
  virtualx=$(dmesg 2>/dev/null)
  if command -v dmidecode &>/dev/null; then
    sys_manu=$(dmidecode -s system-manufacturer 2>/dev/null)
    sys_product=$(dmidecode -s system-product-name 2>/dev/null)
  else
    sys_manu=""; sys_product=""
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
    virtual="Dedicated Motherboard (物理机)"
  fi
}

# 辅助配置函数：清空旧配置，并写入新配置
sysctl_set() {
    local key=$1
    local value=$2
    # 删除旧的配置行
    sed -i "/^${key//./\.}/d" /etc/sysctl.conf
    # 追加新的配置行
    echo "$key = $value" >> /etc/sysctl.conf
}

#############################################
# BBR 内核检测与配置
#############################################
bbr_setup() {
  kernel_version=$(uname -r)
  kernel_major=$(echo "$kernel_version" | cut -d. -f1)
  kernel_minor=$(echo "$kernel_version" | cut -d. -f2)

  bbr_supported=false
  if [ "$kernel_major" -gt 4 ] || { [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -ge 9 ]; }; then
      bbr_supported=true
  fi

  if [ "$bbr_supported" = true ]; then
      echo -e "${Info} 当前内核版本 $kernel_version 满足要求 (>= 4.9)，已配置启用原版 BBR。"
      sysctl_set "net.core.default_qdisc" "fq"
      sysctl_set "net.ipv4.tcp_congestion_control" "bbr"
  else
      echo -e "${Warning} 当前内核版本 $kernel_version 低于 4.9，原版 BBR 不受支持！"
      read -p "是否尝试升级内核安装 BBR？[y/N]: " install_bbr
      if [[ "$install_bbr" =~ ^[yY]$ ]]; then
          wget -N --no-check-certificate http://sh.nekoneko.cloud/bbr/bbr.sh -O bbr.sh && bash bbr.sh
      else
          echo -e "${Info} 已跳过内核升级，将采用默认拥塞控制算法 (Cubic)。"
      fi
  fi
}

#############################################
# 自动检测网卡物理带宽 (仅作显示参考)
#############################################
detect_link_speed() {
  local dev=$(ip route show | awk '/default/ {print $5}' | head -n1)
  if [ -z "$dev" ]; then
      dev=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "lo|virbr|docker|veth|br-" | head -n1)
  fi
  
  if [ -n "$dev" ] && [ -f "/sys/class/net/$dev/speed" ]; then
      local speed=$(cat "/sys/class/net/$dev/speed" 2>/dev/null)
      if [ -n "$speed" ] && [ "$speed" -gt 0 ] && [ "$speed" -lt 1000000 ]; then
          echo "$speed"
          return
      fi
  fi
  echo "0"
}

#############################################
# 网络与系统参数综合调整
#############################################
tune_all() {
  local bw_profile=$1
  echo -e "${Info} 正在应用适用于 ${bw_profile} 带宽的 TCP/内核配置方案..."

  # 获取内存大小
  local total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
  local total_mem_mb=$((total_mem_kb / 1024))
  
  # 定义网络调优变量初值
  local rmem_max wmem_max tcp_rmem tcp_wmem backlog somaxconn max_syn

  # 根据手动选择的带宽档位计算 BDP (基于 100ms 广域网延迟安全冗余计算)
  case "$bw_profile" in
    "500M")
      rmem_max=8388608      # 8 MB
      wmem_max=8388608
      tcp_rmem="4096 87380 8388608"
      tcp_wmem="4096 65536 8388608"
      backlog=5000
      somaxconn=2048
      max_syn=2048
      ;;
    "800M")
      rmem_max=12582912     # 12 MB
      wmem_max=12582912
      tcp_rmem="4096 87380 12582912"
      tcp_wmem="4096 65536 12582912"
      backlog=8000
      somaxconn=4096
      max_syn=4096
      ;;
    "1G")
      rmem_max=16777216     # 16 MB
      wmem_max=16777216
      tcp_rmem="4096 87380 16777216"
      tcp_wmem="4096 65536 16777216"
      backlog=10000
      somaxconn=4096
      max_syn=4096
      ;;
    "1.5G")
      rmem_max=25165824     # 24 MB
      wmem_max=25165824
      tcp_rmem="4096 87380 25165824"
      tcp_wmem="4096 65536 25165824"
      backlog=15000
      somaxconn=6144
      max_syn=6144
      ;;
    "2G")
      rmem_max=33554432     # 32 MB
      wmem_max=33554432
      tcp_rmem="4096 87380 33554432"
      tcp_wmem="4096 65536 33554432"
      backlog=20000
      somaxconn=8192
      max_syn=8192
      ;;
    "2.5G")
      rmem_max=41943040     # 40 MB
      wmem_max=41943040
      tcp_rmem="4096 87380 41943040"
      tcp_wmem="4096 65536 41943040"
      backlog=25000
      somaxconn=8192
      max_syn=8192
      ;;
    "3G")
      rmem_max=50331648     # 48 MB
      wmem_max=50331648
      tcp_rmem="4096 87380 50331648"
      tcp_wmem="4096 65536 50331648"
      backlog=30000
      somaxconn=10240
      max_syn=10240
      ;;
    "5G")
      rmem_max=83886080     # 80 MB
      wmem_max=83886080
      tcp_rmem="4096 87380 83886080"
      tcp_wmem="4096 65536 83886080"
      backlog=50000
      somaxconn=16384
      max_syn=16384
      ;;
    "10G")
      rmem_max=167772160    # 160 MB
      wmem_max=167772160
      tcp_rmem="4096 87380 167772160"
      tcp_wmem="4096 65536 167772160"
      backlog=100000
      somaxconn=32768
      max_syn=32768
      ;;
    "100G")
      if [ "$total_mem_mb" -ge 32768 ]; then
        rmem_max=805306368  # 768 MB (高内存物理机/高配虚拟机)
        wmem_max=805306368
        tcp_rmem="4096 87380 805306368"
        tcp_wmem="4096 65536 805306368"
      else
        rmem_max=402653184  # 384 MB (中内存机型安全适配)
        wmem_max=402653184
        tcp_rmem="4096 87380 402653184"
        tcp_wmem="4096 65536 402653184"
      fi
      backlog=250000
      somaxconn=65535
      max_syn=65535
      ;;
    *)
      echo -e "${Error} 未知的配置档位！使用 1G 默认值。"
      tune_all "1G"
      return
      ;;
  esac

  # 内存安全守护 (如果启用了极限榨干，则跳过)
  if [ "$FORCE_SQUEEZE" = "true" ]; then
      echo -e "${Warning} 【极限榨干模式开启】已绕过内存大小限制，强制写入完整机械性能参数！"
  else
      local max_safe_buffer=805306368 # 768MB
      if [ "$total_mem_mb" -lt 1024 ]; then
          max_safe_buffer=8388608    # 1G内存以下限制8MB
      elif [ "$total_mem_mb" -lt 2048 ]; then
          max_safe_buffer=16777216   # 2G内存以下限制16MB
      elif [ "$total_mem_mb" -lt 4096 ]; then
          max_safe_buffer=67108864   # 4G内存以下限制64MB
      elif [ "$total_mem_mb" -lt 8192 ]; then
          max_safe_buffer=134217728  # 8G内存以下限制128MB
      fi

      if [ "$rmem_max" -gt "$max_safe_buffer" ]; then
          echo -e "${Warning} 检测到当前物理内存较小 (${total_mem_mb}MB)，为了防止内存溢出(OOM)，最大缓冲区上限已安全限流为 $((max_safe_buffer / 1024 / 1024))MB。"
          rmem_max=$max_safe_buffer
          wmem_max=$max_safe_buffer
          tcp_rmem="4096 87380 $max_safe_buffer"
          tcp_wmem="4096 65536 $max_safe_buffer"
      fi
  fi

  # 清理 sysctl 中的高并发与 TCP 性能相关旧参数
  local sysctl_params=(
    "net.core.rmem_max" "net.core.wmem_max" "net.ipv4.tcp_rmem" "net.ipv4.tcp_wmem"
    "net.core.netdev_max_backlog" "net.core.somaxconn" "net.ipv4.tcp_max_syn_backlog"
    "net.ipv4.tcp_slow_start_after_idle" "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_timestamps"
    "net.ipv4.tcp_tw_reuse" "net.ipv4.tcp_sack" "net.ipv4.tcp_fack" "net.ipv4.tcp_window_scaling"
    "net.ipv4.tcp_adv_win_scale" "net.ipv4.tcp_moderate_rcvbuf" "net.ipv4.ip_forward"
    "net.ipv4.conf.all.forwarding" "net.ipv4.conf.default.forwarding" "net.ipv6.conf.all.forwarding"
    "net.ipv6.conf.default.forwarding" "fs.file-max" "vm.swappiness" "vm.overcommit_memory"
    "net.ipv4.tcp_mtu_probing" "net.ipv4.udp_rmem_min" "net.ipv4.udp_wmem_min"
  )
  for param in "${sysctl_params[@]}"; do
      sed -i "/^${param//./\.}/d" /etc/sysctl.conf
  done

  # 写入调优配置
  cat >> /etc/sysctl.conf <<-EOF
# =============== ${bw_profile} 宽带网络与系统综合调优配置 ===============
fs.file-max = 6815744
vm.swappiness = 10
vm.overcommit_memory = 1

# 基础 Socket 接收/发送缓冲区设置
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.ipv4.tcp_rmem = $tcp_rmem
net.ipv4.tcp_wmem = $tcp_wmem

# 网络队列及连接池优化
net.core.netdev_max_backlog = $backlog
net.core.somaxconn = $somaxconn
net.ipv4.tcp_max_syn_backlog = $max_syn

# TCP 高性能特征及 BBR 关联参数
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1

# 转发相关设置
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# UDP 最小缓冲
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
# ==============================================================================
EOF

  # 检查环境并启用 BBR
  bbr_setup

  # 强制刷新配置
  sysctl -p && sysctl --system
  echo -e "${Info} sysctl 参数重载成功！"

  # 配置系统资源限制限制 (文件描述符, 进程等)
  echo "1048576" > /proc/sys/fs/file-max
  ulimit -SHn 1048576 && ulimit -c unlimited
  
  cat > /etc/security/limits.conf <<-'EOF'
root     soft   nofile    1048576
root     hard   nofile    1048576
root     soft   nproc     1048576
root     hard   nproc     1048576
root     soft   core      1048576
root     hard   nofile    1048576
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

  # Systemd 配置更新
  sed -i '/^DefaultTimeoutStartSec/d;/^DefaultTimeoutStopSec/d;/^DefaultRestartSec/d;/^DefaultLimitCORE/d;/^DefaultLimitNOFILE/d;/^DefaultLimitNPROC/d' /etc/systemd/system.conf
  cat >> /etc/systemd/system.conf <<-'EOF'
[Manager]
DefaultTimeoutStopSec=30s
DefaultLimitCORE=infinity
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
  systemctl daemon-reload 2>/dev/null
  echo -e "${Info} 系统级 ulimit 文件句柄与 Systemd 资源限制已成功应用！"
}

banping(){
  sed -i '/^net\.ipv4\.icmp_echo_ignore_all/d;/^net\.ipv4\.icmp_echo_ignore_broadcasts/d' /etc/sysctl.conf
  echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
  echo "net.ipv4.icmp_echo_ignore_broadcasts=1" >> /etc/sysctl.conf
  sysctl -p && echo -e "${Info} ICMP (禁Ping) 已启用。"
}

unbanping(){
  sed -i '/^net\.ipv4\.icmp_echo_ignore_all/d;/^net\.ipv4\.icmp_echo_ignore_broadcasts/d' /etc/sysctl.conf
  echo "net.ipv4.icmp_echo_ignore_all=0" >> /etc/sysctl.conf
  echo "net.ipv4.icmp_echo_ignore_broadcasts=0" >> /etc/sysctl.conf
  sysctl -p && echo -e "${Info} ICMP (禁Ping) 已解除。"
}

#############################################
# 菜单显示与逻辑控制
#############################################
menu(){
  clear
  opsy=$(get_opsy)
  virt_check
  arch=$(uname -m)
  kern=$(uname -r)
  total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
  total_mem_mb=$((total_mem_kb / 1024))
  
  # 网卡带宽自动检测 (显示用，不做强制默认执行)
  auto_speed=$(detect_link_speed)
  if [ "$auto_speed" -gt 0 ]; then
      if [ "$auto_speed" -ge 100000 ]; then
          auto_speed_str="${Yellow_font_prefix}100G${Font_color_suffix}"
      elif [ "$auto_speed" -ge 10000 ]; then
          auto_speed_str="${Yellow_font_prefix}10G${Font_color_suffix}"
      elif [ "$auto_speed" -ge 5000 ]; then
          auto_speed_str="${Yellow_font_prefix}5G${Font_color_suffix}"
      elif [ "$auto_speed" -ge 3000 ]; then
          auto_speed_str="${Yellow_font_prefix}3G${Font_color_suffix}"
      elif [ "$auto_speed" -ge 2500 ]; then
          auto_speed_str="${Yellow_font_prefix}2.5G${Font_color_suffix}"
      elif [ "$auto_speed" -ge 2000 ]; then
          auto_speed_str="${Yellow_font_prefix}2G${Font_color_suffix}"
      elif [ "$auto_speed" -ge 1500 ]; then
          auto_speed_str="${Yellow_font_prefix}1.5G${Font_color_suffix}"
      elif [ "$auto_speed" -ge 1000 ]; then
          auto_speed_str="${Yellow_font_prefix}1G${Font_color_suffix}"
      else
          auto_speed_str="${Yellow_font_prefix}${auto_speed}M${Font_color_suffix}"
      fi
  else
      auto_speed_str="未检测到物理带宽 (虚拟化网卡上报未知)"
  fi

  echo -e "=================================================="
  echo -e "       Linux 网络高吞吐与 BBR 极限调优脚本        "
  echo -e "=================================================="
  echo -e "系统环境: ${opsy} | 架构: ${arch} | 内核: ${kern}"
  echo -e "虚拟化类型: ${Green_font_prefix}${virtual}${Font_color_suffix} | 内存大小: ${total_mem_mb} MB"
  echo -e "自动检测网卡物理带宽: ${auto_speed_str}"
  if [ "$virtual" = "Docker" ] || [ "$virtual" = "Lxc" ] || [ "$virtual" = "OpenVZ" ]; then
      echo -e "${Warning} 当前处于容器环境 (${virtual})，部分内核参数可能无法写入或不生效！"
  fi
  echo -e "=================================================="
  echo -e "【手动选择目标网络带宽，准备进行极限优化调优】"
  echo -e " 1)  适配 500M   宽带网络优化方案"
  echo -e " 2)  适配 800M   宽带网络优化方案"
  echo -e " 3)  适配 1G     宽带网络优化方案"
  echo -e " 4)  适配 1.5G   宽带网络优化方案"
  echo -e " 5)  适配 2G     宽带网络优化方案"
  echo -e " 6)  适配 2.5G   宽带网络优化方案"
  echo -e " 7)  适配 3G     宽带网络优化方案"
  echo -e " 8)  适配 5G     宽带网络优化方案"
  echo -e " 9)  适配 10G    宽带网络优化方案"
  echo -e " 10) 适配 100G   宽带网络优化方案"
  echo -e " 11) 独立管理：开启系统禁 Ping"
  echo -e " 12) 独立管理：关闭系统禁 Ping"
  echo -e "=================================================="
  
  read -p "请输入你要调优的网络速率档位 [1-12]: " num
  
  if [[ ! "$num" =~ ^([1-9]|1[0-2])$ ]]; then
      echo -e "${Error} 无效选择，脚本退出！"
      exit 1
  fi
  
  # 若用户选的是网络调优选项(1-10)，询问是否启用极限性能榨干模式
  if [ "$num" -ge 1 ] && [ "$num" -le 10 ]; then
      echo -e ""
      echo -e "--------------------------------------------------"
      echo -e "${Warning} 是否开启【极限性能榨干模式】？"
      echo -e "  - 开启后：忽略系统物理内存限制，强制写入当前所选高带宽的最佳超大 TCP 缓存参数。"
      echo -e "  - 关闭后：将根据系统可用内存，自动进行安全流控截断，避免高并发下导致内存溢出 (OOM)。"
      echo -e "--------------------------------------------------"
      read -p "是否开启极限榨干模式？(y/N): " squeeze_opt
      if [[ "$squeeze_opt" =~ ^[yY]$ ]]; then
          FORCE_SQUEEZE="true"
      fi
  fi
  
  case "$num" in
    1) tune_all "500M" ;;
    2) tune_all "800M" ;;
    3) tune_all "1G" ;;
    4) tune_all "1.5G" ;;
    5) tune_all "2G" ;;
    6) tune_all "2.5G" ;;
    7) tune_all "3G" ;;
    8) tune_all "5G" ;;
    9) tune_all "10G" ;;
    10) tune_all "100G" ;;
    11) banping ;;
    12) unbanping ;;
  esac
}

menu
