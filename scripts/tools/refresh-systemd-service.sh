#!/usr/bin/env bash

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

_die() {
    printf '📢 %s\n' "$1" >&2
    exit 1
}

_ok() {
    printf '😼 %s\n' "$1"
}

_usage() {
    cat <<'EOF'
Usage:
  sudo refresh-systemd-service.sh

说明：
  刷新当前 clashctl 安装对应的 systemd unit，不重新安装项目，不覆盖用户配置。
  这个命令只写入 /etc/systemd/system/<kernel>.service 并执行 daemon-reload；
  如需让运行中的服务加载新 unit，请随后执行 clashrestart --mode systemd。
EOF
}

_require_root_or_test() {
    [ "$(id -u)" -eq 0 ] && return 0
    [ "${CLASHCTL_REFRESH_SYSTEMD_ALLOW_NON_ROOT:-}" = 1 ] && return 0
    _die "请使用 sudo 执行：sudo $0"
}

_install_dir() {
    local tool_dir install_dir
    tool_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
        _die "无法定位工具脚本目录"
    install_dir=$(cd "$tool_dir/../.." && pwd -P) ||
        _die "无法定位 clashctl 安装目录"
    printf '%s\n' "$install_dir"
}

_state_value() {
    local install_dir=$1 key=$2 state_file yq value
    state_file="$install_dir/resources/install-state.yaml"
    [ -r "$state_file" ] || return 1

    yq="$install_dir/bin/yq"
    if [ -x "$yq" ]; then
        value=$("$yq" ".${key} // \"\"" "$state_file") || return 1
        [ -n "$value" ] || return 1
        printf '%s\n' "$value"
        return 0
    fi

    awk -v key="$key" '
        $1 == key ":" {
            sub(/^[^:]*:[[:space:]]*/, "", $0)
            sub(/^"/, "", $0)
            sub(/"$/, "", $0)
            print $0
            exit
        }
    ' "$state_file"
}

_env_value() {
    local file=$1 key=$2 value
    [ -r "$file" ] || return 1
    value=$(awk -F= -v key="$key" '
        $1 == key {
            sub(/^[^=]*=/, "", $0)
            sub(/^"/, "", $0)
            sub(/"$/, "", $0)
            print $0
            exit
        }
    ' "$file")
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

_owner_home() {
    local install_dir=$1 uid home
    uid=$(stat -c '%u' "$install_dir" 2>/dev/null) ||
        _die "无法读取安装目录属主：$install_dir"
    home=$(awk -F: -v uid="$uid" '$3 == uid { print $6; exit }' /etc/passwd)
    [ -n "$home" ] ||
        _die "无法从 /etc/passwd 解析安装目录属主 home：$uid"
    printf '%s\n' "$home"
}

_expand_install_path() {
    local install_dir=$1 value=$2 home
    case "$value" in
    "~")
        _owner_home "$install_dir"
        ;;
    "~/"*)
        home=$(_owner_home "$install_dir")
        printf '%s/%s\n' "$home" "${value#"~/"}"
        ;;
    *)
        printf '%s\n' "$value"
        ;;
    esac
}

_kernel_name() {
    local install_dir=$1 kernel
    kernel=$(_state_value "$install_dir" kernel_name 2>/dev/null ||
        _env_value "$install_dir/.env" KERNEL_NAME 2>/dev/null ||
        printf '%s\n' mihomo)

    case "$kernel" in
    mihomo | clash)
        printf '%s\n' "$kernel"
        ;;
    *)
        _die "内核名称不安全，仅支持 mihomo、clash：$kernel"
        ;;
    esac
}

_recorded_install_dir() {
    local install_dir=$1 recorded
    recorded=$(_state_value "$install_dir" install_dir 2>/dev/null ||
        _env_value "$install_dir/.env" CLASH_BASE_DIR 2>/dev/null ||
        printf '%s\n' "$install_dir")
    _expand_install_path "$install_dir" "$recorded"
}

_escape_sed_repl() {
    printf '%s' "$1" | sed 's/[\\#&]/\\&/g'
}

_unit_expected_execstart() {
    local install_dir=$1 kernel=$2
    printf 'ExecStart=%s/bin/%s -d %s/resources -f %s/resources/runtime.yaml\n' \
        "$install_dir" "$kernel" "$install_dir" "$install_dir"
}

_target_belongs_to_current_install() {
    local target=$1 expected=$2
    [ -f "$target" ] || return 1
    grep -Fqx "$expected" "$target"
}

_registered_unit_belongs_to_current_install() {
    local kernel=$1 expected=$2
    [ "${CLASHCTL_REFRESH_SYSTEMD_SKIP_SYSTEMCTL_CAT:-}" = 1 ] && return 0
    command -v systemctl >/dev/null 2>&1 || return 0

    local content
    content=$(systemctl cat "$kernel" 2>/dev/null || true)
    [ -n "$content" ] || return 0
    ! grep -Eq '^ExecStart=' <<<"$content" && return 0
    grep -Fqx "$expected" <<<"$content"
}

while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        _usage
        exit 0
        ;;
    *)
        _die "未知参数：$1"
        ;;
    esac
done

_require_root_or_test

command -v install >/dev/null 2>&1 ||
    _die "缺少 install 命令，请先安装 coreutils 或等价工具"

install_dir=$(_install_dir)
[ -f "$install_dir/.clashctl-install-root" ] ||
    _die "当前目录不像 clashctl 安装目录：$install_dir"

kernel=$(_kernel_name "$install_dir")
recorded_install_dir=$(_recorded_install_dir "$install_dir")
template="$install_dir/scripts/init/systemd.sh"
target=${CLASHCTL_REFRESH_SYSTEMD_TARGET:-"/etc/systemd/system/${kernel}.service"}
expected_exec=$(_unit_expected_execstart "$recorded_install_dir" "$kernel")

[ -r "$template" ] ||
    _die "找不到 systemd 模板：$template"

if [ -L "$target" ]; then
    _die "拒绝覆盖符号链接 systemd unit：$target"
fi

if [ -e "$target" ] &&
    ! _target_belongs_to_current_install "$target" "$expected_exec"; then
    _die "systemd unit 已存在且不属于当前安装，拒绝覆盖：$target"
fi

_registered_unit_belongs_to_current_install "$kernel" "$expected_exec" ||
    _die "systemd 已注册同名服务且不属于当前安装，拒绝覆盖：$kernel"

tmp=$(mktemp "${TMPDIR:-/tmp}/clash-systemd-unit.XXXXXX.service") ||
    _die "无法创建临时 unit 文件"
trap 'rm -f "$tmp"' EXIT

sed \
    -e "s#placeholder_kernel_desc#$(_escape_sed_repl "$kernel")#g" \
    -e "s#placeholder_run_as_user##g" \
    -e "s#placeholder_cmd_full#$(_escape_sed_repl "${recorded_install_dir}/bin/${kernel} -d ${recorded_install_dir}/resources -f ${recorded_install_dir}/resources/runtime.yaml")#g" \
    "$template" >"$tmp" ||
    _die "systemd unit 渲染失败"

if [ "${CLASHCTL_REFRESH_SYSTEMD_SKIP_VERIFY:-}" != 1 ] &&
    command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$tmp" >/dev/null ||
        _die "systemd unit 校验失败"
fi

install -D -m 755 "$tmp" "$target" ||
    _die "systemd unit 写入失败：$target"

if [ "${CLASHCTL_REFRESH_SYSTEMD_SKIP_DAEMON_RELOAD:-}" != 1 ]; then
    systemctl daemon-reload ||
        _die "systemd daemon-reload 失败"
fi

_ok "已刷新 systemd unit：$target"
printf '👉 让新 unit 对运行中内核生效：clashrestart --mode systemd\n'
