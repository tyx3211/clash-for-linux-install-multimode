#!/usr/bin/env bash

set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

THIS_ROOT_RC_TOOL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) ||
    exit 1
. "$THIS_ROOT_RC_TOOL_DIR/root-rc-common.sh"

_usage() {
    cat <<'EOF'
Usage:
  sudo unsync-root-rc.sh [--cmd-dir <scripts/cmd>]

说明：
  从 /root/.bashrc 删除指定 clashctl 安装对应的初始化块。
  如果安装目录已经被删除，可以在源码仓库中执行：
    sudo bash scripts/tools/unsync-root-rc.sh --cmd-dir /home/<user>/clashctl/scripts/cmd
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
[ -n "$cmd_dir" ] || cmd_dir=$(_root_rc_cmd_dir_from_install "$(_root_rc_recorded_install_dir "$install_dir")")
target_rc=$(_root_rc_resolve_target_file "$(_root_rc_target_file)")

[ -f "$target_rc" ] || {
    _root_rc_ok "root bash rc 不存在，无需删除：$target_rc"
    exit 0
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/clash-root-rc.XXXXXX") ||
    _root_rc_die "无法创建临时目录"
trap 'rm -rf "$work_dir"' EXIT
stripped_file="$work_dir/root-stripped"

removed=true
_root_rc_remove_block_to_stdout "$target_rc" "$cmd_dir" >"$stripped_file" || {
    status=$?
    if [ "$status" -eq 2 ]; then
        removed=false
    else
        exit "$status"
    fi
}
_root_rc_write_atomic "$target_rc" "$stripped_file"
if [ "$removed" = true ]; then
    _root_rc_ok "已删除 root bash rc 中当前安装的 clashctl 块：$target_rc"
else
    _root_rc_ok "未找到 root bash rc 中对应的 clashctl 块：$target_rc"
fi
