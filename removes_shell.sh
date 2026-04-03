#!/bin/bash
if [ "$(id -u)" != "0" ]; then
   echo "请以 root 权限运行此脚本"
   exit 1
fi

echo "=== 开始暴力清理 ==="

# ================= 配置区域 =================
# 定义目标路径
DIR1="/usr/local/hippo-network-agent"
DIR2="/opt/zf"
DIR3="/root/zf"     # 之前的路径
DIR4="/etc/realm"   # <--- 新增路径 (请确认拼写是否正确，如需删除 realm 请改为 /etc/realm)

SERVICE_LINK="/etc/systemd/system/multi-user.target.wants/hippo-agent.service"
SERVICE_FILE="/etc/systemd/system/hippo-agent.service"
# ===========================================

# 1. 解锁文件属性 (关键步骤：防止 rm -rf 失败)
echo "1. 正在尝试解锁文件属性 (chattr -i)..."
if command -v chattr >/dev/null 2>&1; then
    chattr -R -i "$DIR1" 2>/dev/null
    chattr -R -i "$DIR2" 2>/dev/null
    chattr -R -i "$DIR3" 2>/dev/null
    chattr -R -i "$DIR4" 2>/dev/null # <--- 新增解锁
    chattr -i "$SERVICE_LINK" 2>/dev/null
    chattr -i "$SERVICE_FILE" 2>/dev/null
else
    echo "警告: 未找到 chattr 命令，跳过解锁步骤。"
fi

# 2. 停止服务
echo "2. 停止 Systemd 服务..."
systemctl stop hippo-agent.service 2>/dev/null
systemctl disable hippo-agent.service 2>/dev/null

# 3. 强制杀掉进程
echo "3. 查找并杀掉相关进程..."
# 获取进程名包含 hippo-network-agent 的所有 PID
# 排除 grep 自身的进程
PIDS=$(ps -ef | grep "hippo-network-agent" | grep -v grep | awk '{print $2}')

if [ -n "$PIDS" ]; then
    echo "发现进程 PID: $PIDS，正在 Kill -9..."
    echo "$PIDS" | xargs kill -9
else
    echo "未发现运行中的进程。"
fi

# 再次检查是否还有残留 (防止杀掉后立刻重启)
sleep 1
PIDS_REMAIN=$(ps -ef | grep "hippo-network-agent" | grep -v grep | awk '{print $2}')
if [ -n "$PIDS_REMAIN" ]; then
    echo "警告：进程顽固，再次尝试清理..."
    echo "$PIDS_REMAIN" | xargs kill -9
fi

# 4. 删除文件和目录
echo "4. 执行删除操作..."

# 删除服务文件
if [ -f "$SERVICE_LINK" ] || [ -L "$SERVICE_LINK" ]; then
    rm -f "$SERVICE_LINK"
    echo "已删除: $SERVICE_LINK"
fi

if [ -f "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
    echo "已删除: $SERVICE_FILE"
fi

# 删除目录 DIR1
if [ -d "$DIR1" ]; then
    rm -rf "$DIR1"
    if [ ! -d "$DIR1" ]; then
        echo "已删除: $DIR1"
    else
        echo "错误: $DIR1 删除失败 (可能仍被占用)"
    fi
else
    echo "路径已不存在: $DIR1"
fi

# 删除目录 DIR2
if [ -d "$DIR2" ]; then
    rm -rf "$DIR2"
    if [ ! -d "$DIR2" ]; then
        echo "已删除: $DIR2"
    else
        echo "错误: $DIR2 删除失败"
    fi
else
    echo "路径已不存在: $DIR2"
fi

# 删除目录 DIR3 (/root/zf)
if [ -e "$DIR3" ]; then
    rm -rf "$DIR3"
    if [ ! -e "$DIR3" ]; then
        echo "已删除: $DIR3"
    else
        echo "错误: $DIR3 删除失败"
    fi
else
    echo "路径已不存在: $DIR3"
fi

# 删除目录 DIR4 (/etc/relam) <--- 新增删除逻辑
if [ -e "$DIR4" ]; then
    rm -rf "$DIR4"
    if [ ! -e "$DIR4" ]; then
        echo "已删除: $DIR4"
    else
        echo "错误: $DIR4 删除失败"
    fi
else
    echo "路径已不存在: $DIR4"
fi

# 5. 刷新系统配置
systemctl daemon-reload
echo "=== 清理结束 ==="
