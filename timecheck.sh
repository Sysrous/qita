#!/bin/bash
# ----------------------------------------------------------
#  跨发行版时区 & 时间同步一键初始化
#  支持 Debian/Ubuntu/CentOS/RHEL/Rocky/Alma/Alpine
# ----------------------------------------------------------
set -euo pipefail

TZ="Asia/Shanghai"

# 1. 检测发行版
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "无法识别系统" >&2; exit 1
fi

echo "==> 检测到系统：$OS"

# 2. 设置时区
# 特殊处理：Alpine 默认不带时区数据，需先安装
if [ "$OS" == "alpine" ]; then
    # 检查是否已安装 tzdata，未安装则安装
    if ! [ -d /usr/share/zoneinfo ]; then
        echo "==> Alpine: 安装 tzdata 以支持时区设置..."
        apk add --no-cache tzdata
    fi
fi

if command -v timedatectl &>/dev/null; then
    timedatectl set-timezone "$TZ"
else
    # 极简系统/容器/Alpine 无 timedatectl
    if [ -f "/usr/share/zoneinfo/$TZ" ]; then
        ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
        echo "$TZ" > /etc/timezone
    else
        echo "警告：未找到时区文件 /usr/share/zoneinfo/$TZ，跳过时区设置。"
    fi
fi
echo "==> 时区已设为 $TZ"

# 3. 安装并启动时间同步服务
case "$OS" in
    ubuntu|debian)
        apt-get update -qq
        apt-get install -y chrony sudo
        systemctl enable --now chrony
        echo "==> Debian/Ubuntu：已安装并启动 chrony"
        ;;
    centos|rhel|rocky|almalinux)
        if command -v dnf &>/dev/null; then
            dnf install -y chrony sudo
        else
            yum install -y chrony sudo
        fi
        systemctl enable --now chronyd
        echo "==> CentOS/RHEL：已安装并启动 chronyd"
        ;;
    alpine)
        # Alpine 使用 apk 和 OpenRC
        apk add --no-cache chrony sudo
        # 确保服务随开机启动 (OpenRC)
        if command -v rc-update &>/dev/null; then
            rc-update add chronyd default
            rc-service chronyd restart
        else
            # 容器环境可能没有 OpenRC，直接前台运行一下或者仅依靠 chronyc
            echo "警告：未检测到 OpenRC，尝试直接启动 chronyd..."
            chronyd -d || true
        fi
        echo "==> Alpine：已安装并启动 chronyd"
        ;;
    *)
        echo "未支持系统：$OS" >&2; exit 1
        ;;
esac

# 4. 立即强制同步一次
echo "==> 正在尝试强制同步时间..."

# 判断是否为 systemd 系统
if command -v systemctl &>/dev/null; then
    if systemctl is-active chronyd &>/dev/null || systemctl is-active chrony &>/dev/null; then
        chronyc -a makestep
    elif command -v ntpdate &>/dev/null; then
        ntpdate -u pool.ntp.org
    fi
# 判断是否为 Alpine (OpenRC)
elif [ "$OS" == "alpine" ]; then
    # 给 chronyd 一点启动时间
    sleep 2
    if command -v chronyc &>/dev/null; then
        chronyc -a makestep || echo "chrony 同步指令发送失败 (可能服务未完全就绪)，但已安装。"
    fi
else
    # 极简 fallback
    if command -v ntpdate &>/dev/null; then
        ntpdate -u pool.ntp.org
    fi
fi

echo "==> 时间同步操作结束"

# 5. 查看状态
echo "------------------------------------------------"
if command -v timedatectl &>/dev/null; then
    timedatectl status
else
    echo "Current Time: $(date)"
    echo "Timezone:     $(cat /etc/timezone 2>/dev/null || echo 'Unknown')"
fi
echo "------------------------------------------------"
