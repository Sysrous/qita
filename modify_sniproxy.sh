#!/bin/bash

# ==============================================================================
#  一键修改 SniProxy 配置脚本 - 移除 80 端口监听
# ==============================================================================

# 定义颜色以便输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置文件路径
SNI_CONF="/etc/sniproxy.conf"

# --- 1. 权限和环境检查 ---
echo -e "${YELLOW}--- 开始执行 sniproxy 配置修改脚本 ---${NC}"

# 必须以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${RED}错误：此脚本必须以 root 权限运行。请使用 'sudo ./modify_sniproxy.sh' 执行。${NC}" >&2
   exit 1
fi

# 检查 sniproxy 配置文件是否存在
if [ ! -f "$SNI_CONF" ]; then
    echo -e "${RED}错误：未找到 sniproxy 配置文件: $SNI_CONF ${NC}"
    echo "请确认 sniproxy 是否已正确安装。"
    exit 1
fi

# --- 2. 检查是否需要修改 ---
# 使用 grep 查找未被注释的 'listener ...:80' 行
if ! grep -qP "^\s*listener\s+.*:\s*80" "$SNI_CONF"; then
    echo -e "${GREEN}检查发现 sniproxy 已配置为不监听 80 端口，无需任何操作。${NC}"
    exit 0
fi

echo "检测到 sniproxy 正在监听 80 端口，准备进行修改..."
echo ""

# --- 3. 备份与修改 ---
# 创建带时间戳的备份
BACKUP_FILE="${SNI_CONF}.bak-$(date +%F_%T)"
echo "--> 正在备份当前配置文件到: $BACKUP_FILE"
cp "$SNI_CONF" "$BACKUP_FILE"

# 使用 sed 注释掉整个 80 端口的 listener 块
# 这个命令会找到以 'listener ...:80 {' 开始，到第一个单独的 '}' 结束的块，并将每一行前面加上 '#'
echo "--> 正在注释掉 80 端口的监听配置..."
sed -i -e '/^\s*listener.*:80\s*{/,/^\s*}/ s/^/#/' "$SNI_CONF"
echo "--> 配置文件修改完成。"
echo ""

# --- 4. 重启并验证 ---
echo "--> 正在重启 sniproxy 服务以应用新配置..."
systemctl restart sniproxy

# 检查服务是否成功重启
if ! systemctl is-active --quiet sniproxy; then
    echo -e "${RED}错误：sniproxy 服务重启失败！${NC}"
    echo "可能是配置文件存在语法错误。请检查 $SNI_CONF 文件。"
    echo "您可以使用以下命令恢复备份: "
    echo -e "${YELLOW}sudo cp $BACKUP_FILE $SNI_CONF && sudo systemctl restart sniproxy${NC}"
    exit 1
fi

echo "--> sniproxy 服务已成功重启。"
echo "--> 正在验证端口监听状态..."

# 检查 sniproxy 是否仍在监听 80 端口
if ss -tlpn | grep sniproxy | grep -q ':80'; then
    echo -e "${RED}验证失败：sniproxy 似乎仍在监听 80 端口。请手动检查配置。${NC}"
    exit 1
else
    echo -e "${GREEN}✔ 验证成功！sniproxy 已不再监听 80 端口。${NC}"
fi

echo ""
echo -e "${GREEN}--- 所有操作已成功完成 ---${NC}"

exit 0
