#!/bin/sh
# shellcheck shell=bash
# Snell v4 / v5 / v6 multi-distro installer (Debian / Ubuntu / AlmaLinux / Rocky / CentOS Stream / Alpine).
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" -eq 0 ] && [ -r /etc/os-release ] && \
           grep -qiE '^ID="?alpine"?' /etc/os-release && command -v apk >/dev/null 2>&1; then
            printf '\n检测到 Alpine Linux 缺少 bash，正在自动安装……\n'
            apk add --no-cache bash || { printf '\n错误：自动安装 bash 失败。\n' >&2; exit 1; }
        else
            printf '\n错误：需要 bash 环境运行此脚本（请先安装 bash 后使用 bash %s）。\n' "$0" >&2
            exit 1
        fi
    fi
    if [ ! -r "$0" ]; then
        printf '\n错误：请先将脚本保存为文件再运行，不要通过管道直接执行。\n' >&2
        exit 1
    fi
    exec bash "$0" "$@"
fi

set -Eeuo pipefail
umask 077
export LC_ALL=C

readonly SNELL_V4_VERSION=4.1.1
readonly SNELL_V5_VERSION=5.0.1
readonly SNELL_V6_VERSION=6.0.0
readonly BIN=/usr/local/bin/snell-server
readonly CONF_DIR=/etc/snell
readonly UNIT=/etc/systemd/system/snell.service
readonly OPENRC_INIT=/etc/init.d/snell
readonly OPENRC_LOG_DIR=/var/log/snell
readonly OPENRC_LOG=/var/log/snell/snell.log

# Overridable paths for safe isolated testing.
SYSTEMD_UNIT_DIRS=(/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system)
OPENRC_INIT_DIR=/etc/init.d
LEGACY_BIN_PATHS=(/usr/local/bin/snell-server /usr/bin/snell-server /opt/snell/snell-server /root/snell-server)
LEGACY_CONF_PATHS=(/etc/snell /etc/snell-server /opt/snell)
INSTALL_LOG=/var/log/snell-install.log

SNELL_MAJOR=5
SNELL_VERSION=$SNELL_V5_VERSION
SNELL_MODE=default
CLI_VERSION=''
CLI_MODE=''
AUTO_YES=0
FORCE_CLEAN=0
DO_UNINSTALL=0

OS_ID=''
OS_FAMILY=''
PKG_MGR=''
INIT_SYS=systemd
SERVICE_FILE=$UNIT

WORK=''
CREATED=0
USER_CREATED=0
CONF_CREATED=0
OWNED_FILES=()
OWNED_IDS=()
ENABLE_CHANGED=0
BOOT_STATUS='已设置开机启动'
FIREWALL_STATUS='未检测到拦截规则，保持放行'
DONE=0
REINSTALL=0
REINSTALL_MODE=reuse
BACKUP=''
LEGACY_BACKUP=''
OLD_ACTIVE=0
OLD_ENABLED='disabled'
REUSE_CONFIG=0
REUSE_UNIT=0
OLD_PORT=''
OLD_PSK=''
NODE_EXTRA=''
REMOVE_OBFS=0
REMOVE_OBFS_CONFIRMED=0
UPDATE_MODE=0
REINSTALL_ALLOW_CLEAN_FALLBACK=0
REINSTALL_REJECT_REASON=''

FOUND_ANY=0
FOUND_STANDARD=0
FOUND_BINS=()
FOUND_CONFS=()
FOUND_SYSTEMD_UNITS=()
FOUND_OPENRC_SCRIPTS=()
FOUND_PROC=0

log_msg() {
    if [[ -n ${INSTALL_LOG:-} && -w $(dirname "$INSTALL_LOG") ]]; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'time')" "$*" >> "$INSTALL_LOG" 2>/dev/null || true
    fi
}

info() {
    log_msg "INFO: $*"
    printf '\n%s\n' "$*"
}

fail() {
    log_msg "ERROR: $*"
    printf '\n错误：%s\n' "$*" >&2
    if [[ -n ${INSTALL_LOG:-} && -f $INSTALL_LOG ]]; then
        printf '详细日志：%s\n' "$INSTALL_LOG" >&2
    fi
    exit 1
}

reinstall_reject() {
    if [[ $REINSTALL_ALLOW_CLEAN_FALLBACK == 1 ]]; then
        REINSTALL_REJECT_REASON=$1
        return 2
    fi
    fail "$1"
}

cleanup() {
    local rc=$?
    trap - EXIT ERR
    set +e
    if [[ $CREATED == 1 && $DONE == 0 ]]; then
        local file i restore_failed=0
        svc_stop >/dev/null 2>&1
        if (( ${#OWNED_FILES[@]} > 0 )); then
            for ((i=0; i<${#OWNED_FILES[@]}; i++)); do
                file=${OWNED_FILES[i]}
                if [[ -e $file || -L $file ]]; then
                    if [[ -L $file || $(file_identity "$file") != "${OWNED_IDS[i]}" ]]; then
                        printf '警告：文件被其他程序替换，未删除：%s\n' "$file" >&2
                        restore_failed=1
                        continue
                    fi
                    rm -f -- "$file" || restore_failed=1
                fi
                if [[ -n $BACKUP && -f $BACKUP/${file##*/} ]]; then
                    cp -a -- "$BACKUP/${file##*/}" "$file" || restore_failed=1
                    restore_selinux_context "$file"
                fi
            done
        fi
        if [[ $CONF_CREATED == 1 ]]; then rmdir -- "$CONF_DIR" 2>/dev/null; fi
        svc_reload >/dev/null 2>&1 || restore_failed=1
        # Reused units keep their exact enable/runtime/link state throughout.
        if [[ $ENABLE_CHANGED == 1 ]]; then
            svc_disable >/dev/null 2>&1
        fi
        if [[ $OLD_ACTIVE == 1 ]]; then
            svc_start >/dev/null 2>&1 || restore_failed=1
            svc_is_active || restore_failed=1
        fi
        if [[ $USER_CREATED == 1 ]]; then remove_service_user >/dev/null 2>&1; fi
        if [[ $restore_failed == 0 ]]; then
            printf '\n安装未完成，已撤回本次改动；原来运行中的服务已尝试恢复。\n' >&2
        else
            printf '\n警告：自动恢复未全部成功，请检查 snell 服务；备份：%s\n' "$BACKUP" >&2
        fi
        if [[ -n $LEGACY_BACKUP ]]; then
            printf '原第三方安装备份位于：%s\n' "$LEGACY_BACKUP" >&2
        fi
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    exit "$rc"
}
trap cleanup EXIT
trap 'printf "\n命令执行失败（第 %s 行）。\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

file_identity() {
    local target=$1
    [[ $target == -* ]] && target="./$target"
    stat -c '%d:%i' "$target"
}

restore_selinux_context() {
    if command -v restorecon >/dev/null 2>&1 && command -v getenforce >/dev/null 2>&1; then
        if [[ $(getenforce 2>/dev/null) == Enforcing ]]; then
            restorecon -F "$@" >/dev/null 2>&1 || true
        fi
    fi
}

add_unique() {
    local arr_name=$1 val=$2 existing
    [[ -n $val ]] || return 0
    local -n arr_ref=$arr_name
    for existing in "${arr_ref[@]+"${arr_ref[@]}"}"; do
        [[ $existing == "$val" ]] && return 0
    done
    arr_ref+=("$val")
}

# Service manager abstraction (systemd / OpenRC).
svc_exists() {
    if [[ $INIT_SYS == openrc ]]; then
        [[ -e $OPENRC_INIT || -L $OPENRC_INIT ]] && return 0
        command -v rc-service >/dev/null 2>&1 && rc-service -e snell >/dev/null 2>&1 && return 0
        return 1
    fi
    [[ $(systemctl show snell.service -p LoadState --value 2>/dev/null || echo not-found) != not-found ]] && return 0
    local unit_list
    unit_list=$(systemctl list-unit-files --no-legend --no-pager 2>/dev/null || true)
    grep -qi snell <<< "$unit_list" && return 0
    return 1
}

svc_loaded() {
    if [[ $INIT_SYS == openrc ]]; then
        [[ -e $OPENRC_INIT || -L $OPENRC_INIT ]]
        return
    fi
    [[ $(systemctl show snell.service -p LoadState --value 2>/dev/null || echo not-found) != not-found ]]
}

svc_is_active() {
    if [[ $INIT_SYS == openrc ]]; then
        rc-service snell status >/dev/null 2>&1
        return
    fi
    systemctl is-active --quiet snell.service
}

svc_is_enabled() {
    if [[ $INIT_SYS == openrc ]]; then
        local show_out
        show_out=$(rc-update show default 2>/dev/null || true)
        if awk '$1 == "snell" {found=1} END {exit !found}' <<< "$show_out"; then
            echo enabled
        else
            echo disabled
        fi
        return 0
    fi
    systemctl is-enabled snell.service 2>/dev/null || true
}

svc_start() {
    if [[ $INIT_SYS == openrc ]]; then
        rc-service snell start
        return
    fi
    systemctl start snell.service
}

svc_stop() {
    if [[ $INIT_SYS == openrc ]]; then
        rc-service snell stop
        return
    fi
    systemctl stop snell.service
}

svc_enable() {
    if [[ $INIT_SYS == openrc ]]; then
        rc-update add snell default
        return
    fi
    systemctl enable snell.service
}

svc_disable() {
    if [[ $INIT_SYS == openrc ]]; then
        rc-update del snell default
        return
    fi
    systemctl disable snell.service
}

svc_reload() {
    if [[ $INIT_SYS == openrc ]]; then
        return 0
    fi
    systemctl daemon-reload
}

svc_exec_matches() {
    if [[ $INIT_SYS == openrc ]]; then
        [[ -f $OPENRC_INIT ]] || return 1
        grep -Fqx "command=\"$BIN\"" "$OPENRC_INIT" || return 1
        grep -Fqx "command_args=\"-c $CONF_DIR/snell-server.conf\"" "$OPENRC_INIT" || return 1
        return 0
    fi
    local exec_start
    exec_start=$(systemctl show snell.service -p ExecStart --value 2>/dev/null || true)
    [[ $exec_start == *"path=$BIN ;"* && $exec_start == *" -c $CONF_DIR/snell-server.conf "* ]]
}

svc_backup_effective() {
    local dest=$1
    if [[ $INIT_SYS == openrc ]]; then
        cp -a -- "$OPENRC_INIT" "$dest" 2>/dev/null || true
        return
    fi
    systemctl cat snell.service > "$dest" 2>/dev/null || true
}

svc_show_logs() {
    if [[ $INIT_SYS == openrc ]]; then
        if [[ -s $OPENRC_LOG ]]; then
            tail -n 25 "$OPENRC_LOG" >&2 || true
        fi
        return
    fi
    journalctl -u snell.service -n 25 --no-pager >&2 || true
}

write_service_definition() {
    local out=$1
    if [[ $INIT_SYS == openrc ]]; then
        cat > "$out" <<OPENRC
#!/sbin/openrc-run

name="snell"
description="Snell ${SNELL_VERSION} Proxy Server"
command="${BIN}"
command_args="-c ${CONF_DIR}/snell-server.conf"
command_user="snell-auto:snell-auto"
supervisor="supervise-daemon"
respawn_delay=3
pidfile="/run/snell.pid"
output_log="${OPENRC_LOG}"
error_log="${OPENRC_LOG}"
rc_ulimit="-n 32768"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -o snell-auto:snell-auto -m 0750 "${OPENRC_LOG_DIR}"
}
OPENRC
        return
    fi
    cat > "$out" <<SERVICE
[Unit]
Description=Snell ${SNELL_VERSION} Proxy Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=snell-auto
Group=snell-auto
ExecStart=${BIN} -c ${CONF_DIR}/snell-server.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=32768
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
UMask=0077

[Install]
WantedBy=multi-user.target
SERVICE
}

# System user abstraction.
ensure_service_user() {
    if [[ $OS_FAMILY == alpine ]]; then
        if ! getent group snell-auto >/dev/null 2>&1; then
            addgroup -S snell-auto
        fi
        if ! getent passwd snell-auto >/dev/null 2>&1; then
            adduser -S -D -H -h /nonexistent -s /sbin/nologin -G snell-auto snell-auto
        fi
    else
        local nologin=/usr/sbin/nologin
        [[ -x $nologin ]] || nologin=/sbin/nologin
        if ! getent passwd snell-auto >/dev/null 2>&1; then
            useradd --system --user-group --no-create-home --home-dir /nonexistent \
                --shell "$nologin" snell-auto
        fi
    fi
}

remove_service_user() {
    if [[ $OS_FAMILY == alpine ]]; then
        deluser snell-auto >/dev/null 2>&1 || true
        delgroup snell-auto >/dev/null 2>&1 || true
    else
        userdel snell-auto >/dev/null 2>&1 || true
        if getent group snell-auto >/dev/null 2>&1; then groupdel snell-auto >/dev/null 2>&1 || true; fi
    fi
}

# Open with O_EXCL and track file identity for conflict-safe rollback.
create_file() {
    local source=$1 destination=$2 mode=$3 slot=-1
    if [[ -e $destination || -L $destination ]]; then
        [[ $REINSTALL == 1 && -n $BACKUP && -f $BACKUP/${destination##*/} && ! -L $destination ]] || \
            fail "文件未备份，拒绝覆盖：$destination"
        cmp -s -- "$BACKUP/${destination##*/}" "$destination" || fail "备份后文件被其他程序修改：$destination"
        slot=${#OWNED_FILES[@]}
        OWNED_FILES+=("$destination")
        OWNED_IDS+=('missing')
        rm -- "$destination"
    fi
    set -C
    if exec 8>"$destination"; then
        set +C
        if (( slot < 0 )); then
            slot=${#OWNED_FILES[@]}
            OWNED_FILES+=("$destination")
            OWNED_IDS+=('missing')
        fi
        OWNED_IDS[slot]=$(file_identity "$destination")
        cat "$source" >&8
        exec 8>&-
        chmod "$mode" "$destination"
        restore_selinux_context "$destination"
    else
        set +C
        fail "不能创建文件（可能已存在）：$destination"
    fi
}

existing_install() {
    [[ -e $BIN || -L $BIN || -e $CONF_DIR || -L $CONF_DIR || -e $UNIT || -L $UNIT || -e $OPENRC_INIT || -L $OPENRC_INIT ]] && return 0
    command -v snell-server >/dev/null 2>&1 && return 0
    svc_exists && return 0
    pgrep -x snell-server >/dev/null 2>&1 && return 0
    return 1
}

scan_existing_snell() {
    FOUND_ANY=0
    FOUND_STANDARD=0
    FOUND_BINS=()
    FOUND_CONFS=()
    FOUND_SYSTEMD_UNITS=()
    FOUND_OPENRC_SCRIPTS=()
    FOUND_PROC=0

    local path unit_dir unit_file unit_name cmd_bin exec_line conf_arg
    for path in "$BIN" "${LEGACY_BIN_PATHS[@]}"; do
        [[ -e $path || -L $path ]] && add_unique FOUND_BINS "$path"
    done
    cmd_bin=$(command -v snell-server 2>/dev/null || true)
    [[ -n $cmd_bin ]] && add_unique FOUND_BINS "$cmd_bin"

    for path in "$CONF_DIR" "${LEGACY_CONF_PATHS[@]}"; do
        [[ -e $path || -L $path ]] && add_unique FOUND_CONFS "$path"
    done

    if [[ $INIT_SYS == systemd ]] && command -v systemctl >/dev/null 2>&1; then
        local unit_list
        unit_list=$(systemctl list-unit-files --no-legend --no-pager '*snell*' 2>/dev/null | awk '{print $1}' || true)
        for unit_name in $unit_list; do
            [[ -n $unit_name ]] && add_unique FOUND_SYSTEMD_UNITS "$unit_name"
        done
        for unit_dir in "${SYSTEMD_UNIT_DIRS[@]}"; do
            [[ -d $unit_dir ]] || continue
            for unit_file in "$unit_dir"/*snell*.service; do
                [[ -e $unit_file || -L $unit_file ]] || continue
                unit_name=${unit_file##*/}
                add_unique FOUND_SYSTEMD_UNITS "$unit_name"
                if [[ -f $unit_file ]]; then
                    exec_line=$(awk -F= '/^[[:space:]]*ExecStart[[:space:]]*=/{print $2; exit}' "$unit_file" || true)
                    if [[ -n $exec_line ]]; then
                        cmd_bin=$(awk '{print $1}' <<< "$exec_line")
                        [[ $cmd_bin == /* ]] && [[ -e $cmd_bin || -L $cmd_bin ]] && add_unique FOUND_BINS "$cmd_bin"
                        conf_arg=$(sed -n 's/.*[[:space:]]-c[[:space:]]\([^[:space:]]*\).*/\1/p' <<< "$exec_line")
                        [[ $conf_arg == /* ]] && [[ -e $conf_arg || -L $conf_arg ]] && add_unique FOUND_CONFS "$conf_arg"
                    fi
                fi
            done
        done
    fi

    if [[ -e $OPENRC_INIT || -L $OPENRC_INIT ]]; then
        add_unique FOUND_OPENRC_SCRIPTS "$OPENRC_INIT"
    fi
    if [[ -d $OPENRC_INIT_DIR ]]; then
        for path in "$OPENRC_INIT_DIR"/snell*; do
            [[ -e $path || -L $path ]] && add_unique FOUND_OPENRC_SCRIPTS "$path"
        done
    fi

    if pgrep -x snell-server >/dev/null 2>&1; then
        FOUND_PROC=1
    fi

    if (( ${#FOUND_BINS[@]} > 0 || ${#FOUND_CONFS[@]} > 0 || ${#FOUND_SYSTEMD_UNITS[@]} > 0 || ${#FOUND_OPENRC_SCRIPTS[@]} > 0 || FOUND_PROC == 1 )); then
        FOUND_ANY=1
    else
        return 0
    fi

    # Check if this matches a single standard installation managed by this script.
    if (( ${#FOUND_BINS[@]} <= 1 && ${#FOUND_CONFS[@]} <= 1 && ${#FOUND_SYSTEMD_UNITS[@]} <= 1 && ${#FOUND_OPENRC_SCRIPTS[@]} <= 1 )); then
        local bin_ok=1 conf_ok=1 svc_ok=1
        if (( ${#FOUND_BINS[@]} == 1 )) && [[ ${FOUND_BINS[0]} != "$BIN" ]]; then bin_ok=0; fi
        if (( ${#FOUND_CONFS[@]} == 1 )) && [[ ${FOUND_CONFS[0]} != "$CONF_DIR" ]]; then conf_ok=0; fi
        if [[ $INIT_SYS == systemd ]]; then
            if (( ${#FOUND_OPENRC_SCRIPTS[@]} > 0 )); then svc_ok=0; fi
            if (( ${#FOUND_SYSTEMD_UNITS[@]} == 1 )) && [[ ${FOUND_SYSTEMD_UNITS[0]} != snell.service ]]; then svc_ok=0; fi
        else
            if (( ${#FOUND_SYSTEMD_UNITS[@]} > 0 )); then svc_ok=0; fi
            if (( ${#FOUND_OPENRC_SCRIPTS[@]} == 1 )) && [[ ${FOUND_OPENRC_SCRIPTS[0]} != "$OPENRC_INIT" ]]; then svc_ok=0; fi
        fi
        if [[ $bin_ok == 1 && $conf_ok == 1 && $svc_ok == 1 ]]; then
            FOUND_STANDARD=1
        fi
    fi
}

print_found_summary() {
    local item
    if (( ${#FOUND_SYSTEMD_UNITS[@]} > 0 )); then
        printf '  - systemd 服务：%s\n' "${FOUND_SYSTEMD_UNITS[*]}"
    fi
    if (( ${#FOUND_OPENRC_SCRIPTS[@]} > 0 )); then
        printf '  - OpenRC 服务：%s\n' "${FOUND_OPENRC_SCRIPTS[*]}"
    fi
    if (( ${#FOUND_BINS[@]} > 0 )); then
        for item in "${FOUND_BINS[@]}"; do printf '  - 程序文件：%s\n' "$item"; done
    fi
    if (( ${#FOUND_CONFS[@]} > 0 )); then
        for item in "${FOUND_CONFS[@]}"; do printf '  - 配置路径：%s\n' "$item"; done
    fi
    if [[ $FOUND_PROC == 1 ]]; then
        printf '  - 运行中进程：snell-server\n'
    fi
}

uninstall_existing_snell() {
    local item unit_dir unit_file n=0
    info '正在备份并卸载原有的 Snell……'
    install -d -m 700 /var/backups/snell
    LEGACY_BACKUP=$(mktemp -d /var/backups/snell/legacy-backup-XXXXXXXX)

    # 1. Back up discovered files before stopping/removing.
    for item in "${FOUND_BINS[@]+"${FOUND_BINS[@]}"}"; do
        if [[ -f $item && ! -L $item ]]; then
            cp -a -- "$item" "$LEGACY_BACKUP/" 2>/dev/null || true
        fi
    done
    for item in "${FOUND_CONFS[@]+"${FOUND_CONFS[@]}"}"; do
        if [[ -d $item && ! -L $item ]]; then
            cp -a -- "$item" "$LEGACY_BACKUP/" 2>/dev/null || true
        elif [[ -f $item && ! -L $item ]]; then
            cp -a -- "$item" "$LEGACY_BACKUP/" 2>/dev/null || true
        fi
    done
    for item in "${FOUND_SYSTEMD_UNITS[@]+"${FOUND_SYSTEMD_UNITS[@]}"}"; do
        if command -v systemctl >/dev/null 2>&1; then
            systemctl cat "$item" > "$LEGACY_BACKUP/${item}.txt" 2>/dev/null || true
        fi
        for unit_dir in "${SYSTEMD_UNIT_DIRS[@]}"; do
            unit_file="$unit_dir/$item"
            if [[ -f $unit_file && ! -L $unit_file ]]; then
                cp -a -- "$unit_file" "$LEGACY_BACKUP/" 2>/dev/null || true
            fi
        done
    done
    for item in "${FOUND_OPENRC_SCRIPTS[@]+"${FOUND_OPENRC_SCRIPTS[@]}"}"; do
        if [[ -f $item && ! -L $item ]]; then
            cp -a -- "$item" "$LEGACY_BACKUP/" 2>/dev/null || true
        fi
    done
    info "原有 Snell 相关文件已备份到：$LEGACY_BACKUP（仅 root 可访问）"

    # 2. Stop & disable systemd services.
    if (( ${#FOUND_SYSTEMD_UNITS[@]} > 0 )) && command -v systemctl >/dev/null 2>&1; then
        for item in "${FOUND_SYSTEMD_UNITS[@]}"; do
            systemctl stop "$item" >/dev/null 2>&1 || true
            systemctl disable "$item" >/dev/null 2>&1 || true
            for unit_dir in "${SYSTEMD_UNIT_DIRS[@]}"; do
                unit_file="$unit_dir/$item"
                if [[ -e $unit_file || -L $unit_file ]]; then
                    rm -f -- "$unit_file" || true
                fi
            done
        done
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed >/dev/null 2>&1 || true
    fi

    # 3. Stop & disable OpenRC services.
    for item in "${FOUND_OPENRC_SCRIPTS[@]+"${FOUND_OPENRC_SCRIPTS[@]}"}"; do
        local rc_name=${item##*/}
        if command -v rc-service >/dev/null 2>&1; then
            rc-service "$rc_name" stop >/dev/null 2>&1 || true
        fi
        if command -v rc-update >/dev/null 2>&1; then
            rc-update del "$rc_name" default >/dev/null 2>&1 || true
        fi
        rm -f -- "$item" || true
    done

    # 4. Stop any leftover snell-server processes.
    if pgrep -x snell-server >/dev/null 2>&1; then
        pkill -TERM -x snell-server >/dev/null 2>&1 || true
        for ((n=0; n<10; n++)); do
            pgrep -x snell-server >/dev/null 2>&1 || break
            sleep 0.5
        done
        if pgrep -x snell-server >/dev/null 2>&1; then
            pkill -KILL -x snell-server >/dev/null 2>&1 || true
            sleep 0.5
        fi
    fi

    # 5. Remove discovered binaries and config directories/files.
    for item in "${FOUND_BINS[@]+"${FOUND_BINS[@]}"}"; do
        rm -f -- "$item" || true
    done
    for item in "${FOUND_CONFS[@]+"${FOUND_CONFS[@]}"}"; do
        if [[ -L $item ]]; then
            rm -f -- "$item" || true
        elif [[ -d $item ]]; then
            rm -rf -- "$item" || true
        elif [[ -f $item ]]; then
            rm -f -- "$item" || true
        fi
    done
    if [[ -L $UNIT || -e $UNIT ]]; then rm -f -- "$UNIT" || true; fi
    if [[ -L $OPENRC_INIT || -e $OPENRC_INIT ]]; then rm -f -- "$OPENRC_INIT" || true; fi

    # 6. Clean up snell-auto user if left over from an incomplete install.
    remove_service_user

    REINSTALL=0
    REUSE_CONFIG=0
    REUSE_UNIT=0
    OLD_PORT=''
    OLD_PSK=''
    NODE_EXTRA=''
    OLD_ACTIVE=0
}

valid_ipv4() {
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    (( 10#$a > 0 && 10#$a < 224 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
    # Reject common private / loopback / link-local / CGNAT responses.
    (( 10#$a != 10 && 10#$a != 127 )) || return 1
    [[ $a.$b != 192.168 && $a.$b != 169.254 ]] || return 1
    ! (( 10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 || 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 ))
}

config_value() {
    awk -v key="$1" '
        { sub(/\r$/, "") }
        /^[[:space:]]*\[/ { section = ($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/); next }
        section && /^[[:space:]]*[^#;][^=]*=/ {
            name=$0; sub(/=.*/, "", name); gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name == key) { value=$0; sub(/^[^=]*=/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); print value; exit }
        }' "$CONF_DIR/snell-server.conf"
}

PARSED_PORT=''

parse_listen_port() {
    local listen=$1 item port='' item_port
    PARSED_PORT=''
    if [[ $listen == *,* ]]; then
        if [[ $SNELL_MAJOR != 6 ]]; then
            reinstall_reject '原配置使用了多地址 listen，仅 Snell v6 支持；请先修改 listen 后再安装 v4/v5。' || return $?
        fi
        local items
        IFS=',' read -r -a items <<< "$listen"
        for item in "${items[@]}"; do
            item=${item#"${item%%[![:space:]]*}"}
            item=${item%"${item##*[![:space:]]}"}
            if ! [[ $item =~ ^(0\.0\.0\.0|\[::\]):([0-9]{1,5})$ ]]; then
                reinstall_reject '原配置不是标准公网监听格式；未修改，请先检查 listen。' || return $?
            fi
            item_port=$((10#${BASH_REMATCH[2]}))
            if ! (( item_port >= 1 && item_port <= 65535 )); then
                reinstall_reject '原配置端口无效。' || return $?
            fi
            if [[ -z $port ]]; then
                port=$item_port
            elif [[ $port != "$item_port" ]]; then
                reinstall_reject '原配置多地址 listen 端口不一致；未修改，请先检查 listen。' || return $?
            fi
        done
    else
        if ! [[ $listen =~ ^(0\.0\.0\.0|\[::\]):([0-9]{1,5})$ ]]; then
            reinstall_reject '原配置不是单端口公网监听格式；未修改，请先检查 listen。' || return $?
        fi
        port=$((10#${BASH_REMATCH[2]}))
        if ! (( port >= 1 && port <= 65535 )); then
            reinstall_reject '原配置端口无效。' || return $?
        fi
    fi
    PARSED_PORT=$port
}

rewrite_config_for_v6() {
    local src=$1 dst=$2 remove_obfs=$3 update_mode=$4 new_mode=$5
    awk -v remove_obfs="$remove_obfs" -v update_mode="$update_mode" -v new_mode="$new_mode" '
        BEGIN { in_sec = 0; mode_written = 0 }
        {
            sub(/\r$/, "")
            if ($0 ~ /^[[:space:]]*\[/) {
                if (in_sec && update_mode == 1 && mode_written == 0) {
                    print "mode = " new_mode
                    mode_written = 1
                }
                in_sec = ($0 ~ /^[[:space:]]*\[snell-server\][[:space:]]*$/)
                print
                next
            }
            if (in_sec && $0 ~ /^[[:space:]]*[^#;][^=]*=/) {
                name = $0; sub(/=.*/, "", name); gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
                if (remove_obfs == 1 && (name == "obfs" || name == "obfs-host" || name == "obfs-uri")) {
                    next
                }
                if (update_mode == 1 && name == "mode") {
                    print "mode = " new_mode
                    mode_written = 1
                    next
                }
            }
            print
        }
        END {
            if (in_sec && update_mode == 1 && mode_written == 0) {
                print "mode = " new_mode
            }
        }
    ' "$src" > "$dst"
}

prepare_reinstall() {
    local file listen obfs old_mode dns_pref answer rc=0
    REUSE_CONFIG=0
    REUSE_UNIT=0
    OLD_PORT=''
    OLD_PSK=''
    NODE_EXTRA=''
    REMOVE_OBFS=0
    UPDATE_MODE=0
    if [[ -L $CONF_DIR ]]; then
        reinstall_reject '配置目录是符号链接；请先确认实际安装路径。' || return $?
    fi
    if [[ -e $CONF_DIR && ! -d $CONF_DIR ]]; then
        reinstall_reject '配置目录位置被普通文件占用。' || return $?
    fi
    for file in "$BIN" "$SERVICE_FILE" "$CONF_DIR/snell-server.conf" "$CONF_DIR/surge-proxy.txt"; do
        if [[ -L $file || ( -e $file && ! -f $file ) ]]; then
            reinstall_reject "不能自动覆盖符号链接或特殊文件：$file" || return $?
        fi
    done
    if [[ -f $CONF_DIR/snell-server.conf ]]; then
        listen=$(config_value listen)
        OLD_PSK=$(config_value psk)
        parse_listen_port "$listen" || rc=$?
        if (( rc != 0 )); then return "$rc"; fi
        OLD_PORT=$PARSED_PORT
        if [[ -z $OLD_PSK || $OLD_PSK =~ [[:space:],\;\#] ]]; then
            reinstall_reject '原密钥格式无法直接输出到 Surge；未修改。' || return $?
        fi
        obfs=$(config_value obfs)
        old_mode=$(config_value mode)
        dns_pref=$(config_value dns-ip-preference)

        if [[ $SNELL_MAJOR == 6 ]]; then
            case $obfs in
                ''|off|false) ;;
                *)
                    info "提示：原配置包含 obfs=${obfs}，但 Snell v6 已移除 obfs（改为基于 PSK 自动派生流量特征）。"
                    if [[ $REMOVE_OBFS_CONFIRMED == 1 ]]; then
                        REMOVE_OBFS=1
                    elif [[ $AUTO_YES == 1 ]]; then
                        REMOVE_OBFS=1
                        REMOVE_OBFS_CONFIRMED=1
                        info '已按 --yes 自动确认：将在备份原配置后移除 obfs 相关配置继续升级到 v6。'
                    else
                        printf '是否自动移除原配置中的 obfs 相关项并继续升级到 v6？[yes/no，默认 no]：'
                        if ! read -r answer; then
                            fail '没有读到确认；未修改原配置。'
                        fi
                        case $answer in
                            yes|YES|Yes|y|Y|on|ON)
                                REMOVE_OBFS=1
                                REMOVE_OBFS_CONFIRMED=1
                                ;;
                            *)
                                info '已取消，原配置与服务未作任何修改。'
                                exit 0
                                ;;
                        esac
                    fi
                    ;;
            esac
            if [[ -n $CLI_MODE ]]; then
                SNELL_MODE=$CLI_MODE
                if [[ $old_mode != "$CLI_MODE" ]]; then
                    UPDATE_MODE=1
                fi
            elif [[ -n $old_mode ]]; then
                case $old_mode in
                    default|unshaped|unsafe-raw) SNELL_MODE=$old_mode ;;
                    *) reinstall_reject "原配置的 mode 无效：$old_mode" || return $? ;;
                esac
            fi
            if [[ $SNELL_MODE != default ]]; then
                NODE_EXTRA=", mode=${SNELL_MODE}"
            fi
        else
            if [[ -n $old_mode ]]; then
                reinstall_reject "原配置包含 Snell v6 专用的 mode=${old_mode}，不适用于 Snell v${SNELL_MAJOR}；请先移除后再降级。" || return $?
            fi
            if [[ -n $dns_pref ]]; then
                reinstall_reject "原配置包含 Snell v6 专用的 dns-ip-preference=${dns_pref}，不适用于 Snell v${SNELL_MAJOR}；请先移除后再降级。" || return $?
            fi
            case $obfs in
                ''|off|false) ;;
                http) NODE_EXTRA=', obfs=http' ;;
                *) reinstall_reject "原配置的混淆方式不适用于 Snell v${SNELL_MAJOR}：$obfs" || return $? ;;
            esac
        fi
        REUSE_CONFIG=1
        if [[ $REMOVE_OBFS == 1 ]]; then
            info "将保留原端口 ${OLD_PORT} 与密钥，并在备份后移除 obfs 项以升级至 v6。"
        else
            info "将保留原端口 ${OLD_PORT}、密钥及服务端配置。"
        fi
    fi
    if svc_loaded; then
        if ! svc_exec_matches || [[ $REUSE_CONFIG != 1 ]]; then
            reinstall_reject '已有服务不使用标准程序/配置路径，不能直接覆盖；未修改原服务。' || return $?
        fi
        REUSE_UNIT=1
    fi
    if ! [[ $REUSE_CONFIG == 0 || $REUSE_UNIT == 1 ]]; then
        reinstall_reject '原配置存在但原服务缺失，请先恢复服务文件后重装。' || return $?
    fi
}

backup_install() {
    local file
    install -d -m 700 /var/backups/snell
    BACKUP=$(mktemp -d /var/backups/snell/backup-XXXXXXXX)
    for file in "$BIN" "$SERVICE_FILE" "$CONF_DIR/snell-server.conf" "$CONF_DIR/surge-proxy.txt"; do
        if [[ -f $file ]]; then cp -a -- "$file" "$BACKUP/${file##*/}"; fi
    done
    if svc_is_active; then OLD_ACTIVE=1; fi
    OLD_ENABLED=$(svc_is_enabled) || true
    if [[ $REUSE_UNIT == 1 ]]; then
        case $OLD_ENABLED in
            enabled) BOOT_STATUS='已开启开机启动' ;;
            enabled-runtime) BOOT_STATUS='仅运行时启用（沿用原设置）' ;;
            *) BOOT_STATUS="开机策略沿用原设置（${OLD_ENABLED:-未知}）" ;;
        esac
    fi
    svc_backup_effective "$BACKUP/effective-service.txt"
    printf 'init=%s\nactive=%s\nenabled=%s\n' "$INIT_SYS" "$OLD_ACTIVE" "$OLD_ENABLED" > "$BACKUP/service-state.txt"
    info "原安装已备份：$BACKUP（含密钥，仅 root 可访问）"
}

show_result() {
    local public_ip=$1 port=$2 psk=$3
    local green='' cyan='' yellow='' bold='' reset='' version_note=''
    # Keep redirected output clean; respect terminals that disable color.
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
        green=$'\033[1;32m'
        cyan=$'\033[1;36m'
        yellow=$'\033[1;33m'
        bold=$'\033[1m'
        reset=$'\033[0m'
    fi
    if [[ $SNELL_MAJOR == 6 ]]; then
        version_note=" · Beta（mode=${SNELL_MODE}）"
    fi
    printf '\n%s╔══════════════════════════════════════════════╗\n' "$green"
    printf '║              Snell 安装完成                  ║\n'
    printf '╚══════════════════════════════════════════════╝%s\n\n' "$reset"
    printf '  服务器 IP   %s%s%s\n' "$cyan" "$public_ip" "$reset"
    printf '  连接端口    %s%s%s\n' "$cyan" "$port" "$reset"
    printf '  连接密钥    %s%s%s\n' "$bold" "$psk" "$reset"
    printf '  协议版本    Snell v%s（服务端 %s%s）\n' "$SNELL_MAJOR" "$SNELL_VERSION" "$version_note"
    printf '  服务状态    %s● 本机已启动 · %s%s\n' "$green" "$BOOT_STATUS" "$reset"
    printf '  系统防火墙  %s\n' "$FIREWALL_STATUS"
    printf '\n%s━━━━━━━━━━ 复制下面这行到 Surge ━━━━━━━━━━%s\n\n' "$cyan" "$reset"
    # A single, undecorated node line: safe to select and paste into [Proxy].
    printf '%s我的VPS = snell, %s, %s, psk=%s, version=%s%s%s\n' "$bold" "$public_ip" "$port" "$psk" "$SNELL_MAJOR" "$NODE_EXTRA" "$reset"
    printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "$cyan" "$reset"
    printf '  添加位置：Surge 配置 → [Proxy]\n'
    if [[ $SNELL_MAJOR == 5 ]]; then
        printf '  %s云厂商安全组需放行：%s / TCP + UDP（v5 QUIC Proxy 需要 UDP）%s\n' "$yellow" "$port" "$reset"
    else
        printf '  %s云厂商安全组需放行：%s / TCP + UDP%s\n' "$yellow" "$port" "$reset"
    fi
    if [[ $SNELL_MAJOR == 6 ]]; then
        printf '  %s提示：Snell v6 处于 Beta 阶段，需同步使用支持 v6 的 Surge 客户端。%s\n' "$yellow" "$reset"
    fi
    printf '  配置已保存：%s/surge-proxy.txt\n' "$CONF_DIR"
    if [[ -n $BACKUP ]]; then printf '  原安装备份：%s\n' "$BACKUP"; fi
    if [[ -n $LEGACY_BACKUP ]]; then printf '  原旧版备份：%s\n' "$LEGACY_BACKUP"; fi
    printf '  %s节点含密钥，请勿公开分享或截图。%s\n' "$yellow" "$reset"
    printf '\n  本机启动不代表公网可连接，请在 Surge 中测试节点。\n'
    printf '  NAT VPS 还需配置端口映射。\n\n'
}

set_snell_version() {
    case $1 in
        4|v4|"$SNELL_V4_VERSION")
            SNELL_MAJOR=4
            SNELL_VERSION=$SNELL_V4_VERSION
            ;;
        5|v5|"$SNELL_V5_VERSION")
            SNELL_MAJOR=5
            SNELL_VERSION=$SNELL_V5_VERSION
            ;;
        6|v6|"$SNELL_V6_VERSION")
            SNELL_MAJOR=6
            SNELL_VERSION=$SNELL_V6_VERSION
            ;;
        *)
            fail "不支持的 Snell 版本：$1（仅支持 4、5、6）。"
            ;;
    esac
}

validate_mode() {
    case $1 in
        default|unshaped|unsafe-raw) ;;
        *) fail "不支持的 Snell v6 mode：$1（可选：default、unshaped、unsafe-raw）。" ;;
    esac
}

usage() {
    cat <<'EOF'
用法：install-snell.sh [选项]

选项：
  -v, --version <4|5|6>              指定安装的 Snell 主版本（4.1.1 / 5.0.1 / 6.0.0）
      --mode <default|unshaped|unsafe-raw>
                                     仅 Snell v6 可用，设置传输模式（默认 default）
      --clean                        强制备份并卸载原有 Snell 后全新安装
      --uninstall                    备份并彻底卸载本机已安装的 Snell 后退出
  -y, --yes                          跳过交互确认
  -h, --help                         显示此帮助信息
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case $1 in
            -v|--version)
                (( $# >= 2 )) || fail "参数 $1 缺少版本值。"
                CLI_VERSION=$2
                shift 2
                ;;
            --version=*)
                CLI_VERSION=${1#*=}
                shift
                ;;
            --mode)
                (( $# >= 2 )) || fail "参数 $1 缺少 mode 值。"
                CLI_MODE=$2
                shift 2
                ;;
            --mode=*)
                CLI_MODE=${1#*=}
                shift
                ;;
            --clean)
                FORCE_CLEAN=1
                shift
                ;;
            --uninstall)
                DO_UNINSTALL=1
                shift
                ;;
            -y|--yes)
                AUTO_YES=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "未知参数：$1（使用 --help 查看用法）。"
                ;;
        esac
    done
    if [[ -n $CLI_VERSION ]]; then
        set_snell_version "$CLI_VERSION"
    fi
    if [[ -n $CLI_MODE ]]; then
        validate_mode "$CLI_MODE"
        if [[ -n $CLI_VERSION && $SNELL_MAJOR != 6 ]]; then
            fail '只有 Snell v6 支持 --mode 参数。'
        fi
    fi
}

select_snell_version() {
    if [[ -n $CLI_VERSION ]]; then
        if [[ $SNELL_MAJOR == 6 && -n $CLI_MODE ]]; then
            SNELL_MODE=$CLI_MODE
        fi
        return
    fi
    if [[ $AUTO_YES == 1 ]]; then
        set_snell_version 5
        return
    fi
    info '请选择要安装的 Snell 版本：'
    printf '  1) Snell v6 (%s Beta)  — PSK 派生流量特征、支持 mode/多地址监听（无 obfs / QUIC Proxy）\n' "$SNELL_V6_VERSION"
    printf '  2) Snell v5 (%s 稳定版) — 默认推荐，支持 QUIC Proxy Mode、向下兼容 v4\n' "$SNELL_V5_VERSION"
    printf '  3) Snell v4 (%s 经典版) — 兼容性最佳的旧版协议\n' "$SNELL_V4_VERSION"
    printf '请输入选项 [1/2/3 或 6/5/4，默认 5]：'
    local choice=''
    if ! read -r choice; then
        fail '没有读到版本选择。请先保存脚本再运行，或通过 --version 指定版本。'
    fi
    case ${choice:-5} in
        1|6|v6) set_snell_version 6 ;;
        2|5|v5) set_snell_version 5 ;;
        3|4|v4) set_snell_version 4 ;;
        *) fail "无效的版本选项：$choice" ;;
    esac
    if [[ -n $CLI_MODE && $SNELL_MAJOR != 6 ]]; then
        fail '只有 Snell v6 支持 --mode 参数。'
    fi
}

select_v6_mode() {
    [[ $SNELL_MAJOR == 6 ]] || return 0
    if [[ -n $CLI_MODE ]]; then
        SNELL_MODE=$CLI_MODE
        return 0
    fi
    # Reinstall preserves existing mode unless overridden via --mode.
    [[ $REUSE_CONFIG == 0 && $AUTO_YES == 0 ]] || return 0
    info '请选择 Snell v6 传输模式（mode）：'
    printf '  1) default     — 启用加密与 PSK 派生混淆（默认推荐）\n'
    printf '  2) unshaped    — 仅使用 AES 加密，关闭混淆（吞吐提升约 10%%）\n'
    printf '  3) unsafe-raw  — 明文转发，关闭加密与混淆（仅限安全内网/外层隧道）\n'
    printf '请输入选项 [1/2/3，默认 1]：'
    local mchoice=''
    if ! read -r mchoice; then
        fail '没有读到传输模式选择。'
    fi
    case ${mchoice:-1} in
        1|default) SNELL_MODE=default ;;
        2|unshaped) SNELL_MODE=unshaped ;;
        3|unsafe-raw) SNELL_MODE=unsafe-raw ;;
        *) fail "无效的传输模式：$mchoice" ;;
    esac
}

detect_platform() {
    local os_release=${OS_RELEASE_FILE:-/etc/os-release}
    local systemd_run=${SYSTEMD_RUN_DIR:-/run/systemd/system}
    local openrc_run=${OPENRC_RUN_DIR:-/run/openrc}
    [[ -r $os_release ]] || fail '无法识别系统。'
    local ID='' VERSION_ID='' major='' minor='' rest=''
    # shellcheck disable=SC1090
    . "$os_release"
    OS_ID=${ID:-}
    case ${OS_ID}:${VERSION_ID:-} in
        debian:*)
            major=${VERSION_ID%%.*}
            if ! [[ $major =~ ^[0-9]+$ ]] || (( major < 11 )); then
                fail '需要 Debian 11 或更新版本。'
            fi
            OS_FAMILY=debian
            PKG_MGR=apt
            ;;
        ubuntu:*)
            major=${VERSION_ID%%.*}
            if ! [[ $major =~ ^[0-9]+$ ]] || (( major < 22 )); then
                fail '需要 Ubuntu 22.04 或更新版本。'
            fi
            OS_FAMILY=debian
            PKG_MGR=apt
            ;;
        almalinux:*)
            major=${VERSION_ID%%.*}
            if ! [[ $major =~ ^[0-9]+$ ]] || (( major < 8 )); then
                fail '需要 AlmaLinux 8 或更新版本。'
            fi
            OS_FAMILY=rhel
            PKG_MGR=dnf
            ;;
        rocky:*)
            major=${VERSION_ID%%.*}
            if ! [[ $major =~ ^[0-9]+$ ]] || (( major < 8 )); then
                fail '需要 Rocky Linux 8 或更新版本。'
            fi
            OS_FAMILY=rhel
            PKG_MGR=dnf
            ;;
        centos:*)
            major=${VERSION_ID%%.*}
            if ! [[ $major =~ ^[0-9]+$ ]] || (( major < 9 )); then
                fail '需要 CentOS Stream 9 或更新版本。'
            fi
            OS_FAMILY=rhel
            PKG_MGR=dnf
            ;;
        alpine:*)
            major=${VERSION_ID%%.*}
            rest=${VERSION_ID#*.}
            minor=${rest%%.*}
            minor=${minor%%[!0-9]*}
            if ! [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || ! (( major > 3 || (major == 3 && minor >= 16) )); then
                fail '需要 Alpine Linux 3.16 或更新版本。'
            fi
            OS_FAMILY=alpine
            PKG_MGR=apk
            ;;
        *)
            fail '仅支持 Debian 11+、Ubuntu 22.04+、AlmaLinux 8+、Rocky Linux 8+、CentOS Stream 9+、Alpine Linux 3.16+。'
            ;;
    esac

    if [[ $OS_FAMILY == alpine ]]; then
        if [[ -d $openrc_run ]] && command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
            INIT_SYS=openrc
            SERVICE_FILE=$OPENRC_INIT
        elif [[ -d $systemd_run ]] && command -v systemctl >/dev/null 2>&1; then
            INIT_SYS=systemd
            SERVICE_FILE=$UNIT
        else
            fail '需要使用 OpenRC 的 Alpine Linux VPS，不支持普通 Docker 容器。'
        fi
    else
        if ! [[ -d $systemd_run ]] || ! command -v systemctl >/dev/null 2>&1; then
            fail '需要使用 systemd 的 VPS，不支持普通 Docker 容器。'
        fi
        INIT_SYS=systemd
        SERVICE_FILE=$UNIT
    fi
}

install_dependencies() {
    case $PKG_MGR in
        apt)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                ca-certificates curl unzip openssl iproute2 procps util-linux
            ;;
        dnf)
            local dnf_cmd=dnf
            command -v dnf >/dev/null 2>&1 || dnf_cmd=yum
            local pkgs=(ca-certificates unzip openssl iproute procps-ng util-linux shadow-utils)
            if ! command -v curl >/dev/null 2>&1; then
                pkgs+=(curl)
            fi
            "$dnf_cmd" install -y "${pkgs[@]}"
            ;;
        apk)
            apk add --no-cache \
                bash ca-certificates curl unzip openssl iproute2-ss procps-ng util-linux gcompat libstdc++
            ;;
        *)
            fail "不支持的包管理器：$PKG_MGR"
            ;;
    esac
}

iptables_is_filtering() {
    local ipt_cmd=$1 rules
    command -v "$ipt_cmd" >/dev/null 2>&1 || return 1
    rules=$("$ipt_cmd" -S INPUT 2>/dev/null) || return 1
    grep -qE '^-P INPUT (DROP|REJECT)$|-j (DROP|REJECT)([[:space:]]|$)' <<< "$rules"
}

persist_iptables() {
    local persisted=0
    if command -v netfilter-persistent >/dev/null 2>&1; then
        if netfilter-persistent save >/dev/null 2>&1; then
            persisted=1
        fi
        if [[ $INIT_SYS == systemd ]] && command -v systemctl >/dev/null 2>&1; then
            systemctl enable netfilter-persistent >/dev/null 2>&1 || true
        fi
    elif [[ $OS_FAMILY == alpine ]]; then
        if [[ -x /etc/init.d/iptables ]] && rc-service iptables save >/dev/null 2>&1; then
            rc-update add iptables default >/dev/null 2>&1 || true
            persisted=1
        elif command -v iptables-save >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
            iptables-save > /etc/iptables/rules-save 2>/dev/null && persisted=1
        fi
        if command -v ip6tables-save >/dev/null 2>&1 && [[ -x /etc/init.d/ip6tables ]]; then
            rc-service ip6tables save >/dev/null 2>&1 || true
            rc-update add ip6tables default >/dev/null 2>&1 || true
        fi
    elif [[ $OS_FAMILY == debian ]]; then
        if [[ -d /etc/iptables || -f /etc/iptables/rules.v4 ]]; then
            mkdir -p /etc/iptables
            if [[ -f /etc/iptables/rules.v4 ]]; then
                install -d -m 700 /var/backups/snell
                cp -a -- /etc/iptables/rules.v4 "/var/backups/snell/rules.v4.$(date +%s)" 2>/dev/null || true
            fi
            if iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
                persisted=1
            fi
            if command -v ip6tables-save >/dev/null 2>&1; then
                ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            fi
        elif command -v apt-get >/dev/null 2>&1 && command -v debconf-set-selections >/dev/null 2>&1; then
            printf 'iptables-persistent iptables-persistent/autosave_v4 boolean true\n' | debconf-set-selections
            printf 'iptables-persistent iptables-persistent/autosave_v6 boolean true\n' | debconf-set-selections
            if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iptables-persistent >/dev/null 2>&1; then
                if command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1; then
                    systemctl enable netfilter-persistent >/dev/null 2>&1 || true
                    persisted=1
                fi
            fi
        fi
    elif [[ $OS_FAMILY == rhel ]]; then
        if [[ -d /etc/sysconfig ]]; then
            if [[ -f /etc/sysconfig/iptables ]]; then
                install -d -m 700 /var/backups/snell
                cp -a -- /etc/sysconfig/iptables "/var/backups/snell/iptables.$(date +%s)" 2>/dev/null || true
            fi
            if iptables-save > /etc/sysconfig/iptables 2>/dev/null; then
                persisted=1
                if command -v systemctl >/dev/null 2>&1; then
                    local ipt_units
                    ipt_units=$(systemctl list-unit-files --no-legend --no-pager 'iptables*' 2>/dev/null || true)
                    if grep -q '^iptables\.service' <<< "$ipt_units"; then
                        systemctl enable iptables >/dev/null 2>&1 || true
                    fi
                fi
            fi
        fi
    fi
    [[ $persisted == 1 ]]
}

nft_blocking_input_chains() {
    local ruleset
    ruleset=$(nft list ruleset 2>/dev/null) || return 0
    awk '
        /^[[:space:]]*table[[:space:]]+/ {
            fam = $2; tbl = $3; gsub(/\{.*/, "", tbl); ch = ""; is_in = 0; blocks = 0; next
        }
        /^[[:space:]]*chain[[:space:]]+/ {
            ch = $2; gsub(/\{.*/, "", ch); is_in = 0; blocks = 0; next
        }
        ch != "" && /hook[[:space:]]+input([[:space:]]|;|$)/ { is_in = 1 }
        ch != "" && (/policy[[:space:]]+drop/ || /(^|[[:space:];])(drop|reject)([[:space:];]|$)/) { blocks = 1 }
        ch != "" && /^[[:space:]]*\}/ {
            if (is_in && blocks) print fam, tbl, ch
            ch = ""; is_in = 0; blocks = 0
        }
    ' <<< "$ruleset"
}

persist_nftables() {
    local conf_path=''
    case $OS_FAMILY in
        debian) conf_path=/etc/nftables.conf ;;
        rhel) conf_path=/etc/sysconfig/nftables.conf ;;
        alpine) conf_path=/etc/nftables.nft ;;
    esac
    [[ -n $conf_path ]] || return 1

    if [[ $OS_FAMILY == alpine && -x /etc/init.d/nftables ]]; then
        if rc-service nftables save >/dev/null 2>&1; then
            rc-update add nftables default >/dev/null 2>&1 || true
            return 0
        fi
    fi

    local ruleset tmp
    ruleset=$(nft list ruleset 2>/dev/null) || return 1
    [[ -n $ruleset ]] || return 1
    if [[ -f $conf_path ]]; then
        install -d -m 700 /var/backups/snell
        cp -a -- "$conf_path" "/var/backups/snell/${conf_path##*/}.$(date +%s)" 2>/dev/null || true
    fi
    tmp=$(mktemp)
    {
        printf '#!/usr/sbin/nft -f\nflush ruleset\n\n%s\n' "$ruleset"
    } > "$tmp"
    chmod 644 "$tmp"
    mv -f -- "$tmp" "$conf_path"
    if [[ $INIT_SYS == systemd ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl enable nftables >/dev/null 2>&1 || true
    elif [[ $INIT_SYS == openrc ]] && command -v rc-update >/dev/null 2>&1; then
        rc-update add nftables default >/dev/null 2>&1 || true
    fi
    return 0
}

configure_firewall() {
    local port=$1 firewall_found=0
    local ufw_out=''
    if command -v ufw >/dev/null 2>&1; then
        ufw_out=$(ufw status 2>/dev/null || true)
        if grep -q '^Status: active' <<< "$ufw_out"; then
            firewall_found=1
            if ufw allow "$port/tcp" >/dev/null && ufw allow "$port/udp" >/dev/null; then
                FIREWALL_STATUS="UFW 已放行 ${port}/TCP+UDP（重启后继续生效）"
            else
                FIREWALL_STATUS="UFW 放行未全部成功，请手动放行 ${port}/TCP+UDP"
                info "警告：UFW 放行未全部成功，请手动放行 ${port}/TCP 和 UDP。"
            fi
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall_found=1
        # Apply to every active zone, or the default zone when none is active.
        local zones zone fw_ok=1
        if ! zones=$(firewall-cmd --get-active-zones | awk '/^[^[:space:]]/ {print $1}'); then
            zones=''
            info '警告：无法查询 firewalld 活动区域，将尝试默认区域。'
        fi
        if [[ -z $zones ]]; then
            if ! zones=$(firewall-cmd --get-default-zone); then
                zones=''
                fw_ok=0
                info "警告：无法查询 firewalld 默认区域，请手动放行 ${port}/TCP 和 UDP。"
            fi
        fi
        for zone in $zones; do
            if ! firewall-cmd --zone="$zone" --add-port="$port/tcp" --add-port="$port/udp" >/dev/null || \
                ! firewall-cmd --permanent --zone="$zone" --add-port="$port/tcp" --add-port="$port/udp" >/dev/null; then
                fw_ok=0
                info "警告：firewalld 区域 ${zone} 放行未全部成功，请手动检查。"
            fi
        done
        if [[ $fw_ok == 1 ]]; then
            FIREWALL_STATUS="firewalld 已放行 ${port}/TCP+UDP（已写入 permanent 持久化）"
        else
            FIREWALL_STATUS="firewalld 部分区域放行失败，请手动检查 ${port}/TCP+UDP"
        fi
    fi

    # If neither UFW nor firewalld is active, handle iptables / nftables directly and persist rules.
    if [[ $firewall_found == 0 ]]; then
        local ipt_handled=0 nft_handled=0
        if iptables_is_filtering iptables; then
            firewall_found=1
            ipt_handled=1
            local ipt_ok=1
            if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT || ipt_ok=0
            fi
            if ! iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
                iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT || ipt_ok=0
            fi
            if iptables_is_filtering ip6tables; then
                if ! ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                    ip6tables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT || ipt_ok=0
                fi
                if ! ip6tables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
                    ip6tables -I INPUT 1 -p udp --dport "$port" -j ACCEPT || ipt_ok=0
                fi
            fi
            if [[ $ipt_ok == 1 ]]; then
                if persist_iptables; then
                    FIREWALL_STATUS="iptables 已放行 ${port}/TCP+UDP（已持久化保存）"
                else
                    FIREWALL_STATUS="iptables 已放行 ${port}/TCP+UDP（未检测到持久化服务，重启后可能需重新放行）"
                    info "警告：已临时放行 iptables ${port}/TCP+UDP，但未能自动持久化；建议安装 netfilter-persistent。"
                fi
            else
                FIREWALL_STATUS="iptables 放行失败，请手动放行 ${port}/TCP+UDP"
                info "警告：iptables 放行未成功，请手动放行 ${port}/TCP 和 UDP。"
            fi
        fi

        # Handle native nftables chains (skip if iptables already handled ip/ip6 filter).
        if [[ $ipt_handled == 0 ]] && command -v nft >/dev/null 2>&1; then
            local chains fam tbl ch nft_ok=1
            chains=$(nft_blocking_input_chains)
            if [[ -n $chains ]]; then
                firewall_found=1
                nft_handled=1
                while read -r fam tbl ch; do
                    [[ -n $fam && -n $tbl && -n $ch ]] || continue
                    local existing_ch
                    existing_ch=$(nft list chain "$fam" "$tbl" "$ch" 2>/dev/null || true)
                    if ! grep -Fq "snell-auto-${port}-tcp" <<< "$existing_ch"; then
                        nft insert rule "$fam" "$tbl" "$ch" tcp dport "$port" accept comment "\"snell-auto-${port}-tcp\"" || nft_ok=0
                    fi
                    if ! grep -Fq "snell-auto-${port}-udp" <<< "$existing_ch"; then
                        nft insert rule "$fam" "$tbl" "$ch" udp dport "$port" accept comment "\"snell-auto-${port}-udp\"" || nft_ok=0
                    fi
                done <<< "$chains"
                if [[ $nft_ok == 1 ]]; then
                    if persist_nftables; then
                        FIREWALL_STATUS="nftables 已放行 ${port}/TCP+UDP（已持久化保存）"
                    else
                        FIREWALL_STATUS="nftables 已放行 ${port}/TCP+UDP（请确认 nftables 配置已保存）"
                        info "警告：已放行 nftables ${port}/TCP+UDP，但自动持久化配置未成功，请手动检查。"
                    fi
                else
                    FIREWALL_STATUS="nftables 放行失败，请手动放行 ${port}/TCP+UDP"
                    info "警告：nftables 放行未成功，请手动放行 ${port}/TCP 和 UDP。"
                fi
            fi
        fi

        if [[ $firewall_found == 0 && $ipt_handled == 0 && $nft_handled == 0 ]]; then
            FIREWALL_STATUS="本机未启用拦截规则（默认放行）；仍需在云厂商安全组放行 ${port}/TCP+UDP"
            info '本机没有检测到拦截型防火墙（UFW/firewalld/iptables/nftables）；系统内端口已处于放行状态。'
        fi
    fi
}

confirm_or_clean_existing() {
    if [[ $DO_UNINSTALL == 1 ]]; then
        scan_existing_snell
        if [[ $FOUND_ANY == 0 ]]; then
            info '未检测到已安装的 Snell，无需卸载。'
            exit 0
        fi
        info '检测到以下 Snell 相关文件/服务：'
        print_found_summary
        if [[ $AUTO_YES == 0 ]]; then
            printf '\n确认备份并彻底卸载上述 Snell？[yes/no，默认 no]：'
            local ans=''
            if ! read -r ans; then fail '没有读到确认。'; fi
            case $ans in
                yes|YES|Yes|y|Y|on|ON) ;;
                *) info '已取消卸载。'; exit 0 ;;
            esac
        fi
        uninstall_existing_snell
        info 'Snell 已备份并卸载完成。'
        exit 0
    fi

    if [[ $REINSTALL == 0 ]]; then
        REINSTALL_MODE=none
        return 0
    fi

    if [[ $FORCE_CLEAN == 1 ]]; then
        REINSTALL_MODE=clean
        info '已指定 --clean：将在下载完成后备份并彻底卸载原有 Snell，再全新安装。'
        return 0
    fi

    if [[ $FOUND_STANDARD == 1 ]]; then
        if [[ $AUTO_YES == 1 ]]; then
            REINSTALL_MODE=reuse
            return 0
        fi
        info "发现本机已有标准安装的 Snell，目标版本：v${SNELL_MAJOR}（${SNELL_VERSION}）。"
        printf '请选择处理方式：\n'
        printf '  1) 保留原端口和密钥，直接升级/重装（推荐）\n'
        printf '  2) 备份后彻底卸载旧版，重新生成端口和密钥全新安装\n'
        printf '  0) 取消退出\n'
        printf '请输入选项 [1/2/0，默认 1]：'
        local rchoice=''
        if ! read -r rchoice; then fail '没有读到选择。请先保存脚本再运行。'; fi
        case ${rchoice:-1} in
            1) REINSTALL_MODE=reuse ;;
            2) REINSTALL_MODE=clean ;;
            0) info '已取消，没有修改任何内容。'; exit 0 ;;
            *) fail "无效的选项：$rchoice" ;;
        esac
    else
        REINSTALL_MODE=clean
        info '检测到本机已有其他方式安装或残留的 Snell：'
        print_found_summary
        if [[ $AUTO_YES == 1 ]]; then
            info '已按 --yes 自动确认：将在下载新版本后备份并卸载上述旧 Snell，再全新安装。'
        else
            printf '\n直接覆盖可能导致端口或服务冲突。\n是否备份旧版后彻底卸载，再重新全新安装 Snell v%s？[yes/no，默认 no]：' "$SNELL_MAJOR"
            local ans=''
            if ! read -r ans; then fail '没有读到确认。'; fi
            case $ans in
                yes|YES|Yes|y|Y|on|ON) ;;
                *) info '已取消，未作任何修改。'; exit 0 ;;
            esac
        fi
    fi
}

main() {
    parse_args "$@"
    [[ $(uname -s) == Linux ]] || fail '请在 Linux VPS 上运行，不要在 Mac 上运行。'
    [[ $EUID == 0 ]] || fail '请使用 sudo sh install-snell.sh（或 root 执行）运行。'
    detect_platform
    command -v flock >/dev/null 2>&1 || fail '缺少 flock（util-linux）。'
    exec 9>/run/lock/snell-auto-install.lock
    flock -n 9 || fail '已有一个安装程序正在运行。'

    scan_existing_snell
    if [[ $FOUND_ANY == 1 ]] || existing_install; then
        REINSTALL=1
    fi

    if [[ $DO_UNINSTALL == 1 ]]; then
        confirm_or_clean_existing
        return 0
    fi

    local arch
    case $(uname -m) in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) fail '仅支持 x86_64 和 ARM64 VPS。' ;;
    esac

    select_snell_version
    confirm_or_clean_existing

    if [[ $REINSTALL_MODE == reuse ]]; then
        info "将保留端口、密钥及兼容配置覆盖重装为 Snell v${SNELL_MAJOR}（${SNELL_VERSION}）；重装时连接会短暂中断。"
    elif [[ $REINSTALL_MODE == clean ]]; then
        info "将在备份并卸载原有 Snell 后，全新安装 Snell v${SNELL_MAJOR}（${SNELL_VERSION}）。"
    else
        info "将安装 Snell v${SNELL_MAJOR}（${SNELL_VERSION}）：自动端口、随机密钥、自动开防火墙并开机启动。"
    fi

    if [[ $AUTO_YES == 0 && $REINSTALL == 0 ]]; then
        printf '是否继续？[yes/no，默认 no]：'
        local answer
        if ! read -r answer; then fail '没有读到确认。请先保存脚本，再直接运行。'; fi
        case $answer in
            yes|YES|Yes|y|Y|on|ON) ;;
            *) info '已取消，没有安装。'; return ;;
        esac
    fi

    info '1/5 安装必要工具……'
    install_dependencies

    local public_ip='' endpoint candidate
    for endpoint in https://api.ipify.org https://ipv4.icanhazip.com; do
        candidate=$(curl -4 -fsS --connect-timeout 5 --max-time 12 "$endpoint" 2>/dev/null) || continue
        if valid_ipv4 "$candidate"; then public_ip=$candidate; break; fi
    done
    [[ -n $public_ip ]] || fail '未能检测公网 IPv4；本版暂不支持纯 IPv6 VPS。'

    if [[ $REINSTALL_MODE == reuse ]]; then
        REINSTALL_ALLOW_CLEAN_FALLBACK=1
        REINSTALL_REJECT_REASON=''
        local prep_rc=0
        prepare_reinstall || prep_rc=$?
        REINSTALL_ALLOW_CLEAN_FALLBACK=0
        if (( prep_rc == 2 )); then
            info "保留配置检查未通过：${REINSTALL_REJECT_REASON}"
            REUSE_CONFIG=0
            REUSE_UNIT=0
            OLD_PORT=''
            OLD_PSK=''
            NODE_EXTRA=''
            if [[ $AUTO_YES == 1 ]]; then
                REINSTALL_MODE=clean
                info '已按 --yes 自动切换为：备份并彻底卸载旧版后全新安装。'
            else
                printf '原安装无法直接无损继承，是否改为备份并卸载旧版后全新安装？[yes/no，默认 no]：'
                local fallback_ans=''
                if ! read -r fallback_ans; then fail '没有读到确认。'; fi
                case $fallback_ans in
                    yes|YES|Yes|y|Y|on|ON) REINSTALL_MODE=clean ;;
                    *) info '已取消，未修改任何内容。'; return 0 ;;
                esac
            fi
        elif (( prep_rc != 0 )); then
            exit "$prep_rc"
        fi
    elif [[ $REINSTALL == 0 ]] && existing_install; then
        fail '确认后有其他程序安装了 Snell，请重新运行。'
    fi

    if [[ $REUSE_CONFIG == 0 ]]; then
        select_v6_mode
        if [[ $SNELL_MAJOR == 6 && $SNELL_MODE != default ]]; then
            NODE_EXTRA=", mode=${SNELL_MODE}"
        fi
    fi

    local port=$OLD_PORT n used
    used=$(ss -H -lntu)
    for ((n=0; n<100 && ${#port}==0; n++)); do
        candidate=$((20000 + $(openssl rand -hex 2 | awk '{print "0x" $0}') % 30000))
        if ! awk -v p="$candidate" '$5 ~ (":" p "$") {found=1} END {exit !found}' <<< "$used"; then
            port=$candidate
            break
        fi
    done
    [[ -n $port ]] || fail '未能找到空闲端口。'
    local psk=$OLD_PSK
    if [[ -z $psk ]]; then psk=$(openssl rand -hex 16); fi

    info "2/5 从 Surge 官方下载 Snell ${SNELL_VERSION}……"
    WORK=$(mktemp -d)
    curl --proto '=https' --tlsv1.2 -fSL --retry 2 --connect-timeout 10 --max-time 180 \
        "https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${arch}.zip" -o "$WORK/snell.zip"
    unzip -p "$WORK/snell.zip" snell-server > "$WORK/snell-server"
    [[ -s $WORK/snell-server ]] || fail '下载的安装包中没有有效的 snell-server。'
    chmod 755 "$WORK/snell-server"

    info '3/5 创建配置与后台服务……'
    if [[ $REINSTALL_MODE == clean ]]; then
        scan_existing_snell
        uninstall_existing_snell
    elif [[ $REINSTALL_MODE == reuse ]]; then
        # Revalidate and snapshot only after download, before stopping the old service.
        prepare_reinstall
        [[ $port == "$OLD_PORT" && $psk == "$OLD_PSK" || $REUSE_CONFIG == 0 ]] || fail '下载期间原配置发生变化，请重新运行。'
        backup_install
    elif existing_install; then
        fail '下载期间发现其他 Snell 安装，请重新运行。'
    fi

    if [[ $REUSE_UNIT == 0 ]]; then
        if getent passwd snell-auto >/dev/null || getent group snell-auto >/dev/null; then
            fail 'snell-auto 账户已存在但没有可复用的标准服务，请先检查账户用途。'
        fi
    fi
    CREATED=1
    if [[ $REINSTALL == 1 ]]; then
        if [[ $REUSE_UNIT == 1 ]]; then svc_stop; fi
        if pgrep -x snell-server >/dev/null; then fail '仍有其他 Snell 实例运行，未强制结束；请先检查。'; fi
    fi
    if [[ $REUSE_UNIT == 0 ]]; then
        ensure_service_user
        USER_CREATED=1
    fi
    create_file "$WORK/snell-server" "$BIN" 755
    if [[ $REUSE_CONFIG == 0 ]]; then
        if [[ ! -d $CONF_DIR ]]; then
            mkdir -m 750 -- "$CONF_DIR"
            CONF_CREATED=1
            chown root:snell-auto "$CONF_DIR"
            restore_selinux_context "$CONF_DIR"
        fi
        {
            printf '[snell-server]\nlisten = 0.0.0.0:%s\npsk = %s\n' "$port" "$psk"
            if [[ $SNELL_MAJOR == 6 && $SNELL_MODE != default ]]; then
                printf 'mode = %s\n' "$SNELL_MODE"
            fi
        } > "$WORK/snell-server.conf"
        create_file "$WORK/snell-server.conf" "$CONF_DIR/snell-server.conf" 640
        chown root:snell-auto "$CONF_DIR/snell-server.conf"
        restore_selinux_context "$CONF_DIR/snell-server.conf"
    elif [[ $REMOVE_OBFS == 1 || $UPDATE_MODE == 1 ]]; then
        rewrite_config_for_v6 "$CONF_DIR/snell-server.conf" "$WORK/snell-server.conf" "$REMOVE_OBFS" "$UPDATE_MODE" "$SNELL_MODE"
        create_file "$WORK/snell-server.conf" "$CONF_DIR/snell-server.conf" 640
        chown root:snell-auto "$CONF_DIR/snell-server.conf"
        restore_selinux_context "$CONF_DIR/snell-server.conf"
    fi
    write_service_definition "$WORK/snell.service-def"
    if [[ $REUSE_UNIT == 0 ]]; then
        local svc_mode=644
        [[ $INIT_SYS == openrc ]] && svc_mode=755
        create_file "$WORK/snell.service-def" "$SERVICE_FILE" "$svc_mode"
    fi
    svc_reload
    svc_start

    local ready=0 ss_out ss_pid_out
    for ((n=0; n<15; n++)); do
        ss_out=$(ss -H -ltn "sport = :$port" 2>/dev/null || true)
        if svc_is_active && grep -q . <<< "$ss_out"; then
            ss_pid_out=$(ss -H -ltnp "sport = :$port" 2>/dev/null || true)
            if grep -q snell-server <<< "$ss_pid_out" || pgrep -f "$BIN" >/dev/null 2>&1; then
                ready=1
                break
            fi
        fi
        sleep 1
    done
    if [[ $ready != 1 ]]; then
        svc_show_logs
        fail '服务未能正常监听；请查看上面的错误信息。'
    fi
    printf '我的VPS = snell, %s, %s, psk=%s, version=%s%s\n' "$public_ip" "$port" "$psk" "$SNELL_MAJOR" "$NODE_EXTRA" > "$WORK/surge-proxy.txt"
    create_file "$WORK/surge-proxy.txt" "$CONF_DIR/surge-proxy.txt" 600
    if [[ $REUSE_UNIT == 0 ]]; then
        ENABLE_CHANGED=1
        svc_enable
    fi
    # Service is now valid. Firewall failures must not destroy a working installation.
    DONE=1

    info '4/5 开放并持久化防火墙端口……'
    configure_firewall "$port"

    info '5/5 安装流程完成。'
    show_result "$public_ip" "$port" "$psk"
}

main "$@"
