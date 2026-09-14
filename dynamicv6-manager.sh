#!/usr/bin/env bash
###############################################################################
# dynamicv6-manager.sh — AetherCloud DynamicV6 管理脚本
#
# 功能: 交互式管理 AT&T 动态 IPv6 下发、出口选择、监控与恢复
# 兼容: 任何使用 AetherCloud DynamicV6 的 Linux 服务器
# 防失联: 使用 metric 优先级 + src 源地址控制路由，从不删除原生路由，不动 IPv4
###############################################################################
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

VERSION="1.1.0"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_URL="https://billing.aethercloud.io/dynamicv6/client.sh"
RESTORE_URL="https://billing.aethercloud.io/dynamicv6/restore.sh"

STATE_DIR="/var/lib/dynamicv6-manager"
CONFIG_FILE="${STATE_DIR}/config.json"
RECOVERY_FILE="${STATE_DIR}/RECOVERY.md"
CACHE_CLIENT="${STATE_DIR}/client.sh"
CACHE_RESTORE="${STATE_DIR}/restore.sh"
LOG_FILE="/var/log/dynamicv6-manager.log"
MONITOR_CRON_TAG="# dynamicv6-manager-monitor"

METRIC_PRIMARY=100
METRIC_BACKUP=200
METRIC_GATEWAY_HOST=1023

POLICY_RULE_PREF_BASE=16000
POLICY_TABLE_BASE=16000

PING6_TARGETS=("2001:4860:4860::8888" "2606:4700:4700::1111")
CONNECTIVITY_TIMEOUT=3
CONNECTIVITY_RETRIES=2

# 全局变量（由 parse_args 设置）
RUN_MODE="interactive"
AUTO_MODE=0
AUTO_EGRESS="dynamic:1"
AUTO_NO_MONITOR=0
AUTO_RECOVERY_ENABLED=0
VERBOSE=0
IFACE=""
MAX_RECOVERY_ATTEMPTS=3

###############################################################################
# 颜色与输出
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; log_to_file "[INFO] $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; log_to_file "[WARN] $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; log_to_file "[ERROR] $*"; }
debug()   { 
    if [[ "$VERBOSE" == "1" ]]; then 
        echo -e "${CYAN}[DEBUG]${NC} $*"
        log_to_file "[DEBUG] $*"
    fi
}
header()  { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}"; }

log_to_file() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] $*" >> "$LOG_FILE" 2>/dev/null || true

    # 极简日志轮转 (5MB)
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size="$(stat -c %s "$LOG_FILE" 2>/dev/null || true)"
        if [[ -n "$size" ]] && (( size > 5242880 )); then
            mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
            echo "[$timestamp] [INFO] Log rotated" > "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

###############################################################################
# 前置检查
###############################################################################
need_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "此脚本需要 root 权限运行"
        exit 1
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1
}

ensure_deps() {
    local missing=()
    for cmd in "$@"; do
        if ! need_cmd "$cmd"; then
            missing+=("$cmd")
        fi
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        return 0
    fi

    info "缺失依赖: ${missing[*]}，正在尝试自动安装..."
    if need_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null 2>&1
    elif need_cmd dnf; then
        dnf install -y "${missing[@]}" >/dev/null 2>&1
    elif need_cmd yum; then
        yum install -y "${missing[@]}" >/dev/null 2>&1
    elif need_cmd apk; then
        apk add --no-cache "${missing[@]}" >/dev/null 2>&1
    elif need_cmd zypper; then
        zypper --non-interactive install "${missing[@]}" >/dev/null 2>&1
    fi

    local still_missing=()
    for cmd in "${missing[@]}"; do
        if ! need_cmd "$cmd"; then
            still_missing+=("$cmd")
        fi
    done

    if [[ "${#still_missing[@]}" -gt 0 ]]; then
        error "无法自动安装部分依赖: ${still_missing[*]}，请手动安装后重试"
        exit 1
    fi
    info "依赖安装完成"
}

###############################################################################
# 网络检测
###############################################################################
detect_iface() {
    local iface
    iface="$(ip -o route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
    if [[ -n "$iface" ]]; then echo "${iface%%@*}"; return 0; fi
    iface="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    if [[ -n "$iface" ]]; then echo "${iface%%@*}"; return 0; fi
    iface="$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}' || true)"
    if [[ -n "$iface" ]]; then echo "${iface%%@*}"; return 0; fi
    return 1
}

get_native_ipv6() {
    ip -6 -o addr show dev "$1" scope global 2>/dev/null \
        | awk '{print $4}' | grep -v '/128$' | head -n1 || true
}

get_native_ipv6_addr() {
    local cidr
    cidr="$(get_native_ipv6 "$1")"
    echo "${cidr%/*}"
}

get_dynamic_ipv6_addrs() {
    ip -6 -o addr show dev "$1" scope global 2>/dev/null \
        | awk '{print $4}' | grep '/128$' || true
}

get_default_v6_gateway() {
    ip -6 route show default dev "$1" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true
}

###############################################################################
# 连通性检测
###############################################################################
check_ipv6_connectivity() {
    local target_addr="${1:-}"
    
    local ping_cmd=""
    if need_cmd ping6; then
        ping_cmd="ping6"
    elif ping -6 -c1 ::1 >/dev/null 2>&1; then
        ping_cmd="ping -6"
    elif need_cmd ping; then
        ping_cmd="ping"
    fi

    if [[ -z "$ping_cmd" ]]; then
        if [[ -n "$target_addr" ]]; then
            ip -6 route get "$target_addr" >/dev/null 2>&1
            return $?
        fi
        return 0
    fi

    local targets=()
    if [[ -n "$target_addr" ]]; then
        targets=("$target_addr")
    else
        targets=("${PING6_TARGETS[@]}")
    fi

    local attempt target
    for attempt in $(seq 1 "$CONNECTIVITY_RETRIES"); do
        for target in "${targets[@]}"; do
            if $ping_cmd -c1 -W"$CONNECTIVITY_TIMEOUT" "$target" >/dev/null 2>&1; then
                return 0
            fi
        done
    done
    return 1
}

###############################################################################
# 上游脚本管理
###############################################################################
download_upstream_script() {
    local url="$1" cache_path="$2" name="$3"
    if curl -4 -fsSL --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 2 \
        "$url" -o "$cache_path" 2>/dev/null; then
        chmod +x "$cache_path"
        touch "$cache_path"
        debug "下载 $name 成功"
        return 0
    else
        if [[ -f "$cache_path" ]]; then
            warn "下载 $name 失败，使用本地缓存"
            return 0
        fi
        error "下载 $name 失败且无本地缓存"
        return 1
    fi
}

ensure_upstream_scripts() {
    mkdir -p "$STATE_DIR"
    download_upstream_script "$SCRIPT_URL" "$CACHE_CLIENT" "client.sh" || return 1
    download_upstream_script "$RESTORE_URL" "$CACHE_RESTORE" "restore.sh" || return 1
}

###############################################################################
# 读取上游 state 文件的网关映射
###############################################################################
read_upstream_gateways() {
    local iface="$1"
    local state_file="/var/lib/dynamicv6/client-${iface}.state"
    if [[ -f "$state_file" ]]; then
        jq -r '.gateways[]? | select(length > 0)' "$state_file" 2>/dev/null || true
    fi
}

###############################################################################
# 状态管理
###############################################################################
save_config() {
    local mode="$1" selected_ipv6="$2" selected_gateway="$3"
    shift 3
    local dynamic_ipv6_list=("$@")

    mkdir -p "$STATE_DIR"
    local dynamic_json="[]"
    if [[ "${#dynamic_ipv6_list[@]}" -gt 0 ]]; then
        dynamic_json="$(printf '%s\n' "${dynamic_ipv6_list[@]}" | jq -R . | jq -s .)"
    fi

    cat > "$CONFIG_FILE" <<EOF
{
  "version": "${VERSION}",
  "mode": "${mode}",
  "selected_ipv6": "${selected_ipv6}",
  "selected_gateway": "${selected_gateway}",
  "dynamic_ipv6_list": ${dynamic_json},
  "iface": "${IFACE:-}",
  "native_ipv6": "$(get_native_ipv6_addr "${IFACE:-}")",
  "auto_recovery": ${AUTO_RECOVERY_ENABLED},
  "updated_at": "$(date -Iseconds)",
  "recovery_attempts": 0
}
EOF
}

config_get() {
    local key="$1"
    if [[ -f "$CONFIG_FILE" ]]; then
        jq -r ".$key // empty" "$CONFIG_FILE" 2>/dev/null
    fi
}

###############################################################################
# RECOVERY.md 生成
###############################################################################
generate_recovery() {
    local iface="$1" mode="$2"
    shift 2
    local dynamic_addrs=("$@")

    cat > "$RECOVERY_FILE" <<EOF
# DynamicV6 手动恢复指南
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 网卡: $iface
# 当前模式: $mode

## 步骤 1: 删除动态 IPv6 地址
EOF

    if [[ "${#dynamic_addrs[@]}" -gt 0 ]]; then
        for addr in "${dynamic_addrs[@]}"; do
            echo "ip -6 addr del ${addr} dev ${iface}" >> "$RECOVERY_FILE"
        done
    else
        echo "# (无动态 IPv6 地址)" >> "$RECOVERY_FILE"
    fi

    cat >> "$RECOVERY_FILE" <<EOF

## 步骤 2: 删除默认路由并恢复原生（勿 flush table main，会清掉该网卡全部路由）
ip -6 route show default dev ${iface}
# 按上面输出逐条删除 default，例如:
# ip -6 route del default via <网关> dev ${iface} metric <值>
ip -6 route add default via \${原生网关:-<请填入原生网关>} dev ${iface} src \${原生IPv6地址:-$(get_native_ipv6_addr "$iface")} metric 100

## 步骤 3: 清理策略路由
$(for i in $(seq 0 15); do
    echo "ip -6 rule del pref $((POLICY_RULE_PREF_BASE + i)) 2>/dev/null || true"
    echo "ip -6 route flush table $((POLICY_TABLE_BASE + i)) 2>/dev/null || true"
done)

## 步骤 4: 删除监控 cron
crontab -l 2>/dev/null | grep -v "${MONITOR_CRON_TAG}" | crontab -

## 步骤 5: 删除状态目录
rm -rf ${STATE_DIR}
EOF

    info "恢复指南已写入: $RECOVERY_FILE"
}

###############################################################################
# 路由管理（src 源地址控制）
#
# 核心思路：
#   - 动态 IPv6 和原生 IPv6 可能共享同一网关
#   - 用 ip -6 route 的 src 参数控制出站源地址
#   - 先删除所有默认路由，再按优先级重建
###############################################################################
apply_route_policy() {
    local iface="$1" mode="$2" target_gateway="$3" target_src="$4"
    shift 4
    local all_gateways=("$@")

    info "配置路由策略: mode=$mode target_src=$target_src"

    # 确保网关主机路由存在
    for gw in "${all_gateways[@]}"; do
        ip -6 route replace "${gw}/128" dev "$iface" metric "$METRIC_GATEWAY_HOST" 2>/dev/null || true
    done

    # 获取原生 IPv6 地址（备用 src）
    local native_src
    native_src="$(get_native_ipv6_addr "$iface")"

    # 删除所有现有的默认路由（干净重建）
    while read -r line; do
        [[ -z "$line" ]] && continue
        local del_via del_met del_src
        del_via="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
        del_met="$(echo "$line" | sed -n 's/.* metric \([0-9]\+\).*/\1/p')"
        [[ -z "$del_via" ]] && continue
        if [[ -n "$del_met" ]]; then
            ip -6 route del default via "$del_via" dev "$iface" metric "$del_met" 2>/dev/null || true
        else
            ip -6 route del default via "$del_via" dev "$iface" 2>/dev/null || true
        fi
    done < <(ip -6 route show default dev "$iface")

    case "$mode" in
        dynamic)
            # 主路由：用动态 IPv6 做 src
            if [[ -n "$target_src" ]]; then
                # src 需要纯地址，去掉 /prefix
                local clean_src="${target_src%%/*}"
                ip -6 route add default via "$target_gateway" dev "$iface" src "$clean_src" metric "$METRIC_PRIMARY" 2>/dev/null \
                    || ip -6 route replace default via "$target_gateway" dev "$iface" src "$clean_src" metric "$METRIC_PRIMARY" 2>/dev/null || true
                info "主出口: via=$target_gateway src=$clean_src metric=$METRIC_PRIMARY"
            else
                ip -6 route add default via "$target_gateway" dev "$iface" metric "$METRIC_PRIMARY" 2>/dev/null \
                    || ip -6 route replace default via "$target_gateway" dev "$iface" metric "$METRIC_PRIMARY" 2>/dev/null || true
                info "主出口: via=$target_gateway (无src) metric=$METRIC_PRIMARY"
            fi

            # 备用路由：原生 IPv6 做 src
            if [[ -n "$native_src" && "$native_src" != "$target_src" ]]; then
                local gw="${all_gateways[0]:-$target_gateway}"
                local clean_native="${native_src%%/*}"
                ip -6 route add default via "$gw" dev "$iface" src "$clean_native" metric "$METRIC_BACKUP" 2>/dev/null || true
                debug "备用路由: via=$gw src=$clean_native metric=$METRIC_BACKUP"
            fi
            ;;
        native)
            # 主路由：用原生 IPv6 做 src
            local gw="${all_gateways[0]:-$target_gateway}"
            if [[ -n "$native_src" ]]; then
                local clean_native="${native_src%%/*}"
                ip -6 route add default via "$gw" dev "$iface" src "$clean_native" metric "$METRIC_PRIMARY" 2>/dev/null \
                    || ip -6 route replace default via "$gw" dev "$iface" src "$clean_native" metric "$METRIC_PRIMARY" 2>/dev/null || true
                info "主出口: via=$gw src=$clean_native metric=$METRIC_PRIMARY"
            else
                ip -6 route add default via "$gw" dev "$iface" metric "$METRIC_PRIMARY" 2>/dev/null \
                    || ip -6 route replace default via "$gw" dev "$iface" metric "$METRIC_PRIMARY" 2>/dev/null || true
                info "主出口: via=$gw (无src) metric=$METRIC_PRIMARY"
            fi

            # 备用路由：动态 IPv6 做 src
            if [[ -n "$target_src" && "$target_src" != "$native_src" ]]; then
                ip -6 route add default via "$gw" dev "$iface" src "$target_src" metric "$METRIC_BACKUP" 2>/dev/null || true
                debug "备用路由: via=$gw src=$target_src metric=$METRIC_BACKUP"
            fi
            ;;
    esac
}

###############################################################################
# 源地址策略路由
###############################################################################
apply_source_policy_routes() {
    local iface="$1"
    shift
    local cidr_gateway_pairs=("$@")

    for i in $(seq 0 127); do
        ip -6 rule del pref "$((POLICY_RULE_PREF_BASE + i))" >/dev/null 2>&1 || true
        ip -6 route flush table "$((POLICY_TABLE_BASE + i))" >/dev/null 2>&1 || true
    done

    [[ "${#cidr_gateway_pairs[@]}" -eq 0 ]] && return 0

    local idx=0
    for pair in "${cidr_gateway_pairs[@]}"; do
        local cidr="${pair%%|*}"
        local gw="${pair#*|}"
        [[ -z "$cidr" || -z "$gw" ]] && continue
        (( idx < 128 )) || break

        local table=$((POLICY_TABLE_BASE + idx))
        local pref=$((POLICY_RULE_PREF_BASE + idx))

        ip -6 route replace "${gw}/128" dev "$iface" table "$table" 2>/dev/null || true
        ip -6 route replace default via "$gw" dev "$iface" onlink table "$table" 2>/dev/null || true
        ip -6 rule add pref "$pref" from "$cidr" table "$table" 2>/dev/null || true
        idx=$((idx + 1))
    done
}

###############################################################################
# 上游 timer 清理
###############################################################################
cleanup_upstream_timer() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet dynamicv6-client.timer 2>/dev/null; then
            systemctl disable --now dynamicv6-client.timer 2>/dev/null || true
            info "已禁用上游 dynamicv6-client.timer"
        fi
        if [[ -f /etc/systemd/system/dynamicv6-client.timer ]]; then
            rm -f /etc/systemd/system/dynamicv6-client.timer
            rm -f /etc/systemd/system/dynamicv6-client.service
            systemctl daemon-reload 2>/dev/null || true
            info "已删除上游 timer 文件"
        fi
    fi
}

###############################################################################
# 监控 cron 管理
###############################################################################
install_monitor() {
    local script_path
    script_path="$(readlink -f "$0")"
    remove_monitor

    if need_cmd systemctl && pidof systemd >/dev/null 2>&1; then
        cat > /etc/systemd/system/dynamicv6-manager.service <<EOF
[Unit]
Description=DynamicV6 Manager Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=${script_path} --monitor
EOF
        cat > /etc/systemd/system/dynamicv6-manager.timer <<EOF
[Unit]
Description=Run DynamicV6 Manager Monitor every 3 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=3min

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable --now dynamicv6-manager.timer >/dev/null 2>&1 || true
        info "监控 Systemd Timer 已安装 (每 3 分钟)"
    else
        (crontab -l 2>/dev/null || true; echo "*/3 * * * * ${script_path} --monitor ${MONITOR_CRON_TAG}") | crontab -
        info "监控 cron 已安装 (每 3 分钟)"
    fi
}

remove_monitor() {
    if need_cmd systemctl && pidof systemd >/dev/null 2>&1; then
        systemctl disable --now dynamicv6-manager.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/dynamicv6-manager.service
        rm -f /etc/systemd/system/dynamicv6-manager.timer
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    if crontab -l >/dev/null 2>&1; then
        crontab -l | grep -v "${MONITOR_CRON_TAG}" | crontab - 2>/dev/null || true
    fi
}

is_monitor_active() {
    if need_cmd systemctl && pidof systemd >/dev/null 2>&1; then
        if systemctl is-active --quiet dynamicv6-manager.timer >/dev/null 2>&1; then
            return 0
        fi
    fi
    crontab -l 2>/dev/null | grep -q "${MONITOR_CRON_TAG}"
}

###############################################################################
# 监控逻辑
###############################################################################
do_monitor() {
    need_root
    ensure_deps jq

    if [[ ! -f "$CONFIG_FILE" ]]; then
        warn "无配置文件，跳过监控"
        log_to_file "MONITOR: 无配置文件，跳过"
        exit 0
    fi

    local mode selected_ipv6 selected_gateway iface auto_recovery
    mode="$(config_get mode)"
    selected_ipv6="$(config_get selected_ipv6)"
    selected_gateway="$(config_get selected_gateway)"
    iface="$(config_get iface)"
    auto_recovery="$(config_get auto_recovery)"

    if [[ -z "$iface" ]]; then
        iface="$(detect_iface || true)"
    fi
    if [[ -z "$iface" ]]; then
        error "监控: 无法检测网卡"
        log_to_file "MONITOR ERROR: 无法检测网卡"
        exit 1
    fi

    local needs_fix=0
    local reason=""

    case "$mode" in
        dynamic)
            if [[ -n "$selected_ipv6" ]]; then
                if ! ip -6 addr show dev "$iface" | grep -qF "${selected_ipv6%%/*}"; then
                    needs_fix=1
                    reason="选中的 IPv6 地址已消失: $selected_ipv6"
                fi
            fi
            if [[ "$needs_fix" -eq 0 ]]; then
                if ! check_ipv6_connectivity; then
                    needs_fix=1
                    reason="IPv6 连通性检测失败"
                fi
            fi
            ;;
        native)
            if ! check_ipv6_connectivity; then
                needs_fix=1
                reason="原生 IPv6 连通性检测失败"
            fi
            ;;
    esac

    if [[ "$needs_fix" -eq 1 ]]; then
        warn "监控发现问题: $reason"
        log_to_file "MONITOR: 问题发现 - $reason"
        if [[ "$auto_recovery" == "1" ]]; then
            do_auto_recovery "$iface" "$reason"
        else
            warn "自动恢复未启用，请手动检查"
        fi
    else
        debug "监控检查通过"
    fi
}

###############################################################################
# 自动恢复
###############################################################################
do_auto_recovery() {
    local iface="$1" reason="$2"
    local attempts
    attempts="$(config_get recovery_attempts)"
    attempts="${attempts:-0}"

    if (( attempts >= MAX_RECOVERY_ATTEMPTS )); then
        error "自动恢复已达最大尝试次数，回退到原生 IPv6"
        log_to_file "RECOVERY: 达到最大尝试次数，回退原生"
        fallback_to_native "$iface"
        return
    fi

    header "自动恢复 (尝试 $((attempts + 1))/$MAX_RECOVERY_ATTEMPTS)"
    info "原因: $reason"
    log_to_file "RECOVERY: 尝试重新下发 (第 $((attempts + 1)) 次)"

    if [[ -f "$CONFIG_FILE" ]]; then
        local tmp
        if tmp="$(jq ".recovery_attempts = $((attempts + 1))" "$CONFIG_FILE")"; then
            echo "$tmp" > "$CONFIG_FILE"
        fi
    fi

    if [[ -x "$CACHE_CLIENT" ]]; then
        DYNAMICV6_AUTO_TIMER=0 bash "$CACHE_CLIENT" "$iface" >/dev/null 2>&1
        cleanup_upstream_timer

        local new_addrs=()
        mapfile -t new_addrs < <(get_dynamic_ipv6_addrs "$iface")

        if [[ "${#new_addrs[@]}" -gt 0 ]]; then
            info "重新下发成功"
            log_to_file "RECOVERY: 重新下发成功"

            # 旧 selected 可能已消失；优先沿用仍在的，否则用第一个新地址
            local mode selected_ipv6 selected_gateway
            mode="$(config_get mode)"
            selected_ipv6="$(config_get selected_ipv6)"
            selected_gateway="$(config_get selected_gateway)"

            if [[ "$mode" == "dynamic" ]]; then
                local still_present=0
                if [[ -n "$selected_ipv6" ]]; then
                    for a in "${new_addrs[@]}"; do
                        if [[ "$a" == "$selected_ipv6" || "${a%%/*}" == "${selected_ipv6%%/*}" ]]; then
                            selected_ipv6="$a"
                            still_present=1
                            break
                        fi
                    done
                fi
                if [[ "$still_present" -eq 0 ]]; then
                    selected_ipv6="${new_addrs[0]}"
                    info "原出口已失效，切换为: $selected_ipv6"
                    log_to_file "RECOVERY: 出口更新为 $selected_ipv6"
                fi
            fi

            local all_gws=()
            mapfile -t all_gws < <(read_upstream_gateways "$iface")
            if [[ "${#all_gws[@]}" -eq 0 ]]; then
                while read -r gw; do
                    [[ -n "$gw" ]] && all_gws+=("$gw")
                done < <(ip -6 route show dev "$iface" metric "$METRIC_GATEWAY_HOST" 2>/dev/null \
                    | awk '{print $1}' | grep '/128$' | sed 's|/128||' | sort -u)
            fi
            if [[ -z "$selected_gateway" ]]; then
                selected_gateway="${all_gws[0]:-}"
            fi

            if [[ "$mode" == "dynamic" && -n "$selected_gateway" && -n "$selected_ipv6" ]]; then
                apply_route_policy "$iface" "$mode" "$selected_gateway" "$selected_ipv6" "${all_gws[@]}"
            fi

            if [[ -f "$CONFIG_FILE" ]]; then
                local tmp
                if tmp="$(jq --arg ipv6 "$selected_ipv6" --arg gw "$selected_gateway" \
                    '.recovery_attempts = 0 | .selected_ipv6 = $ipv6 | .selected_gateway = $gw' \
                    "$CONFIG_FILE")"; then
                    echo "$tmp" > "$CONFIG_FILE"
                fi
            fi
            return
        fi
    fi

    warn "重新下发失败，回退到原生 IPv6"
    fallback_to_native "$iface"
}

fallback_to_native() {
    local iface="$1"
    info "回退到原生 IPv6 出口..."

    local native_src
    native_src="$(get_native_ipv6_addr "$iface")"

    # 先记下网关（删默认路由后 get_default_v6_gateway 会失效）
    local gw
    gw="$(get_default_v6_gateway "$iface")"
    if [[ -z "$gw" ]]; then
        local all_gws=()
        mapfile -t all_gws < <(read_upstream_gateways "$iface")
        if [[ "${#all_gws[@]}" -eq 0 ]]; then
            while read -r line; do
                [[ -z "$line" ]] && continue
                local via
                via="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
                [[ -n "$via" ]] && all_gws+=("$via")
            done < <(ip -6 route show default dev "$iface")
        fi
        gw="${all_gws[0]:-}"
    fi

    # 删除所有默认路由
    while read -r line; do
        [[ -z "$line" ]] && continue
        local via met
        via="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
        met="$(echo "$line" | sed -n 's/.* metric \([0-9]\+\).*/\1/p')"
        [[ -z "$via" ]] && continue
        if [[ -n "$met" ]]; then
            ip -6 route del default via "$via" dev "$iface" metric "$met" 2>/dev/null || true
        else
            ip -6 route del default via "$via" dev "$iface" 2>/dev/null || true
        fi
    done < <(ip -6 route show default dev "$iface")

    if [[ -n "$gw" && -n "$native_src" ]]; then
        ip -6 route add default via "$gw" dev "$iface" src "$native_src" metric "$METRIC_PRIMARY" 2>/dev/null || true
    elif [[ -n "$gw" ]]; then
        ip -6 route add default via "$gw" dev "$iface" metric "$METRIC_PRIMARY" 2>/dev/null || true
    else
        warn "无法确定原生网关，请查看 $RECOVERY_FILE 手动恢复"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        local tmp
        if tmp="$(jq '.mode = "native" | .selected_ipv6 = "" | .selected_gateway = "" | .recovery_attempts = 0' "$CONFIG_FILE")"; then
            echo "$tmp" > "$CONFIG_FILE"
        fi
    fi

    info "已回退到原生 IPv6 出口"
    log_to_file "RECOVERY: 已回退原生 IPv6"
}

###############################################################################
# 下发 IPv6
###############################################################################
do_deploy() {
    header "下发 IPv6"
    ensure_upstream_scripts || return 1

    local iface="$IFACE"
    info "网卡: $iface"

    if [[ -f "$CONFIG_FILE" ]]; then
        local prev_mode
        prev_mode="$(config_get mode)"
        if [[ -n "$prev_mode" ]]; then
            warn "检测到已有配置 (mode=$prev_mode)，将覆盖"
            local prev_dynamic=()
            mapfile -t prev_dynamic < <(jq -r '.dynamic_ipv6_list[]?' "$CONFIG_FILE" 2>/dev/null || true)
            generate_recovery "$iface" "$prev_mode" "${prev_dynamic[@]}"
        fi
    fi

    info "运行上游下发脚本..."
    DYNAMICV6_AUTO_TIMER=0 bash "$CACHE_CLIENT" "$iface" 2>&1 | tee -a "$LOG_FILE"
    local deploy_rc=${PIPESTATUS[0]}

    if [[ "$deploy_rc" -ne 0 ]]; then
        error "上游下发脚本失败 (exit code: $deploy_rc)"
        return 1
    fi

    cleanup_upstream_timer
    sleep 1

    local dynamic_addrs=()
    mapfile -t dynamic_addrs < <(get_dynamic_ipv6_addrs "$iface")

    if [[ "${#dynamic_addrs[@]}" -eq 0 ]]; then
        error "未检测到动态 IPv6 地址"
        return 1
    fi

    header "下发结果"
    info "检测到 ${#dynamic_addrs[@]} 个动态 IPv6 地址"

    # 从上游 state 读网关
    local dynamic_gws=()
    mapfile -t dynamic_gws < <(read_upstream_gateways "$iface")

    # 兜底
    if [[ "${#dynamic_gws[@]}" -eq 0 ]]; then
        for addr in "${dynamic_addrs[@]}"; do
            local gw
            gw="$(ip -6 route get "${addr%%/*}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true)"
            [[ -n "$gw" ]] && dynamic_gws+=("$gw")
        done
    fi

    # 交互选择出口
    local native_ipv6_addr
    native_ipv6_addr="$(get_native_ipv6_addr "$iface")"

    echo ""
    echo -e "${BOLD}可用 IPv6 地址:${NC}"
    echo -e "  ${CYAN}n)${NC} 使用机房原生 IPv6 (${native_ipv6_addr:-未知})"
    local idx=1
    for addr in "${dynamic_addrs[@]}"; do
        echo -e "  ${CYAN}${idx})${NC} 使用 ${addr}"
        idx=$((idx + 1))
    done
    echo -e "  ${CYAN}0)${NC} 返回上级菜单"
    echo ""

    local choice
    if [[ "$AUTO_MODE" == "1" ]]; then
        case "$AUTO_EGRESS" in
            native)   choice="n" ;;
            dynamic:*) choice="${AUTO_EGRESS#dynamic:}" ;;
            *)         choice="1" ;;
        esac
        info "自动模式: 选择 $choice"
    else
        echo -n "请选择默认 IPv6 出口 [n/1-${#dynamic_addrs[@]}/0]: "
        read -r choice
    fi

    if [[ "$choice" == "0" ]]; then
        return 0
    fi

    local mode selected_ipv6 selected_gateway

    if [[ "$choice" == "n" || "$choice" == "N" ]]; then
        mode="native"
        selected_ipv6=""
        selected_gateway="${dynamic_gws[0]:-}"
        info "选择: 机房原生 IPv6"
    else
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dynamic_addrs[@]} )); then
            mode="dynamic"
            selected_ipv6="${dynamic_addrs[$((choice - 1))]}"
            selected_gateway="${dynamic_gws[0]:-}"
            info "选择: ${selected_ipv6} (网关: ${selected_gateway:-未知})"
        else
            error "无效选择: $choice"
            return 1
        fi
    fi

    generate_recovery "$iface" "$mode" "${dynamic_addrs[@]}"

    # 去重网关
    local unique_gws=()
    for gw in "${dynamic_gws[@]}"; do
        local found=0
        for ug in "${unique_gws[@]:-}"; do
            [[ "$gw" == "$ug" ]] && found=1 && break
        done
        [[ "$found" -eq 0 ]] && unique_gws+=("$gw")
    done

    # 读取上游的 cidr-gateway 映射
    local cidr_gw_pairs=()
    local state_file="/var/lib/dynamicv6/client-${iface}.state"
    if [[ -f "$state_file" ]]; then
        mapfile -t cidr_gw_pairs < <(jq -r '
            [.ipv6_cidrs[]?, .selected_ipv6_cidrs[]?] as $all |
            ($all | unique | .[]) as $cidr |
            (.gateways[0] // "") as $gw |
            select($cidr | length > 0 and $gw | length > 0) |
            "\($cidr)|\($gw)"
        ' "$state_file" 2>/dev/null || true)
    fi

    apply_route_policy "$iface" "$mode" "$selected_gateway" "$selected_ipv6" "${unique_gws[@]}"
    apply_source_policy_routes "$iface" "${cidr_gw_pairs[@]}"

    save_config "$mode" "$selected_ipv6" "$selected_gateway" "${dynamic_addrs[@]}"

    if [[ "$AUTO_NO_MONITOR" != "1" ]]; then
        install_monitor
    fi

    header "配置完成"
    show_status_summary
    log_to_file "DEPLOY: 完成 mode=$mode selected=$selected_ipv6 gateway=$selected_gateway"
}

###############################################################################
# 切换出口
###############################################################################
do_switch() {
    header "切换默认 IPv6 出口"

    local iface="$IFACE"
    local dynamic_addrs=()
    mapfile -t dynamic_addrs < <(get_dynamic_ipv6_addrs "$iface")

    if [[ "${#dynamic_addrs[@]}" -eq 0 ]]; then
        error "当前没有动态 IPv6 地址，请先下发"
        return 1
    fi

    local native_ipv6_addr
    native_ipv6_addr="$(get_native_ipv6_addr "$iface")"

    echo ""
    echo -e "${BOLD}可用 IPv6 出口:${NC}"
    echo -e "  ${CYAN}n)${NC} 机房原生 IPv6 (${native_ipv6_addr:-未知})"
    local idx=1
    for addr in "${dynamic_addrs[@]}"; do
        echo -e "  ${CYAN}${idx})${NC} ${addr}"
        idx=$((idx + 1))
    done
    echo -e "  ${CYAN}0)${NC} 返回上级菜单"
    echo ""

    local choice
    echo -n "选择新的默认出口 [n/1-${#dynamic_addrs[@]}/0]: "
    read -r choice

    if [[ "$choice" == "0" ]]; then
        return 0
    fi

    local mode selected_ipv6 selected_gateway

    # 从上游 state 读网关
    local gws=()
    mapfile -t gws < <(read_upstream_gateways "$iface")

    if [[ "$choice" == "n" || "$choice" == "N" ]]; then
        mode="native"
        selected_ipv6=""
        selected_gateway="${gws[0]:-}"
    else
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#dynamic_addrs[@]} )); then
            mode="dynamic"
            selected_ipv6="${dynamic_addrs[$((choice - 1))]}"
            selected_gateway="${gws[0]:-}"
            if [[ -z "$selected_gateway" ]]; then
                selected_gateway="$(ip -6 route get "${selected_ipv6%%/*}" 2>/dev/null \
                    | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true)"
            fi
        else
            error "无效选择"
            return 1
        fi
    fi

    # 兜底：从路由表找网关
    if [[ -z "$selected_gateway" ]]; then
        selected_gateway="$(get_default_v6_gateway "$iface")"
    fi

    if [[ -z "$selected_gateway" ]]; then
        error "无法确定网关地址"
        return 1
    fi

    generate_recovery "$iface" "$mode" "${dynamic_addrs[@]}"

    local all_gws=("${gws[@]}")
    # 补充路由表中可能存在的网关
    while read -r gw; do
        [[ -n "$gw" ]] && all_gws+=("$gw")
    done < <(ip -6 route show dev "$iface" metric "$METRIC_GATEWAY_HOST" 2>/dev/null \
        | awk '{print $1}' | grep '/128$' | sed 's|/128||')

    # 去重
    local unique_gws=()
    for gw in "${all_gws[@]}"; do
        local found=0
        for ug in "${unique_gws[@]:-}"; do
            [[ "$gw" == "$ug" ]] && found=1 && break
        done
        [[ "$found" -eq 0 ]] && unique_gws+=("$gw")
    done

    apply_route_policy "$iface" "$mode" "$selected_gateway" "$selected_ipv6" "${unique_gws[@]}"

    save_config "$mode" "$selected_ipv6" "$selected_gateway" "${dynamic_addrs[@]}"

    header "切换完成"
    show_status_summary
    log_to_file "SWITCH: mode=$mode selected=$selected_ipv6 gateway=$selected_gateway"
}

###############################################################################
# 还原
###############################################################################
do_restore() {
    header "还原所有变更"
    ensure_upstream_scripts || return 1

    local iface="$IFACE"
    info "网卡: $iface"

    local current_dynamic=()
    mapfile -t current_dynamic < <(get_dynamic_ipv6_addrs "$iface")
    generate_recovery "$iface" "before-restore" "${current_dynamic[@]}"

    remove_monitor
    info "已删除监控任务"

    info "运行上游还原脚本..."
    bash "$CACHE_RESTORE" "$iface" 2>&1 | tee -a "$LOG_FILE"

    rm -f "$CONFIG_FILE"
    rm -f "$RECOVERY_FILE"
    info "已清理本地状态"

    header "还原完成"
    ip -6 addr show dev "$iface"
    ip -6 route show default dev "$iface" 2>/dev/null || true
    log_to_file "RESTORE: 完成"
}

###############################################################################
# 状态显示
###############################################################################
show_status_summary() {
    local iface="$IFACE"
    local mode="" selected_ipv6="" selected_gateway="" native_ipv6="" auto_recovery=""

    if [[ -f "$CONFIG_FILE" ]]; then
        mode="$(config_get mode)"
        selected_ipv6="$(config_get selected_ipv6)"
        selected_gateway="$(config_get selected_gateway)"
        native_ipv6="$(config_get native_ipv6)"
        auto_recovery="$(config_get auto_recovery)"
    fi

    native_ipv6="${native_ipv6:-$(get_native_ipv6_addr "$iface")}"
    local dynamic_count
    dynamic_count="$(get_dynamic_ipv6_addrs "$iface" | wc -l | tr -d ' ')"
    local monitor_icon monitor_text
    if is_monitor_active; then
        monitor_icon="${GREEN}●${NC}"
        monitor_text="${GREEN}运行中${NC}"
    else
        monitor_icon="${RED}○${NC}"
        monitor_text="${RED}未安装${NC}"
    fi
    local recovery_icon recovery_text
    if [[ "$auto_recovery" == "1" ]]; then
        recovery_icon="${GREEN}●${NC}"
        recovery_text="${GREEN}已开启${NC}"
    else
        recovery_icon="${YELLOW}○${NC}"
        recovery_text="${YELLOW}已关闭${NC}"
    fi

    local mode_text
    case "$mode" in
        dynamic) mode_text="${GREEN}▲ 动态 IPv6${NC}" ;;
        native)  mode_text="${CYAN}■ 原生 IPv6${NC}" ;;
        *)       mode_text="${YELLOW}○ 未配置${NC}" ;;
    esac

    echo ""
    echo -e "  ${BOLD}DynamicV6 Manager${NC}  ${DIM}v${VERSION}${NC}"
    echo -e "  ${DIM}───────────────────────────────────────${NC}"
    echo ""
    printf "    %-14s %s\n" "网卡:" "$iface"
    printf "    %-14s %b\n" "模式:" "$mode_text"
    echo ""

    if [[ "$mode" == "dynamic" && -n "$selected_ipv6" ]]; then
        printf "    ${BOLD}%-14s${NC} %s\n" "▶ 出口地址:" "$selected_ipv6"
        printf "    %-14s %s\n" "  网关:" "${selected_gateway:-未知}"
    fi

    printf "    %-14s %s\n" "原生 IPv6:" "${native_ipv6:-无}"
    echo ""
    printf "    %-14s %b  %b\n" "监控:" "$monitor_icon" "$monitor_text"
    printf "    %-14s %b  %b\n" "自动恢复:" "$recovery_icon" "$recovery_text"
    printf "    %-14s %s\n" "动态地址:" "${dynamic_count} 个"

    echo ""
    echo -e "  ${DIM}───────────────────────────────────────${NC}"
    echo -e "  ${BOLD}当前路由:${NC}"
    while read -r line; do
        [[ -z "$line" ]] && continue
        local via src met
        via="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
        src="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
        met="$(echo "$line" | sed -n 's/.* metric \([0-9]\+\).*/\1/p')"
        local marker=""
        if [[ "$mode" == "dynamic" && "$src" == "${selected_ipv6%%/*}" ]]; then
            marker="${GREEN}◀ 主出口${NC}"
        elif [[ "$mode" == "native" && -n "$native_ipv6" && "$src" == "$native_ipv6" ]]; then
            marker="${GREEN}◀ 主出口${NC}"
        elif [[ -n "$met" ]]; then
            marker="${DIM}备用 (metric $met)${NC}"
        fi
        if [[ -n "$src" ]]; then
            printf "    %-18s src %-38s %b\n" "via $via" "$src" "$marker"
        else
            printf "    %-18s %-38s %b\n" "via $via" "" "$marker"
        fi
    done < <(ip -6 route show default dev "$iface" 2>/dev/null)
    echo ""
}

do_status() {
    header "DynamicV6 状态"
    show_status_summary
}

###############################################################################
# 交互菜单
###############################################################################
show_menu() {
    local has_dynamic=0
    if [[ -n "$(get_dynamic_ipv6_addrs "$IFACE")" ]]; then
        has_dynamic=1
    fi

    echo -e "${BOLD}DynamicV6 Manager v${VERSION}${NC}"
    echo ""

    if [[ "$has_dynamic" -eq 1 ]]; then
        echo -e "  ${CYAN}1)${NC} 重新下发 IPv6（刷新租约）"
        echo -e "  ${CYAN}2)${NC} 切换默认 IPv6 出口"
        echo -e "  ${CYAN}3)${NC} 还原所有变更"
        echo -e "  ${CYAN}4)${NC} 查看状态"
        echo -e "  ${CYAN}5)${NC} 开启/关闭自动恢复"
    else
        echo -e "  ${CYAN}1)${NC} 下发 IPv6"
        echo -e "  ${CYAN}4)${NC} 查看状态"
    fi

    echo -e "  ${CYAN}0)${NC} 退出"
    echo ""
}

do_interactive() {
    # 启动时显示当前状态
    do_status

    while true; do
        show_menu
        local choice
        echo -n "请选择: "
        read -r choice

        case "$choice" in
            1) do_deploy ;;
            2) do_switch ;;
            3) do_restore ;;
            4) do_status ;;
            5) toggle_auto_recovery ;;
            0) echo "退出"; exit 0 ;;
            *) warn "无效选择" ;;
        esac

        echo ""
        echo -n "按 Enter 继续..."
        read -r
    done
}

toggle_auto_recovery() {
    local current
    current="$(config_get auto_recovery)"
    if [[ "$current" == "1" ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            local tmp
            if tmp="$(jq '.auto_recovery = 0' "$CONFIG_FILE")"; then
                echo "$tmp" > "$CONFIG_FILE"
            fi
        fi
        info "自动恢复已关闭"
    else
        if [[ -f "$CONFIG_FILE" ]]; then
            local tmp
            if tmp="$(jq '.auto_recovery = 1' "$CONFIG_FILE")"; then
                echo "$tmp" > "$CONFIG_FILE"
            fi
        fi
        info "自动恢复已开启"
    fi
}

###############################################################################
# 帮助信息
###############################################################################
show_help() {
    cat <<EOF
DynamicV6 Manager v${VERSION} — AetherCloud DynamicV6 管理脚本

用法: $SCRIPT_NAME [选项]

交互模式 (默认):
  $SCRIPT_NAME                进入交互菜单

自动模式:
  $SCRIPT_NAME --auto         自动下发，使用第 1 个动态 IPv6
  $SCRIPT_NAME --auto --egress=native     自动下发，使用原生 IPv6
  $SCRIPT_NAME --auto --egress=dynamic:2  自动下发，使用第 2 个动态 IPv6

状态查看:
  $SCRIPT_NAME --status       显示当前状态

还原:
  $SCRIPT_NAME --restore      还原所有变更

监控 (由 cron 调用):
  $SCRIPT_NAME --monitor      执行监控检查

选项:
  --auto-recovery             启用自动恢复
  --no-monitor                不安装监控 cron
  --iface=<name>              指定网卡
  --verbose                   详细输出
  --help, -h                  显示帮助

示例:
  $SCRIPT_NAME                                    # 交互模式
  $SCRIPT_NAME --auto --egress=native             # 全自动，用原生 IPv6
  $SCRIPT_NAME --auto --egress=dynamic:1 --auto-recovery  # 全自动+自动恢复
  $SCRIPT_NAME --status                           # 查看状态
EOF
}

###############################################################################
# 参数解析
###############################################################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --monitor)       RUN_MODE="monitor" ;;
            --auto)          AUTO_MODE=1; RUN_MODE="auto" ;;
            --auto-recovery) AUTO_RECOVERY_ENABLED=1 ;;
            --egress=*)      AUTO_EGRESS="${1#*=}" ;;
            --no-monitor)    AUTO_NO_MONITOR=1 ;;
            --status)        RUN_MODE="status" ;;
            --restore)       RUN_MODE="restore" ;;
            --iface=*)       IFACE="${1#*=}" ;;
            --verbose)       VERBOSE=1 ;;
            --help|-h)       show_help; exit 0 ;;
            *)               warn "未知参数: $1" ;;
        esac
        shift
    done
}

###############################################################################
# 主入口
###############################################################################
main() {
    for arg in "$@"; do
        if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
            show_help
            exit 0
        fi
    done

    parse_args "$@"
    local mode="$RUN_MODE"

    if [[ "$mode" != "monitor" ]]; then
        need_root
    fi

    # 并发锁 (防踩踏)
    if need_cmd flock; then
        exec 9>"/var/run/dynamicv6-manager.lock"
        if ! flock -n 9; then
            log_to_file "ERROR: 另一个实例正在运行，本次启动取消"
            echo -e "${RED}[ERROR]${NC} 另一个实例正在运行，请稍后再试" >&2
            exit 1
        fi
    fi

    if [[ -z "$IFACE" ]]; then
        IFACE="$(detect_iface || true)"
    fi
    if [[ -z "$IFACE" ]]; then
        error "无法检测网络接口，请用 --iface=<name> 指定"
        exit 1
    fi
    debug "网卡: $IFACE"

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    mkdir -p "$STATE_DIR"

    case "$mode" in
        interactive)
            ensure_deps jq curl
            do_interactive
            ;;
        auto)
            ensure_deps jq curl
            do_deploy
            ;;
        monitor)
            do_monitor
            ;;
        status)
            ensure_deps jq
            do_status
            ;;
        restore)
            ensure_deps jq curl
            do_restore
            ;;
        *)
            error "未知模式: $mode"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
