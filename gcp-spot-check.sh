#!/usr/bin/env bash

set -uo pipefail

VERSION="2.0.0"
VERSION_DATE="2025-02-17"

INSTALL_PATH="/usr/local/bin"
GCPSC_SCRIPT="$INSTALL_PATH/gcpsc"
CONFIG_DIR="/etc/gcpsc"
CONFIG_FILE="$CONFIG_DIR/config.json"
LASTCHECK_DIR="$CONFIG_DIR/lastcheck"
KEY_DIR="$CONFIG_DIR/keys"
SCRIPT_URL="https://raw.githubusercontent.com/crazy0x70/scripts/refs/heads/main/gcp-spot-check/gcp-spot-check.sh"

if [ -w "/var/log" ]; then
    LOG_FILE="/var/log/gcpsc.log"
else
    LOG_FILE="/tmp/gcpsc.log"
fi

LOGO="
========================================================
       Google Cloud Spot Instance 保活服务
                Version: $VERSION
                Date: $VERSION_DATE
                 (by crazy0x70)
========================================================
"

if [ -n "${SUDO_USER:-}" ] && [ "${HOME:-}" = "/root" ]; then
    ORIGINAL_USER_HOME=$(eval echo "~$SUDO_USER" 2>/dev/null)
    ORIGINAL_USER_HOME=${ORIGINAL_USER_HOME:-$HOME}
else
    ORIGINAL_USER_HOME="${HOME:-/root}"
fi

DEFAULT_INTERVAL_MIN=10
MAX_PARALLEL_STARTS=5
START_RETRY=3
WAIT_SECONDS_FOR_RUNNING=90
STATUS_POLL_INTERVAL=5

log() {
    local level="$1"; shift
    local msg="$*"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $msg" | tee -a "$LOG_FILE"
}

fatal() {
    log ERROR "$*"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 或 sudo 运行此脚本"
        exit 1
    fi
}

expand_user_path() {
    local input="$1"
    case "$input" in
        "~") echo "$ORIGINAL_USER_HOME" ;;
        "~/*") echo "$ORIGINAL_USER_HOME/${input:2}" ;;
        *) echo "$input" ;;
    esac
}

sanitize_account_key_filename() {
    echo "$1" | tr -c 'A-Za-z0-9._-' '_'
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$LASTCHECK_DIR" "$KEY_DIR"
    touch "$LOG_FILE"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo '{"version":"'$VERSION'","accounts":[]}' > "$CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

config_jq() {
    local filter="$1"; shift
    tmp="${CONFIG_FILE}.tmp"
    jq "$filter" "$CONFIG_FILE" "$@" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return
    fi
    log INFO "正在安装 jq..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y jq
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release jq
    else
        fatal "无法自动安装 jq，请手动安装 jq 后重试"
    fi
}

ensure_gcloud() {
    if command -v gcloud >/dev/null 2>&1; then
        return
    fi
    log INFO "正在安装 Google Cloud SDK..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        SYS="$ID"
    else
        SYS="unknown"
    fi
    case "$SYS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y apt-transport-https ca-certificates gnupg curl
            echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list
            curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
            apt-get update && apt-get install -y google-cloud-sdk
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/google-cloud-sdk.repo <<EOFYUM
[google-cloud-sdk]
name=Google Cloud SDK
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el8-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOFYUM
            yum install -y google-cloud-sdk
            ;;
        *)
            fatal "不支持的操作系统，无法自动安装 gcloud"
            ;;
    esac
    command -v gcloud >/dev/null 2>&1 || fatal "gcloud 安装失败"
    log INFO "Google Cloud SDK 安装完成"
}

ensure_crontab() {
    if ! command -v crontab >/dev/null 2>&1; then
        log INFO "正在安装 cron..."
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y cron
            systemctl enable cron && systemctl start cron
        elif [ -f /etc/redhat-release ]; then
            yum install -y cronie
            systemctl enable crond && systemctl start crond
        fi
    fi
    if ! crontab -l 2>/dev/null | grep -q "$GCPSC_SCRIPT check"; then
        (crontab -l 2>/dev/null; echo "* * * * * $GCPSC_SCRIPT check >/dev/null 2>&1") | crontab -
        log INFO "已添加每分钟巡检定时任务"
    fi
}

store_service_account_key() {
    local account_email="$1"
    local source_path="$2"
    local sanitized
    sanitized=$(sanitize_account_key_filename "$account_email")
    local dest_path="$KEY_DIR/${sanitized}.json"
    mkdir -p "$KEY_DIR"
    cp "$source_path" "$dest_path"
    chmod 600 "$dest_path" 2>/dev/null || true
    echo "$dest_path"
}

persist_account_entry() {
    local account="$1"; local type="$2"; local key_file="$3"
    if jq -e --arg acc "$account" '.accounts[] | select(.account == $acc)' "$CONFIG_FILE" >/dev/null 2>&1; then
        if [ "$type" = "service" ]; then
            config_jq --arg acc "$account" --arg file "$key_file" '
                .accounts = (.accounts | map(if .account == $acc then . + {"type":"service","key_file":$file} else . end))'
        else
            config_jq --arg acc "$account" '
                .accounts = (.accounts | map(if .account == $acc then (. + {"type":"user"} | del(.key_file)) else . end))'
        fi
    else
        if [ "$type" = "service" ]; then
            config_jq --arg acc "$account" --arg file "$key_file" '
                .accounts += [{"account":$acc,"type":"service","key_file":$file,"projects":[]}]'
        else
            config_jq --arg acc "$account" '
                .accounts += [{"account":$acc,"type":"user","projects":[]}]'
        fi
    fi
}

cleanup_account_artifacts() {
    local account="$1"
    local sanitized=${account//@/_}
    rm -f "$LASTCHECK_DIR/${sanitized}_"* 2>/dev/null || true
}

remove_account_entry() {
    local account="$1"
    local acc_info
    acc_info=$(jq -r --arg acc "$account" '.accounts[] | select(.account == $acc)' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$acc_info" ] || [ "$acc_info" = "null" ]; then
        echo "账号不存在"
        return 1
    fi
    local key_file
    key_file=$(echo "$acc_info" | jq -r '.key_file // ""')
    config_jq --arg acc "$account" '.accounts = (.accounts | map(select(.account != $acc)))'
    if [ -n "$key_file" ] && [[ "$key_file" == "$KEY_DIR/"* ]]; then
        rm -f "$key_file" 2>/dev/null || true
    fi
    cleanup_account_artifacts "$account"
    gcloud auth revoke "$account" >/dev/null 2>&1 || true
    log INFO "已删除账号 $account"
}

ensure_project_entry() {
    local account="$1" project="$2"
    config_jq --arg acc "$account" --arg proj "$project" '
        .accounts = (.accounts | map(
            if .account == $acc then
                if (.projects // [] | map(.id == $proj) | any) then .
                else . + {projects: ((.projects // []) + [{"id":$proj,"zones":[]}])}
                end
            else .
            end))'
}

ensure_zone_entry() {
    local account="$1" project="$2" zone="$3"
    config_jq --arg acc "$account" --arg proj "$project" --arg z "$zone" '
        .accounts = (.accounts | map(
            if .account == $acc then
                .projects = (.projects // [] | map(
                    if .id == $proj then
                        if (.zones // [] | map(.name == $z) | any) then .
                        else . + {zones: ((.zones // []) + [{"name":$z,"instances":[]}])}
                        end
                    else . end))
            else . end))'
}

ensure_instance_entry() {
    local account="$1" project="$2" zone="$3" instance="$4" interval="$5" monitor="$6"
    config_jq --arg acc "$account" --arg proj "$project" --arg z "$zone" --arg inst "$instance" --argjson int "$interval" --argjson mon "$monitor" '
        .accounts = (.accounts | map(
            if .account == $acc then
                .projects = (.projects // [] | map(
                    if .id == $proj then
                        .zones = (.zones // [] | map(
                            if .name == $z then
                                if (.instances // [] | map(.name == $inst) | any) then
                                    .instances = (.instances | map(if .name == $inst then . + {interval:$int, monitor:$mon} else . end))
                                else
                                    .instances = ((.instances // []) + [{"name":$inst,"interval":$int,"monitor":$mon}])
                                end
                                .
                            else . end))
                    else . end))
            else . end))'
}

activate_account() {
    local account="$1"
    local info
    info=$(jq -r --arg acc "$account" '.accounts[] | select(.account == $acc)' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$info" ] || [ "$info" = "null" ]; then
        log ERROR "账号 $account 未配置"
        return 1
    fi
    local type key_file
    type=$(echo "$info" | jq -r '.type // "service"')
    key_file=$(echo "$info" | jq -r '.key_file // ""')
    if [ "$type" = "service" ]; then
        if [ ! -f "$key_file" ]; then
            log ERROR "账号 $account 的密钥缺失"
            return 1
        fi
        if ! gcloud auth activate-service-account "$account" --key-file="$key_file" --quiet >/dev/null 2>&1; then
            log ERROR "账号 $account 激活失败"
            return 1
        fi
        gcloud config set account "$account" >/dev/null 2>&1 || true
    else
        if ! gcloud auth list --filter="account:$account" --format="value(account)" 2>/dev/null | grep -qx "$account"; then
            log ERROR "账号 $account 未登录，请先执行 gcloud auth login"
            return 1
        fi
        gcloud config set account "$account" >/dev/null 2>&1 || true
    fi
    return 0
}

get_instance_status() {
    local account="$1" project="$2" zone="$3" instance="$4"
    local output
    if ! output=$(gcloud compute instances describe "$instance" --zone="$zone" --project="$project" --account="$account" --format='value(status)' 2>&1); then
        log WARN "[$account/$project/$zone/$instance] 获取状态失败: $(echo "$output" | head -n1)"
        echo "UNKNOWN"
        return 1
    fi
    if [ -z "$output" ]; then
        echo "UNKNOWN"
        return 1
    fi
    echo "$output"
    return 0
}

should_start() {
    case "$1" in
        RUNNING|PROVISIONING|STAGING|REPAIRING) return 1 ;;
        *) return 0 ;;
    esac
}

wait_for_running() {
    local account="$1" project="$2" zone="$3" instance="$4"
    local waited=0
    while [ $waited -lt $WAIT_SECONDS_FOR_RUNNING ]; do
        sleep $STATUS_POLL_INTERVAL
        local st
        st=$(gcloud compute instances describe "$instance" --zone="$zone" --project="$project" --account="$account" --format='value(status)' 2>/dev/null || echo "UNKNOWN")
        if [ "$st" = "RUNNING" ]; then
            return 0
        fi
        waited=$((waited + STATUS_POLL_INTERVAL))
    done
    return 1
}

start_instance() {
    local account="$1" project="$2" zone="$3" instance="$4"
    local attempt=1
    while [ $attempt -le $START_RETRY ]; do
        log WARN "[$account/$project/$zone/$instance] 触发启动 (第 $attempt 次)"
        activate_account "$account" || return 1
        local output
        if output=$(gcloud compute instances start "$instance" --zone="$zone" --project="$project" --account="$account" --quiet 2>&1); then
            if wait_for_running "$account" "$project" "$zone" "$instance"; then
                log INFO "[$account/$project/$zone/$instance] 已启动并处于 RUNNING"
                return 0
            else
                log WARN "[$account/$project/$zone/$instance] 启动命令成功但未在超时时间内进入 RUNNING"
            fi
        else
            log ERROR "[$account/$project/$zone/$instance] 启动失败: $(echo "$output" | head -n1)"
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    return 1
}

record_last_check() {
    local account="$1" project="$2" zone="$3" instance="$4"
    local name="${account//@/_}_${project}_${zone}_${instance}"
    echo "$(date +%s)" > "$LASTCHECK_DIR/$name" 2>/dev/null || true
}

check_single_instance() {
    local account="$1" project="$2" zone="$3" instance="$4"
    activate_account "$account" || return 1
    local status status_rc
    status=$(get_instance_status "$account" "$project" "$zone" "$instance")
    status_rc=$?
    log INFO "[$account/$project/$zone/$instance] 当前状态: $status"
    record_last_check "$account" "$project" "$zone" "$instance"
    if should_start "$status"; then
        start_instance "$account" "$project" "$zone" "$instance"
    else
        if [ "$status_rc" -ne 0 ]; then
            log WARN "[$account/$project/$zone/$instance] 状态未知，暂不操作"
        fi
    fi
}

list_instances_for_account() {
    local account="$1"
    jq -r --arg acc "$account" '
        .accounts[] | select(.account==$acc) |
        .projects[]? as $p |
        $p.zones[]? as $z |
        $z.instances[]? |
        "",$p.id,"",$z.name,"",.name,"",(.monitor//true),"",(.interval//10)'
        "$CONFIG_FILE"
}

refresh_account_inventory() {
    local account="$1" default_interval="$2"
    activate_account "$account" || return
    local projects
    projects=$(gcloud projects list --account="$account" --filter="lifecycleState=ACTIVE" --format="value(projectId)" 2>/dev/null)
    if [ -z "$projects" ]; then
        log WARN "账号 $account 未获取到项目列表"
        return
    fi
    while IFS= read -r proj; do
        [ -z "$proj" ] && continue
        ensure_project_entry "$account" "$proj"
        local instances
        instances=$(gcloud compute instances list --project="$proj" --account="$account" --format="csv[no-heading](name,zone)" 2>/dev/null)
        [ -z "$instances" ] && continue
        while IFS=',' read -r inst zone_full; do
            [ -z "$inst" ] && continue
            local zone="${zone_full##*/}"
            ensure_zone_entry "$account" "$proj" "$zone"
            ensure_instance_entry "$account" "$proj" "$zone" "$inst" "${default_interval:-$DEFAULT_INTERVAL_MIN}" true
        done <<< "$instances"
    done <<< "$projects"
    log INFO "账号 $account 资源发现完成"
}

check_all_instances() {
    local target_account="${1:-}" refresh="${2:-true}"
    local starts_in_cycle=0
    local accounts_json
    accounts_json=$(jq -c '.accounts[]?' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$accounts_json" ]; then
        log WARN "未配置任何账号"
        return
    fi
    while IFS= read -r acc_json; do
        [ -z "$acc_json" ] && continue
        local account
        account=$(echo "$acc_json" | jq -r '.account')
        if [ -n "$target_account" ] && [ "$account" != "$target_account" ]; then
            continue
        fi
        if [ "$refresh" = "true" ]; then
            refresh_account_inventory "$account" "$DEFAULT_INTERVAL_MIN"
        fi
        local lines
        lines=$(list_instances_for_account "$account")
        if [ -z "$lines" ]; then
            log INFO "账号 $account 没有配置实例"
            continue
        fi
        while IFS=$'\1' read -r proj zone inst monitor interval; do
            [ -z "$proj" ] && continue
            if [ "$monitor" != "true" ]; then
                log INFO "[$account/$proj/$zone/$inst] 监控关闭"
                continue
            fi
            if [ "$starts_in_cycle" -ge "$MAX_PARALLEL_STARTS" ]; then
                log WARN "已达到本轮启动上限 $MAX_PARALLEL_STARTS，跳过 [$account/$proj/$zone/$inst]"
                continue
            fi
            check_single_instance "$account" "$proj" "$zone" "$inst"
            local last_status
            last_status=$(get_instance_status "$account" "$proj" "$zone" "$inst")
            if [ "$last_status" != "RUNNING" ] && should_start "$last_status"; then
                starts_in_cycle=$((starts_in_cycle + 1))
            fi
        done <<< "$lines"
    done <<< "$accounts_json"
}

# 交互式菜单

pause() { read -p "按回车继续..." _; }

select_account() {
    local accounts
    accounts=$(jq -r '.accounts[].account' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$accounts" ]; then
        echo ""
        return 1
    fi
    local idx=1
    echo "可用账号："
    while IFS= read -r acc; do
        echo "  $idx) $acc"
        idx=$((idx + 1))
    done <<< "$accounts"
    read -p "请选择账号序号: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
        echo ""
        return 1
    fi
    local chosen
    chosen=$(echo "$accounts" | sed -n "${sel}p")
    echo "$chosen"
}

menu_accounts() {
    while true; do
        clear
        echo "===== 账号管理 ====="
        echo "1) 添加服务账号(导入 key 文件)"
        echo "2) 添加已登录的用户账号"
        echo "3) 删除账号"
        echo "4) 查看账号详情"
        echo "0) 返回主菜单"
        read -p "请选择 [0-4]: " c
        case "$c" in
            1)
                read -p "请输入服务账号 email: " acc
                read -p "请输入 key 文件路径: " key_path
                key_path=$(expand_user_path "$key_path")
                if [ ! -f "$key_path" ]; then
                    echo "文件不存在"; pause; continue
                fi
                persist_account_entry "$acc" "service" "$(store_service_account_key "$acc" "$key_path")"
                log INFO "添加服务账号 $acc"
                pause
                ;;
            2)
                read -p "请输入用户账号 email(需已通过 gcloud auth login 登录): " acc
                if ! gcloud auth list --format="value(account)" 2>/dev/null | grep -qx "$acc"; then
                    echo "未在 gcloud 中找到该账号，请先执行 gcloud auth login"
                else
                    persist_account_entry "$acc" "user" ""
                    log INFO "添加用户账号 $acc"
                fi
                pause
                ;;
            3)
                local acc
                acc=$(select_account) || { echo "暂无账号"; pause; continue; }
                read -p "确认删除 $acc ? [y/N]: " yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    remove_account_entry "$acc"
                fi
                pause
                ;;
            4)
                local acc
                acc=$(select_account) || { echo "暂无账号"; pause; continue; }
                echo "账号: $acc"
                jq -r --arg acc "$acc" '
                    .accounts[] | select(.account==$acc) | .projects[]? as $p |
                    $p.zones[]? as $z | $z.instances[]? | "  " + $p.id + "/" + $z.name + "/" + .name + " (interval=" + ((.interval//10)|tostring) + "m, monitor=" + ((.monitor//true)|tostring) + ")"' "$CONFIG_FILE"
                pause
                ;;
            0) return ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

menu_discover() {
    clear
    echo "===== 快速发现资源 ====="
    local acc
    acc=$(select_account) || { echo "暂无账号"; pause; return; }
    read -p "默认检查间隔(分钟，默认$DEFAULT_INTERVAL_MIN): " interval
    interval=${interval:-$DEFAULT_INTERVAL_MIN}
    refresh_account_inventory "$acc" "$interval"
    pause
}

menu_instances() {
    local acc
    acc=$(select_account) || { echo "暂无账号"; pause; return; }
    while true; do
        clear
        echo "===== 实例管理 ($acc) ====="
        echo "1) 列出实例"
        echo "2) 切换监控开关"
        echo "3) 修改检查间隔"
        echo "4) 手动检查某实例"
        echo "0) 返回"
        read -p "请选择 [0-4]: " c
        case "$c" in
            1)
                list_instances_for_account "$acc" | while IFS=$'\1' read -r proj zone inst monitor interval; do
                    echo "- $proj/$zone/$inst (监控:${monitor:-true}, 间隔:${interval:-10}m)"
                done
                pause
                ;;
            2)
                local lines
                lines=$(list_instances_for_account "$acc")
                if [ -z "$lines" ]; then echo "无实例"; pause; continue; fi
                local idx=1
                echo "请选择实例："
                echo "$lines" | while IFS=$'\1' read -r proj zone inst monitor interval; do
                    echo "  $idx) $proj/$zone/$inst 当前:${monitor}"
                    idx=$((idx+1))
                done
                read -p "序号: " sel
                if ! [[ "$sel" =~ ^[0-9]+$ ]]; then pause; continue; fi
                local chosen
                chosen=$(echo "$lines" | sed -n "${sel}p")
                IFS=$'\1' read -r proj zone inst monitor interval <<< "$chosen"
                local new_flag="true"
                if [ "$monitor" = "true" ]; then new_flag="false"; fi
                config_jq --arg acc "$acc" --arg proj "$proj" --arg z "$zone" --arg inst "$inst" --argjson flag "$new_flag" '
                    .accounts = (.accounts | map(if .account==$acc then .projects = (.projects|map(if .id==$proj then .zones = (.zones|map(if .name==$z then .instances = (.instances|map(if .name==$inst then .+{monitor:$flag} else . end)) else . end)) else . end)) else . end))'
                log INFO "[$acc/$proj/$zone/$inst] 监控已设置为 $new_flag"
                pause
                ;;
            3)
                read -p "新间隔(分钟): " new_int
                if ! [[ "$new_int" =~ ^[0-9]+$ ]] || [ "$new_int" -lt 1 ]; then echo "输入非法"; pause; continue; fi
                config_jq --arg acc "$acc" --argjson int "$new_int" '
                    (.accounts[] | select(.account==$acc) | .projects[].zones[].instances[].interval) = $int'
                log INFO "账号 $acc 所有实例间隔设为 ${new_int}分钟"
                pause
                ;;
            4)
                local lines
                lines=$(list_instances_for_account "$acc")
                if [ -z "$lines" ]; then echo "无实例"; pause; continue; fi
                local idx=1
                echo "$lines" | while IFS=$'\1' read -r proj zone inst monitor interval; do
                    echo "  $idx) $proj/$zone/$inst"
                    idx=$((idx+1))
                done
                read -p "序号: " sel
                if ! [[ "$sel" =~ ^[0-9]+$ ]]; then pause; continue; fi
                local chosen
                chosen=$(echo "$lines" | sed -n "${sel}p")
                IFS=$'\1' read -r proj zone inst monitor interval <<< "$chosen"
                check_single_instance "$acc" "$proj" "$zone" "$inst"
                pause
                ;;
            0) return ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

menu_statistics() {
    clear
    echo "===== 监控统计 ====="
    local total_accounts total_projects total_instances
    total_accounts=$(jq '.accounts|length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    total_projects=$(jq '[.accounts[].projects[]] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    total_instances=$(jq '[.accounts[].projects[].zones[].instances[]] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    echo "账号: $total_accounts"
    echo "项目: $total_projects"
    echo "实例: $total_instances"
    local now=$(date +%s) active=0 checked=0
    for f in "$LASTCHECK_DIR"/*; do
        [ -f "$f" ] || continue
        checked=$((checked+1))
        local ts
        ts=$(cat "$f")
        if [ $((now - ts)) -lt 600 ]; then
            active=$((active+1))
        fi
    done
    echo "最近10分钟活跃检查: $active / $checked"
    pause
}

menu_logs() {
    clear
    echo "===== 最近日志(尾部100行) ====="
    tail -n 100 "$LOG_FILE" 2>/dev/null || echo "暂无日志"
    pause
}

main_menu() {
    while true; do
        clear
        echo "$LOGO"
        local acc_count inst_count
        acc_count=$(jq '.accounts|length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        inst_count=$(jq '[.accounts[].projects[].zones[].instances[]]|length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        echo "当前: $acc_count 个账号，$inst_count 个实例"
        echo
        echo "1) 账号管理"
        echo "2) 快速发现资源"
        echo "3) 实例监控与操作"
        echo "4) 查看监控统计"
        echo "5) 查看运行日志"
        echo "6) 手动执行一次全量检查"
        echo "0) 退出"
        read -p "请选择 [0-6]: " choice
        case "$choice" in
            1) menu_accounts ;;
            2) menu_discover ;;
            3) menu_instances ;;
            4) menu_statistics ;;
            5) menu_logs ;;
            6) echo "正在执行检查..."; check_all_instances "" false; pause ;;
            0) echo "再见"; exit 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

perform_install() {
    require_root
    echo "$LOGO"
    echo "正在安装..."
    ensure_dirs; ensure_jq; ensure_gcloud; ensure_crontab
    curl -fsSL "$SCRIPT_URL" -o "$GCPSC_SCRIPT"
    chmod +x "$GCPSC_SCRIPT"
    ln -sf "$GCPSC_SCRIPT" /usr/bin/gcpsc
    log INFO "安装完成，版本 $VERSION"
    echo "安装完成，使用命令: sudo gcpsc"
    exec "$GCPSC_SCRIPT" __installed__
}

perform_uninstall() {
    require_root
    echo "$LOGO"
    read -p "确认卸载并删除配置? [y/N]: " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then echo "已取消"; exit 0; fi
    crontab -l 2>/dev/null | grep -v "$GCPSC_SCRIPT" | crontab - 2>/dev/null || true
    rm -f "$GCPSC_SCRIPT" /usr/bin/gcpsc 2>/dev/null || true
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    rm -f "$LOG_FILE" 2>/dev/null || true
    echo "已卸载"
}

main() {
    if [ "${1:-}" = "install" ]; then
        perform_install; exit 0
    elif [ "${1:-}" = "remove" ] || [ "${1:-}" = "uninstall" ]; then
        perform_uninstall; exit 0
    fi

    require_root
    ensure_dirs; ensure_jq

    local config_ver
    config_ver=$(jq -r '.version // "0.0.0"' "$CONFIG_FILE" 2>/dev/null)
    if [ "$config_ver" != "$VERSION" ]; then
        config_jq --arg v "$VERSION" '.version=$v'
        log INFO "配置版本更新到 $VERSION"
    fi

    case "${1:-}" in
        check)
            shift
            local target="" refresh=true
            while [ $# -gt 0 ]; do
                case "$1" in
                    --account|-a) target="$2"; shift 2 ;;
                    --no-refresh) refresh=false; shift ;;
                    --help|-h)
                        cat <<'EOH'
用法: gcpsc check [--account <email>] [--no-refresh]
  --account/-a  仅检查指定账号
  --no-refresh  跳过检查前的资源发现，直接按配置检查
EOH
                        exit 0 ;;
                    *) echo "未知参数: $1"; exit 1 ;;
                esac
            done
            check_all_instances "$target" "$refresh"
            exit 0
            ;;
        version|-v|--version)
            echo "GCP Spot Check $VERSION ($VERSION_DATE)"; exit 0 ;;
        __installed__)
            main_menu ;;
        *)
            main_menu ;;
    esac
}

main "$@"
