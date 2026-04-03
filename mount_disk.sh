# 建议直接复制这一整块代码到终端执行
cat << 'EOF' > mount_www.sh
#!/bin/bash

# 1. 权限检查
[[ $(id -u) != "0" ]] && echo "错误：请以 root 运行！" && exit 1

echo "--- 正在启动 6GB+ 硬盘智能挂载脚本 ---"

# 2. 环境清理：移除之前残留的错误挂载配置 (防止重启黑屏)
sed -i '/\/dev\/sr0/d' /etc/fstab
sed -i '/\/data/d' /etc/fstab
sed -i '/\/www/d' /etc/fstab
umount /data 2>/dev/null
umount /www 2>/dev/null

# 3. 识别主硬盘 (系统盘)
ROOT_DISK=$(lsblk -no PKNAME $(df / | awk 'NR==2 {print $1}') | head -n1)
[[ -z "$ROOT_DISK" ]] && ROOT_DISK=$(lsblk -no NAME $(df / | awk 'NR==2 {print $1}') | head -n1)

# 4. 寻找符合条件的硬盘 (磁盘类型, 不是主盘, 容量 > 6GB)
# 6GB = 6442450944 Bytes
TARGET_DISK=$(lsblk -bnd -o NAME,TYPE,SIZE | awk -v root="$ROOT_DISK" '$2=="disk" && $1!=root && $3>6442450944 {print $1, $3}' | sort -k2 -rn | head -n1 | awk '{print $1}')

if [[ -z "$TARGET_DISK" ]]; then
    echo "❌ 错误：未发现大于 6GB 的可用数据盘！"
    exit 1
fi

# 5. 确定最终挂载路径 (如果有 vdb1 就用 vdb1，否则用 vdb)
PARTITION=$(lsblk -nlo NAME "/dev/$TARGET_DISK" | grep -E "${TARGET_DISK}[0-9]+" | head -n1)
if [[ -z "$PARTITION" ]]; then
    TARGET_PATH="/dev/$TARGET_DISK"
else
    TARGET_PATH="/dev/$PARTITION"
fi

echo "✅ 目标硬盘锁定: $TARGET_PATH"

# 6. 获取主硬盘文件系统格式 (xfs 或 ext4)
MAIN_FS=$(df -T / | awk 'NR==2 {print $2}')
[[ "$MAIN_FS" != "xfs" && "$MAIN_FS" != "ext4" ]] && MAIN_FS="xfs"
echo "⚙️  主硬盘格式为 $MAIN_FS，将执行格式对齐..."

# 7. 准备挂载点并格式化
mkdir -p /www
echo "🏗️  正在格式化 2TB 级别硬盘 $TARGET_PATH (请稍候)..."

if [[ "$MAIN_FS" == "xfs" ]]; then
    mkfs.xfs -f $TARGET_PATH
else
    mkfs.ext4 -F $TARGET_PATH
fi

# 8. 写入 fstab 实现开机自启
UUID=$(blkid -s UUID -o value $TARGET_PATH)
if [[ -z "$UUID" ]]; then
    echo "❌ 错误：无法获取硬盘 UUID！"
    exit 1
fi

# nofail 确保如果盘丢了，系统也能照常启动
echo "UUID=$UUID  /www  $MAIN_FS  defaults,nofail  0  2" >> /etc/fstab

# 9. 执行挂载
systemctl daemon-reload
mount -a

# 10. 最终确认
echo "------------------------------------------"
if mountpoint -q /www; then
    echo "🎉 挂载成功！"
    echo "📍 挂载点: /www"
    echo "📊 容量状态:"
    df -h /www
else
    echo "❌ 挂载失败，请检查硬盘状态。"
fi
echo "------------------------------------------"
EOF

chmod +x mount_www.sh && ./mount_www.sh
