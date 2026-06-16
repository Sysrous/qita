#!/bin/bash
# ============================================================
#  一键挖矿木马清除 + Nezha v1 漏洞查杀 + 持续防护部署
#  Nezha 面板批量执行 / 单机 bash anti-miner-deploy.sh
# ============================================================
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG="/var/log/anti-miner.log"
ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*"; echo "[$(ts)] $*" >> "$LOG"; }

log "========== 开始一键部署 =========="

# =============================================
#  第一步：立即清除已有矿工
# =============================================
log "[1/6] 扫描并清除矿工进程..."

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

# =============================================
#  第二步：清除木马文件
# =============================================
log "[2/6] 清除木马文件和服务..."

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

# 可疑 systemd 服务（矿工类）
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

# 释放矿工残留的 HugePages
hp=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)
if [ "${hp:-0}" -gt 0 ]; then
    log "  释放 HugePages: ${hp} 页 ($((hp * 2))MB)"
    echo 0 > /proc/sys/vm/nr_hugepages
    sysctl -w vm.nr_hugepages=0 >/dev/null 2>&1
    sed -i '/nr_hugepages/d' /etc/sysctl.conf 2>/dev/null
    find /etc/sysctl.d/ -name '*.conf' -exec sed -i '/nr_hugepages/d' {} \; 2>/dev/null
fi

# =============================================
#  第三步：Nezha v1 已知漏洞查杀
# =============================================
log "[3/6] Nezha v1 漏洞查杀..."

# 3a. 查杀哪吒后门 Agent（连接 207.58.173.192）
log "  检查 207.58.173.192 后门连接..."
AGENT_PIDS=$(ss -tupn 2>/dev/null | grep '207.58.173.192' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
if [ -z "$AGENT_PIDS" ]; then
    AGENT_PIDS=$(netstat -antp 2>/dev/null | grep '207.58.173.192' | awk '{print $7}' | cut -d/ -f1 | grep -E '^[0-9]+$' | sort -u)
fi
if [ -n "$AGENT_PIDS" ]; then
    for pid in $AGENT_PIDS; do
        exe_path=$(readlink -f /proc/$pid/exe 2>/dev/null)
        log "  击杀恶意代理: PID=$pid EXE=$exe_path"
        kill -9 "$pid" 2>/dev/null
        [ -f "$exe_path" ] && rm -f "$exe_path" && log "  已删: $exe_path"
    done
else
    log "  未发现 207.58.173.192 连接"
fi

# 清理引用恶意 IP 的 systemd 服务
for svc in $(grep -rl '207.58.173.192' /etc/systemd/system/ /lib/systemd/system/ 2>/dev/null); do
    svc_name=$(basename "$svc")
    log "  清除恶意服务: $svc_name"
    systemctl stop "$svc_name" 2>/dev/null
    systemctl disable "$svc_name" 2>/dev/null
    rm -f "$svc"
done

# 3b. 查杀 gary@gary SSH 后门公钥
log "  检查 gary@gary SSH 后门公钥..."
for auth_file in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    if [ -f "$auth_file" ] && grep -q "gary@gary" "$auth_file"; then
        log "  发现 gary@gary 后门公钥: $auth_file"
        sed -i '/gary@gary/d' "$auth_file"
        log "  已清除"
    fi
done

# 3c. 查杀 memfd 内存马（伪装 kworker，连 24.x）
log "  检查 memfd 内存马..."
for piddir in /proc/[0-9]*/; do
    pid=${piddir#/proc/}; pid=${pid%/}
    [ -d "/proc/$pid" ] || continue
    exe_link=$(readlink "/proc/$pid/exe" 2>/dev/null)
    cmd_name=$(cat "/proc/$pid/comm" 2>/dev/null)
    is_mal=0
    [[ "$exe_link" == *"memfd"* ]] && is_mal=1
    if [[ "$cmd_name" == "kworker"* ]] && [ -n "$exe_link" ]; then
        ss -tupn 2>/dev/null | grep -E "pid=$pid\b" | grep -qE '24\.[0-9]+' && is_mal=1
    fi
    if [ $is_mal -eq 1 ]; then
        log "  击杀 memfd 内存马: PID=$pid NAME=$cmd_name EXE=$exe_link"
        kill -9 "$pid" 2>/dev/null
    fi
done

# 3d. 查杀 SystemLoger 守护服务（systemlog.service，连 24.x）
log "  检查 SystemLoger 守护服务..."
SYS_LOG_SVC=$(systemctl list-unit-files 2>/dev/null | grep -oE 'systemlog(er)?\.service' | head -n1)
if [ -n "$SYS_LOG_SVC" ]; then
    svc_file=$(systemctl show -p FragmentPath "$SYS_LOG_SVC" 2>/dev/null | cut -d= -f2)
    bin_path=""
    [ -f "$svc_file" ] && bin_path=$(grep -oP 'ExecStart=\K\S+' "$svc_file")
    log "  清除守护服务: $SYS_LOG_SVC"
    systemctl stop "$SYS_LOG_SVC" 2>/dev/null
    systemctl disable "$SYS_LOG_SVC" 2>/dev/null
    [ -n "$bin_path" ] && [ -f "$bin_path" ] && rm -f "$bin_path" && log "  已删: $bin_path"
    [ -f "$svc_file" ] && rm -f "$svc_file"
    systemctl daemon-reload 2>/dev/null
    systemctl reset-failed 2>/dev/null
fi

# 清理残留 systemlog 进程
for pid in $(ss -tupn 2>/dev/null | grep -E '24\.[0-9]+' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    if [[ "$comm" == *"systemlog"* ]]; then
        exe=$(readlink -f /proc/$pid/exe 2>/dev/null)
        log "  击杀残留 systemlog: PID=$pid EXE=$exe"
        kill -9 "$pid" 2>/dev/null
        [ -f "$exe" ] && rm -f "$exe"
    fi
done

systemctl daemon-reload 2>/dev/null

# =============================================
#  第四步：部署持续防护
# =============================================
log "[4/6] 部署持续防护..."

cat > /opt/anti-miner.sh << 'XEOF'
#!/bin/bash
LOG="/var/log/anti-miner.log"
ALERT=0
ts(){ date '+%F %T'; }
log(){ echo "[$(ts)] $*" >> "$LOG"; }
alert(){ echo "[$(ts)] [!] $*" >> "$LOG"; ALERT=1; }
log "===== 扫描 ====="

# --- 挖矿查杀 ---

# 高CPU(>80%)
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

# 已知矿工名
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

# 可疑服务（矿工类）
for sp in defunct cryptod minerd kswapd0 dbused kernelagent xmrig; do
    systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -i "$sp" | while read svc; do
        alert "可疑服务: $svc"; systemctl stop "$svc" 2>/dev/null; systemctl disable "$svc" 2>/dev/null
        sf=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2)
        [ -n "$sf" ] && [ -f "$sf" ] && chattr -i "$sf" 2>/dev/null && rm -f "$sf"
        systemctl daemon-reload 2>/dev/null
    done
done

# HugePages 残留
hp=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)
if [ "${hp:-0}" -gt 0 ]; then
    alert "HugePages 异常: ${hp} 页 ($((hp * 2))MB)"
    echo 0 > /proc/sys/vm/nr_hugepages
    sysctl -w vm.nr_hugepages=0 >/dev/null 2>&1
    sed -i '/nr_hugepages/d' /etc/sysctl.conf 2>/dev/null
    find /etc/sysctl.d/ -name '*.conf' -exec sed -i '/nr_hugepages/d' {} \; 2>/dev/null
fi

# --- Nezha v1 漏洞查杀 ---

# 207.58.173.192 后门
for pid in $(ss -tupn 2>/dev/null | grep '207.58.173.192' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
    exe=$(readlink -f /proc/$pid/exe 2>/dev/null)
    alert "哪吒后门: PID=$pid EXE=$exe"; kill -9 "$pid" 2>/dev/null
    [ -f "$exe" ] && rm -f "$exe"
done

# gary@gary 后门公钥
for auth_file in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    if [ -f "$auth_file" ] && grep -q "gary@gary" "$auth_file"; then
        alert "gary@gary 后门: $auth_file"; sed -i '/gary@gary/d' "$auth_file"
    fi
done

# memfd 内存马
for piddir in /proc/[0-9]*/; do
    pid=${piddir#/proc/}; pid=${pid%/}
    [ -d "/proc/$pid" ] || continue
    exe_link=$(readlink "/proc/$pid/exe" 2>/dev/null)
    cmd_name=$(cat "/proc/$pid/comm" 2>/dev/null)
    is_mal=0
    [[ "$exe_link" == *"memfd"* ]] && is_mal=1
    if [[ "$cmd_name" == "kworker"* ]] && [ -n "$exe_link" ]; then
        ss -tupn 2>/dev/null | grep -E "pid=$pid\b" | grep -qE '24\.[0-9]+' && is_mal=1
    fi
    if [ $is_mal -eq 1 ]; then
        alert "memfd内存马: PID=$pid $cmd_name $exe_link"; kill -9 "$pid" 2>/dev/null
    fi
done

# SystemLoger 守护服务
SYS_LOG_SVC=$(systemctl list-unit-files 2>/dev/null | grep -oE 'systemlog(er)?\.service' | head -n1)
if [ -n "$SYS_LOG_SVC" ]; then
    alert "SystemLoger: $SYS_LOG_SVC"
    systemctl stop "$SYS_LOG_SVC" 2>/dev/null; systemctl disable "$SYS_LOG_SVC" 2>/dev/null
    sf=$(systemctl show -p FragmentPath "$SYS_LOG_SVC" 2>/dev/null | cut -d= -f2)
    [ -f "$sf" ] && bin=$(grep -oP 'ExecStart=\K\S+' "$sf") && [ -f "$bin" ] && rm -f "$bin"
    [ -f "$sf" ] && rm -f "$sf"
    systemctl daemon-reload 2>/dev/null
fi

# 恶意IP服务文件
for svc in $(grep -rl '207.58.173.192' /etc/systemd/system/ /lib/systemd/system/ 2>/dev/null); do
    svc_name=$(basename "$svc")
    alert "恶意IP服务: $svc_name"
    systemctl stop "$svc_name" 2>/dev/null; systemctl disable "$svc_name" 2>/dev/null; rm -f "$svc"
done

# 可疑 crontab
crontab -l 2>/dev/null | grep -iE 'xmr|miner|\.xhv|kinsing|curl.*\|.*bash|wget.*\|.*bash|/dev/shm' | grep -v anti-miner | while read -r cline; do
    alert "可疑cron: $cline"
done

# 日志轮转
[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 3000 ] && tail -1000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
[ "$ALERT" -eq 0 ] && log "正常" || log "已处理告警"
XEOF
chmod +x /opt/anti-miner.sh

# =============================================
#  第五步：写 cron
# =============================================
log "[5/6] 配置定时任务..."
(crontab -l 2>/dev/null | grep -v 'anti-miner') | crontab -
(crontab -l 2>/dev/null; echo '*/10 * * * * /opt/anti-miner.sh') | crontab -

# =============================================
#  第六步：验证
# =============================================
log "[6/6] 验证..."
load=$(cat /proc/loadavg | awk '{print $1}')
mem_avail=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo)
hp_now=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)
log "负载: $load | 可用内存: ${mem_avail}MB | HugePages: $hp_now"
log "cron: $(crontab -l 2>/dev/null | grep anti-miner)"
log "========== 部署完成 =========="

echo ""
echo "====================================="
echo "  部署完成"
echo "  负载: $load"
echo "  可用内存: ${mem_avail}MB"
echo "  HugePages: $hp_now"
echo "  防护: /opt/anti-miner.sh (每10分钟)"
echo "  日志: /var/log/anti-miner.log"
echo "====================================="
