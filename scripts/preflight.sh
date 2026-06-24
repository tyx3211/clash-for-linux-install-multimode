#!/usr/bin/env bash

CLASH_BASE_DIR=${CLASH_BASE_DIR:-}
CLASH_RESOURCES_DIR=${CLASH_RESOURCES_DIR:-"${CLASH_BASE_DIR}/resources"}
KERNEL_NAME=${KERNEL_NAME:-mihomo}

_PREFLIGHT_SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE:-${(%):-%N}}")")" && pwd -P)
. "$_PREFLIGHT_SCRIPT_DIR/lib/install-state.sh"
. "$_PREFLIGHT_SCRIPT_DIR/install/archive-safe.sh"
. "$_PREFLIGHT_SCRIPT_DIR/install/dependency-downloads.sh"
. "$_PREFLIGHT_SCRIPT_DIR/install/service-render.sh"
. "$_PREFLIGHT_SCRIPT_DIR/install/rc.sh"
unset _PREFLIGHT_SCRIPT_DIR

RESOURCES_BASE_DIR=".${CLASH_RESOURCES_DIR#"$CLASH_BASE_DIR"}"

ZIP_BASE_DIR=".${CLASH_RESOURCES_DIR#"$CLASH_BASE_DIR"}/zip"

SCRIPT_BASE_DIR='scripts'
SCRIPT_INIT_DIR="${SCRIPT_BASE_DIR}/init"
SCRIPT_CMD_DIR="${SCRIPT_BASE_DIR}/cmd"
SCRIPT_CMD_FISH="${SCRIPT_CMD_DIR}/clashctl.fish"

CLASH_CMD_DIR="${CLASH_BASE_DIR}/$SCRIPT_CMD_DIR"

FILE_LOG="${CLASH_RESOURCES_DIR}/${KERNEL_NAME}.log"
FILE_PID="${CLASH_RESOURCES_DIR}/${KERNEL_NAME}.pid"
INSTALL_MARKER="${CLASH_BASE_DIR}/.clashctl-install-root"
CLASH_INSTALL_CREATED_DIR=
CLASH_INSTALL_COMPLETE=false
CLASH_INSTALL_SERVICE_TOUCHED=false
CLASH_INSTALL_SERVICE_WRITTEN=false
CLASH_INSTALL_RC_TOUCHED=false

_refresh_install_paths() {
    CLASH_RESOURCES_DIR="${CLASH_BASE_DIR}/resources"
    CLASH_CONFIG_DIR="${CLASH_BASE_DIR}/config"
    CLASH_INSTALL_STATE="${CLASH_RESOURCES_DIR}/install-state.yaml"
    CLASH_CONFIG_BASE="${CLASH_RESOURCES_DIR}/config.yaml"
    CLASH_CONFIG_MIXIN="${CLASH_CONFIG_DIR}/mixin.yaml"
    CLASH_CONFIG_SIDECAR="${CLASH_CONFIG_DIR}/clashctl.yaml"
    CLASH_CONFIG_RUNTIME="${CLASH_RESOURCES_DIR}/runtime.yaml"
    CLASH_CONFIG_TEMP="${CLASH_RESOURCES_DIR}/temp.yaml"
    CLASH_SERVICE_STATE="${CLASH_RESOURCES_DIR}/service-state.yaml"

    BIN_BASE_DIR="${CLASH_BASE_DIR}/bin"
    BIN_KERNEL="${BIN_BASE_DIR}/$KERNEL_NAME"
    BIN_YQ="${BIN_BASE_DIR}/yq"
    BIN_SUBCONVERTER_DIR="${BIN_BASE_DIR}/subconverter"
    BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
    BIN_SUBCONVERTER_START="$BIN_SUBCONVERTER"
    BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
    BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"
    BIN_SUBCONVERTER_PID="${BIN_SUBCONVERTER_DIR}/subconverter.pid"

    CLASH_PROFILES_DIR="${CLASH_RESOURCES_DIR}/profiles"
    CLASH_PROFILES_META="${CLASH_CONFIG_DIR}/subscriptions.yaml"
    CLASH_PROFILES_LOG="${CLASH_RESOURCES_DIR}/profiles.log"

    RESOURCES_BASE_DIR=".${CLASH_RESOURCES_DIR#"$CLASH_BASE_DIR"}"
    ZIP_BASE_DIR=".${CLASH_RESOURCES_DIR#"$CLASH_BASE_DIR"}/zip"
    CLASH_CMD_DIR="${CLASH_BASE_DIR}/$SCRIPT_CMD_DIR"
    FILE_LOG="${CLASH_RESOURCES_DIR}/${KERNEL_NAME}.log"
    FILE_PID="${CLASH_RESOURCES_DIR}/${KERNEL_NAME}.pid"
    INSTALL_MARKER="${CLASH_BASE_DIR}/.clashctl-install-root"
}

_normalize_sudo_install_path() {
    _is_regular_sudo || return 0

    case "$CLASH_BASE_DIR" in
    /root/)
        return 0
        ;;
    /root/*)
        local sudo_home
        sudo_home=$(awk -F: -v user="$SUDO_USER" '$1==user{print $6}' /etc/passwd)
        [ -n "$sudo_home" ] || _error_quit "无法识别 sudo 调用用户的 HOME：$SUDO_USER"
        CLASH_BASE_DIR="${sudo_home}${CLASH_BASE_DIR#/root}"
        ;;
    esac
}

_validate_init_mode() {
    [ -z "$INIT_TYPE" ] && INIT_TYPE='tmux'

    case "$INIT_TYPE" in
    tmux | nohup)
        return 0
        ;;
    systemd)
        command -v systemctl >&/dev/null || _error_quit "未检测到 systemctl，请改用 INIT_TYPE=tmux 或 INIT_TYPE=nohup"
        _is_root || _is_regular_sudo || _error_quit "INIT_TYPE=systemd 需要 root 或 sudo 执行"
        return 0
        ;;
    *)
        _error_quit "仅支持 INIT_TYPE=tmux、nohup、systemd"
        ;;
    esac
}

_validate_kernel_name() {
    _install_state_validate_kernel_name "$KERNEL_NAME" ||
        _error_quit "内核名称不安全，仅支持 mihomo、clash：$KERNEL_NAME"
}

_validate_install_path() {
    case "$CLASH_BASE_DIR" in
    "" | "/" | /root | /root/ | "$HOME" | "$HOME/" | . | .. | ./* | ../*)
        _error_quit "安装路径不安全，请在 .env 中更换 CLASH_BASE_DIR：${CLASH_BASE_DIR:-<empty>}"
        ;;
    /*)
        ;;
    *)
        _error_quit "安装路径必须是绝对路径：$CLASH_BASE_DIR"
        ;;
    esac

    case "$CLASH_BASE_DIR" in
    *[!A-Za-z0-9_./-]*)
        _error_quit "安装路径包含 shell 模板不支持的字符，请仅使用字母、数字、_、-、.、/：$CLASH_BASE_DIR"
        ;;
    esac

    case "$CLASH_BASE_DIR" in
    */../* | */.. | */./* | */.)
        _error_quit "安装路径不能包含 . 或 .. 路径组件：$CLASH_BASE_DIR"
        ;;
    esac
}

_register_install_cleanup() {
    [ -e "$CLASH_BASE_DIR" ] || CLASH_INSTALL_CREATED_DIR=$CLASH_BASE_DIR
    trap _cleanup_incomplete_install EXIT
}

_mark_install_complete() {
    CLASH_INSTALL_COMPLETE=true
    trap - EXIT
}

_mark_install_recoverable() {
    _mark_install_complete
}

_cleanup_incomplete_install() {
    local exit_status=$?

    [ "$CLASH_INSTALL_COMPLETE" = true ] && return "$exit_status"
    [ -n "$CLASH_INSTALL_CREATED_DIR" ] || return "$exit_status"

    case "$CLASH_INSTALL_CREATED_DIR" in
    "" | "/" | "$HOME" | "$HOME/" | . | .. | ./* | ../*)
        return "$exit_status"
        ;;
    esac
    case "$CLASH_INSTALL_CREATED_DIR" in
    /*)
        ;;
    *)
        return "$exit_status"
        ;;
    esac
    case "$CLASH_INSTALL_CREATED_DIR" in
    *[!A-Za-z0-9_./-]* | */../* | */.. | */./* | */.)
        return "$exit_status"
        ;;
    esac

    if [ "${CLASH_INSTALL_SERVICE_WRITTEN:-false}" = true ]; then
        _uninstall_service --force-current-attempt >/dev/null 2>&1 || true
    elif [ "${CLASH_INSTALL_SERVICE_TOUCHED:-false}" = true ]; then
        _uninstall_service >/dev/null 2>&1 || true
    fi
    if [ "${CLASH_INSTALL_RC_TOUCHED:-false}" = true ]; then
        _revoke_rc >/dev/null 2>&1 || true
    fi
    rm -rf "$CLASH_INSTALL_CREATED_DIR" 2>/dev/null || true
    return "$exit_status"
}

_valid_required() {
    local required_cmds=("xz" "pgrep" "curl" "tar" "unzip" "shuf" "gzip" "install" "mktemp" "rm" "mv" "cp" "chmod" "stat")
    local missing=()

    case "${INIT_TYPE:-tmux}" in
    tmux)
        required_cmds+=("tmux")
        ;;
    systemd)
        required_cmds+=("systemctl" "ip")
        ;;
    esac

    for cmd in "${required_cmds[@]}"; do
        command -v "$cmd" >&/dev/null || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        _error_quit "请先安装以下命令：${missing[*]}"
        return $?
    fi
    _valid_pgrep_support || return 1
    _valid_unzip_support || return 1
    _valid_install_support || return 1
    return 0
}

_valid_pgrep_support() {
    local status probe="clashctl-pgrep-probe-$$"

    pgrep -P "$$" >/dev/null 2>&1
    status=$?
    case "$status" in
    0 | 1)
        ;;
    *)
        _error_quit "当前 pgrep 不支持 -P 选项，请安装 procps/procps-ng 完整版"
        return $?
        ;;
    esac

    pgrep -u "$(id -u)" -x "$probe" >/dev/null 2>&1
    status=$?
    case "$status" in
    0 | 1)
        ;;
    *)
        _error_quit "当前 pgrep 不支持 -u/-x 选项，请安装 procps/procps-ng 完整版"
        return $?
        ;;
    esac

    pgrep -f "$probe" >/dev/null 2>&1
    status=$?
    case "$status" in
    0 | 1)
        return 0
        ;;
    *)
        _error_quit "当前 pgrep 不支持 -f 选项，请安装 procps/procps-ng 完整版"
        return $?
        ;;
    esac
}

_valid_unzip_support() {
    unzip -Z 2>&1 | grep -qi 'zipinfo' && return 0

    _error_quit "当前 unzip 不支持 Info-ZIP 的 unzip -Z；请安装完整 unzip/zipinfo（Alpine 可尝试 apk add unzip）"
    return $?
}

_valid_install_support() {
    local tmpdir

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/clash-install-probe.XXXXXX") || {
        _error_quit "无法创建 install 能力探测临时目录"
        return $?
    }
    install -D -m 755 /dev/null "$tmpdir/a/b" >/dev/null 2>&1 || {
        rm -rf "$tmpdir" 2>/dev/null || true
        _error_quit "当前 install 不支持 -D -m 选项，请安装 coreutils 或等价工具"
        return $?
    }
    rm -rf "$tmpdir" 2>/dev/null || true
}

_valid() {
    _validate_install_path || return 1
    _valid_required || return 1

    if [ -d "$CLASH_BASE_DIR" ]; then
        _error_quit "请先执行卸载脚本,以清除安装路径：$CLASH_BASE_DIR"
        return $?
    fi

    local msg="${CLASH_BASE_DIR}：当前路径不可用，请在 .env 中更换安装路径。"
    mkdir -p "$CLASH_BASE_DIR" || _error_quit "$msg"
    if _is_regular_sudo && [[ $CLASH_BASE_DIR == /root* ]]; then
        _error_quit "$msg"
        return $?
    fi

    if [ -z "${ZSH_VERSION:-}" ] && [ -z "${BASH_VERSION:-}" ]; then
        _error_quit "仅支持：bash、zsh 执行"
        return $?
    fi
    return 0
}

_print_install_help() {
    cat <<EOF
Usage:
  bash install.sh [mihomo|clash] [subscription_url] [OPTIONS]

Options:
  --init <tmux|nohup|systemd>
                         设置默认运行托管模式；systemd 需要 root 或 sudo
  --init=<mode>          等价写法
  --config-git           安装时在 <安装目录>/config 下执行 git init
  --no-config-git        即使 CLASHCTL_CONFIG_GIT=1 也不初始化配置仓库
  --gh-proxy <url>       设置 GitHub 下载代理前缀，例如 https://gh-proxy.org
  --gh-proxy=<url>       等价写法
  --no-gh-proxy          不使用 GitHub 下载代理；这是默认行为
  -h, --help             显示帮助信息

Environment:
  CLASHCTL_CONFIG_GIT=1  等价于 --config-git
  URL_GH_PROXY=<url>     等价于 --gh-proxy <url>
  CLASHCTL_NO_RC=1       不写入 shell rc
  CLASHCTL_NO_QUIT=1     跳过安装末尾的订阅导入交互

Examples:
  bash install.sh
  bash install.sh --init nohup
  bash install.sh --gh-proxy https://gh-proxy.org
  CLASHCTL_CONFIG_GIT=1 bash install.sh
  sudo bash install.sh --init systemd
EOF
}

_validate_gh_proxy() {
    [ -z "${URL_GH_PROXY:-}" ] && return 0

    case "$URL_GH_PROXY" in
    http://* | https://*)
        ;;
    *)
        _error_quit "GitHub 下载代理前缀必须以 http:// 或 https:// 开头：$URL_GH_PROXY"
        ;;
    esac

    case "$URL_GH_PROXY" in
    *[[:space:]]* | *\'* | *\"* | *'`'* | *'$('* | *';'* | *'|'* | *'&'* | *'<'* | *'>'*)
        _error_quit "GitHub 下载代理前缀包含不支持的字符：$URL_GH_PROXY"
        ;;
    esac
}

_parse_args() {
    while [ "$#" -gt 0 ]; do
        local arg=$1
        case $arg in
        -h | --help)
            _print_install_help
            exit 0
            ;;
        mihomo)
            KERNEL_NAME=mihomo
            ;;
        clash)
            KERNEL_NAME=clash
            ;;
        http* | file://*)
            CLASH_CONFIG_URL=$arg
            ;;
        --init=*)
            INIT_TYPE=${arg#--init=}
            ;;
        --init)
            shift
            [ "$#" -gt 0 ] || _error_quit "--init 需要指定模式：tmux、nohup、systemd"
            INIT_TYPE=$1
            ;;
        --config-git | --config-git=1 | --config-git=true | --config-git=yes | --config-git=on)
            CLASHCTL_CONFIG_GIT=1
            ;;
        --config-git=0 | --config-git=false | --config-git=no | --config-git=off | --no-config-git)
            CLASHCTL_CONFIG_GIT=0
            ;;
        --gh-proxy=*)
            URL_GH_PROXY=${arg#--gh-proxy=}
            ;;
        --gh-proxy)
            shift
            [ "$#" -gt 0 ] || _error_quit "--gh-proxy 需要指定 URL，例如：https://gh-proxy.org"
            URL_GH_PROXY=$1
            ;;
        --no-gh-proxy)
            URL_GH_PROXY=
            ;;
        esac
        shift
    done
    _validate_gh_proxy
    _refresh_install_paths
}

_config_git_enabled() {
    case "${CLASHCTL_CONFIG_GIT:-0}" in
    1 | true | yes | on)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

_init_config_git() {
    _config_git_enabled || return 0

    [ -d "$CLASH_CONFIG_DIR" ] || _error_quit "配置目录不存在，无法初始化 git：$CLASH_CONFIG_DIR"
    [ ! -L "$CLASH_CONFIG_DIR" ] || _error_quit "配置目录不能是符号链接：$CLASH_CONFIG_DIR"
    local base_real config_real expected_config_real
    base_real=$(cd "$CLASH_BASE_DIR" && pwd -P) || _error_quit "安装目录不存在：$CLASH_BASE_DIR"
    config_real=$(cd "$CLASH_CONFIG_DIR" && pwd -P) || _error_quit "配置目录不存在：$CLASH_CONFIG_DIR"
    expected_config_real="${base_real}/config"
    [ "$config_real" = "$expected_config_real" ] ||
        _error_quit "配置目录不属于当前安装目录：$CLASH_CONFIG_DIR"
    command -v git >/dev/null || _error_quit "未检测到 git，无法初始化配置仓库；可去掉 --config-git 后重试"

    if [ -d "$CLASH_CONFIG_DIR/.git" ]; then
        _okcat "配置目录已经是 git 仓库：$CLASH_CONFIG_DIR"
        return 0
    fi

    (cd "$CLASH_CONFIG_DIR" && git init >/dev/null) ||
        _error_quit "配置目录 git 初始化失败：$CLASH_CONFIG_DIR"
    _okcat "已在配置目录初始化 git 仓库：$CLASH_CONFIG_DIR"
}

_shell_quote() {
    printf '%q' "$1"
}

_set_envs() {
    local installed_systemd=false
    [ "$INIT_TYPE" = systemd ] && installed_systemd=true

    _install_state_write \
        "$CLASH_INSTALL_STATE" \
        "$CLASH_BASE_DIR" \
        "$KERNEL_NAME" \
        "$INIT_TYPE" \
        "$installed_systemd" \
        "${VERSION_MIHOMO:-}" \
        "${VERSION_YQ:-}" \
        "${VERSION_SUBCONVERTER:-}" ||
        _error_quit "安装状态写入失败：$CLASH_INSTALL_STATE"

    _set_env INIT_TYPE "$INIT_TYPE"
    _set_env CLASH_INSTALLED_INIT_TYPE "$INIT_TYPE"
    _set_env KERNEL_NAME "$KERNEL_NAME"
    _set_env CLASH_BASE_DIR "$CLASH_BASE_DIR"
    _set_env VERSION_MIHOMO "$VERSION_MIHOMO"
    _set_env URL_GH_PROXY "${URL_GH_PROXY:-}"
}

_get_random_val() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 6
}

_is_regular_sudo() {
    _is_root && [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != 'root' ]
}
_is_root() {
    [ "$(id -u)" -eq 0 ]
}

_quit() {
    _is_regular_sudo && exec su "$SUDO_USER"
    exec "$SHELL" -i
}
