#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

install_base() {
    if command -v yum >/dev/null 2>&1; then
        yum install wget curl tar socat -y >/dev/null 2>&1
    else
        apt update >/dev/null 2>&1
        apt install wget curl tar socat -y >/dev/null 2>&1
    fi
}

install_XrayR() {
    # 1. 准备目录
    rm -rf /usr/local/XrayR/
    mkdir -p /usr/local/XrayR/
	cd /usr/local/XrayR/

    # 2. 下载后端程序和所有配置文件
    echo -e "${green}开始下载 XrayR 后端及配置文件...${plain}"
    wget -q -N --no-check-certificate -O /usr/local/XrayR/XrayR https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/xrayr
    # 【关键修正】为后端程序添加可执行权限
    chmod +x /usr/local/XrayR/XrayR
    
    wget -q -N --no-check-certificate -O /usr/local/XrayR/config.yml https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/config.yml
    wget -q -N --no-check-certificate -O /usr/local/XrayR/dns.json https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/dns.json
    wget -q -N --no-check-certificate -O /usr/local/XrayR/route.json https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/route.json
    wget -q -N --no-check-certificate -O /usr/local/XrayR/custom_inbound.json https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/custom_inbound.json
    wget -q -N --no-check-certificate -O /usr/local/XrayR/custom_outbound.json https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/custom_outbound.json
    wget -q -N --no-check-certificate -O /usr/local/XrayR/geoip.dat https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat
    wget -q -N --no-check-certificate -O /usr/local/XrayR/geosite.dat https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat

    # 3. 下载并安装 systemd 服务文件
    echo -e "${green}正在安装 systemd 服务...${plain}"
    rm -f /etc/systemd/system/XrayR.service
    wget -q -N --no-check-certificate -O /etc/systemd/system/XrayR.service https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/XrayR.service
    
    # 4. 下载并安装管理脚本
    echo -e "${green}正在安装管理脚本...${plain}"
    curl -o /usr/bin/XrayR -Ls https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/refs/heads/master/XrayR.sh
    chmod +x /usr/bin/XrayR
    ln -sf /usr/bin/XrayR /usr/bin/xrayr

    # 5. 复制所有配置文件
    mkdir -p /etc/XrayR/
    cp /usr/local/XrayR/* /etc/XrayR/
    # 后端程序不需要放在 /etc/XrayR
    rm -f /etc/XrayR/XrayR

    # 6. 设置权限
    chmod -R 777 /etc/XrayR/
    
    # 7. 重载并启用服务
    systemctl daemon-reload
    systemctl enable XrayR
    echo -e "${green}XrayR 安装完成，已设置开机自启。${plain}"

    # 8. 尝试启动服务
    systemctl start XrayR
    sleep 2

    # 9. 最终提示
    echo -e "\n${green}=====================================================${plain}"
    echo -e "${green} XrayR 安装成功！${plain}"
    echo -e " "
    echo -e "您现在可以执行 ${green}xrayr${plain} 命令来管理后端。"
    echo -e "请立即使用 ${green}xrayr config${plain} 命令修改配置文件！"
    echo -e "${green}=====================================================${plain}"
    
    # 10. 清理
    cd $cur_dir
    rm -f install.sh
}

# --- Main ---
echo -e "${green}正在准备安装环境...${plain}"
install_base
install_XrayR
