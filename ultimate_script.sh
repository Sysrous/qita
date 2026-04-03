#!/bin/bash
# ==============================================================================
#  终极合并脚本 (严格按照用户提供的所有内容和顺序构建)
#  版本: 忠于原文版
# ==============================================================================

# --- 定义颜色输出，方便查看日志 ---
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
NC="\033[0m"
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_step() { echo -e "\n${BLUE}>>> 步骤 ${1}: ${2}${NC}"; }

set -e # 任何命令失败则立即退出

log_info "终极合并脚本开始执行，将严格按照预定顺序完成所有任务..."
sleep 2

# --- 步骤 1: 基础环境设置 (DNS修改和系统更新) ---
log_step "1/4" "基础环境设置 (DNS、包管理器、依赖)"

log_info "正在修改DNS为 1.1.1.1 和 8.8.8.8..."
chattr -i /etc/resolv.conf &>/dev/null
\cp /etc/resolv.conf /etc/resolv.conf.bak
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf

log_info "正在配置包管理器并更新..."
dpkg --configure -a &>/dev/null
apt update -y

log_info "正在安装核心依赖 (ipset, iptables-persistent)..."
# 预设iptables-persistent的配置，实现全自动安装
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt install ipset iptables-persistent -y

# --- 步骤 2: 执行 deploy_manager.sh 的全部逻辑 ---
run_deploy_manager() {
    log_step "2/4" "执行 deploy_manager.sh 的全部逻辑"
    
    # ##################################################################
    # ##                                                              ##
    # ##  ⬇️ 以下是 deploy_manager.sh 的完整内联脚本 ⬇️                 ##
    # ##                                                              ##
    # ##################################################################

    # --- 配置 ---
    # 注意：这里的URL已不再使用，因为子脚本已被内联
    # DNSMASQ_SNIPROXY_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/dnsmasq_sniproxy.sh"
    # WHITELIST_INSTALLER_URL="https://raw.githubusercontent.com/Sysrous/qita/refs/heads/main/install_whitelist.sh"
    GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
    info() { echo -e "${GREEN}[INFO]${NC} $1"; }; warn() { echo -e "${YELLOW}[WARN]NC} $1"; }; error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }; step() { echo -e "\n${BLUE}>>> 子步骤 ${1}: ${2}${NC}"; }
    # --- 辅助函数 ---
    check_root() { if [ "$(id -u)" -ne 0 ]; then error "此脚本必须以 root 用户权限运行。"; fi; }
    update_package_manager() {
        info "正在更新软件包列表..."
        if command -v apt-get &> /dev/null; then
            apt-get update -y >/dev/null 2>&1 || warn "apt-get update 失败，但仍将继续。"
        elif command -v yum &> /dev/null; then
            yum makecache fast >/dev/null 2>&1 || warn "yum makecache 失败，但仍将继续。"
        fi
    }
    install_tool() {
        local tool_cmd=$1; local pkg_name=$2; [[ -z "$pkg_name" ]] && pkg_name=$tool_cmd
        if command -v "$tool_cmd" &> /dev/null; then return 0; fi
        warn "命令 '$tool_cmd' 未找到，正在自动安装软件包 '$pkg_name'..."
        local install_success=false
        if command -v apt-get &> /dev/null; then
            apt-get install -y "$pkg_name" >/dev/null 2>&1 && install_success=true
        elif command -v yum &> /dev/null; then
            yum install -y "$pkg_name" >/dev/null 2>&1 && install_success=true
        fi
        if [ "$install_success" = true ]; then info "软件包 '$pkg_name' 安装成功。"; else error "自动安装 '$pkg_name' 失败。请手动安装后再试。"; fi
    }
    # --- 核心功能模块 ---
    # ==================== 全新重构的终极净化模块 ====================
    ultimate_purge() {
        step 1 "执行终极环境净化"
        info "本步骤将停止并彻底移除 dnsmasq, sniproxy, mosdns 及 systemd-resolved..."
        # 1. 停止并禁用所有潜在的冲突服务
        info "正在停止服务: dnsmasq, sniproxy, mosdns, systemd-resolved..."
        systemctl stop dnsmasq.service sniproxy.service mosdns.service systemd-resolved.service >/dev/null 2>&1
        systemctl disable dnsmasq.service sniproxy.service mosdns.service systemd-resolved.service >/dev/null 2>&1
        
        # 2. 彻底卸载软件包
        info "正在卸载软件包: dnsmasq, sniproxy..."
        if command -v apt-get &> /dev/null; then
            apt-get purge -y dnsmasq sniproxy dnsmasq-base >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum remove -y dnsmasq sniproxy >/dev/null 2>&1
        fi
        # 3. 删除残留的配置文件和二进制文件 (特别是针对手动安装的 mosdns)
        info "正在删除残留文件和目录..."
        rm -rf /etc/dnsmasq.conf /etc/dnsmasq.d /etc/sniproxy.conf /etc/mosdns /usr/local/bin/mosdns /etc/systemd/system/mosdns.service /etc/systemd/system/sniproxy.service
        # 4. 重新加载 systemd 并恢复网络
        info "正在重载 systemd 并恢复系统 DNS..."
        systemctl daemon-reload
        if [ -f /etc/resolv.conf ]; then chattr -i /etc/resolv.conf >/dev/null 2>&1; fi
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
        info "终极净化完成。环境已清理至最干净状态。"
    }
    pre_flight_checks() {
        step 2 "环境预检查与依赖安装"
        update_package_manager
        install_tool "lsof" "lsof"
        install_tool "wget" "wget"
        install_tool "dig" "dnsutils"
        REQUIRED_PORTS=(53 80 443)
        info "验证端口 ${REQUIRED_PORTS[*]} 在净化后是否可用..."
        for port in "${REQUIRED_PORTS[@]}"; do
            if lsof -ti tcp:"${port}" -sTCP:LISTEN >/dev/null; then
                local pid; pid=$(lsof -ti tcp:"${port}" -sTCP:LISTEN)
                local process_name; process_name=$(ps -p "$pid" -o comm=)
                error "严重错误：在终极净化后，端口 ${port} 仍然被未知进程 '${process_name}' (PID: ${pid}) 占用。脚本无法继续，请手动排查。"
            fi
        done
        info "端口验证通过！所有必需端口均可用。"
    }
    
    install_core_services() {
        step 3 "安装核心服务 (Dnsmasq + SNI Proxy)"
        install_tool "ifconfig" "net-tools"
        info "正在执行内联的 Dnsmasq + SNI Proxy 安装脚本..."

        # ##################################################################
        # ##  ⬇️ dnsmasq_sniproxy.sh 的完整内联脚本内容 START ⬇️            ##
        # ##################################################################
        (
            # Run in a subshell to avoid variable conflicts
            PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
            export PATH
            red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'
            disable_selinux(){ if [ -s /etc/selinux/config ] && grep 'SELINUX=enforcing' /etc/selinux/config; then sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config; setenforce 0; fi; };
            check_sys(){ local a=$1; local b=$2; local c=''; local d=''; if [[ -f /etc/redhat-release ]]; then c="centos"; d="yum"; elif grep -Eqi "debian|raspbian" /etc/issue; then c="debian"; d="apt"; elif grep -Eqi "ubuntu" /etc/issue; then c="ubuntu"; d="apt"; elif grep -Eqi "centos|red hat|redhat" /etc/issue; then c="centos"; d="yum"; elif grep -Eqi "debian|raspbian" /proc/version; then c="debian"; d="apt"; elif grep -Eqi "ubuntu" /proc/version; then c="ubuntu"; d="apt"; elif grep -Eqi "centos|red hat|redhat" /proc/version; then c="centos"; d="yum"; fi; if [[ "${a}" == "sysRelease" ]]; then if [ "${b}" == "${c}" ]; then return 0; else return 1; fi; elif [[ "${a}" == "packageManager" ]]; then if [ "${b}" == "${d}" ]; then return 0; else return 1; fi; fi; };
            getversion(){ if [[ -s /etc/redhat-release ]]; then grep -oE "[0-9.]+" /etc/redhat-release; else grep -oE "[0-9.]+" /etc/issue; fi; };
            centosversion(){ if check_sys sysRelease centos; then local a=$1; local b="$(getversion)"; local c=${b%%.*}; if [ "$c" == "$a" ]; then return 0; else return 1; fi; else return 1; fi; };
            get_ip(){ local a=$( ip addr | egrep -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | egrep -v "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | head -n 1 ); [ -z ${a} ] && a=$( wget -qO- -t1 -T2 ipv4.icanhazip.com ); [ -z ${a} ] && a=$( wget -qO- -t1 -T2 ipinfo.io/ip ); echo ${a}; };
            download(){ local a=${1}; echo -e "[${green}Info${plain}] ${a} download configuration now..."; wget --no-check-certificate -q -t3 -T60 -O ${1} ${2}; if [ $? -ne 0 ]; then echo -e "[${red}Error${plain}] Download ${a} failed."; exit 1; fi; };
            error_detect_depends(){ local a=$1; local b=`echo "${a}" | awk '{print $4}'`; echo -e "[${green}Info${plain}] Starting to install package ${b}"; ${a} > /dev/null 2>&1; if [ $? -ne 0 ]; then echo -e "[${red}Error${plain}] Failed to install ${red}${b}${plain}"; exit 1; fi; };
            install_dependencies(){ echo "安装依赖软件..."; if check_sys packageManager yum; then echo -e "[${green}Info${plain}] Checking the EPEL repository..."; if [ ! -f /etc/yum.repos.d/epel.repo ]; then yum install -y epel-release > /dev/null 2>&1; fi; [ ! -f /etc/yum.repos.d/epel.repo ] && echo -e "[${red}Error${plain}] Install EPEL repository failed, please check it." && exit 1; [ ! "$(command -v yum-config-manager)" ] && yum install -y yum-utils > /dev/null 2>&1; [ x"$(yum repolist epel | grep -w epel | awk '{print $NF}')" != x"enabled" ] && yum-config-manager --enable epel > /dev/null 2>&1; echo -e "[${green}Info${plain}] Checking the EPEL repository complete..."; yum_depends=(curl gettext libev-dev libpcre3-dev libudns-dev); for b in ${yum_depends[@]}; do error_detect_depends "yum -y install ${b}"; done; elif check_sys packageManager apt; then apt_depends=(curl gettext libev-dev libpcre3-dev libudns-dev); apt-get -y update; for b in ${apt_depends[@]}; do error_detect_depends "apt-get -y install ${b}"; done; fi; };
            install_dnsmasq(){ netstat -a -n -p | grep LISTEN | grep -P "\d+\.\d+\.\d+\.\d+:53\s+" > /dev/null && echo -e "[${red}Error${plain}] required port 53 already in use\n" && exit 1; echo "安装Dnsmasq..."; if check_sys packageManager yum; then error_detect_depends "yum -y install dnsmasq"; elif check_sys packageManager apt; then error_detect_depends "apt -y install dnsmasq"; fi; [ ! -f /usr/sbin/dnsmasq ] && echo -e "[${red}Error${plain}] 安装dnsmasq出现问题，请检查." && exit 1; download /etc/dnsmasq.d/custom_netflix.conf https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/dnsmasq.conf; download /tmp/proxy-domains.txt https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/proxy-domains.txt; for a in $(cat /tmp/proxy-domains.txt); do printf "address=/${a}/${publicip}\n" | tee -a /etc/dnsmasq.d/custom_netflix.conf > /dev/null 2>&1; done; [ "$(grep -x -E "(conf-dir=/etc/dnsmasq.d|conf-dir=/etc/dnsmasq.d,.bak|conf-dir=/etc/dnsmasq.d/,\*.conf|conf-dir=/etc/dnsmasq.d,.rpmnew,.rpmsave,.rpmorig)" /etc/dnsmasq.conf)" ] || echo -e "\nconf-dir=/etc/dnsmasq.d" >> /etc/dnsmasq.conf; echo "启动 Dnsmasq 服务..."; if check_sys packageManager yum; then if centosversion 6; then chkconfig dnsmasq on; service dnsmasq start; else systemctl enable dnsmasq; systemctl start dnsmasq; fi; elif check_sys packageManager apt; then if grep -q "^#IGNORE_RESOLVCONF=yes" /etc/default/dnsmasq; then sed -i 's/^#IGNORE_RESOLVCONF=yes/IGNORE_RESOLVCONF=yes/' /etc/default/dnsmasq; elif ! grep -q "^IGNORE_RESOLVCONF=yes" /etc/default/dnsmasq; then echo "IGNORE_RESOLVCONF=yes" >> /etc/default/dnsmasq; fi; systemctl enable dnsmasq; systemctl restart dnsmasq; fi; cd /tmp; rm -f /tmp/proxy-domains.txt; echo -e "[${green}Info${plain}] dnsmasq install complete..."; };
            install_sniproxy(){ for a in 80 443; do netstat -a -n -p | grep LISTEN | grep -P "\d+\.\d+\.\d+\.\d+:${a}\s+" > /dev/null && echo -e "[${red}Error${plain}] required port ${a} already in use\n" && exit 1; done; install_dependencies; echo "安装SNI Proxy..."; bit=`uname -m`; cd /tmp; if check_sys packageManager yum; then if [[ ${bit} = "x86_64" ]]; then download /tmp/sniproxy-0.6.1-1.el8.x86_64.rpm https://github.com/Sysrous/dnsmasq_sniproxy_install/raw/master/sniproxy/sniproxy-0.6.1-1.el8.x86_64.rpm; error_detect_depends "yum -y install /tmp/sniproxy-0.6.1-1.el8.x86_64.rpm"; rm -f /tmp/sniproxy-0.6.1-1.el8.x86_64.rpm; else echo -e "${red}暂不支持${bit}内核，请使用编译模式安装！${plain}" && exit 1; fi; if centosversion 6; then download /etc/init.d/sniproxy https://raw.githubusercontent.com/dlundquist/sniproxy/master/redhat/sniproxy.init && chmod +x /etc/init.d/sniproxy; [ ! -f /etc/init.d/sniproxy ] && echo -e "[${red}Error${plain}] 下载Sniproxy启动文件出现问题，请检查." && exit 1; else download /etc/systemd/system/sniproxy.service https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/sniproxy.service; systemctl daemon-reload; [ ! -f /etc/systemd/system/sniproxy.service ] && echo -e "[${red}Error${plain}] 下载Sniproxy启动文件出现问题，请检查." && exit 1; fi; elif check_sys packageManager apt; then if [[ ${bit} = "x86_64" ]]; then download /tmp/sniproxy_0.6.1_amd64.deb https://github.com/Sysrous/dnsmasq_sniproxy_install/raw/master/sniproxy/sniproxy_0.6.1_amd64.deb; error_detect_depends "dpkg -i --no-debsig /tmp/sniproxy_0.6.1_amd64.deb"; rm -f /tmp/sniproxy_0.6.1_amd64.deb; else echo -e "${red}暂不支持${bit}内核，请使用编译模式安装！${plain}" && exit 1; fi; download /etc/systemd/system/sniproxy.service https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/sniproxy.service; systemctl daemon-reload; [ ! -f /etc/systemd/system/sniproxy.service ] && echo -e "[${red}Error${plain}] 下载Sniproxy启动文件出现问题，请检查." && exit 1; fi; [ ! -f /usr/sbin/sniproxy ] && echo -e "[${red}Error${plain}] 安装Sniproxy出现问题，请检查." && exit 1; download /etc/sniproxy.conf https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/sniproxy.conf; download /tmp/sniproxy-domains.txt https://raw.githubusercontent.com/Sysrous/dnsmasq_sniproxy_install/master/proxy-domains.txt; sed -i -e 's/\./\\\./g' -e 's/^/    \.\*/' -e 's/$/\$ \*/' /tmp/sniproxy-domains.txt || (echo -e "[${red}Error:${plain}] Failed to configuration sniproxy." && exit 1); sed -i '/table {/r /tmp/sniproxy-domains.txt' /etc/sniproxy.conf || (echo -e "[${red}Error:${plain}] Failed to configuration sniproxy." && exit 1); if [ ! -e /var/log/sniproxy ]; then mkdir /var/log/sniproxy; fi; echo "启动 SNI Proxy 服务..."; if check_sys packageManager yum; then if centosversion 6; then chkconfig sniproxy on > /dev/null 2>&1; service sniproxy start || (echo -e "[${red}Error:${plain}] Failed to start sniproxy." && exit 1); else systemctl enable sniproxy > /dev/null 2>&1; systemctl start sniproxy || (echo -e "[${red}Error:${plain}] Failed to start sniproxy." && exit 1); fi; elif check_sys packageManager apt; then systemctl enable sniproxy > /dev/null 2>&1; systemctl restart sniproxy || (echo -e "[${red}Error:${plain}] Failed to start sniproxy." && exit 1); fi; cd /tmp; rm -f /tmp/sniproxy-domains.txt; echo -e "[${green}Info${plain}] sniproxy install complete..."; };
            install_check(){ if check_sys packageManager yum || check_sys packageManager apt; then if centosversion 5; then return 1; fi; return 0; else return 1; fi; };
            ready_install(){ if ! install_check; then echo -e "[${red}Error${plain}] Your OS is not supported to run it!" && exit 1; fi; if check_sys packageManager yum; then yum makecache; error_detect_depends "yum -y install net-tools"; error_detect_depends "yum -y install wget"; elif check_sys packageManager apt; then apt update; error_detect_depends "apt-get -y install net-tools"; error_detect_depends "apt-get -y install wget"; fi; disable_selinux; };
            fastmode=1; ports="53 80 443"; publicip=$(get_ip); ready_install; install_dnsmasq; install_sniproxy;
        )
        local exit_code=$?
        # ##################################################################
        # ##  ⬆️ dnsmasq_sniproxy.sh 的完整内联脚本内容 END ⬆️              ##
        # ##################################################################
        [ ${exit_code} -ne 0 ] && error "核心服务安装脚本执行失败。"
        info "核心服务安装脚本执行完毕。"
    }

    apply_whitelist() {
        step 4 "应用白名单配置"
        info "正在执行内联的白名单安装脚本..."
        # ##################################################################
        # ##  ⬇️ install_whitelist.sh 的完整内联脚本内容 START ⬇️           ##
        # ##################################################################
        (
            # Run in a subshell
            set -e
            MAIN_SCRIPT_URL="https://dl.xinluc.com/update_whitelist.sh"
            MAIN_SCRIPT_PATH="/usr/local/bin/update_whitelist.sh"
            REQUIRED_PKGS="cron wget ipset iptables-persistent"
            SILENT_MODE=true # Force silent mode inside the main script
            
            # Re-check deps silently
            deps_missing=false
            for pkg in $REQUIRED_PKGS; do
                if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
                    deps_missing=true; break
                fi
            done
            if $deps_missing; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq < /dev/null
                apt-get install -y -qq $REQUIRED_PKGS < /dev/null
            fi
            
            wget -q -O "$MAIN_SCRIPT_PATH" "$MAIN_SCRIPT_URL"
            chmod +x "$MAIN_SCRIPT_PATH"
            "$MAIN_SCRIPT_PATH" &>/dev/null
            (crontab -l 2>/dev/null | grep -Fv "$MAIN_SCRIPT_PATH"; echo "*/5 * * * * ${MAIN_SCRIPT_PATH} >/dev/null 2>&1") | crontab -
        )
        local exit_code=$?
        # ##################################################################
        # ##  ⬆️ install_whitelist.sh 的完整内联脚本内容 END ⬆️             ##
        # ##################################################################
        [ ${exit_code} -ne 0 ] && warn "白名单脚本执行时似乎有错误，但我们将继续。"
        info "白名单配置已应用。正在重启 Dnsmasq 服务以加载新规则..."
        systemctl restart dnsmasq.service; sleep 2
        info "服务已重启。"
    }

    final_verification() {
        step 5 "最终服务健康检查"
        info "在修改系统DNS前，进行最后的、最严格的验证..."
        local max_retries=10; local retry_count=0
        until lsof -i :53 -sTCP:LISTEN >/dev/null; do
            retry_count=$((retry_count + 1))
            [ $retry_count -gt $max_retries ] && error "验证失败：Dnsmasq 未能在53端口启动。"
            echo -e "${YELLOW}[WAIT]${NC} 等待 Dnsmasq 在53端口启动... (${retry_count}/${max_retries})"
            sleep 1
        done
        info "端口验证成功：Dnsmasq 正在监听端口 53。"
        info "正在进行本地 DNS 健康检查 (查询 google.com)..."
        if ! dig @127.0.0.1 google.com +short +time=2 | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            error "本地DNS健康检查失败！Dnsmasq 服务虽在运行，但无法正确解析域名。"
        fi
        info "健康检查成功！本地 Dnsmasq 服务功能完备，工作正常。"
    }
    configure_system_resolver() {
        step 6 "配置系统使用本地DNS服务"
        info "所有检查均已通过。现在，安全地将系统 DNS 指向本地。"
        if [ -f /etc/resolv.conf ]; then chattr -i /etc/resolv.conf >/dev/null 2>&1; fi
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        info "系统 DNS 已成功配置为 127.0.0.1。未进行任何文件锁定。"
    }
    configure_xrayr() {
        step 7 "可选: 自动配置 XrayR"
        local xrayr_config="/etc/XrayR/config.yml"
        if [ -f "$xrayr_config" ]; then
            info "检测到 XrayR 配置文件，开始自动配置 DNS..."
            if grep -q "Enable: false" "$xrayr_config"; then sed -i 's/Enable: false/Enable: true/' "$xrayr_config"; info "XrayR DNS 配置已启用 (Enable: true)。"; fi
            info "正在重启 XrayR 服务以应用更改..."; systemctl restart XrayR
        else info "未检测到 XrayR 配置文件，跳过此步骤。"; fi
    }
    # --- 主逻辑 ---
    main() {
        check_root
        ultimate_purge
        pre_flight_checks
        install_core_services
        apply_whitelist
        final_verification
        configure_system_resolver
        configure_xrayr
        echo -e "\n${GREEN}================== 🎉 deploy_manager 任务执行完毕！🎉 ==================${NC}"
    }
    main "$@"

    # ##################################################################
    # ##                                                              ##
    # ##  ⬆️ 以上是 deploy_manager.sh 的完整内联脚本 ⬆️                 ##
    # ##                                                              ##
    # ##################################################################
}


# --- 步骤 3: 执行 diable.sh (防火墙迁移脚本) 的全部逻辑 ---
run_firewall_migration() {
    log_step "3/4" "执行防火墙迁移与整合脚本 (原 diable.sh)"

    # ##################################################################
    # ##                                                              ##
    # ##  ⬇️ 以下是 diable.sh 的完整内联脚本 ⬇️                         ##
    # ##                                                              ##
    # ##################################################################

    # --- 配置区 ---
    BACKUP_SSH_PORT="2233"
    PORT_RANGE_ANYWHERE_TCP="5000:65535"
    PORT_RANGE_ANYWHERE_UDP="5000:65535"
    PORTS_WHITELIST="53 80 443"
    SET_NAME="rpc_whitelist"
    
    # 重新定义日志函数以匹配此脚本的风格
    fw_log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
    fw_log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
    fw_log_error() { echo -e "${RED}[错误]${NC} $1"; }

    fw_log_info "--- 子步骤 1/6: 自动检测 SSH 端口... ---"
    DETECTED_SSH_PORT=$(grep -i "^ *Port" /etc/ssh/sshd_config | grep -v "^#" | awk '{print $2}')
    if [[ -z "$DETECTED_SSH_PORT" ]]; then
        DETECTED_SSH_PORT="22"
        fw_log_warn "未在 /etc/ssh/sshd_config 中找到明确的Port配置，将使用默认端口 22。"
    else
        fw_log_info "成功检测到当前SSH端口为: ${YELLOW}${DETECTED_SSH_PORT}${NC}"
    fi
    PORTS_ANYWHERE_TCP="$DETECTED_SSH_PORT"
    if [[ "$DETECTED_SSH_PORT" != "$BACKUP_SSH_PORT" ]]; then
        PORTS_ANYWHERE_TCP="$PORTS_ANYWHERE_TCP $BACKUP_SSH_PORT"
    fi
    fw_log_info "将对任何人开放以下SSH端口: ${YELLOW}${PORTS_ANYWHERE_TCP}${NC}"

    fw_log_info "--- 子步骤 2/6: 检查并创建 ipset 集合... ---"
    if ! ipset list -n | grep -q "^${SET_NAME}$"; then
        fw_log_warn "ipset 集合 '${SET_NAME}' 不存在。正在创建..."
        ipset create "${SET_NAME}" hash:ip
        fw_log_info "集合已创建。请记得运行一次白名单更新脚本来填充IP。"
    else
        fw_log_info "ipset 集合 '${SET_NAME}' 已存在。"
    fi

    fw_log_info "--- 子步骤 3/6: 建立新的、统一的 iptables 规则集... ---"
    fw_log_warn "临时将 INPUT 策略设置为 ACCEPT 以防断连..."
    iptables -P INPUT ACCEPT
    ip6tables -P INPUT ACCEPT &>/dev/null || true # Ignore error if ipv6 is not available
    fw_log_info "正在清空所有旧的 IPv4 和 IPv6 规则..."
    iptables -F && iptables -X
    ip6tables -F && ip6tables -X &>/dev/null || true
    
    fw_log_info "正在构建新的防火墙规则..."
    build_rules() {
        local ipt_cmd=$1
        $ipt_cmd -A INPUT -i lo -j ACCEPT
        $ipt_cmd -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        for port in $PORTS_ANYWHERE_TCP; do
            $ipt_cmd -A INPUT -p tcp --dport "$port" -j ACCEPT
        done
        if [ -n "$PORT_RANGE_ANYWHERE_TCP" ]; then
            $ipt_cmd -A INPUT -p tcp --dport "$PORT_RANGE_ANYWHERE_TCP" -j ACCEPT
        fi
        if [ -n "$PORT_RANGE_ANYWHERE_UDP" ]; then
            $ipt_cmd -A INPUT -p udp --dport "$PORT_RANGE_ANYWHERE_UDP" -j ACCEPT
        fi
    }
    
    # 应用 IPv4 规则
    build_rules iptables
    for port in $PORTS_WHITELIST; do
        iptables -A INPUT -p tcp -m set --match-set "${SET_NAME}" src --dport "$port" -j ACCEPT
        iptables -A INPUT -p udp -m set --match-set "${SET_NAME}" src --dport "$port" -j ACCEPT
    done
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # 应用 IPv6 规则 (如果可用)
    if command -v ip6tables &>/dev/null; then
        build_rules ip6tables
        ip6tables -P INPUT DROP
        ip6tables -P FORWARD DROP
        ip6tables -P OUTPUT ACCEPT
    fi
    fw_log_info "${GREEN}✅ 新的防火墙规则集已成功应用。${NC}"

    fw_log_info "--- 子步骤 4/6: 禁用 UFW 服务... ---"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        fw_log_warn "检测到 UFW 正在运行，现在将禁用它..."
        ufw disable
        fw_log_info "${GREEN}✅ UFW 已成功禁用，冲突源已移除。${NC}"
    else
        fw_log_info "UFW 已经是禁用状态或未安装，无需操作。"
    fi

    fw_log_info "--- 子步骤 5/6: 持久化新的 iptables 规则... ---"
    netfilter-persistent save
    fw_log_info "${GREEN}✅ 所有规则已保存，将在系统重启后自动加载。${NC}"

    fw_log_info "--- 子步骤 6/6: 最终状态检查 ---"
    echo "--- 当前 IPv4 规则 (iptables -L -n -v) ---"
    iptables -L -n -v --line-numbers
    echo "-------------------------------------------"
    # ##################################################################
    # ##                                                              ##
    # ##  ⬆️ 以上是 diable.sh 的完整内联脚本 ⬆️                         ##
    # ##                                                              ##
    # ##################################################################
}

# --- 步骤 4: 按顺序执行所有主要功能 ---
log_step "4/4" "开始执行主要任务流程"
run_deploy_manager
run_firewall_migration

echo -e "\n${GREEN}🎉🎉🎉 全部任务已严格按照您的要求执行完毕！🎉🎉🎉${NC}"
