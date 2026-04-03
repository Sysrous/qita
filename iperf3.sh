#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
#=================================================
#
#   iperf3测速一键脚本 (全自动安装版)
#
#	System Required: CentOS 7/8,Debian/ubuntu,oraclelinux
#
#_______________________________________________________

sh_ver="1.2"

#############系统检测组件#############
check_sys(){
	if [[ -f /etc/redhat-release ]]; then
		release="centos"
	elif cat /etc/issue | grep -q -E -i "debian"; then
		release="debian"
	elif cat /etc/issue | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
	elif cat /proc/version | grep -q -E -i "debian"; then
		release="debian"
	elif cat /proc/version | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
    fi
}

installiperf3(){
    # 这里的 -y 参数即代表自动回答 Yes，避免弹窗询问
	if [[ "${release}" == "centos" ]]; then
	    echo -e "正在静默安装 iperf3 (CentOS)..."
        # -q 为静默模式，-y 为自动确认
		yum -y -q install iperf3
	elif [[ "${release}" == "debian" || "${release}" == "ubuntu" ]]; then
		echo -e "正在静默安装 iperf3 (Debian/Ubuntu)..."
        # DEBIAN_FRONTEND=noninteractive 防止出现蓝色配置弹窗
        # -y 自动确认安装
		apt-get update -y -q > /dev/null 2>&1
		DEBIAN_FRONTEND=noninteractive apt-get -y -q install iperf3
	else
        echo -e "未检测到支持的系统，尝试直接运行..."
    fi
    echo -e "安装/检查完成。"
}

# 检查是否安装了iperf3，未安装则自动安装
check_and_install(){
    if ! command -v iperf3 > /dev/null 2>&1; then
        echo -e "系统检测: 未找到 iperf3，开始自动安装..."
        installiperf3
    else 
        echo -e "系统检测: iperf3 已安装。"
    fi
}

startservers(){
    echo -e " "
    echo -e "正在运行服务端 - Ctrl+C强制结束"
    echo -e " "
    iperf3 -s -i 1
}

startclientup(){
    echo -e "启动客户端上传测试"
    echo -e " "
    echo -e "____________________________________"
    echo -e " "
    echo -e " "
	read -e -p "请输入服务端IP地址 (默认 127.0.0.1): " serverip
	[[ -z "${serverip}" ]] && serverip="127.0.0.1"
	echo -e " "
    echo -e "____________________________________"
    echo -e " "
	echo "服务端IP - ${serverip}"
	echo -e " "
	echo -e "____________________________________"
    echo -e " "
    echo -e " "
	read -e -p "请输入运行时间(秒 - 默认12秒): " time
	[[ -z "${time}" ]] && time="12"
	echo -e " "
    echo -e "____________________________________"
    echo -e " "
	echo "运行时间 - ${time}"
	echo -e " "
    echo -e "正在运行客户端上传测试(单线程) - Ctrl+C强制结束"
    echo -e " "
    iperf3 -c ${serverip} -i 1 -P 1 -t ${time}
}

startclientdown(){
    echo -e "启动客户端下载测试"
    echo -e " "
    echo -e "____________________________________"
    echo -e " "
    echo -e " "
	read -e -p "请输入服务端IP地址 (默认 127.0.0.1): " serverip
	[[ -z "${serverip}" ]] && serverip="127.0.0.1"
	echo -e " "
    echo -e "____________________________________"
    echo -e " "
	echo "服务端IP - ${serverip}"
	echo -e " "
	echo -e "____________________________________"
    echo -e " "
    echo -e " "
	read -e -p "请输入运行时间(秒 - 默认12秒): " time
	[[ -z "${time}" ]] && time="12"
	echo -e " "
    echo -e "____________________________________"
    echo -e " "
	echo "运行时间 - ${time}"
	echo -e " "
    echo -e "正在运行客户端下载测试 - Ctrl+C强制结束"
    echo -e " "
    iperf3 -c ${serverip} -i 1 -P 1 -t ${time} -R
}

#开始菜单
start_menu(){
    
clear
echo && echo -e " iperf3 一键端对端测速脚本[v${sh_ver}]
————————————模式选择————————————

 1. 服务端启动 (接收端)
 2. 客户端上传测试 (发送端)
 3. 客户端下载测试 (反向模式)
 
————————————————————————————" && echo

echo
read -p " 请输入数字 [1-3] :" num
case "$num" in
	1)
	startservers
	;;
	2)
	startclientup
	;;
	3)
	startclientdown
	;;
	*)
	clear
	echo -e "请输入正确数字 [1-3]"
	sleep 2s
	start_menu
	;;
esac
}

# 脚本入口执行顺序
check_sys
check_and_install
start_menu
