#!/usr/bin/env bash

set -euo pipefail

THIS_ROOT_RC_TOOL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
    exit 1
. "$THIS_ROOT_RC_TOOL_DIR/root-rc-common.sh"

_usage() {
    cat <<'EOF'
Usage:
  sudo sync-root-rc.sh

说明：
  把当前 clashctl 安装用户 ~/.bashrc 中的 clashctl 初始化块同步到 /root/.bashrc。
  只建议在单用户机器、个人虚拟机或明确授权的 systemd/Tun 场景中使用。
EOF
}

cmd_dir=

while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        _usage
        exit 0
        ;;
    --cmd-dir)
        shift
        [ $# -gt 0 ] || _root_rc_die "--cmd-dir 需要指定 scripts/cmd 目录"
        cmd_dir=$1
        ;;
    --cmd-dir=*)
        cmd_dir=${1#--cmd-dir=}
        ;;
    *)
        _root_rc_die "未知参数：$1"
        ;;
    esac
    shift
done

_root_rc_require_root_or_test

install_dir=$(_root_rc_install_dir)
recorded_install_dir=$(_root_rc_recorded_install_dir "$install_dir")
[ -n "$cmd_dir" ] || cmd_dir=$(_root_rc_cmd_dir_from_install "$recorded_install_dir")
source_rc=$(_root_rc_source_file "$install_dir")
target_rc=$(_root_rc_resolve_target_file "$(_root_rc_target_file)")

[ -r "$source_rc" ] ||
    _root_rc_die "找不到可读取的用户 bash rc：$source_rc；请先用普通用户完成安装或手工加载 clashctl"

if [ "$source_rc" = "$target_rc" ]; then
    _root_rc_ok "root 本身就是该安装的 rc 目标，无需同步"
    exit 0
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/clash-root-rc.XXXXXX") ||
    _root_rc_die "无法创建临时目录"
trap '/usr/bin/rm -rf "$work_dir"' EXIT
block_file="$work_dir/block"
stripped_file="$work_dir/root-stripped"
merged_file="$work_dir/root-merged"

_root_rc_extract_block "$source_rc" "$cmd_dir" >"$block_file" ||
    _root_rc_die "用户 bash rc 中没有找到当前安装的 clashctl 块：$cmd_dir"

if [ -f "$target_rc" ]; then
    _root_rc_remove_block_to_stdout "$target_rc" "$cmd_dir" >"$stripped_file" || {
        status=$?
        [ "$status" -eq 2 ] || exit "$status"
    }
else
    : >"$stripped_file"
fi

{
    cat "$stripped_file"
    if [ -s "$stripped_file" ] && [ -n "$(tail -n 1 "$stripped_file")" ]; then
        printf '\n'
    fi
    cat "$block_file"
} >"$merged_file"

_root_rc_write_atomic "$target_rc" "$merged_file"
_root_rc_ok "已同步 root bash rc：$target_rc"
_root_rc_ok "root shell 将复用安装用户的 clashctl 入口；建议日常只用只读命令、clashproxy on/off/status 或 clashproxy on -g，少做配置写操作"
