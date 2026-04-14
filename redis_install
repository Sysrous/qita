#!/bin/bash

#================================================================================
# Redis "源码编译终极版" 通用安装脚本 (已根据您的要求适配)
#
# 版本:   8.6.2 (由您指定)
# 来源:   官方开源仓库 https://github.com/redis/redis/releases
# 适用于: Debian/Ubuntu 等使用 systemd 的 Linux 系统
#================================================================================

# --- !! 核心配置区 !! ---
# 完全按照您的要求，锁定版本为 8.6.2
REDIS_VERSION="8.6.2"

# --- 脚本自动执行区 (请勿轻易修改) ---

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
   echo "错误：此脚本必须以 root 权限运行。" 1>&2
   exit 1
fi

set -e # 任何命令失败则立即退出

echo ">>> 步骤 1/8: 安装编译所需依赖..."
apt-get update
apt-get install -y gcc g++ make libc6-dev libssl-dev tcl pkg-config wget

echo ">>> 步骤 2/8: 下载 Redis ${REDIS_VERSION} 源码..."
# 使用您提供的官方 tar.gz 包地址格式
DOWNLOAD_URL="https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz"
TMP_DIR="/tmp"
TAR_FILE="${TMP_DIR}/redis-${REDIS_VERSION}.tar.gz"
SRC_DIR="${TMP_DIR}/redis-${REDIS_VERSION}" # 解压后的目录名通常是 redis-[版本号]

echo "开始从 ${DOWNLOAD_URL} 下载..."
wget -O "$TAR_FILE" "$DOWNLOAD_URL"
echo "下载完成。"

# 清理旧的源码目录
rm -rf "$SRC_DIR"
tar -xzf "$TAR_FILE" -C "$TMP_DIR"

# GitHub 的 tar 包解压出来目录名是 redis-[版本号]，而不是 redis-[版本号]，需要适配
# 例如 8.6.2.tar.gz 解压出来是 redis-8.6.2 目录
# 为了脚本健壮性，我们动态查找目录
SRC_DIR=$(find "$TMP_DIR" -type d -name "redis-${REDIS_VERSION}*")
if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR" ]; then
    echo "错误：找不到解压后的源码目录。"
    exit 1
fi
echo "源码解压至: ${SRC_DIR}"

echo ">>> 步骤 3/8: 编译 Redis..."
cd "$SRC_DIR"
make

echo ">>> 步骤 4/8: 运行测试套件 (重要步骤)..."
if make test; then
    echo "测试通过！编译质量可靠。"
else
    echo "警告：'make test' 执行失败。请检查日志。继续安装可能存在风险。"
fi

echo ">>> 步骤 5/8: 安装 Redis 二进制文件..."
make install

echo ">>> 步骤 6/8: 创建用户、目录和配置文件..."
if ! id "redis" &>/dev/null; then
    adduser --system --group --no-create-home redis
fi

mkdir -p /var/lib/redis
mkdir -p /etc/redis

chown redis:redis /var/lib/redis
chmod 770 /var/lib/redis

# 从源码目录复制一份干净的配置文件
cp "${SRC_DIR}/redis.conf" /etc/redis/redis.conf

echo "配置 redis.conf 以适配 systemd 和标准目录..."
sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf
sed -i 's/^daemonize yes/daemonize no/' /etc/redis/redis.conf
sed -i "s|^dir ./|dir /var/lib/redis/|" /etc/redis/redis.conf
sed -i "s|^logfile \"\"|logfile /var/log/redis_server.log|" /etc/redis/redis.conf

echo ">>> 步骤 7/8: 创建 systemd 服务文件..."
cat > /etc/systemd/system/redis.service <<EOF
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
User=redis
Group=redis
ExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf
ExecStop=/usr/local/bin/redis-cli shutdown
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

echo ">>> 步骤 8/8: 重新加载 systemd 并启动 Redis..."
systemctl daemon-reload
systemctl enable redis
systemctl start redis

sleep 2 # 等待服务启动

echo "======================================================="
echo " Redis ${REDIS_VERSION} 源码编译安装完成！"
echo "======================================================="

echo "--- 服务状态 ---"
systemctl status redis --no-pager | grep "Active:"
echo ""
echo "--- 版本信息 ---"
redis-server -v
echo ""
echo "--- PING 测试 ---"
redis-cli ping

echo ""
echo "安装成功，服务已启动并已设置为开机自启。"
