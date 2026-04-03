#!/bin/bash

# ==============================================================================
# XrayR DNS 和路由配置一键修复脚本
#
# 功能:
# 1. 自动安装 JSON 处理工具 jq。
# 2. 修改 /etc/XrayR/dns.json:
#    - 将 127.0.0.1 的 DNS 端口从 15454 改为 53。
#    - 将其他 DNS 的 10053 端口也改为 53。
# 3. 修改 /etc/XrayR/route.json:
#    - 删除指向本地 15454 端口的特定路由规则。
#
# 安全性:
# - 所有文件修改都通过临时文件进行，确保原子性操作，防止中途失败导致配置损坏。
# - 在操作前检查文件是否存在。
# ==============================================================================

# --- 美化输出 ---
GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; NC="\033[0m"
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 1. 确保以 root 身份运行
if [ "$(id -u)" -ne 0 ]; then
    error "此脚本必须以 root 用户权限运行。"
fi

# 2. 检查并安装 jq
if ! command -v jq &>/dev/null; then
    info "未找到 'jq' 命令，正在尝试自动安装..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y jq
    elif command -v yum &>/dev/null; then
        yum install -y jq
    else
        error "无法确定包管理器，请手动安装 'jq' 后重试。"
    fi
    if ! command -v jq &>/dev/null; then
        error "'jq' 安装失败，请检查您的软件源。"
    fi
    info "'jq' 安装成功。"
fi

# 3. 定义文件路径
DNS_CONFIG="/etc/XrayR/dns.json"
ROUTE_CONFIG="/etc/XrayR/route.json"

# 4. 修改 dns.json
if [ -f "$DNS_CONFIG" ]; then
    info "正在处理 $DNS_CONFIG ..."
    
    # 使用 jq 修改：
    # 1. .servers |= map(...) -> 对 servers 数组中的每个元素进行操作
    # 2. if .address == "127.0.0.1" and .port == 15454 then .port = 53 -> 条件1：修改本地DNS端口
    # 3. elif .port == 10053 then .port = 53 -> 条件2：修改解锁DNS端口
    # 4. else . end -> 保持其他元素不变
    jq '.servers |= map(if .address == "127.0.0.1" and .port == 15454 then .port = 53 elif .port == 10053 then .port = 53 else . end)' "$DNS_CONFIG" > "${DNS_CONFIG}.tmp"
    
    if [ $? -eq 0 ] && [ -s "${DNS_CONFIG}.tmp" ]; then
        mv "${DNS_CONFIG}.tmp" "$DNS_CONFIG"
        info "$DNS_CONFIG 修改成功。"
    else
        rm -f "${DNS_CONFIG}.tmp"
        error "$DNS_CONFIG 修改失败！"
    fi
else
    warn "文件 $DNS_CONFIG 未找到，跳过。"
fi

# 5. 修改 route.json
if [ -f "$ROUTE_CONFIG" ]; then
    info "正在处理 $ROUTE_CONFIG ..."
    
    # 使用 jq 删除特定规则：
    # 1. .rules |= map(...) -> 对 rules 数组中的每个元素进行操作
    # 2. select( (condition) | not ) -> 选择所有 *不满足* 条件的元素，从而达到删除的效果
    # 3. condition: .type == "field" and .ip == ["127.0.0.1"] and .port == 15454
    jq '.rules |= map(select( (.type == "field" and .ip == ["127.0.0.1"] and .port == 15454) | not ))' "$ROUTE_CONFIG" > "${ROUTE_CONFIG}.tmp"
    
    if [ $? -eq 0 ] && [ -s "${ROUTE_CONFIG}.tmp" ]; then
        mv "${ROUTE_CONFIG}.tmp" "$ROUTE_CONFIG"
        info "$ROUTE_CONFIG 修改成功。"
    else
        rm -f "${ROUTE_CONFIG}.tmp"
        error "$ROUTE_CONFIG 修改失败！"
    fi
else
    warn "文件 $ROUTE_CONFIG 未找到，跳过。"
fi

info "所有配置修改完成。建议重启 XrayR 服务以应用更改: systemctl restart XrayR"
