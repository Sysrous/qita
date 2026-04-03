#!/bin/bash
# ==========================================================
#  Linux 系统盘自动清理脚本（Root 毁灭版 - 带 Swap 保护）
#  
#  功能特点：
#  1. 暴力清空 /var/log 下所有文件和文件夹（不限时间）
#  2. 清空 /tmp 和 /var/tmp（跳过 .sock/.lock 文件）
#  3. 删除系统前 50 个大于 110MB 的文件（跳过 .sock/.lock 文件）
#  4. 【保护】自动跳过 Swap 文件、数据库文件、Docker核心文件、所有 .sock/.lock 文件
# ==========================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%F %T')] $*${NC}"
}

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：必须使用 root 权限运行此脚本！${NC}"
  exit 1
fi

log "开始执行暴力清理（全局跳过 .sock/.lock 文件）..."

# 1. 记录初始磁盘状态
df -h / | tee -a /dev/null

# 2. 清理 APT 缓存
log "清理包管理器缓存..."
apt-get clean -qq
apt-get autoclean -qq
apt-get autoremove --purge -y -qq

# 3. 清理旧内核
log "清理旧内核..."
cur=$(uname -r)
keep=$(dpkg -l linux-image-* | awk '/^ii/{print $2}' | grep -E "$cur|generic" | tail -n 2 | tr '\n' '|')
dpkg -l linux-{image,headers}-* | awk '/^ii/{print $2}' | grep -vE "$keep" | xargs -r apt-get purge -y -qq

# 4. 【核平】/var/log 所有内容（仍保留此逻辑，log文件无 .sock/.lock）
log "正在彻底清空 /var/log 下的所有文件夹和文件..."
journalctl --rotate >/dev/null 2>&1
journalctl --vacuum-time=1s >/dev/null 2>&1
if [ -d "/var/log" ]; then
    find /var/log -mindepth 1 -delete 2>/dev/null
fi
# 重建基础登录记录文件
touch /var/log/wtmp /var/log/btmp /var/log/lastlog
chmod 664 /var/log/wtmp /var/log/btmp /var/log/lastlog
chown root:utmp /var/log/wtmp /var/log/btmp /var/log/lastlog

# 5. 清理临时文件（核心修改：跳过所有 .sock/.lock 文件）
log "清空临时目录 /tmp 和 /var/tmp（跳过 .sock/.lock 文件）..."
# 匹配规则：排除 后缀为 .sock 或 .lock 的文件
find /tmp -mindepth 1 \
    -not -name "*.sock" \
    -not -name "*.lock" \
    -delete 2>/dev/null

find /var/tmp -mindepth 1 \
    -not -name "*.sock" \
    -not -name "*.lock" \
    -delete 2>/dev/null

# 6. 清理缩略图
[ -d /root/.cache/thumbnails ] && rm -rf /root/.cache/thumbnails/*

# 7. 清理浏览器缓存
log "清理浏览器缓存..."
for h in /home/*; do
    [ -d "$h" ] || continue
    rm -rf "$h/.cache/google-chrome/Default/"{Cache,"Code Cache"} 2>/dev/null
    find "$h/.cache/mozilla/firefox" -name cache2 -exec rm -rf {} + 2>/dev/null
done

# 8. 清理旧 Snap
if command -v snap &>/dev/null; then
    log "清理 Snap 旧版本..."
    LANG=C snap list --all | awk '/disabled/{print $1, $3}' | \
    while read -r snapname revision; do
        snap remove "$snapname" --revision="$revision" >/dev/null 2>&1
    done
fi

# 9. Docker 清理
if command -v docker &>/dev/null; then
    log "清理 Docker 冗余数据..."
    docker system prune -af --volumes >/dev/null 2>&1
fi

# 10. 【高危】删除 >110MB 的大文件（核心修改：全局跳过 .sock/.lock 文件）
log "扫描并删除大于 110MB 的文件 (Top 50，跳过 .sock/.lock 文件)..."

find / -xdev -type f -size +110M -printf "%s %p\n" 2>/dev/null | \
sort -rn | \
head -n 50 | \
while read -r size filepath; do
    
    # ================= [全局白名单区域] =================
    # 1. 跳过所有 .sock / .lock 文件（核心需求）
    if [[ "$filepath" == *.sock ]]; then 
        echo -e "${YELLOW}跳过 Socket 文件: $filepath${NC}"; continue; 
    fi
    if [[ "$filepath" == *.lock ]]; then 
        echo -e "${YELLOW}跳过 Lock 文件: $filepath${NC}"; continue; 
    fi

    # 2. Swap 交换文件保护
    if [[ "$filepath" == "/swapfile" || "$filepath" == *"/swap.img"* || "$filepath" =~ "swap" ]]; then 
        echo -e "${YELLOW}跳过 Swap: $filepath${NC}"; continue; 
    fi

    # 3. 数据库数据保护
    if [[ "$filepath" == *"/var/lib/mysql"* || "$filepath" == *"/var/lib/postgresql"* || \
         "$filepath" == *"/var/lib/mongodb"* || "$filepath" == *"/var/lib/redis"* ]]; then 
        continue; 
    fi

    # 4. Docker 容器核心层保护
    if [[ "$filepath" == *"/var/lib/docker/overlay2"* || "$filepath" == *"/var/lib/docker/containers"* ]]; then 
        continue; 
    fi

    # ===============================================

    # 转换为易读大小
    human_size=$(numfmt --to=iec $size 2>/dev/null || echo "$size bytes")
    
    echo -e "${RED}正在删除: $filepath (大小: $human_size)${NC}"
    rm -f "$filepath"
done

# 11. 结束
log "清理完毕，当前磁盘用量："
df -h /
