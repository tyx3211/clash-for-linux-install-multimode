#!/usr/bin/env bash

set -euo pipefail

. "$(dirname "$0")/lib/test_helpers.bash"

. "$TEST_ROOT/scripts/lib/env-write.sh"

env_file=$(make_test_tmpdir env-write)/.env
cat >"$env_file" <<'EOF'
VERSION_YQ=v-old
URL_GH_PROXY=https://mirror.example/a&b
EOF

_env_write_set "$env_file" VERSION_YQ v4.53.3
grep -qx 'VERSION_YQ=v4.53.3' "$env_file" ||
    fail "env writer should replace an existing plain assignment"
[ "$(grep -Ec '^VERSION_YQ=' "$env_file")" -eq 1 ] ||
    fail "env writer should not duplicate an existing key"

_env_write_set "$env_file" URL_GH_PROXY 'https://mirror.example/c|d\path&x'
[ "$(grep -E '^URL_GH_PROXY=' "$env_file")" = 'URL_GH_PROXY=https://mirror.example/c|d\path&x' ] ||
    fail "env writer should preserve sed-sensitive characters in replacement values"

_env_write_set "$env_file" VERSION_SUBCONVERTER v0.9.0
grep -qx 'VERSION_SUBCONVERTER=v0.9.0' "$env_file" ||
    fail "env writer should append missing keys"

if _env_write_set "$env_file" 'BAD-KEY' value 2>/dev/null; then
    fail "env writer should reject keys that are not shell assignment identifiers"
fi

if _env_write_set "$env_file" '1BAD' value 2>/dev/null; then
    fail "env writer should reject keys that start with a digit"
fi

if _env_write_set "$env_file" VERSION_YQ $'bad\nvalue' 2>/dev/null; then
    fail "env writer should reject values with line feeds"
fi

if _env_write_set "$env_file" VERSION_YQ $'bad\rvalue' 2>/dev/null; then
    fail "env writer should reject values with carriage returns"
fi

set +e
missing_args_err=$(
    (
        set -u
        . "$TEST_ROOT/scripts/lib/env-write.sh"
        _env_write_set "$env_file" ONLY_KEY
    ) 2>&1 >/dev/null
)
missing_args_status=$?
set -e
[ "$missing_args_status" -ne 0 ] ||
    fail "env writer should reject missing arguments"
printf '%s\n' "$missing_args_err" | grep -q 'usage: _env_write_set' ||
    fail "env writer should report a controlled usage error for missing arguments"

cat >"$CLASH_BASE_DIR/.env" <<'EOF'
VERSION_YQ=v-old
EOF

(
    THIS_SCRIPT_DIR="$TEST_ROOT/scripts/cmd"
    . "$TEST_ROOT/scripts/cmd/common.sh"
    _set_env VERSION_YQ 'v|common\path&x'
)
[ "$(grep -E '^VERSION_YQ=' "$CLASH_BASE_DIR/.env")" = 'VERSION_YQ=v|common\path&x' ] ||
    fail "_set_env should write through the shared env writer into CLASH_BASE_DIR/.env"

set +e
set_env_missing_args_err=$(
    (
        set -u
        THIS_SCRIPT_DIR="$TEST_ROOT/scripts/cmd"
        . "$TEST_ROOT/scripts/cmd/common.sh"
        _set_env ONLY_KEY
    ) 2>&1 >/dev/null
)
set_env_missing_args_status=$?
set -e
[ "$set_env_missing_args_status" -ne 0 ] ||
    fail "_set_env should reject missing arguments"
printf '%s\n' "$set_env_missing_args_err" | grep -q 'usage: _env_write_set' ||
    fail "_set_env should forward missing arguments to the shared env writer"

pass "env write helper"
