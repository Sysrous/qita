#!/bin/bash
set -e

# =========================================================
# 日志自动清理与轮转配置脚本
# 功能：配置 journald 限制1G、配置 rsyslog 轮转、设置定时任务
# =========================================================

# 1. 必须的root权限检查
if [ "$(id -u)" != "0" ]; then
    echo "错误：日志管控需要root权限，请执行 sudo -i 切换后再运行！"
    exit 1
fi

# 2. 配置 systemd-journald (500M自动清理)
echo "===== [1/5] 配置 journald 日志500M自动清理 ====="
cat > /etc/systemd/journald.conf << 'EOF'
[Journal]
Storage=auto
Compress=yes
SystemMaxUse=500M
SystemMaxFileSize=10M
MaxRetentionSec=600
ForwardToSyslog=no
ForwardToConsole=no
MaxFileSec=300
EOF

# 重启 journald 生效
systemctl restart systemd-journald || echo "提示：journald 重启跳过（可能是非systemd环境）"

# 立即清理日志到1G以内
journalctl --vacuum-size=500M || echo "提示：journald 清理跳过"

# 3. 配置 rsyslog logrotate 轮转
echo "===== [2/5] 配置 rsyslog 日志轮转 ====="
# 备份原有配置
cp /etc/logrotate.d/rsyslog /etc/logrotate.d/rsyslog.error.bak 2>/dev/null || echo "提示：无旧配置文件，跳过备份"

# 写入自定义 rsyslog 轮转配置
cat > /etc/logrotate.d/rsyslog << 'EOF'
/var/log/syslog
/var/log/auth.log
{
        rotate 1
        daily
        size 10M
        missingok
        notifempty
        compress
        delaycompress
        sharedscripts
        postrotate
                systemctl restart rsyslog > /dev/null 2>&1 || true
        endscript
        maxage 0.5
}
EOF

# 4. 重新配置定时任务（15分钟轮转）
echo "===== [3/5] 配置 Crontab 定时任务 ====="
# 清理旧的重复任务
sed -i '/logrotate -f \/etc\/logrotate.d\/rsyslog/d' /etc/crontab
# 添加新任务
echo "*/15 * * * * root /usr/sbin/logrotate -f /etc/logrotate.d/rsyslog > /dev/null 2>&1" >> /etc/crontab

# 5. 重启服务 + 立即清理
echo "===== [4/5] 重启服务并执行首次清理 ====="
systemctl restart systemd-journald cron rsyslog > /dev/null 2>&1 || true
> /var/log/syslog
journalctl --vacuum-time=30min --vacuum-size=500M > /dev/null 2>&1
logrotate -vf /etc/logrotate.d/rsyslog

# 6. 最终验证
echo "===== [5/5] 当前日志占用情况 ====="
echo "--- 磁盘空间 (Avail) ---"
df -h / | grep / 
echo "--- Syslog 大小 (应≤10M) ---"
ls -lh /var/log/syslog 2>/dev/null || echo "/var/log/syslog 不存在"
echo "--- Journald 占用 (应≤500M) ---"
journalctl --disk-usage || echo "无 journalctl 命令"

echo "✅ rizhi.sh 脚本执行完毕！日志策略已生效。"
