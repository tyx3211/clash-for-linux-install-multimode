#!/usr/bin/env bash

set -euo pipefail

. "$(dirname "$0")/lib/test_helpers.bash"

PREFLIGHT_SH="$TEST_ROOT/scripts/preflight.sh"
ARCHIVE_SAFE_SH="$TEST_ROOT/scripts/install/archive-safe.sh"
DEPENDENCY_DOWNLOADS_SH="$TEST_ROOT/scripts/install/dependency-downloads.sh"
SERVICE_RENDER_SH="$TEST_ROOT/scripts/install/service-render.sh"
RC_SH="$TEST_ROOT/scripts/install/rc.sh"

[ -f "$ARCHIVE_SAFE_SH" ] ||
    fail "archive safety helpers should live in scripts/install/archive-safe.sh"
[ -f "$DEPENDENCY_DOWNLOADS_SH" ] ||
    fail "dependency download helpers should live in scripts/install/dependency-downloads.sh"
[ -f "$SERVICE_RENDER_SH" ] ||
    fail "service rendering helpers should live in scripts/install/service-render.sh"
[ -f "$RC_SH" ] ||
    fail "shell rc helpers should live in scripts/install/rc.sh"

assert_file_contains "$PREFLIGHT_SH" 'install/archive-safe\.sh' \
    "preflight should source archive safety helpers"
assert_file_contains "$PREFLIGHT_SH" 'install/dependency-downloads\.sh' \
    "preflight should source dependency download helpers"
assert_file_contains "$PREFLIGHT_SH" 'install/service-render\.sh' \
    "preflight should source service rendering helpers"
assert_file_contains "$PREFLIGHT_SH" 'install/rc\.sh' \
    "preflight should source shell rc helpers"

assert_file_contains "$ARCHIVE_SAFE_SH" '^_archive_member_path_is_safe\(\)' \
    "archive member validation should be in archive-safe module"
assert_file_contains "$ARCHIVE_SAFE_SH" '^_extract_tar_archive\(\)' \
    "tar extraction guard should be in archive-safe module"
assert_file_contains "$DEPENDENCY_DOWNLOADS_SH" '^_download_zip\(\)' \
    "dependency download helper should be in dependency-downloads module"
assert_file_contains "$DEPENDENCY_DOWNLOADS_SH" '^_prepare_zip\(\)' \
    "zip preparation helper should be in dependency-downloads module"
assert_file_contains "$DEPENDENCY_DOWNLOADS_SH" '^_unzip_zip\(\)' \
    "dependency extraction helper should be in dependency-downloads module"
fake_archive_path_tmp=$(make_test_tmpdir "clash-fake-archive-path")
printf '#!/usr/bin/env bash\nexit 99\n' >"$fake_archive_path_tmp/_extract_tar_archive"
chmod +x "$fake_archive_path_tmp/_extract_tar_archive"
PATH="$fake_archive_path_tmp:$PATH" bash -c '
    . "$1"
    [ "$(type -t _extract_tar_archive)" = function ] &&
        [ "$(type -t _extract_zip_archive)" = function ]
' _ "$DEPENDENCY_DOWNLOADS_SH" ||
    fail "dependency download module should load archive-safe functions even when PATH contains same-name commands"
assert_file_contains "$SERVICE_RENDER_SH" '^_install_service\(\)' \
    "service rendering should be in service-render module"
assert_file_contains "$SERVICE_RENDER_SH" '^_detect_init\(\)' \
    "service init detection should be in service-render module"
assert_file_contains "$SERVICE_RENDER_SH" '^_quote_command\(\)' \
    "service command quoting should be in service-render module"
assert_file_contains "$SERVICE_RENDER_SH" '^_preflight_escape_sed_repl\(\)' \
    "sed replacement escaping should stay with service rendering"
assert_file_contains "$RC_SH" '^_apply_rc\(\)' \
    "shell rc apply helper should be in rc module"
assert_file_contains "$RC_SH" '^_revoke_rc_file\(\)' \
    "shell rc revoke helper should be in rc module"

assert_file_not_contains "$PREFLIGHT_SH" '^_archive_member_path_is_safe\(\)' \
    "preflight should not keep archive safety function bodies"
assert_file_not_contains "$PREFLIGHT_SH" '^_download_zip\(\)' \
    "preflight should not keep dependency download function bodies"
assert_file_not_contains "$PREFLIGHT_SH" '^_prepare_zip\(\)' \
    "preflight should not keep zip preparation function bodies"
assert_file_not_contains "$PREFLIGHT_SH" '^_install_service\(\)' \
    "preflight should not keep service rendering function bodies"
assert_file_not_contains "$PREFLIGHT_SH" '^_detect_init\(\)' \
    "preflight should not keep service init detection function bodies"
assert_file_not_contains "$PREFLIGHT_SH" '^_apply_rc\(\)' \
    "preflight should not keep shell rc function bodies"

pass "preflight split checks"
