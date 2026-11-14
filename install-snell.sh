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

SNELL_MAJOR=5
SNELL_VERSION=$SNELL_V5_VERSION
SNELL_MODE=default
CLI_VERSION=''
CLI_MODE=''
AUTO_YES=0

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
DONE=0
REINSTALL=0
BACKUP=''
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

info() { printf '\n%s\n' "$*"; }
fail() { printf '\n错误：%s\n' "$*" >&2; exit 1; }

cleanup() {
    local rc=$?
    trap - EXIT ERR
    set +e
    if [[ $CREATED == 1 && $DONE == 0 ]]; then
        local file i restore_failed=0
        svc_stop >/dev/null 2>&1
        if (( ${#OWNED_FILES[@]} > 0 )); then
            for ((i=0; i<${#OWNED_FILES[@]}; i++)); do
                file=${OWNED_FILES[$i]}
                if [[ -e $file || -L $file ]]; then
                    if [[ -L $file || $(file_identity "$file") != "${OWNED_IDS[$i]}" ]]; then
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

# Service manager abstraction (systemd / OpenRC).
svc_exists() {
    if [[ $INIT_SYS == openrc ]]; then
        [[ -e $OPENRC_INIT || -L $OPENRC_INIT ]] && return 0
        command -v rc-service >/dev/null 2>&1 && rc-service -e snell >/dev/null 2>&1 && return 0
        return 1
    fi
    [[ $(systemctl show snell.service -p LoadState --value) != not-found ]] && return 0
    systemctl list-unit-files --no-legend --no-pager | grep -qi snell && return 0
    return 1
}

svc_loaded() {
    if [[ $INIT_SYS == openrc ]]; then
        [[ -e $OPENRC_INIT || -L $OPENRC_INIT ]]
        return
    fi
    [[ $(systemctl show snell.service -p LoadState --value) != not-found ]]
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
        if rc-update show default 2>/dev/null | awk '{print $1}' | grep -qx snell; then
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
    exec_start=$(systemctl show snell.service -p ExecStart --value)
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
        adduser -S -D -H -h /nonexistent -s /sbin/nologin -G snell-auto snell-auto
    else
        local nologin=/usr/sbin/nologin
        [[ -x $nologin ]] || nologin=/sbin/nologin
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell "$nologin" snell-auto
    fi
}

remove_service_user() {
    if [[ $OS_FAMILY == alpine ]]; then
        deluser snell-auto >/dev/null 2>&1 || true
        delgroup snell-auto >/dev/null 2>&1 || true
    else
        userdel snell-auto >/dev/null 2>&1 || true
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

parse_listen_port() {
    local listen=$1 item port='' item_port
    if [[ $listen == *,* ]]; then
        if [[ $SNELL_MAJOR != 6 ]]; then
            fail '原配置使用了多地址 listen，仅 Snell v6 支持；请先修改 listen 后再安装 v4/v5。'
        fi
        local items
        IFS=',' read -r -a items <<< "$listen"
        for item in "${items[@]}"; do
            item=${item#"${item%%[![:space:]]*}"}
            item=${item%"${item##*[![:space:]]}"}
            [[ $item =~ ^(0\.0\.0\.0|\[::\]):([0-9]{1,5})$ ]] || \
                fail '原配置不是标准公网监听格式；未修改，请先检查 listen。'
            item_port=$((10#${BASH_REMATCH[2]}))
            (( item_port >= 1 && item_port <= 65535 )) || fail '原配置端口无效。'
            if [[ -z $port ]]; then
                port=$item_port
            elif [[ $port != "$item_port" ]]; then
                fail '原配置多地址 listen 端口不一致；未修改，请先检查 listen。'
            fi
        done
    else
        [[ $listen =~ ^(0\.0\.0\.0|\[::\]):([0-9]{1,5})$ ]] || \
            fail '原配置不是单端口公网监听格式；未修改，请先检查 listen。'
        port=$((10#${BASH_REMATCH[2]}))
        (( port >= 1 && port <= 65535 )) || fail '原配置端口无效。'
    fi
    printf '%s' "$port"
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
    local file listen obfs old_mode dns_pref answer
    REUSE_CONFIG=0
    REUSE_UNIT=0
    OLD_PORT=''
    OLD_PSK=''
    NODE_EXTRA=''
    REMOVE_OBFS=0
    UPDATE_MODE=0
    [[ ! -L $CONF_DIR ]] || fail '配置目录是符号链接；请先确认实际安装路径。'
    [[ ! -e $CONF_DIR || -d $CONF_DIR ]] || fail '配置目录位置被普通文件占用。'
    for file in "$BIN" "$SERVICE_FILE" "$CONF_DIR/snell-server.conf" "$CONF_DIR/surge-proxy.txt"; do
        [[ ! -L $file && ( ! -e $file || -f $file ) ]] || fail "不能自动覆盖符号链接或特殊文件：$file"
    done
    if [[ -f $CONF_DIR/snell-server.conf ]]; then
        listen=$(config_value listen)
        OLD_PSK=$(config_value psk)
        OLD_PORT=$(parse_listen_port "$listen")
        [[ -n $OLD_PSK && ! $OLD_PSK =~ [[:space:],\;\#] ]] || fail '原密钥格式无法直接输出到 Surge；未修改。'
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
                    *) fail "原配置的 mode 无效：$old_mode" ;;
                esac
            fi
            if [[ $SNELL_MODE != default ]]; then
                NODE_EXTRA=", mode=${SNELL_MODE}"
            fi
        else
            [[ -z $old_mode ]] || fail "原配置包含 Snell v6 专用的 mode=${old_mode}，不适用于 Snell v${SNELL_MAJOR}；请先移除后再降级。"
            [[ -z $dns_pref ]] || fail "原配置包含 Snell v6 专用的 dns-ip-preference=${dns_pref}，不适用于 Snell v${SNELL_MAJOR}；请先移除后再降级。"
            case $obfs in
                ''|off|false) ;;
                http) NODE_EXTRA=', obfs=http' ;;
                *) fail "原配置的混淆方式不适用于 Snell v${SNELL_MAJOR}：$obfs" ;;
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
        (svc_exec_matches && [[ $REUSE_CONFIG == 1 ]]) || \
            fail '已有服务不使用标准程序/配置路径，不能直接覆盖；未修改原服务。'
        REUSE_UNIT=1
    fi
    [[ $REUSE_CONFIG == 0 || $REUSE_UNIT == 1 ]] || fail '原配置存在但原服务缺失，请先恢复服务文件后重装。'
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
    printf '\n%s━━━━━━━━━━ 复制下面这行到 Surge ━━━━━━━━━━%s\n\n' "$cyan" "$reset"
    # A single, undecorated node line: safe to select and paste into [Proxy].
    printf '%s我的VPS = snell, %s, %s, psk=%s, version=%s%s%s\n' "$bold" "$public_ip" "$port" "$psk" "$SNELL_MAJOR" "$NODE_EXTRA" "$reset"
    printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "$cyan" "$reset"
    printf '  添加位置：Surge 配置 → [Proxy]\n'
    if [[ $SNELL_MAJOR == 5 ]]; then
        printf '  %s安全组需放行：%s / TCP + UDP（v5 QUIC Proxy 需要 UDP）%s\n' "$yellow" "$port" "$reset"
    else
        printf '  %s安全组需放行：%s / TCP + UDP%s\n' "$yellow" "$port" "$reset"
    fi
    if [[ $SNELL_MAJOR == 6 ]]; then
        printf '  %s提示：Snell v6 处于 Beta 阶段，需同步使用支持 v6 的 Surge 客户端。%s\n' "$yellow" "$reset"
    fi
    printf '  配置已保存：%s/surge-proxy.txt\n' "$CONF_DIR"
    if [[ -n $BACKUP ]]; then printf '  原安装备份：%s\n' "$BACKUP"; fi
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
  -y, --yes                          跳过交互确认（重装升级 v6 时将自动移除 obfs）
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

configure_firewall() {
    local port=$1 firewall_found=0
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        firewall_found=1
        if ! ufw allow "$port/tcp" || ! ufw allow "$port/udp"; then
            info "警告：UFW 放行未全部成功，请手动放行 ${port}/TCP 和 UDP。"
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall_found=1
        # Apply to every active zone, or the default zone when none is active.
        local zones zone
        if ! zones=$(firewall-cmd --get-active-zones | awk '/^[^[:space:]]/ {print $1}'); then
            zones=''
            info '警告：无法查询 firewalld 活动区域，将尝试默认区域。'
        fi
        if [[ -z $zones ]]; then
            if ! zones=$(firewall-cmd --get-default-zone); then
                zones=''
                info "警告：无法查询 firewalld 默认区域，请手动放行 ${port}/TCP 和 UDP。"
            fi
        fi
        for zone in $zones; do
            if ! firewall-cmd --zone="$zone" --add-port="$port/tcp" --add-port="$port/udp" || \
                ! firewall-cmd --permanent --zone="$zone" --add-port="$port/tcp" --add-port="$port/udp"; then
                info "警告：firewalld 区域 ${zone} 放行未全部成功，请手动检查。"
            fi
        done
    fi
    if [[ $firewall_found == 0 ]]; then
        info '没有检测到启用的 UFW/firewalld；不改动自定义 nftables/iptables/awall 规则。'
    fi
}

main() {
    parse_args "$@"
    [[ $(uname -s) == Linux ]] || fail '请在 Linux VPS 上运行，不要在 Mac 上运行。'
    [[ $EUID == 0 ]] || fail '请使用 sudo bash install-snell.sh（或 root 执行）运行。'
    detect_platform
    command -v flock >/dev/null 2>&1 || fail '缺少 flock（util-linux）。'
    exec 9>/run/lock/snell-auto-install.lock
    flock -n 9 || fail '已有一个安装程序正在运行。'
    if existing_install; then REINSTALL=1; fi

    local arch
    case $(uname -m) in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) fail '仅支持 x86_64 和 ARM64 VPS。' ;;
    esac

    select_snell_version

    if [[ $REINSTALL == 1 ]]; then
        info "发现已有 Snell，将备份后覆盖重装为 v${SNELL_MAJOR}（${SNELL_VERSION}）。"
        info '标准安装会保留端口、密钥及兼容配置；重装时连接会短暂中断。'
    else
        info "将安装 Snell v${SNELL_MAJOR}（${SNELL_VERSION}）：自动端口、随机密钥、开机启动。"
    fi

    if [[ $AUTO_YES == 0 ]]; then
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
    if [[ $REINSTALL == 1 ]]; then
        prepare_reinstall
    elif existing_install; then
        fail '确认后有其他程序安装了 Snell，请重新运行以确认覆盖。'
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
    if [[ $REINSTALL == 1 ]]; then
        # Revalidate and snapshot only after download, before stopping the old service.
        prepare_reinstall
        [[ $port == "$OLD_PORT" && $psk == "$OLD_PSK" || $REUSE_CONFIG == 0 ]] || fail '下载期间原配置发生变化，请重新运行。'
        backup_install
    elif existing_install; then
        fail '下载期间发现其他 Snell 安装，请重新运行以确认覆盖。'
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

    local ready=0
    for ((n=0; n<15; n++)); do
        if svc_is_active && ss -H -ltn "sport = :$port" | grep -q .; then
            if ss -H -ltnp "sport = :$port" | grep -q snell-server || pgrep -f "$BIN" >/dev/null 2>&1; then
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

    info '4/5 处理防火墙……'
    configure_firewall "$port"

    info '5/5 安装流程完成。'
    show_result "$public_ip" "$port" "$psk"
}

main "$@"
