#!/usr/bin/env bash

# ==============================================================================
# 一键卸载 mosdns, smartdns, sniproxy, ipset白名单并恢复 UFW 端口规则脚本
# 适配 哪吒面板 计划任务，包含清理完整性校验与 DNS 解析连通性验证
# ==============================================================================

# 颜色定义
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Yellow_font_prefix="\033[33m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Warning="${Yellow_font_prefix}[警告]${Font_color_suffix}"

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${Error} 此脚本必须以 root 用户运行！请使用 sudo bash 执行。" 
   exit 1
fi

echo -e "${Info} 开始执行一键清理与恢复脚本..."

# 2. 卸载 Mosdns
echo -e "${Info} 正在清理 Mosdns..."
if systemctl is-active --quiet mosdns 2>/dev/null || systemctl list-unit-files | grep -q mosdns 2>/dev/null; then
    systemctl stop mosdns 2>/dev/null
    systemctl disable mosdns 2>/dev/null
    echo -e "${Info} 已停止并禁用 Mosdns 服务"
fi
# 删除 systemd 服务文件
rm -f /etc/systemd/system/mosdns.service
rm -f /lib/systemd/system/mosdns.service
# 删除二进制文件和配置文件
rm -f /usr/local/bin/mosdns
rm -f /usr/bin/mosdns
rm -rf /etc/mosdns
systemctl daemon-reload
echo -e "${Info} Mosdns 清理完成。"

# 3. 卸载 Smartdns
echo -e "${Info} 正在清理 Smartdns..."
if systemctl is-active --quiet smartdns 2>/dev/null || systemctl list-unit-files | grep -q smartdns 2>/dev/null; then
    systemctl stop smartdns 2>/dev/null
    systemctl disable smartdns 2>/dev/null
    echo -e "${Info} 已停止并禁用 Smartdns 服务"
fi
# 尝试包管理器卸载
if command -v apt-get &>/dev/null; then
    apt-get purge -y smartdns &>/dev/null
elif command -v yum &>/dev/null; then
    yum remove -y smartdns &>/dev/null
fi
# 删除手动安装的文件
rm -f /etc/systemd/system/smartdns.service
rm -f /lib/systemd/system/smartdns.service
rm -f /usr/local/bin/smartdns
rm -f /usr/sbin/smartdns
rm -rf /etc/smartdns
systemctl daemon-reload
echo -e "${Info} Smartdns 清理完成。"

# 4. 卸载 Sniproxy
echo -e "${Info} 正在清理 Sniproxy..."
if systemctl is-active --quiet sniproxy 2>/dev/null || systemctl list-unit-files | grep -q sniproxy 2>/dev/null; then
    systemctl stop sniproxy 2>/dev/null
    systemctl disable sniproxy 2>/dev/null
    echo -e "${Info} 已停止并禁用 Sniproxy 服务"
fi
# 尝试包管理器卸载
if command -v apt-get &>/dev/null; then
    apt-get purge -y sniproxy &>/dev/null
elif command -v yum &>/dev/null; then
    yum remove -y sniproxy &>/dev/null
fi
# 删除手动安装/配置文件
rm -f /etc/systemd/system/sniproxy.service
rm -f /lib/systemd/system/sniproxy.service
rm -f /usr/sbin/sniproxy
rm -f /usr/local/sbin/sniproxy
rm -f /etc/sniproxy.conf
systemctl daemon-reload
echo -e "${Info} Sniproxy 清理完成。"

# 5. 清理 ipset 白名单及其 iptables 规则
echo -e "${Info} 正在清理 ipset 白名单及相关 iptables 规则..."
# 备份并清理 iptables 中包含 set / match-set 匹配的规则，防止 ipset 无法被 destroy
if command -v iptables-save &>/dev/null; then
    iptables-save | grep -v -- "-m set --match-set" | iptables-restore 2>/dev/null
fi
if command -v ip6tables-save &>/dev/null; then
    ip6tables-save | grep -v -- "-m set --match-set" | ip6tables-restore 2>/dev/null
fi

# 清除 ipset 集合
if command -v ipset &>/dev/null; then
    ipset flush 2>/dev/null
    ipset destroy 2>/dev/null
    echo -e "${Info} 已清空并销毁所有 ipset 集合。"
fi

# 6. 恢复系统 DNS并锁定
echo -e "${Info} 正在恢复系统默认 DNS 配置并锁定..."
chattr -i /etc/resolv.conf 2>/dev/null
\cp /etc/resolv.conf /etc/resolv.conf.bak && echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null
echo -e "${Info} DNS 配置恢复完成，当前配置已锁定。"

# 7. 恢复 UFW 规则并开启 22, 2233 和 4500:65535 端口
echo -e "${Info} 正在恢复 UFW 防火墙配置..."
if command -v ufw &>/dev/null; then
    # 重置 UFW 规则
    echo "y" | ufw reset >/dev/null
    
    # 设置默认策略
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    
    # 允许指定端口
    ufw allow 22/tcp comment 'SSH' >/dev/null
    ufw allow 2233/tcp comment 'Custom SSH/Service' >/dev/null
    ufw allow 4500:65535/tcp comment 'Service Ports TCP' >/dev/null
    ufw allow 4500:65535/udp comment 'Service Ports UDP' >/dev/null
    
    # 启用 UFW
    echo "y" | ufw enable >/dev/null
    ufw reload >/dev/null
    
    echo -e "${Info} UFW 防火墙规则已完成恢复配置。"
else
    echo -e "${Warning} 系统未安装 UFW。若需要，请手动安装并配置。"
fi

# 8. 验证卸载与恢复状态 (Nezha 任务检测与退出状态码)
echo -e "\n============================================="
echo -e "${Info} 开始验证卸载与配置恢复状态..."
echo -e "============================================="

errors=0

# 验证 Mosdns 是否卸载干净
if systemctl list-unit-files | grep -q mosdns 2>/dev/null || [ -f /usr/local/bin/mosdns ] || [ -f /usr/bin/mosdns ] || [ -d /etc/mosdns ]; then
    echo -e "${Error} Mosdns 未卸载干净！"
    errors=$((errors+1))
else
    echo -e "${Info} Mosdns 已彻底卸载干净。"
fi

# 验证 Smartdns 是否卸载干净
if systemctl list-unit-files | grep -q smartdns 2>/dev/null || [ -f /usr/local/bin/smartdns ] || [ -f /usr/sbin/smartdns ] || [ -d /etc/smartdns ]; then
    echo -e "${Error} Smartdns 未卸载干净！"
    errors=$((errors+1))
else
    echo -e "${Info} Smartdns 已彻底卸载干净。"
fi

# 验证 Sniproxy 是否卸载干净
if systemctl list-unit-files | grep -q sniproxy 2>/dev/null || [ -f /usr/sbin/sniproxy ] || [ -f /usr/local/sbin/sniproxy ] || [ -f /etc/sniproxy.conf ]; then
    echo -e "${Error} Sniproxy 未卸载干净！"
    errors=$((errors+1))
else
    echo -e "${Info} Sniproxy 已彻底卸载干净。"
fi

# 验证 ipset 是否已清理
if command -v ipset &>/dev/null; then
    ipset_count=$(ipset list -n 2>/dev/null | wc -l)
    if [ "$ipset_count" -gt 0 ]; then
        echo -e "${Error} 仍有 $ipset_count 个 ipset 集合未被销毁！"
        errors=$((errors+1))
    else
        echo -e "${Info} 所有 ipset 集合已清理完毕。"
    fi
else
    echo -e "${Info} 系统中未检测到 ipset 命令，无需清理。"
fi

# 验证 DNS 是否恢复并生效
if grep -q "nameserver 1.1.1.1" /etc/resolv.conf && grep -q "nameserver 8.8.8.8" /etc/resolv.conf; then
    echo -e "${Info} /etc/resolv.conf DNS 规则验证成功（包含 1.1.1.1 和 8.8.8.8）。"
else
    echo -e "${Error} /etc/resolv.conf DNS 规则未正确恢复！"
    errors=$((errors+1))
fi

# 测试 DNS 解析是否正常
if command -v ping &>/dev/null; then
    if ping -c 2 -W 3 google.com &>/dev/null; then
        echo -e "${Info} DNS 域名解析测试成功 (google.com 可正常解析并连通)。"
    elif ping -c 2 -W 3 1.1.1.1 &>/dev/null; then
        # 境外网段如果不通，测试国内公网
        if ping -c 2 -W 3 baidu.com &>/dev/null; then
            echo -e "${Info} DNS 域名解析测试成功 (baidu.com 可正常解析并连通)。"
        else
            echo -e "${Error} 域名解析失败，请检查网络或 DNS 设置！"
            errors=$((errors+1))
        fi
    else
        echo -e "${Error} 网络连通性测试失败 (Ping 1.1.1.1 失败)，请检查网络连接。"
        errors=$((errors+1))
    fi
else
    # 没有 ping 时尝试 getent 查找
    if getent ahosts google.com &>/dev/null || getent ahosts baidu.com &>/dev/null; then
        echo -e "${Info} DNS 域名解析测试成功。"
    else
        echo -e "${Error} 域名解析测试失败。"
        errors=$((errors+1))
    fi
fi

# 验证 UFW 状态
if command -v ufw &>/dev/null; then
    ufw_status=$(ufw status | grep -i "Status: active")
    if [ -n "$ufw_status" ]; then
        # 验证关键端口是否开通
        ssh_ok=$(ufw status | grep -E "22/tcp|22.*ALLOW")
        custom_ssh_ok=$(ufw status | grep -E "2233/tcp|2233.*ALLOW")
        ports_range_tcp=$(ufw status | grep -E "4500:65535/tcp|4500:65535.*ALLOW")
        ports_range_udp=$(ufw status | grep -E "4500:65535/udp|4500:65535.*ALLOW")
        
        if [ -n "$ssh_ok" ] && [ -n "$custom_ssh_ok" ] && [ -n "$ports_range_tcp" ] && [ -n "$ports_range_udp" ]; then
            echo -e "${Info} UFW 防火墙端口配置验证通过。"
        else
            echo -e "${Warning} UFW 部分指定端口规则缺失或配置有误！"
            errors=$((errors+1))
        fi
    else
        echo -e "${Error} UFW 防火墙未处于启用状态！"
        errors=$((errors+1))
    fi
fi

echo -e "============================================="
if [ "$errors" -eq 0 ]; then
    echo -e "${Green_font_prefix}【验证成功】所有服务已彻底卸载干净，配置与 DNS 已全部恢复！${Font_color_suffix}"
    exit 0
else
    echo -e "${Red_font_prefix}【验证失败】存在 $errors 处异常，请检查上述日志排查问题！${Font_color_suffix}"
    exit 1
fi
