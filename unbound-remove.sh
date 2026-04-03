#!/bin/bash
#====================================================
# 名称: unbound-remove.sh
# 功能: 移除 unbound 非标端口 DNS 转发配置
# 系统: Debian / Ubuntu
#====================================================

echo "🔄 正在清理 unbound 配置..."

# 1. 停止并禁用 unbound
if systemctl is-active --quiet unbound; then
    echo "🛑 停止 unbound 服务..."
    systemctl stop unbound
    systemctl disable unbound > /dev/null 2>&1 || true
fi

# 2. 删除配置文件
UNBOUND_CONF="/etc/unbound/unbound.conf.d/forward-to-custom-dns.conf"
if [ -f "$UNBOUND_CONF" ]; then
    echo "🗑️ 删除配置文件: $UNBOUND_CONF"
    rm -f "$UNBOUND_CONF"
fi

# 3. 卸载 unbound（可选）
echo "🧼 是否卸载 unbound 软件包？[y/N]: "
read -r confirm
case "${confirm:-n}" in
    y|Y|yes|YES)
        echo "📦 正在卸载 unbound..."
        apt remove -y unbound > /dev/null && apt autoremove -y > /dev/null
        ;;
    *)
        echo "ℹ️ 保留 unbound 软件包。"
        ;;
esac

# 4. 恢复 systemd-resolved（如果之前被禁用了）
echo "🔁 是否恢复 systemd-resolved 服务？[Y/n]: "
read -r confirm_restore
case "${confirm_restore:-y}" in
    y|Y|yes|YES)
    echo "🔄 启用并启动 systemd-resolved..."
    systemctl enable systemd-resolved --now 2>/dev/null || true

    # 创建符号链接 /etc/resolv.conf（标准做法）
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    echo "✅ 已恢复 systemd-resolved 和 /etc/resolv.conf"
    ;;
    *)
    echo "🔧 手动设置 /etc/resolv.conf 使用 Google DNS"
    echo -e "nameserver  1.1.1.1\nnameserver  8.8.8.8" > /etc/resolv.conf
    echo "✅ /etc/resolv.conf 已设为公共 DNS"
    ;;
esac

echo
echo "🎉 清理完成！DNS 已恢复默认环境。"
