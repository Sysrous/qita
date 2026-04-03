#!/bin/bash

# ==============================================================================
# Script Name:   add_swap.sh
# Description:   为 Debian/Ubuntu 系统交互式地增加虚拟内存 (Swap)。
#                自动处理已存在的 /swapfile。
# Author:        AI Assistant
# Version:       2.0
# ==============================================================================

# --- 配置颜色输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 步骤 1: 检查是否以 root 权限运行 ---
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${RED}错误: 此脚本必须以 root 权限运行。${NC}"
   echo -e "${YELLOW}请先切换到 root 用户 (例如使用 'sudo -i' 或 'su -')，然后再执行此脚本。${NC}"
   exit 1
fi

# --- 步骤 2: 检测并显示当前硬盘剩余空间 (以 MB 为单位) ---
echo -e "${YELLOW}正在检测根分区 / 的剩余磁盘空间...${NC}"
FREE_DISK_MB=$(df -BM / | awk 'NR==2 {print $4}' | sed 's/M//')

if [ -z "$FREE_DISK_MB" ]; then
    echo -e "${RED}错误: 无法检测到磁盘剩余空间。脚本退出。${NC}"
    exit 1
fi

echo -e "${GREEN}检测完成。当前可用空间为: ${FREE_DISK_MB} MB${NC}"
echo "-----------------------------------------------------"


# --- 步骤 3: 获取用户输入的 Swap 大小 ---
while true; do
    read -p "请输入您希望增加的虚拟内存大小 (单位 MB，直接输入数字): " SWAP_SIZE_MB

    # 验证输入是否为非空正整数
    if [[ "$SWAP_SIZE_MB" =~ ^[1-9][0-9]*$ ]]; then
        # 验证输入大小是否小于可用空间
        if [ "$SWAP_SIZE_MB" -lt "$FREE_DISK_MB" ]; then
            break # 输入有效，跳出循环
        else
            echo -e "${RED}错误: 您输入的 Swap 大小 (${SWAP_SIZE_MB} MB) 大于或等于可用磁盘空间 (${FREE_DISK_MB} MB)。${NC}"
            echo -e "${YELLOW}请输入一个更小的值。${NC}"
        fi
    else
        echo -e "${RED}错误: 无效输入。请输入一个正整数。${NC}"
    fi
done

echo "-----------------------------------------------------"
echo -e "${GREEN}好的，将为您创建一个 ${SWAP_SIZE_MB} MB 大小的虚拟内存文件。${NC}"
echo "-----------------------------------------------------"


# --- 步骤 4: 创建并应用 Swap 文件 ---
SWAP_FILE="/swapfile"

# NEW: 检查 swapfile 是否已存在，如果存在则自动移除
if [ -f "$SWAP_FILE" ]; then
    echo -e "${YELLOW}检测到已存在的 Swap 文件 ${SWAP_FILE}，正在自动移除...${NC}"
    
    # 1. 关闭 Swap
    echo "  -> 正在关闭旧的 Swap: ${SWAP_FILE}"
    swapoff "$SWAP_FILE" >/dev/null 2>&1

    # 2. 从 /etc/fstab 中移除旧配置 (非常重要！)
    #    使用 sed -i.bak 创建备份文件，更安全
    echo "  -> 正在从 /etc/fstab 中移除旧的配置..."
    sed -i.bak "\#${SWAP_FILE}#d" /etc/fstab

    # 3. 删除旧的 Swap 文件
    echo "  -> 正在删除旧的 Swap 文件..."
    rm -f "$SWAP_FILE"

    echo -e "${GREEN}旧的 Swap 已成功移除。${NC}"
    echo "-----------------------------------------------------"
fi

echo -e "${YELLOW}1. 正在创建 Swap 文件，请稍候...${NC}"
fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_FILE"
if [ $? -ne 0 ]; then
    echo -e "${RED}创建 Swap 文件失败。脚本退出。${NC}"
    exit 1
fi

echo -e "${YELLOW}2. 设置文件权限...${NC}"
chmod 600 "$SWAP_FILE"

echo -e "${YELLOW}3. 将文件格式化为 Swap...${NC}"
mkswap "$SWAP_FILE"

echo -e "${YELLOW}4. 强制启用 Swap 文件...${NC}"
swapon "$SWAP_FILE"


# --- 步骤 5: 使 Swap 持久化 ---
echo -e "${YELLOW}5. 将 Swap 配置写入 /etc/fstab 以便开机自启...${NC}"
# 在此之前已经确保旧条目被删除了，所以直接添加即可
echo "$SWAP_FILE   none    swap    sw    0   0" >> /etc/fstab
echo -e "${GREEN}配置已成功写入 /etc/fstab。${NC}"

echo "====================================================="
echo -e "${GREEN}恭喜！虚拟内存已成功创建并激活！${NC}"
echo "====================================================="


# --- 步骤 6: 显示最终结果 ---
echo -e "${YELLOW}--- 当前 Swap 信息 ---${NC}"
swapon --show

echo ""
echo -e "${YELLOW}--- 当前内存和 Swap 使用情况 ---${NC}"
free -h