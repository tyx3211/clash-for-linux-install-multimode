#!/usr/bin/env bash

set -euo pipefail

. "$(dirname "$0")/lib/test_helpers.bash"

root_rc_tmp=$(make_test_tmpdir "clash-root-rc")
sync_script="$TEST_ROOT/scripts/tools/sync-root-rc.sh"
unsync_script="$TEST_ROOT/scripts/tools/unsync-root-rc.sh"
install_dir="$root_rc_tmp/home/william/clashctl"
cmd_dir="$install_dir/scripts/cmd"
user_rc="$root_rc_tmp/home/william/.bashrc"
root_rc="$root_rc_tmp/root/.bashrc"
root_rc_target="$root_rc_tmp/root/managed-bashrc"
root_rc_link="$root_rc_tmp/root/link-bashrc"

mkdir -p "$cmd_dir" "$(dirname "$user_rc")" "$(dirname "$root_rc")"
printf 'echo root-pre\n' >"$root_rc"
cat >"$user_rc" <<EOF
echo user-pre
# clashctl START $cmd_dir
# 加载 clashctl 命令
. $cmd_dir/clashctl.sh
# 按 sidecar 配置检查是否写入代理变量
watch_proxy
# clashctl END $cmd_dir
echo user-post
EOF

cat >>"$root_rc" <<'EOF'
# clashctl START /opt/other/scripts/cmd
. /opt/other/scripts/cmd/clashctl.sh
# clashctl END /opt/other/scripts/cmd
echo root-post
EOF

CLASHCTL_ROOT_RC_ALLOW_NON_ROOT=1 \
    CLASHCTL_ROOT_RC_SOURCE="$user_rc" \
    CLASHCTL_ROOT_RC_TARGET="$root_rc" \
    bash "$sync_script" --cmd-dir "$cmd_dir" >/dev/null

grep -qx ". $cmd_dir/clashctl.sh" "$root_rc" ||
    fail "sync-root-rc should copy the current install clashctl source line into root rc"
grep -qx ". /opt/other/scripts/cmd/clashctl.sh" "$root_rc" ||
    fail "sync-root-rc should preserve unrelated clashctl blocks"
[ "$(grep -c "^# clashctl START $cmd_dir$" "$root_rc")" -eq 1 ] ||
    fail "sync-root-rc should add the current install block exactly once"
first_sync_content=$(cat "$root_rc")

CLASHCTL_ROOT_RC_ALLOW_NON_ROOT=1 \
    CLASHCTL_ROOT_RC_SOURCE="$user_rc" \
    CLASHCTL_ROOT_RC_TARGET="$root_rc" \
    bash "$sync_script" --cmd-dir "$cmd_dir" >/dev/null

[ "$(grep -c "^# clashctl START $cmd_dir$" "$root_rc")" -eq 1 ] ||
    fail "sync-root-rc should be idempotent for the same install"
[ "$(cat "$root_rc")" = "$first_sync_content" ] ||
    fail "sync-root-rc should not change root rc content when run twice for the same install"

CLASHCTL_ROOT_RC_ALLOW_NON_ROOT=1 \
    CLASHCTL_ROOT_RC_TARGET="$root_rc" \
    bash "$unsync_script" --cmd-dir "$cmd_dir" >/dev/null

! grep -qx ". $cmd_dir/clashctl.sh" "$root_rc" ||
    fail "unsync-root-rc should remove the current install clashctl source line"
grep -qx ". /opt/other/scripts/cmd/clashctl.sh" "$root_rc" ||
    fail "unsync-root-rc should preserve unrelated clashctl blocks"
grep -qx 'echo root-pre' "$root_rc" ||
    fail "unsync-root-rc should preserve root rc content before managed blocks"
grep -qx 'echo root-post' "$root_rc" ||
    fail "unsync-root-rc should preserve root rc content after managed blocks"

cp "$root_rc" "$root_rc_tmp/root/wrong-path-before"
CLASHCTL_ROOT_RC_ALLOW_NON_ROOT=1 \
    CLASHCTL_ROOT_RC_TARGET="$root_rc" \
    bash "$unsync_script" --cmd-dir "$root_rc_tmp/wrong/scripts/cmd" >"$root_rc_tmp/wrong-unsync.out"
grep -q '未找到' "$root_rc_tmp/wrong-unsync.out" ||
    fail "unsync-root-rc should report when the requested block is not found"
cmp -s "$root_rc" "$root_rc_tmp/root/wrong-path-before" ||
    fail "unsync-root-rc should leave root rc unchanged when no matching block exists"

cat >"$root_rc_target" <<EOF
# clashctl START $cmd_dir
. $cmd_dir/clashctl.sh
# clashctl END $cmd_dir
EOF
ln -s "$root_rc_target" "$root_rc_link"
CLASHCTL_ROOT_RC_ALLOW_NON_ROOT=1 \
    CLASHCTL_ROOT_RC_TARGET="$root_rc_link" \
    bash "$unsync_script" --cmd-dir "$cmd_dir" >/dev/null
[ -L "$root_rc_link" ] ||
    fail "unsync-root-rc should preserve a symlinked root rc path"
! grep -qx ". $cmd_dir/clashctl.sh" "$root_rc_target" ||
    fail "unsync-root-rc should edit the symlink target"

mkdir -p "$root_rc_tmp/root/rc-directory"
CLASHCTL_ROOT_RC_ALLOW_NON_ROOT=1 \
    CLASHCTL_ROOT_RC_TARGET="$root_rc_tmp/root/rc-directory" \
    bash "$unsync_script" --cmd-dir "$cmd_dir" >/dev/null 2>"$root_rc_tmp/root/rc-directory.err" &&
    fail "unsync-root-rc should reject a directory target"
grep -q '不是普通文件' "$root_rc_tmp/root/rc-directory.err" ||
    fail "unsync-root-rc should explain directory targets are invalid"

grep -q 'unsync-root-rc.sh' "$TEST_ROOT/uninstall.sh" ||
    fail "uninstall should tell users how to remove a previously synced root rc block"

pass "root rc sync helper checks"
