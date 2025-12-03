#!/usr/bin/env bash

set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:/opt/google-cloud-sdk/bin:${PATH:-}"

readonly VERSION="1.2"
readonly VERSION_DATE="2025-12-03"

readonly INSTALL_PATH="/usr/local/bin"
readonly GCPSC_SCRIPT="$INSTALL_PATH/gcpsc"
readonly CONFIG_DIR="/etc/gcpsc"
readonly CONFIG_FILE="$CONFIG_DIR/config.json"
readonly LASTCHECK_DIR="$CONFIG_DIR/lastcheck"
readonly KEY_DIR="$CONFIG_DIR/keys"
# 当脚本从管道执行且无法定位自我路径时用于安装的回退下载地址，可用环境变量 SCRIPT_URL 覆盖
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/crazy0x70/GCP-Spot-Check/refs/heads/main/gcp-spot-check.sh}"
readonly LOG_FILE="${LOG_FILE:-/var/log/gcpsc.log}"
readonly LOCK_FILE="/tmp/gcpsc.lock"

readonly DEFAULT_INTERVAL_MIN=10
readonly MAX_PARALLEL_STARTS=5
readonly START_RETRY=3
readonly WAIT_SECONDS_FOR_RUNNING=90
readonly STATUS_POLL_INTERVAL=5

LOCK_FD=200
LOCK_HELD=0

SELF_SCRIPT=""
[[ -f "${BASH_SOURCE[0]:-}" ]] && SELF_SCRIPT="${BASH_SOURCE[0]}"

readonly LOGO="
========================================================
       Google Cloud Spot Instance 保活服务
                Version: $VERSION
                Date: $VERSION_DATE
========================================================
"

log() {
    local level="$1"; shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE" 2>/dev/null || true
}
log_info()  { log INFO "$@"; }
log_warn()  { log WARN "$@"; }
log_error() { log ERROR "$@"; }
fatal() { log_error "$@"; exit 1; }

require_root() { [[ $(id -u) -eq 0 ]] || fatal "请使用 root 或 sudo 运行此脚本"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$LASTCHECK_DIR" "$KEY_DIR"
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    [[ ! -f "$CONFIG_FILE" ]] && printf '{"version":"%s","accounts":[]}' "$VERSION" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

ensure_jq() {
    command_exists jq && return 0
    log_info "正在安装 jq..."
    if [[ -f /etc/debian_version ]]; then
        apt-get update -qq && apt-get install -y -qq jq
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y -q epel-release 2>/dev/null || true
        yum install -y -q jq
    else
        fatal "请手动安装 jq"
    fi
}

ensure_gcloud() {
    command_exists gcloud && return 0
    log_info "正在安装 Google Cloud SDK..."
    local os_id="unknown"
    [[ -f /etc/os-release ]] && source /etc/os-release && os_id="$ID"
    case "$os_id" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq apt-transport-https ca-certificates gnupg curl
            curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg 2>/dev/null
            echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list
            apt-get update -qq && apt-get install -y -qq google-cloud-sdk
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/google-cloud-sdk.repo <<'EOF'
[google-cloud-sdk]
name=Google Cloud SDK
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el8-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
            yum install -y -q google-cloud-sdk
            ;;
        *) fatal "不支持的操作系统" ;;
    esac
    command_exists gcloud || fatal "gcloud 安装失败"
}

ensure_crontab() {
    if ! command_exists crontab; then
        if [[ -f /etc/debian_version ]]; then
            apt-get update -qq && apt-get install -y -qq cron
            systemctl enable cron 2>/dev/null; systemctl start cron 2>/dev/null
        elif [[ -f /etc/redhat-release ]]; then
            yum install -y -q cronie
            systemctl enable crond 2>/dev/null; systemctl start crond 2>/dev/null
        fi
    fi
    if ! crontab -l 2>/dev/null | grep -qF "$GCPSC_SCRIPT check"; then
        (crontab -l 2>/dev/null; echo "* * * * * $GCPSC_SCRIPT check >/dev/null 2>&1") | crontab -
        log_info "已添加定时任务"
    fi
}

acquire_lock() {
    [[ $LOCK_HELD -eq 1 ]] && return 0
    if command_exists flock; then
        eval "exec $LOCK_FD>\"$LOCK_FILE\""
        flock -n "$LOCK_FD" || { log_warn "已有进程运行"; return 1; }
        LOCK_HELD=1
    fi
    return 0
}

config_read() { jq -r "$@" "$CONFIG_FILE" 2>/dev/null; }
config_write() {
    local filter="$1"; shift
    local tmp="${CONFIG_FILE}.tmp.$$"
    jq "$@" "$filter" "$CONFIG_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$CONFIG_FILE" || { rm -f "$tmp"; return 1; }
}

sanitize_filename() { echo "$1" | tr -c 'A-Za-z0-9._-' '_'; }

cleanup_lastcheck_files_for_account() {
    local account="$1"
    local allow_file
    allow_file=$(mktemp)

    # 根据当前配置生成允许的 lastcheck 文件名列表
    config_read --arg acc "$account" '
        .accounts[] | select(.account == $acc) |
        .projects[]? as $p | $p.zones[]? as $z | $z.instances[]? as $i |
        "\($p.id)_\($z.name)_\($i.name)"
    ' | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "$(sanitize_filename "${account}_${line}")" >>"$allow_file"
    done

    for f in "$LASTCHECK_DIR"/$(sanitize_filename "${account}")_*; do
        [[ -e "$f" ]] || continue
        if [[ ! -s "$allow_file" ]] || ! grep -Fxq "$(basename "$f")" "$allow_file" 2>/dev/null; then
            rm -f "$f" 2>/dev/null || true
        fi
    done

    rm -f "$allow_file" 2>/dev/null || true
}

remove_instance_entry() {
    local account="$1" project="$2" zone="$3" instance="$4"
    log_warn "[$project/$zone/$instance] 实例不存在，移除监控记录"
    config_write '.accounts=(.accounts|map(
        if .account==$a then
            .projects=((.projects//[])|map(
                if .id==$p then
                    .zones=((.zones//[])|map(
                        if .name==$z then
                            .instances=((.instances//[])|map(select(.name!=$i)))
                        else . end
                    )|map(select((.instances//[])|length>0)))
                else . end
            )|map(select((.zones//[])|length>0)))
        else . end
    ))' --arg a "$account" --arg p "$project" --arg z "$zone" --arg i "$instance"
    cleanup_lastcheck_files_for_account "$account"
}

prune_account_inventory() {
    local account="$1" seen_file="$2" scanned_file="$3"

    local seen_json scanned_json
    if [[ -n "$seen_file" && -s "$seen_file" ]]; then
        seen_json=$(awk -F'\t' 'NF>=3{printf "{\"project\":\"%s\",\"zone\":\"%s\",\"instance\":\"%s\"}\n",$1,$2,$3}' "$seen_file" | jq -s '.')
    else
        seen_json="[]"
    fi

    if [[ -n "$scanned_file" && -s "$scanned_file" ]]; then
        scanned_json=$(sort -u "$scanned_file" | jq -R -s 'split("\n")|map(select(length>0))')
    else
        scanned_json="[]"
    fi

    config_write '.accounts = (.accounts | map(
        if .account == $acc then
            .projects = ((.projects // []) | map(
                . as $proj |
                if any($scanned[]; . == $proj.id) then
                    .zones = ((.zones // []) | map(
                        . as $zone |
                        .instances = ((.instances // []) | map(
                            select(any($seen[]; .project == $proj.id and .zone == $zone.name and .instance == .name))
                        )) | map(select((.instances // []) | length > 0))
                    )) | map(select((.zones // []) | length > 0))
                else . end
            ))
        else . end
    ))' --arg acc "$account" --argjson seen "$seen_json" --argjson scanned "$scanned_json"

    cleanup_lastcheck_files_for_account "$account"
}

add_service_account() {
    local key_path="${1/#\~/$HOME}"
    [[ ! -f "$key_path" ]] && { echo "错误: 文件不存在: $key_path"; return 1; }

    # 预先校验工具可用性
    command_exists gcloud || { echo "错误: gcloud 未安装或不可用"; return 1; }

    local account project_id
    account=$(jq -r '.client_email // empty' "$key_path" 2>/dev/null)
    project_id=$(jq -r '.project_id // empty' "$key_path" 2>/dev/null)
    [[ -z "$account" ]] && { echo "错误: 无效的密钥文件"; return 1; }

    local dest_path="$KEY_DIR/$(sanitize_filename "$account").json"
    cp "$key_path" "$dest_path" && chmod 600 "$dest_path"

    # 捕获 gcloud 激活失败的详细原因，便于排障
    local gcloud_err=""
    if ! gcloud_err=$(gcloud auth activate-service-account "$account" --key-file="$dest_path" --quiet 2>&1); then
        rm -f "$dest_path"
        log_error "服务账号激活失败: $gcloud_err"
        echo "错误: 服务账号激活失败"
        echo "详情: $gcloud_err"
        return 1
    fi

    if config_read ".accounts[] | select(.account == \"$account\")" | grep -q .; then
        config_write '.accounts = (.accounts | map(if .account == $acc then . + {type:"service",key_file:$key,project_id:$pid} else . end))' \
            --arg acc "$account" --arg key "$dest_path" --arg pid "$project_id"
    else
        config_write '.accounts += [{account:$acc,type:"service",key_file:$key,project_id:$pid,projects:[]}]' \
            --arg acc "$account" --arg key "$dest_path" --arg pid "$project_id"
    fi

    log_info "服务账号 $account 已添加 (项目: $project_id)"
    echo "账号添加成功: $account"
    echo "所属项目: $project_id"
    echo ""
    refresh_account_inventory "$account" "$DEFAULT_INTERVAL_MIN"
}

add_user_account() {
    command_exists gcloud || { echo "错误: gcloud 未安装"; return 1; }
    echo "请在浏览器中完成授权..."
    gcloud auth login --no-launch-browser --force 2>&1 || { echo "登录失败"; return 1; }

    local account
    account=$(gcloud config get-value account 2>/dev/null)
    [[ -z "$account" ]] && { echo "无法获取账号"; return 1; }

    if config_read ".accounts[] | select(.account == \"$account\")" | grep -q .; then
        config_write '.accounts = (.accounts | map(if .account == $acc then (.+{type:"user"}|del(.key_file,.project_id)) else . end))' --arg acc "$account"
    else
        config_write '.accounts += [{account:$acc,type:"user",projects:[]}]' --arg acc "$account"
    fi

    log_info "用户账号 $account 已添加"
    echo "账号添加成功: $account"
    echo "⚠️ OAuth 令牌会过期，建议使用服务账号"
    echo ""
    refresh_account_inventory "$account" "$DEFAULT_INTERVAL_MIN"
}

remove_account() {
    local account="$1"
    local acc_info key_file
    acc_info=$(config_read --arg acc "$account" '.accounts[] | select(.account == $acc)')
    [[ -z "$acc_info" ]] && { echo "账号不存在"; return 1; }

    key_file=$(echo "$acc_info" | jq -r '.key_file // empty')
    [[ -n "$key_file" && -f "$key_file" ]] && rm -f "$key_file"
    rm -f "$LASTCHECK_DIR/$(sanitize_filename "$account")_"* 2>/dev/null

    config_write '.accounts = (.accounts | map(select(.account != $acc)))' --arg acc "$account"
    gcloud auth revoke "$account" 2>/dev/null || true
    log_info "已删除账号 $account"
}

activate_account() {
    local account="$1"
    local acc_info acc_type key_file
    acc_info=$(config_read --arg acc "$account" '.accounts[] | select(.account == $acc)')
    [[ -z "$acc_info" ]] && { log_error "账号未配置: $account"; return 1; }

    acc_type=$(echo "$acc_info" | jq -r '.type // "user"')
    key_file=$(echo "$acc_info" | jq -r '.key_file // empty')

    if [[ "$acc_type" == "service" ]]; then
        [[ ! -f "$key_file" ]] && { log_error "密钥缺失: $key_file"; return 1; }
        gcloud auth activate-service-account "$account" --key-file="$key_file" --quiet 2>/dev/null || { log_error "激活失败"; return 1; }
    else
        gcloud auth list --filter="account:$account" --format="value(account)" 2>/dev/null | grep -qx "$account" || { log_error "令牌过期"; return 1; }
    fi
    gcloud config set account "$account" --quiet 2>/dev/null
}

refresh_account_inventory() {
    local account="$1"
    local default_interval="${2:-$DEFAULT_INTERVAL_MIN}"

    activate_account "$account" || return 1

    local seen_file scanned_file
    seen_file=$(mktemp) || seen_file=""
    scanned_file=$(mktemp) || scanned_file=""
    # RETURN trap 只在本函数内执行一次，避免 set -u 下未绑定变量
    trap 'rm -f "${seen_file:-}" "${scanned_file:-}"; trap - RETURN' RETURN

    # 获取账号信息
    local acc_info acc_type key_file project_id_from_key
    acc_info=$(config_read --arg acc "$account" '.accounts[] | select(.account == $acc)')
    acc_type=$(echo "$acc_info" | jq -r '.type // "user"')
    key_file=$(echo "$acc_info" | jq -r '.key_file // empty')
    project_id_from_key=$(echo "$acc_info" | jq -r '.project_id // empty')

    local projects=""

    # 服务账号: 优先使用密钥中的项目ID
    if [[ "$acc_type" == "service" ]]; then
        if [[ -n "$project_id_from_key" ]]; then
            projects="$project_id_from_key"
            log_info "使用服务账号所属项目: $project_id_from_key"
        elif [[ -n "$key_file" && -f "$key_file" ]]; then
            projects=$(jq -r '.project_id // empty' "$key_file" 2>/dev/null)
            [[ -n "$projects" ]] && log_info "从密钥文件获取项目: $projects"
        fi
    fi

    # 如果没有获取到项目，尝试列出所有项目
    if [[ -z "$projects" ]]; then
        log_info "尝试列出所有可访问项目..."
        projects=$(gcloud projects list --format="value(projectId)" --filter="lifecycleState=ACTIVE" 2>/dev/null)
    fi

    if [[ -z "$projects" ]]; then
        log_warn "账号 $account 未发现任何项目"
        echo "未发现项目。请检查:"
        echo "1. 服务账号是否有项目访问权限"
        echo "2. 项目 ID 是否正确"
        return 0
    fi

    local proj_count=0 inst_count=0

    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        ((proj_count++))
        log_info "扫描项目: $project"

        # 添加项目条目
        config_write '.accounts = (.accounts | map(
            if .account == $acc then
                .projects = ((.projects // []) | if any(.id == $proj) then . else . + [{id:$proj,zones:[]}] end)
            else . end
        ))' --arg acc "$account" --arg proj "$project"

        # 获取实例列表，若失败输出详细原因
        local instances errfile out ret
        errfile=$(mktemp)
        # gcloud CSV 格式正确写法: csv[no-heading](...)
        out=$(gcloud compute instances list --project="$project" --format="csv[no-heading](name,zone)" 2>"$errfile")
        ret=$?
        if [[ $ret -ne 0 ]]; then
            instances=""
            local err_msg
            err_msg=$(cat "$errfile")
            log_warn "获取实例失败 ($project): $err_msg"
            echo "警告: 列出实例失败 ($project): $err_msg"
        else
            instances="$out"
            echo "$project" >>"$scanned_file"
        fi
        rm -f "$errfile"

        if [[ -z "$instances" ]]; then
            log_info "项目 $project 没有实例"
            continue
        fi

        while IFS=',' read -r inst_name zone_full; do
            [[ -z "$inst_name" ]] && continue
            local zone="${zone_full##*/}"
            ((inst_count++))
            printf "%s\t%s\t%s\n" "$project" "$zone" "$inst_name" >>"$seen_file"
            log_info "发现实例: $project/$zone/$inst_name"

            # 添加zone和实例，保留已有的监控与间隔设置
            config_write '.accounts = (.accounts | map(
                if .account == $acc then
                    .projects = (.projects | map(
                        if .id == $proj then
                            .zones = ((.zones // []) |
                                if any(.name == $z) then
                                    map(if .name == $z then
                                        .instances = ((.instances // []) |
                                            if any(.name == $inst) then
                                                map(if .name == $inst then
                                                    . + {interval:(.interval // $int), monitor:(.monitor // true)}
                                                else . end)
                                            else . + [{name:$inst, interval:$int, monitor:true}] end)
                                    else . end)
                                else . + [{name:$z,instances:[{name:$inst,interval:$int,monitor:true}]}] end)
                        else . end))
                else . end
            ))' --arg acc "$account" --arg proj "$project" --arg z "$zone" --arg inst "$inst_name" --argjson int "$default_interval"
        done <<< "$instances"
    done <<< "$projects"

    prune_account_inventory "$account" "$seen_file" "$scanned_file"

    log_info "账号 $account: 发现 $proj_count 个项目, $inst_count 个实例"
    echo "发现 $proj_count 个项目, $inst_count 个实例"
}

get_instance_status() {
    local project="$1" zone="$2" instance="$3"
    local errfile out ret
    errfile=$(mktemp)
    out=$(gcloud compute instances describe "$instance" --project="$project" --zone="$zone" --format='value(status)' 2>"$errfile")
    ret=$?
    if [[ $ret -eq 0 && -n "$out" ]]; then
        echo "$out"
    elif grep -qi "not found" "$errfile" 2>/dev/null; then
        echo "NOT_FOUND"
    else
        echo "UNKNOWN"
    fi
    rm -f "$errfile" 2>/dev/null || true
}

should_start_instance() {
    case "$1" in RUNNING|PROVISIONING|STAGING|REPAIRING|SUSPENDING|SUSPENDED) return 1 ;; *) return 0 ;; esac
}

wait_instance_running() {
    local project="$1" zone="$2" instance="$3"
    local waited=0
    while ((waited < WAIT_SECONDS_FOR_RUNNING)); do
        sleep "$STATUS_POLL_INTERVAL"
        ((waited += STATUS_POLL_INTERVAL))
        [[ "$(get_instance_status "$project" "$zone" "$instance")" == "RUNNING" ]] && return 0
    done
    return 1
}

start_instance() {
    local account="$1" project="$2" zone="$3" instance="$4"
    local tag="[$project/$zone/$instance]"
    local attempt=1
    while ((attempt <= START_RETRY)); do
        log_warn "$tag 启动 (第$attempt次)"
        activate_account "$account" || return 1
        if gcloud compute instances start "$instance" --project="$project" --zone="$zone" --quiet 2>&1; then
            if wait_instance_running "$project" "$zone" "$instance"; then
                log_info "$tag 启动成功"
                return 0
            fi
        fi
        ((attempt++))
        sleep 5
    done
    return 1
}

reset_instance() {
    local account="$1" project="$2" zone="$3" instance="$4"
    log_warn "[$project/$zone/$instance] reset"
    gcloud compute instances reset "$instance" --project="$project" --zone="$zone" --quiet 2>/dev/null && \
        wait_instance_running "$project" "$zone" "$instance" && return 0
    start_instance "$account" "$project" "$zone" "$instance"
}

record_check() {
    echo "$(date +%s)" > "$LASTCHECK_DIR/$(sanitize_filename "${1}_${2}_${3}_${4}")" 2>/dev/null || true
}

should_check_instance_interval() {
    local account="$1" project="$2" zone="$3" instance="$4" interval_min="$5"
    [[ -z "$interval_min" || ! "$interval_min" =~ ^[0-9]+$ ]] && interval_min="$DEFAULT_INTERVAL_MIN"
    (( interval_min <= 0 )) && return 0
    
    local f="$LASTCHECK_DIR/$(sanitize_filename "${account}_${project}_${zone}_${instance}")"
    [[ ! -f "$f" ]] && return 0
    
    local last_ts now diff
    last_ts=$(cat "$f" 2>/dev/null)
    [[ -z "$last_ts" || ! "$last_ts" =~ ^[0-9]+$ ]] && return 0
    now=$(date +%s)
    diff=$(( now - last_ts ))
    (( diff < 0 )) && return 0  # 时钟漂移，直接触发检查
    (( diff >= interval_min * 60 )) && return 0 || return 1
}

check_instance() {
    local account="$1" project="$2" zone="$3" instance="$4"
    local tag="[$project/$zone/$instance]"
    activate_account "$account" || return 1

    local status
    status=$(get_instance_status "$project" "$zone" "$instance")
    log_info "$tag 状态: $status"
    record_check "$account" "$project" "$zone" "$instance"

    case "$status" in
        RUNNING) return 0 ;;
        ERROR) reset_instance "$account" "$project" "$zone" "$instance" ;;
        TERMINATED|STOPPED) start_instance "$account" "$project" "$zone" "$instance" ;;
        NOT_FOUND)
            remove_instance_entry "$account" "$project" "$zone" "$instance"
            return 0 ;;
        UNKNOWN) log_warn "$tag 状态未知" ;;
    esac
}

list_instances() {
    local account="$1"
    config_read --arg acc "$account" '
        .accounts[] | select(.account == $acc) |
        .projects[]? as $p | $p.zones[]? as $z | $z.instances[]? |
        [$p.id, $z.name, .name, (.monitor//true|tostring), ((.interval//10)|tostring)] | join("\t")
    '
}

check_all() {
    local target="${1:-}" do_refresh="${2:-true}"
    acquire_lock || return 0
    command_exists gcloud || { log_error "gcloud 未安装"; return 1; }

    local accounts starts=0 checked=0 skipped=0 started_actions=0
    log_info "开始巡检: target=${target:-all}, refresh=$do_refresh"
    accounts=$(config_read '.accounts[].account')
    [[ -z "$accounts" ]] && { log_warn "未配置账号"; return 0; }

    while IFS= read -r account; do
        [[ -z "$account" ]] && continue
        [[ -n "$target" && "$account" != "$target" ]] && continue
        [[ "$do_refresh" == "true" ]] && refresh_account_inventory "$account" "$DEFAULT_INTERVAL_MIN"

        local instances
        instances=$(list_instances "$account")
        [[ -z "$instances" ]] && { log_info "账号 $account 没有实例"; continue; }

        while IFS=$'\t' read -r proj zone inst monitor interval; do
            [[ -z "$proj" || "$monitor" != "true" ]] && continue
            local interval_min="$interval"
            [[ -z "$interval_min" || ! "$interval_min" =~ ^[0-9]+$ ]] && interval_min="$DEFAULT_INTERVAL_MIN"
            # 按间隔跳过无需检查的实例
            if ! should_check_instance_interval "$account" "$proj" "$zone" "$inst" "$interval_min"; then
                ((skipped++))
                continue
            fi
            ((starts >= MAX_PARALLEL_STARTS)) && break 2
            local prev=$(get_instance_status "$proj" "$zone" "$inst")
            check_instance "$account" "$proj" "$zone" "$inst"
            ((checked++))
            if should_start_instance "$prev"; then
                ((starts++))
                ((started_actions++))
            fi
        done <<< "$instances"
    done <<< "$accounts"

    log_info "巡检结束: 检查=$checked, 跳过(间隔)=$skipped, 启动作业=$started_actions"
}

pause() { echo ""; read -rp "按回车继续..." _; }

select_account() {
    local accounts i=1
    accounts=$(config_read '.accounts[].account')
    [[ -z "$accounts" ]] && return 1
    echo "账号列表:" >&2
    while IFS= read -r acc; do
        local t=$(config_read --arg a "$acc" '.accounts[]|select(.account==$a)|.type//"user"')
        local p=$(config_read --arg a "$acc" '.accounts[]|select(.account==$a)|.project_id//""')
        printf "  %d) %s [%s] %s\n" "$i" "$acc" "$t" "${p:+($p)}" >&2
        ((i++))
    done <<< "$accounts"
    read -rp "选择 [1-$((i-1))]: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && ((sel>=1 && sel<i)) && echo "$accounts" | sed -n "${sel}p" || return 1
}

menu_accounts() {
    while true; do
        clear
        echo "===== 账号管理 ====="
        echo "1) 添加服务账号"
        echo "2) 添加用户账号"
        echo "3) 删除账号"
        echo "4) 刷新资源"
        echo "0) 返回"
        read -rp "选择: " c
        case "$c" in
            1) echo ""; read -rp "密钥文件路径: " p; [[ -n "$p" ]] && add_service_account "$p"; pause ;;
            2) add_user_account; pause ;;
            3) local a=$(select_account)||{ echo "无账号"; pause; continue; }; read -rp "删除 $a? [y/N]: " y; [[ "$y" =~ ^[Yy]$ ]] && remove_account "$a"; pause ;;
            4) local a=$(select_account)||{ echo "无账号"; pause; continue; }; refresh_account_inventory "$a" "$DEFAULT_INTERVAL_MIN"; pause ;;
            0) return ;;
        esac
    done
}

menu_instances() {
    local acc=$(select_account) || { echo "无账号"; pause; return; }
    while true; do
        clear
        echo "===== 实例 ($acc) ====="
        echo "1) 列表"
        echo "2) 设置监控开关"
        echo "3) 手动检查"
        echo "4) 设置检查间隔(分钟)"
        echo "5) 删除实例监控记录"
        echo "0) 返回"
        read -rp "选择: " c
        case "$c" in
            1) list_instances "$acc" | while IFS=$'\t' read -r p z i m itv; do echo "  $p/$z/$i [监控:$m, 间隔:${itv}m]"; done; [[ -z "$(list_instances "$acc")" ]] && echo "  (无)"; pause ;;
            2)
                local lines=$(list_instances "$acc")
                [[ -z "$lines" ]] && { echo "无"; pause; continue; }
                local idx=1; while IFS=$'\t' read -r p z i m _; do echo "  $idx) $p/$z/$i [当前:$m]"; ((idx++)); done <<< "$lines"
                read -rp "序号: " s; [[ "$s" =~ ^[0-9]+$ ]] || { pause; continue; }
                IFS=$'\t' read -r proj zone inst mon _ <<< "$(echo "$lines"|sed -n "${s}p")"
                local ans="" nm="$mon"
                read -rp "是否开启监控? (y=开 / n=关, 当前:$mon): " ans
                case "$ans" in
                    [Yy]*) nm="true" ;;
                    [Nn]*) nm="false" ;;
                    *) echo "未更改"; pause; continue ;;
                esac
                config_write '.accounts=(.accounts|map(if .account==$a then .projects=(.projects|map(if .id==$p then .zones=(.zones|map(if .name==$z then .instances=(.instances|map(if .name==$i then .monitor=($m=="true") else . end)) else . end)) else . end)) else . end))' \
                    --arg a "$acc" --arg p "$proj" --arg z "$zone" --arg i "$inst" --arg m "$nm"
                echo "已设为 $nm"; pause ;;
            3)
                local lines=$(list_instances "$acc")
                [[ -z "$lines" ]] && { echo "无"; pause; continue; }
                local idx=1; while IFS=$'\t' read -r p z i _ _; do echo "  $idx) $p/$z/$i"; ((idx++)); done <<< "$lines"
                read -rp "序号: " s; [[ "$s" =~ ^[0-9]+$ ]] || { pause; continue; }
                IFS=$'\t' read -r proj zone inst _ _ <<< "$(echo "$lines"|sed -n "${s}p")"
                check_instance "$acc" "$proj" "$zone" "$inst"; pause ;;
            4)
                local lines=$(list_instances "$acc")
                [[ -z "$lines" ]] && { echo "无"; pause; continue; }
                local idx=1; while IFS=$'\t' read -r p z i _ itv; do echo "  $idx) $p/$z/$i (当前间隔:${itv}m)"; ((idx++)); done <<< "$lines"
                read -rp "序号: " s; [[ "$s" =~ ^[0-9]+$ ]] || { pause; continue; }
                IFS=$'\t' read -r proj zone inst _ old_itv <<< "$(echo "$lines"|sed -n "${s}p")"
                read -rp "新间隔(分钟, 正整数, 当前${old_itv}): " new_itv
                [[ -z "$new_itv" || ! "$new_itv" =~ ^[0-9]+$ ]] && { echo "输入无效"; pause; continue; }
                config_write '.accounts=(.accounts|map(if .account==$a then .projects=(.projects|map(if .id==$p then .zones=(.zones|map(if .name==$z then .instances=(.instances|map(if .name==$i then .interval=$v else . end)) else . end)) else . end)) else . end))' \
                    --arg a "$acc" --arg p "$proj" --arg z "$zone" --arg i "$inst" --argjson v "$new_itv"
                echo "已设为 ${new_itv} 分钟"; pause ;;
            5)
                local lines=$(list_instances "$acc")
                [[ -z "$lines" ]] && { echo "无"; pause; continue; }
                local idx=1; while IFS=$'\t' read -r p z i _ _; do echo "  $idx) $p/$z/$i"; ((idx++)); done <<< "$lines"
                read -rp "序号: " s; [[ "$s" =~ ^[0-9]+$ ]] || { pause; continue; }
                IFS=$'\t' read -r proj zone inst _ _ <<< "$(echo "$lines"|sed -n "${s}p")"
                read -rp "确认删除监控记录 $proj/$zone/$inst ? [y/N]: " y
                [[ "$y" =~ ^[Yy]$ ]] || { echo "已取消"; pause; continue; }
                remove_instance_entry "$acc" "$proj" "$zone" "$inst"
                echo "已删除监控记录"; pause ;;
            0) return ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        echo "$LOGO"
        local ac=$(config_read '.accounts|length' 2>/dev/null||echo 0)
        local ic=$(config_read '[.accounts[].projects[].zones[].instances[]]|length' 2>/dev/null||echo 0)
        echo "账号: $ac  实例: $ic"
        echo ""
        echo "1) 账号管理"
        echo "2) 实例管理"
        echo "3) 统计日志"
        echo "4) 立即检查"
        echo "0) 退出"
        read -rp "选择: " c
        case "$c" in
            1) menu_accounts ;;
            2) menu_instances ;;
            3)
                echo "账号: $(config_read '.accounts|length')"
                echo "实例: $(config_read '[.accounts[].projects[].zones[].instances[]]|length')"
                echo ""
                echo "最近日志:"
                tail -30 "$LOG_FILE" 2>/dev/null || echo "(无)"
                pause ;;
            4) check_all "" false; pause ;;
            0) exit 0 ;;
        esac
    done
}

do_install() {
    require_root
    echo "$LOGO"
    echo "安装中..."
    ensure_dirs; ensure_jq; ensure_gcloud; ensure_crontab
    
    local ok=false
    if [[ -n "$SELF_SCRIPT" && -f "$SELF_SCRIPT" ]]; then
        cp "$SELF_SCRIPT" "$GCPSC_SCRIPT" && ok=true
    elif [[ -n "${SCRIPT_URL:-}" ]]; then
        log_info "从远程下载脚本以完成安装: $SCRIPT_URL"
        curl -fsSL "$SCRIPT_URL" -o "${GCPSC_SCRIPT}.new" 2>/dev/null && [[ -s "${GCPSC_SCRIPT}.new" ]] && mv "${GCPSC_SCRIPT}.new" "$GCPSC_SCRIPT" && ok=true
        rm -f "${GCPSC_SCRIPT}.new" 2>/dev/null
    fi
    [[ "$ok" != "true" ]] && fatal "安装失败"
    
    chmod +x "$GCPSC_SCRIPT"
    ln -sf "$GCPSC_SCRIPT" /usr/bin/gcpsc
    log_info "安装完成 v$VERSION"
    echo "完成! 运行: sudo gcpsc"
    exec "$GCPSC_SCRIPT" __installed__
}

do_uninstall() {
    require_root
    read -rp "确认卸载? [y/N]: " y
    [[ ! "$y" =~ ^[Yy]$ ]] && exit 0
    crontab -l 2>/dev/null | grep -v "$GCPSC_SCRIPT" | crontab - 2>/dev/null || true
    rm -f "$GCPSC_SCRIPT" /usr/bin/gcpsc
    rm -rf "$CONFIG_DIR" "$LOG_FILE"
    echo "已卸载"
}

main() {
    case "${1:-}" in
        install) do_install ;;
        remove|uninstall) do_uninstall ;;
        check)
            require_root; ensure_dirs; ensure_jq
            shift; local t="" r="true"
            while [[ $# -gt 0 ]]; do
                case "$1" in -a|--account) t="$2"; shift 2 ;; --no-refresh) r="false"; shift ;; *) shift ;; esac
            done
            check_all "$t" "$r" ;;
        version|-v|--version) echo "v$VERSION" ;;
        __installed__|"")
            require_root; ensure_dirs; ensure_jq
            [[ "$(config_read '.version//"0"')" != "$VERSION" ]] && config_write '.version=$v' --arg v "$VERSION"
            main_menu ;;
        *) echo "用法: gcpsc [install|remove|check|version]"; exit 1 ;;
    esac
}

main "$@"
