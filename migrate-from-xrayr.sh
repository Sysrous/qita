#!/bin/bash
#
# migrate-from-xrayr.sh
#
# 把同机器上一份正在跑的 XrayR 一键迁移成 KimiR v1.8。
#
# 流程：
#   1. 预检（root / systemctl / 已安装 XrayR）
#   2. 备份 /etc/XrayR 到 /etc/XrayR.bak.<timestamp>
#   3. 扫描旧 config.yml 的 PanelType / WS 状态等关键字段
#   4. 跑 install.sh -rv <版本>（它内部会 migrate_from_xrayr：停服务、mv 目录、删旧 unit、sed 改路径、拉新二进制 + geoip/geosite + 起 KimiR.service）
#   5. 升级后按需把 PanelType: "NewV2board" / "V2board" 改成 V2 等价名（默认询问，可用 -y 自动同意）
#   6. 重启 KimiR + 抓 30 行日志做即时验证
#   7. 把回滚命令打到屏幕上
#
# 用法：
#   sudo bash migrate-from-xrayr.sh                # 交互模式
#   sudo bash migrate-from-xrayr.sh -y             # 全自动（PanelType 自动改 V2）
#   sudo bash migrate-from-xrayr.sh -y --no-bump   # 全自动但不改 PanelType
#   sudo bash migrate-from-xrayr.sh -v 1.8         # 指定版本（默认 v1.8）
#
# 全程幂等；任何一步失败都打印回滚命令再退出。

set -u

#=================================================
#               日志 / 颜色
#=================================================
Green="\033[32m"
Red="\033[31m"
Yellow='\033[33m'
Blue='\033[34m'
Font="\033[0m"
INFO_PREFIX="[${Green}INFO${Font}]"
ERROR_PREFIX="[${Red}ERROR${Font}]"
WARN_PREFIX="[${Yellow}WARN${Font}]"
BLUE_PREFIX="[${Blue}STEP${Font}]"

INFO()  { echo -e "${INFO_PREFIX} ${1}"  >&2; }
ERROR() { echo -e "${ERROR_PREFIX} ${1}" >&2; }
WARN()  { echo -e "${WARN_PREFIX} ${1}"  >&2; }
STEP()  { echo -e "\n${BLUE_PREFIX} ${1}" >&2; }

#=================================================
#               默认参数
#=================================================
KIMIR_VERSION="v1.8"
AUTO_YES="false"
NO_BUMP="false"
# 用 api.github.com/contents endpoint 而不是 raw.githubusercontent.com，
# 原因：fine-grained PAT (github_pat_*) 在 raw URL 上经常 404，api endpoint 稳定。
INSTALL_API_URL="https://api.github.com/repos/Sysrous/KimiR/contents/install.sh"
INSTALL_RAW_URL_LEGACY="https://raw.githubusercontent.com/Sysrous/KimiR/main/install.sh"
# 私库需要 PAT；优先用 -t/--token 命令行参数，否则用 GH_TOKEN / GITHUB_TOKEN 环境变量。
# install.sh 的 -t/--token 走 GitHub Releases API 同一个 token。
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

OLD_ETC="/etc/XrayR"
OLD_BIN_DIR="/usr/local/XrayR"
OLD_UNIT="/etc/systemd/system/XrayR.service"
NEW_ETC="/etc/KimiR"
NEW_BIN_DIR="/usr/local/KimiR"
NEW_UNIT="/etc/systemd/system/KimiR.service"

BACKUP_TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/etc/XrayR.bak.${BACKUP_TS}"

#=================================================
#               参数解析
#=================================================
print_usage() {
    cat <<USAGE
用法: sudo bash $0 [options]

选项:
  -v, --version <ver>   要安装的 KimiR 版本 (默认: ${KIMIR_VERSION})
  -t, --token <pat>     GitHub PAT；私库必填。也可用环境变量 GH_TOKEN / GITHUB_TOKEN
  -y, --yes             非交互模式，所有 prompt 默认 yes
      --no-bump         即使旧 config 是 V1 也不自动改 PanelType
  -h, --help            打印本帮助
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)  KIMIR_VERSION="$2"; shift 2 ;;
        -t|--token)    GH_TOKEN="$2"; shift 2 ;;
        -y|--yes)      AUTO_YES="true"; shift ;;
        --no-bump)     NO_BUMP="true"; shift ;;
        -h|--help)     print_usage; exit 0 ;;
        *)             ERROR "未知参数: $1"; print_usage; exit 1 ;;
    esac
done

#=================================================
#               工具函数
#=================================================
confirm() {
    # confirm "提示" [默认 y/n]
    local prompt="$1"
    local default="${2:-y}"
    if [[ "$AUTO_YES" == "true" ]]; then
        INFO "(-y) 自动同意：${prompt}"
        return 0
    fi
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"
    read -r -p "$(echo -e "${Yellow}? ${Font}${prompt} ${hint}: ")" reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

print_rollback_hint() {
    cat >&2 <<HINT

------------------------------------------------------------
如需回滚：
  sudo systemctl stop KimiR 2>/dev/null || true
  sudo systemctl disable KimiR 2>/dev/null || true
  sudo rm -rf ${NEW_ETC} ${NEW_BIN_DIR} ${NEW_UNIT}
  sudo mv ${BACKUP_DIR} ${OLD_ETC}
  # 然后用你原来的方式重新装 XrayR 二进制 + 写 ${OLD_UNIT}
  sudo systemctl daemon-reload
  sudo systemctl enable --now XrayR
------------------------------------------------------------
HINT
}

#=================================================
#               1. 预检
#=================================================
STEP "[1/7] 预检环境"

if [[ $EUID -ne 0 ]]; then
    ERROR "必须以 root 运行 (sudo bash $0)"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    ERROR "未找到 systemctl；本脚本只支持 systemd 系发行版"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    ERROR "未找到 curl；先 apt/yum install curl 再来"
    exit 1
fi

found_any="false"
[[ -d "$OLD_ETC"     ]] && found_any="true"
[[ -d "$OLD_BIN_DIR" ]] && found_any="true"
[[ -f "$OLD_UNIT"    ]] && found_any="true"

if [[ "$found_any" != "true" ]]; then
    ERROR "未检测到旧 XrayR 安装（$OLD_ETC / $OLD_BIN_DIR / $OLD_UNIT 都不存在）"
    ERROR "如果你想做全新 KimiR 安装，直接跑："
    ERROR "  bash <(curl -fsSL --proto '=https' --tlsv1.2 ${INSTALL_URL_BASE}) -rv ${KIMIR_VERSION}"
    exit 1
fi

INFO "检测到旧 XrayR 安装"

# 如果 KimiR 已经存在，提示一下
if [[ -d "$NEW_ETC" || -d "$NEW_BIN_DIR" || -f "$NEW_UNIT" ]]; then
    WARN "KimiR 路径已存在 (${NEW_ETC} / ${NEW_BIN_DIR} / ${NEW_UNIT})"
    WARN "install.sh 的 migrate_from_xrayr 检测到目标存在不会覆盖（避免吃掉你已有 KimiR 配置）"
    if ! confirm "继续吗？" "n"; then
        ERROR "用户取消"
        exit 1
    fi
fi

#=================================================
#               2. 备份 /etc/XrayR
#=================================================
STEP "[2/7] 备份 ${OLD_ETC} → ${BACKUP_DIR}"

if [[ -d "$OLD_ETC" ]]; then
    if cp -a "$OLD_ETC" "$BACKUP_DIR"; then
        INFO "已备份到 ${BACKUP_DIR}"
    else
        ERROR "备份失败，磁盘空间或权限有问题；中止"
        exit 1
    fi
else
    WARN "${OLD_ETC} 不存在，跳过备份步骤"
fi

#=================================================
#               3. 扫描旧 config.yml
#=================================================
STEP "[3/7] 扫描旧 config.yml 关键字段"

OLD_CONFIG="${OLD_ETC}/config.yml"
NEEDS_PANEL_BUMP="false"
OLD_PANEL_TYPE=""

if [[ -f "$OLD_CONFIG" ]]; then
    # 抓所有 PanelType 行（多节点情况）
    mapfile -t panel_lines < <(grep -nE '^\s*PanelType:' "$OLD_CONFIG" || true)
    if [[ ${#panel_lines[@]} -eq 0 ]]; then
        WARN "旧 config.yml 没找到 PanelType 行；脚本不会自动改"
    else
        INFO "旧 config.yml 中的 PanelType 行："
        for line in "${panel_lines[@]}"; do
            echo "    $line" >&2
        done
        # 抓第一行的值方便判定
        OLD_PANEL_TYPE=$(echo "${panel_lines[0]}" | sed -E 's/^[^:]+:.*PanelType:[[:space:]]*"?([^"]+)"?.*/\1/' | tr -d '[:space:]')
        case "$OLD_PANEL_TYPE" in
            NewV2board|V2board)
                INFO "检测到 V1 面板类型 (${OLD_PANEL_TYPE})"
                if [[ "$NO_BUMP" == "true" ]]; then
                    WARN "--no-bump 已开，不自动改 PanelType；如果你面板已是 V2 Xboard，KimiR 启动后会请求 V1 路径而失败"
                else
                    NEEDS_PANEL_BUMP="true"
                fi
                ;;
            NewV2boardV2|V2boardV2)
                INFO "PanelType 已经是 V2 (${OLD_PANEL_TYPE})，不需要改名"
                ;;
            *)
                WARN "PanelType=\"${OLD_PANEL_TYPE}\" 不在已知列表里，脚本不会动它"
                ;;
        esac
    fi
else
    WARN "${OLD_CONFIG} 不存在，跳过 config 扫描"
fi

#=================================================
#               4. 执行 install.sh（含 migrate_from_xrayr）
#=================================================
STEP "[4/7] 拉取并执行 install.sh -rv ${KIMIR_VERSION}"

INFO "下载 install.sh ..."
tmp_install=$(mktemp /tmp/kimir-install.XXXXXX.sh) || { ERROR "mktemp 失败"; exit 1; }
trap 'rm -f "$tmp_install"' EXIT

# 优先 api.github.com/contents endpoint（对 fine-grained PAT 友好）；
# 失败时回落到 raw URL（兼容 classic PAT / 公开仓库情况）。
curl_auth=()
if [[ -n "$GH_TOKEN" ]]; then
    curl_auth=(-H "Authorization: token ${GH_TOKEN}")
    INFO "使用 PAT 鉴权下载 install.sh (api endpoint)"
else
    WARN "未设置 GH_TOKEN，按公开仓库尝试；若仓库是私库会失败"
fi

# 走 api endpoint：raw 内容由 Accept: application/vnd.github.raw 触发
if ! curl -fsSL --proto '=https' --tlsv1.2 \
        "${curl_auth[@]}" \
        -H "Accept: application/vnd.github.raw" \
        -o "$tmp_install" \
        "$INSTALL_API_URL"; then
    WARN "api endpoint 下载失败，回落到 raw URL 再试一次"
    if ! curl -fsSL --proto '=https' --tlsv1.2 \
            "${curl_auth[@]}" \
            -o "$tmp_install" \
            "$INSTALL_RAW_URL_LEGACY"; then
        ERROR "两条 URL 都下载失败"
        ERROR "  api: ${INSTALL_API_URL}"
        ERROR "  raw: ${INSTALL_RAW_URL_LEGACY}"
        ERROR "1) 验证 PAT 大小写完整: head -c 30 <<< \"\$GH_TOKEN\""
        ERROR "2) 验证 PAT 能访问仓库: curl -fsS -H \"Authorization: token \$GH_TOKEN\" https://api.github.com/repos/Sysrous/KimiR | head -3"
        ERROR "3) PAT 需要 Contents:Read 权限对 Sysrous/KimiR 仓库"
        print_rollback_hint
        exit 1
    fi
fi

# 简单 sanity 检查：内容看着像 bash 脚本
if ! head -1 "$tmp_install" | grep -q '^#!/'; then
    ERROR "下载的 install.sh 内容不是 bash 脚本，可能拿到了 GitHub JSON 错误体："
    head -3 "$tmp_install" >&2
    print_rollback_hint
    exit 1
fi

# install.sh 自己也要 PAT 才能拉 release tarball + raw 文件。
install_args=(-rv "$KIMIR_VERSION")
if [[ -n "$GH_TOKEN" ]]; then
    install_args+=(-t "$GH_TOKEN")
fi

INFO "运行 install.sh（这一步内部会自动 stop XrayR、mv 目录、起 KimiR.service）"
if ! bash "$tmp_install" "${install_args[@]}"; then
    ERROR "install.sh 执行失败"
    print_rollback_hint
    exit 1
fi

#=================================================
#               5. 按需 bump PanelType
#=================================================
STEP "[5/7] 调整 PanelType（V1 → V2，如果需要）"

NEW_CONFIG="${NEW_ETC}/config.yml"
if [[ "$NEEDS_PANEL_BUMP" == "true" ]]; then
    if [[ ! -f "$NEW_CONFIG" ]]; then
        WARN "${NEW_CONFIG} 不存在，跳过 PanelType 修改"
    else
        if confirm "把 config.yml 里的 PanelType: \"${OLD_PANEL_TYPE}\" 改成 \"NewV2boardV2\"?" "y"; then
            sed -i.bak.$(date +%s) -E \
                -e 's/(^\s*PanelType:\s*")NewV2board(")/\1NewV2boardV2\2/' \
                -e 's/(^\s*PanelType:\s*")V2board(")/\1V2boardV2\2/' \
                "$NEW_CONFIG"
            INFO "PanelType 已批量改为 V2"
            grep -nE '^\s*PanelType:' "$NEW_CONFIG" >&2 || true
        else
            WARN "用户跳过 PanelType 改名；如果面板已是 V2 你需要自己改 ${NEW_CONFIG}"
        fi
    fi
else
    INFO "无需改 PanelType"
fi

#=================================================
#               6. 重启 KimiR + 验证
#=================================================
STEP "[6/7] 重启 KimiR 并抓最近 50 行日志"

if ! systemctl restart KimiR; then
    ERROR "systemctl restart KimiR 失败"
    print_rollback_hint
    exit 1
fi

sleep 2

INFO "服务状态："
systemctl --no-pager --full status KimiR | head -15 >&2 || true

INFO "最近 50 行日志（关键字过滤优先 WS / 面板 / error）："
journalctl -u KimiR --no-pager -n 50 >&2 || true

if systemctl is-active --quiet KimiR; then
    INFO "KimiR 已 active"
else
    ERROR "KimiR 没起来；看上面日志排查"
    print_rollback_hint
    exit 1
fi

#=================================================
#               7. 总结
#=================================================
STEP "[7/7] 完成"

cat >&2 <<DONE

✔ XrayR → KimiR ${KIMIR_VERSION} 迁移完成

关键路径：
  二进制      ${NEW_BIN_DIR}/kimir
  配置        ${NEW_CONFIG}
  systemd 单元 ${NEW_UNIT}
  备份        ${BACKUP_DIR}

常用命令（旧的 XrayR 改 KimiR 即可）：
  sudo systemctl status KimiR
  sudo systemctl restart KimiR
  sudo journalctl -u KimiR -f
  /usr/local/KimiR/kimir version

WebSocket 自动启用（面板 server_ws_enable=1 时）；从日志里搜
"WS 推送通道已启动 / WS 鉴权成功" 可确认是否吃到。

刷 geoip/geosite（之后想单独更新时；私库别忘了 token）：
  curl -fsSL -H "Authorization: token \$GH_TOKEN" \\
    -H "Accept: application/vnd.github.raw" \\
    ${INSTALL_API_URL} \\
    | bash -s -- -m update-geo -t \$GH_TOKEN
DONE

print_rollback_hint
exit 0
