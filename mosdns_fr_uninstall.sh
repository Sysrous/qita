#!/bin/bash

echo "==================================="
echo "       MosDNS 一键卸载脚本         "
echo "==================================="

# 停止服务
systemctl stop mosdns 2>/dev/null
systemctl disable mosdns 2>/dev/null

# 删除服务文件
rm -f /etc/systemd/system/mosdns.service
rm -f /lib/systemd/system/mosdns.service 2>/dev/null

# 重新加载 systemd
systemctl daemon-reload

# 删除程序和配置
rm -rf /usr/local/bin/mosdns
rm -rf /etc/mosdns

echo ""
echo "✅ MosDNS 已完全卸载！"
echo ""
