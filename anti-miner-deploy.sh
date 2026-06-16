#!/bin/bash
# ============================================================
#  一键挖矿木马清除 + 持续防护部署
#  Nezha 面板批量执行 / 单机 bash anti-miner-deploy.sh
# ============================================================
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG="/var/log/anti-miner.log"
ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*"; echo "[$(ts)] $*" >> "$LOG"; }

log "========== 开始一键部署 =========="

# ============ 第一步：立即清除已有矿工 ============
log "[1/4] 扫描并清除矿工进程..."

# 杀高CPU进程(>80%，排除内核线程)
while IFS= read -r line; do
    pid=$(echo "$line" | awk '{print $2}')
    cpu=$(echo "$line" | awk '{print $3}')
    cmd_str=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf "%s ",$i}')
    exe=$(readlink /proc/$pid/exe 2>/dev/null)
    [ -z "$exe" ] && continue
    [[ "$cmd_str" =~ anti-miner ]] && continue
    log "  击杀高CPU: PID=$pid CPU=${cpu}% EXE=$exe"
    kill -9 "$pid" 2>/dev/null
done < <(ps aux --sort=-%cpu | awk 'NR>1 && $3+0>=80')

# 杀已知矿工名
for pattern in xmrig xmr-stak ccminer cgminer bfgminer minerd ksysrqd kdevtmpfsi kinsing cryptonight xmhv solrd dbused; do
    pids=$(pgrep -f "$pattern" 2>/dev/null | grep -v $$)
    for p in $pids; do
        exe=$(readlink /proc/$p/exe 2>/dev/null)
        [ -z "$exe" ] && continue
        log "  击杀矿工: PID=$p NAME=$pattern EXE=$exe"
        kill -9 "$p" 2>/dev/null
    done
done

# 杀伪装内核线程(有exe但cmdline带方括号)
for piddir in /proc/[0-9]*/; do
    pid=${piddir#/proc/}; pid=${pid%/}
    exe=$(readlink /proc/$pid/exe 2>/dev/null) || continue
    cmdline=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)
    if [ -n "$exe" ] && echo "$cmdline" | grep -qP '^\[.*\]\s*$'; then
        log "  击杀伪装内核线程: PID=$pid EXE=$exe CMD=$cmdline"
        kill -9 "$pid" 2>/dev/null
    fi
done

# ============ 第二步：清除木马文件 ============
log "[2/4] 清除木马文件和服务..."

# 常见木马路径
for f in /usr/bin/defunct /usr/bin/dbused /usr/bin/kinsing /usr/bin/kdevtmpfsi /tmp/kdevtmpfsi /tmp/kinsing /var/tmp/kinsing; do
    if [ -f "$f" ]; then
        chattr -i "$f" 2>/dev/null; rm -f "$f" && log "  已删: $f"
    fi
done

# 隐藏矿工目录
for d in /root/.xhv /root/.xmrig /root/.cache/xmr /tmp/.X11-unix/.x /tmp/.font-unix/.x /dev/shm/.x /var/tmp/.x; do
    if [ -d "$d" ] && find "$d" -maxdepth 2 -type f -executable -size +100k 2>/dev/null | grep -q .; then
        chattr -Ri "$d" 2>/dev/null; rm -rf "$d" && log "  已删目录: $d"
    fi
done

# 隐藏目录大型可执行文件(>1MB)
for base in /root /tmp /var/tmp /dev/shm; do
    [ -d "$base" ] || continue
    find "$base" -maxdepth 4 -path '*/.*/*' -type f -executable -size +1M 2>/dev/null \
        | grep -vE '\.cache/mozilla|\.local/share|\.config|\.nvm|\.npm|\.cargo|\.rustup|\.pyenv' \
        | while read -r f; do
            chattr -i "$f" 2>/dev/null; rm -f "$f" && log "  已删可疑文件: $f"
        done
done

# 可疑 systemd 服务
for svc_pat in defunct cryptod minerd kswapd0 dbused kernelagent xmrig; do
    systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -i "$svc_pat" | while read svc; do
        log "  清除服务: $svc"
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        svc_file=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2)
        if [ -n "$svc_file" ] && [ -f "$svc_file" ]; then
            chattr -i "$svc_file" "${svc_file%.service}.dat" 2>/dev/null
            rm -f "$svc_file" "${svc_file%.service}.dat"
        fi
    done
done
systemctl daemon-reload 2>/dev/null

# 清理可疑 crontab
if crontab -l 2>/dev/null | grep -qiE 'xmr|miner|\.xhv|kinsing|kdevtmpfsi|/dev/shm.*bash'; then
    log "  清理可疑 crontab 条目"
    crontab -l 2>/dev/null | grep -viE 'xmr|miner|\.xhv|kinsing|kdevtmpfsi|/dev/shm.*bash' | crontab -
fi

# ============ 第三步：部署持续防护 ============
log "[3/4] 部署持续防护..."

cat > /opt/anti-miner.sh << 'XEOF'
#!/bin/bash
LOG="/var/log/anti-miner.log"
ALERT=0
ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*" >> "$LOG"; }
alert(){ echo "[$(ts)] [!] $*" >> "$LOG"; ALERT=1; }
log "===== 扫描 ====="

# 高CPU
while IFS= read -r line; do
    pid=$(echo "$line" | awk '{print $2}')
    cpu=$(echo "$line" | awk '{print $3}')
    exe=$(readlink /proc/$pid/exe 2>/dev/null); [ -z "$exe" ] && continue
    cmd=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf "%s ",$i}')
    [[ "$cmd" =~ ^\[ ]] && continue
    [[ "$cmd" =~ anti-miner ]] && continue
    alert "高CPU: PID=$pid ${cpu}% $exe"
    if [[ "$exe" == /root/.* || "$exe" == /tmp/* || "$exe" == /var/tmp/* || "$exe" == /dev/shm/* ]]; then
        kill -9 "$pid" 2>/dev/null && alert "已杀 $pid"
    fi
done < <(ps aux --sort=-%cpu | awk 'NR>1 && $3+0>=80')

# 矿工名
for p in xmrig xmr-stak ccminer cgminer bfgminer minerd ksysrqd kdevtmpfsi kinsing xmhv solrd dbused; do
    pgrep -f "$p" 2>/dev/null | while read kpid; do
        exe=$(readlink /proc/$kpid/exe 2>/dev/null); [ -z "$exe" ] && continue
        alert "矿工: $kpid $p $exe"; kill -9 "$kpid" 2>/dev/null
    done
done

# 伪装内核线程
for piddir in /proc/[0-9]*/; do
    pid=${piddir#/proc/}; pid=${pid%/}
    exe=$(readlink /proc/$pid/exe 2>/dev/null) || continue
    cmdline=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)
    if [ -n "$exe" ] && echo "$cmdline" | grep -qP '^\[.*\]\s*$'; then
        alert "伪装线程: $pid $exe"; kill -9 "$pid" 2>/dev/null
    fi
done

# 隐藏目录大文件
for d in /root /tmp /var/tmp /dev/shm; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 4 -path '*/.*/*' -type f -executable -size +1M 2>/dev/null \
        | grep -vE '\.cache/mozilla|\.local/share|\.config|\.nvm|\.npm|\.cargo|\.rustup|\.pyenv' \
        | while read -r f; do
            alert "可疑: $f"; chattr -i "$f" 2>/dev/null; rm -f "$f"
        done
done

# 矿池连接
pool=$(ss -tnp 2>/dev/null | grep -E ':(3333|4444|5555|7777|8888|9999|14433|14444|45700)\s' | grep -v '127.0.0.1\|::1')
if [ -n "$pool" ]; then
    alert "矿池连接:"; echo "$pool" >> "$LOG"
    echo "$pool" | grep -oP 'pid=\K[0-9]+' | sort -u | while read kpid; do kill -9 "$kpid" 2>/dev/null; done
fi

# 可疑服务
for sp in defunct cryptod minerd kswapd0 dbused kernelagent xmrig; do
    systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -i "$sp" | while read svc; do
        alert "可疑服务: $svc"; systemctl stop "$svc" 2>/dev/null; systemctl disable "$svc" 2>/dev/null
        sf=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2)
        [ -n "$sf" ] && [ -f "$sf" ] && chattr -i "$sf" 2>/dev/null && rm -f "$sf"
        systemctl daemon-reload 2>/dev/null
    done
done

# 可疑cron
crontab -l 2>/dev/null | grep -iE 'xmr|miner|\.xhv|kinsing|curl.*\|.*bash|wget.*\|.*bash|/dev/shm' | grep -v anti-miner | while read -r cline; do
    alert "可疑cron: $cline"
done

# authorized_keys
ak="/root/.ssh/authorized_keys"
[ -f "$ak" ] && [ -s "$ak" ] && alert "authorized_keys 非空!" && cat "$ak" >> "$LOG"

# 日志轮转
[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 3000 ] && tail -1000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
[ "$ALERT" -eq 0 ] && log "正常" || log "已处理告警"
XEOF
chmod +x /opt/anti-miner.sh

# 写 cron
(crontab -l 2>/dev/null | grep -v 'anti-miner') | crontab -
(crontab -l 2>/dev/null; echo '*/10 * * * * /opt/anti-miner.sh') | crontab -

# ============ 第四步：验证 ============
log "[4/4] 验证..."
load=$(cat /proc/loadavg | awk '{print $1}')
log "负载: $load"
log "cron: $(crontab -l 2>/dev/null | grep anti-miner)"
log "========== 部署完成 =========="

echo ""
echo "====================================="
echo "  部署完成"
echo "  负载: $load"
echo "  防护: /opt/anti-miner.sh (每10分钟)"
echo "  日志: /var/log/anti-miner.log"
echo "====================================="
