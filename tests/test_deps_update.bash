#!/usr/bin/env bash

set -euo pipefail

. "$(dirname "$0")/lib/test_helpers.bash"

CLASHCTL_SH="$TEST_ROOT/scripts/cmd/clashctl.sh"
COMMON_SH="$TEST_ROOT/scripts/cmd/common.sh"
CONFIG_SH="$TEST_ROOT/scripts/lib/config.sh"
SERVICE_RUNTIME_SH="$TEST_ROOT/scripts/lib/service-runtime.sh"
TUN_SH="$TEST_ROOT/scripts/lib/tun.sh"

deps_tmp=$(make_test_tmpdir "clash-deps-update")
install_dir="$deps_tmp/install"
mkdir -p "$install_dir/bin" "$install_dir/config" "$install_dir/resources" "$deps_tmp/artifacts/yq" "$deps_tmp/artifacts/subconverter/subconverter"
cp -a "$TEST_ROOT/scripts" "$install_dir/scripts"
mkdir -p "$install_dir/resources/zip"
printf 'stale mihomo zip\n' >"$install_dir/resources/zip/mihomo-linux-amd64-v3-v0.0.1.gz"
printf 'stale yq zip\n' >"$install_dir/resources/zip/yq_linux_amd64.tar.gz.old"
printf 'stale subconverter zip\n' >"$install_dir/resources/zip/subconverter_linux64.tar.gz.old"

cat >"$install_dir/bin/mihomo" <<'EOF'
#!/usr/bin/env bash
printf 'old mihomo\n'
EOF
chmod +x "$install_dir/bin/mihomo"

write_test_install_yq "$install_dir"

mkdir -p "$install_dir/bin/subconverter"
cat >"$install_dir/bin/subconverter/subconverter" <<'EOF'
#!/usr/bin/env bash
printf 'old subconverter\n'
EOF
chmod +x "$install_dir/bin/subconverter/subconverter"
printf 'user pref\n' >"$install_dir/bin/subconverter/pref.yml"

cat >"$install_dir/.env" <<EOF
KERNEL_NAME=mihomo
CLASH_BASE_DIR=$install_dir
INIT_TYPE=tmux
CLASH_INSTALLED_INIT_TYPE=tmux
VERSION_MIHOMO=v-old
VERSION_YQ=v-old
VERSION_SUBCONVERTER=v-old
SUBCONVERTER_REPO=tindy2013/subconverter
EOF

cat >"$install_dir/resources/install-state.yaml" <<EOF
install_dir: "$install_dir"
kernel_name: "mihomo"
default_mode: "tmux"
installed_systemd_service: false
versions:
  mihomo: "v-old"
  yq: "v-old"
  subconverter: "v-old"
EOF

cat >"$deps_tmp/artifacts/mihomo" <<'EOF'
#!/usr/bin/env bash
printf 'Mihomo Meta v1.19.27\n'
EOF
chmod +x "$deps_tmp/artifacts/mihomo"
gzip -c "$deps_tmp/artifacts/mihomo" >"$deps_tmp/artifacts/mihomo.gz"

cat >"$deps_tmp/artifacts/yq/yq_linux_amd64" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    printf 'yq version v4.53.3\n'
    exit 0
fi
if [ "${1:-}" = "-n" ] && [ -n "${INSTALL_STATE_INSTALL_DIR+x}" ]; then
    printf 'install_dir: "%s"\n' "$INSTALL_STATE_INSTALL_DIR"
    printf 'kernel_name: "%s"\n' "$INSTALL_STATE_KERNEL_NAME"
    printf 'default_mode: "%s"\n' "$INSTALL_STATE_DEFAULT_MODE"
    printf 'installed_systemd_service: %s\n' "$INSTALL_STATE_SYSTEMD"
    printf 'versions:\n'
    printf '  mihomo: "%s"\n' "$INSTALL_STATE_VERSION_MIHOMO"
    printf '  yq: "%s"\n' "$INSTALL_STATE_VERSION_YQ"
    printf '  subconverter: "%s"\n' "$INSTALL_STATE_VERSION_SUBCONVERTER"
    exit 0
fi
exit 0
EOF
chmod +x "$deps_tmp/artifacts/yq/yq_linux_amd64"
tar -C "$deps_tmp/artifacts/yq" -czf "$deps_tmp/artifacts/yq.tar.gz" yq_linux_amd64

cat >"$deps_tmp/artifacts/subconverter/subconverter/subconverter" <<'EOF'
#!/usr/bin/env bash
printf 'subconverter v0.9.0\n'
EOF
chmod +x "$deps_tmp/artifacts/subconverter/subconverter/subconverter"
printf 'example pref\n' >"$deps_tmp/artifacts/subconverter/subconverter/pref.example.yml"
tar -C "$deps_tmp/artifacts/subconverter" -czf "$deps_tmp/artifacts/subconverter.tar.gz" subconverter

(
    set +e
    . "$CLASHCTL_SH"

    CLASH_BASE_DIR="$install_dir"
    CLASH_RESOURCES_DIR="$install_dir/resources"
    CLASH_INSTALL_STATE="$install_dir/resources/install-state.yaml"
    KERNEL_NAME=mihomo
    INIT_TYPE=tmux
    CLASH_INSTALLED_INIT_TYPE=tmux
    BIN_BASE_DIR="$install_dir/bin"
    BIN_KERNEL="$install_dir/bin/mihomo"
    BIN_YQ="$install_dir/bin/yq"
    BIN_SUBCONVERTER_DIR="$install_dir/bin/subconverter"
    BIN_SUBCONVERTER="$install_dir/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$install_dir/bin/subconverter/pref.yml"

    curl() {
        local output= url= arg
        while (($#)); do
            arg=$1
            shift
            case "$arg" in
            --output)
                output=$1
                shift
                ;;
            http*)
                url=$arg
                ;;
            esac
        done

        case "$url" in
        *mihomo*)
            cp "$deps_tmp/artifacts/mihomo.gz" "$output"
            ;;
        *mikefarah/yq*)
            cp "$deps_tmp/artifacts/yq.tar.gz" "$output"
            ;;
        *subconverter*)
            cp "$deps_tmp/artifacts/subconverter.tar.gz" "$output"
            ;;
        *)
            return 9
            ;;
        esac
    }

    clashdeps --no-gh-proxy >"$deps_tmp/out" 2>"$deps_tmp/err"
    status=$?
    [ "$status" -eq 0 ] || {
        cat "$deps_tmp/err" >&2
        fail "clashdeps should update dependencies from vetted defaults"
    }
)

"$install_dir/bin/mihomo" | grep -q 'v1.19.27' ||
    fail "dependency update should replace mihomo binary"

"$install_dir/bin/yq" --version | grep -q 'v4.53.3' ||
    fail "dependency update should replace yq binary"

"$install_dir/bin/subconverter/subconverter" | grep -q 'v0.9.0' ||
    fail "dependency update should replace subconverter binary"

[ "$(cat "$install_dir/bin/subconverter/pref.yml")" = "user pref" ] ||
    fail "dependency update should preserve user subconverter pref.yml"

grep -qx 'VERSION_MIHOMO=v1.19.27' "$install_dir/.env" ||
    fail "dependency update should refresh local mihomo version metadata"
grep -qx 'VERSION_YQ=v4.53.3' "$install_dir/.env" ||
    fail "dependency update should refresh local yq version metadata"
grep -qx 'VERSION_SUBCONVERTER=v0.9.0' "$install_dir/.env" ||
    fail "dependency update should refresh local subconverter version metadata"
grep -q 'mihomo: "v1.19.27"' "$install_dir/resources/install-state.yaml" ||
    fail "dependency update should refresh install-state mihomo version"

single_tmp=$(make_test_tmpdir "clash-deps-update-single")
single_install="$single_tmp/install"
mkdir -p "$single_install/bin" "$single_install/resources" "$single_install/config"
cp -a "$TEST_ROOT/scripts" "$single_install/scripts"
write_test_install_yq "$single_install"
cat >"$single_install/.env" <<EOF
KERNEL_NAME=mihomo
CLASH_BASE_DIR=$single_install
INIT_TYPE=tmux
VERSION_MIHOMO=v-env-mihomo
VERSION_YQ=v-env-yq
VERSION_SUBCONVERTER=v-env-subconverter
SUBCONVERTER_REPO=tindy2013/subconverter
EOF
cat >"$single_install/resources/install-state.yaml" <<EOF
install_dir: "$single_install"
kernel_name: "mihomo"
default_mode: "tmux"
installed_systemd_service: false
versions: {}
EOF
(
    set +e
    . "$CLASHCTL_SH"

    CLASH_BASE_DIR="$single_install"
    CLASH_RESOURCES_DIR="$single_install/resources"
    CLASH_INSTALL_STATE="$single_install/resources/install-state.yaml"
    KERNEL_NAME=mihomo
    INIT_TYPE=tmux
    BIN_BASE_DIR="$single_install/bin"
    BIN_KERNEL="$single_install/bin/mihomo"
    BIN_YQ="$single_install/bin/yq"
    BIN_SUBCONVERTER_DIR="$single_install/bin/subconverter"
    BIN_SUBCONVERTER="$single_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$single_install/bin/subconverter/pref.yml"
    VERSION_MIHOMO=v-env-mihomo
    VERSION_YQ=v-env-yq
    VERSION_SUBCONVERTER=v-env-subconverter

    _clashdeps_state_version() { return 1; }
    _clashdeps_source_preflight() {
        ZIP_BASE_DIR="$single_install/resources/zip"
        mkdir -p "$ZIP_BASE_DIR"
        ZIP_YQ="$deps_tmp/artifacts/yq.tar.gz"
    }
    _download_zip() { return 0; }
    _valid_zip() { return 0; }
    _extract_tar_archive() { tar -xf "$1" -C "$2"; }

    clashdeps yq --no-gh-proxy >/dev/null || exit 1
)
grep -qx 'VERSION_MIHOMO=v-env-mihomo' "$single_install/.env" ||
    fail "single dependency update should preserve mihomo version metadata when install-state version is empty"
grep -qx 'VERSION_SUBCONVERTER=v-env-subconverter' "$single_install/.env" ||
    fail "single dependency update should preserve subconverter version metadata when install-state version is empty"
grep -qx 'VERSION_YQ=v4.53.3' "$single_install/.env" ||
    fail "single dependency update should refresh only the selected yq metadata"

(
    set +e
    . "$CLASHCTL_SH"
    KERNEL_NAME=clash
    clash_targets=()
    while IFS= read -r target; do
        [ -n "$target" ] && clash_targets+=("$target")
    done < <(_clashdeps_normalize_targets all) || exit 1
    printf '%s\n' "${clash_targets[@]}" >"$deps_tmp/clash-targets"
)
! grep -qx 'mihomo' "$deps_tmp/clash-targets" ||
    fail "update-deps all should not silently update mihomo for a clash install"

rollback_tmp=$(make_test_tmpdir "clash-deps-update-rollback")
rollback_install="$rollback_tmp/install"
mkdir -p "$rollback_install/bin/subconverter" "$rollback_install/resources" "$rollback_install/config"
cp -a "$TEST_ROOT/scripts" "$rollback_install/scripts"
write_test_install_yq "$rollback_install"
printf '#!/usr/bin/env bash\nprintf old-mihomo\\n\n' >"$rollback_install/bin/mihomo"
chmod +x "$rollback_install/bin/mihomo"
printf '#!/usr/bin/env bash\nprintf old-subconverter\\n\n' >"$rollback_install/bin/subconverter/subconverter"
chmod +x "$rollback_install/bin/subconverter/subconverter"
printf 'old pref\n' >"$rollback_install/bin/subconverter/pref.yml"
cat >"$rollback_install/.env" <<EOF
KERNEL_NAME=mihomo
CLASH_BASE_DIR=$rollback_install
INIT_TYPE=tmux
VERSION_MIHOMO=v-old
VERSION_YQ=v-old
VERSION_SUBCONVERTER=v-old
SUBCONVERTER_REPO=tindy2013/subconverter
EOF
cat >"$rollback_install/resources/install-state.yaml" <<EOF
install_dir: "$rollback_install"
kernel_name: "mihomo"
default_mode: "tmux"
installed_systemd_service: false
versions:
  mihomo: "v-old"
  yq: "v-old"
  subconverter: "v-old"
EOF
(
    set +e
    . "$CLASHCTL_SH"

    CLASH_BASE_DIR="$rollback_install"
    CLASH_RESOURCES_DIR="$rollback_install/resources"
    CLASH_INSTALL_STATE="$rollback_install/resources/install-state.yaml"
    KERNEL_NAME=mihomo
    INIT_TYPE=tmux
    BIN_BASE_DIR="$rollback_install/bin"
    BIN_KERNEL="$rollback_install/bin/mihomo"
    BIN_YQ="$rollback_install/bin/yq"
    BIN_SUBCONVERTER_DIR="$rollback_install/bin/subconverter"
    BIN_SUBCONVERTER="$rollback_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$rollback_install/bin/subconverter/pref.yml"

    _clashdeps_source_preflight() {
        ZIP_BASE_DIR="$rollback_install/resources/zip"
        mkdir -p "$ZIP_BASE_DIR"
        ZIP_MIHOMO="$deps_tmp/artifacts/mihomo.gz"
        ZIP_SUBCONVERTER="$deps_tmp/artifacts/subconverter.tar.gz"
    }
    _download_zip() { return 0; }
    _valid_zip() { return 0; }
    _extract_tar_archive() {
        [ "$1" = "$ZIP_SUBCONVERTER" ] || return 1
        tar -xf "$1" -C "$2"
    }
    _install_state_write() { return 1; }

    clashdeps mihomo subconverter --no-gh-proxy >/dev/null 2>"$rollback_tmp/err" && exit 1
    exit 0
)
"$rollback_install/bin/mihomo" | grep -q 'old-mihomo' ||
    fail "failed metadata write should roll back replaced mihomo binary"
"$rollback_install/bin/subconverter/subconverter" | grep -q 'old-subconverter' ||
    fail "failed metadata write should roll back replaced subconverter binary"
grep -qx 'VERSION_MIHOMO=v-old' "$rollback_install/.env" ||
    fail "failed dependency update should not rewrite env metadata"

state_rollback_tmp=$(make_test_tmpdir "clash-deps-update-state-rollback")
state_rollback_install="$state_rollback_tmp/install"
mkdir -p "$state_rollback_install/bin" "$state_rollback_install/resources" "$state_rollback_install/config"
cp -a "$TEST_ROOT/scripts" "$state_rollback_install/scripts"
write_test_install_yq "$state_rollback_install"
cat >"$state_rollback_install/.env" <<EOF
KERNEL_NAME=mihomo
CLASH_BASE_DIR=$state_rollback_install
INIT_TYPE=tmux
VERSION_MIHOMO=v-old
VERSION_YQ=v-old
VERSION_SUBCONVERTER=v-old
EOF
cat >"$state_rollback_install/resources/install-state.yaml" <<EOF
install_dir: "$state_rollback_install"
kernel_name: "mihomo"
default_mode: "tmux"
installed_systemd_service: false
versions:
  mihomo: "v-old"
  yq: "v-old"
  subconverter: "v-old"
EOF
(
    set +e
    . "$CLASHCTL_SH"
    CLASHDEPS_TMP="$state_rollback_tmp/work"
    mkdir -p "$CLASHDEPS_TMP"
    CLASH_BASE_DIR="$state_rollback_install"
    CLASH_INSTALL_STATE="$state_rollback_install/resources/install-state.yaml"
    BIN_BASE_DIR="$state_rollback_install/bin"
    BIN_YQ="$state_rollback_install/bin/yq"
    BIN_SUBCONVERTER_DIR="$state_rollback_install/bin/subconverter"
    BIN_SUBCONVERTER="$state_rollback_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$state_rollback_install/bin/subconverter/pref.yml"
    _clashdeps_backup_current || exit 1
    _clashdeps_write_env_versions() { return 1; }
    _clashdeps_write_versions v-old v-new v-old >/dev/null 2>"$state_rollback_tmp/err" &&
        exit 1
    _clashdeps_restore_current
    exit 0
) || fail "failed env metadata write should be treated as dependency update failure"
grep -qx 'VERSION_YQ=v-old' "$state_rollback_install/.env" ||
    fail "failed env metadata write should restore .env"
grep -q 'yq: "v-old"' "$state_rollback_install/resources/install-state.yaml" ||
    fail "failed env metadata write should restore install-state.yaml"

backup_fail_tmp=$(make_test_tmpdir "clash-deps-update-backup-fail")
backup_fail_install="$backup_fail_tmp/install"
mkdir -p "$backup_fail_install/bin/yq" "$backup_fail_install/bin/subconverter" "$backup_fail_tmp/work"
(
    set +e
    . "$CLASHCTL_SH"
    CLASHDEPS_TMP="$backup_fail_tmp/work"
    BIN_BASE_DIR="$backup_fail_install/bin"
    BIN_YQ="$backup_fail_install/bin/yq"
    BIN_SUBCONVERTER_DIR="$backup_fail_install/bin/subconverter"
    BIN_SUBCONVERTER="$backup_fail_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$backup_fail_install/bin/subconverter/pref.yml"
    _clashdeps_backup_current >/dev/null 2>"$backup_fail_tmp/err"
    [ "$?" -ne 0 ]
) || fail "dependency update should fail when an existing managed binary cannot be backed up"

leaf_symlink_tmp=$(make_test_tmpdir "clash-deps-update-leaf-symlink")
leaf_symlink_install="$leaf_symlink_tmp/install"
mkdir -p "$leaf_symlink_install/bin/subconverter" "$leaf_symlink_install/resources/zip" "$leaf_symlink_tmp/outside"
ln -s "$leaf_symlink_tmp/outside/pref.example.yml" "$leaf_symlink_install/bin/subconverter/pref.example.yml"
(
    set +e
    . "$CLASHCTL_SH"
    CLASH_BASE_DIR="$leaf_symlink_install"
    BIN_BASE_DIR="$leaf_symlink_install/bin"
    BIN_SUBCONVERTER_DIR="$leaf_symlink_install/bin/subconverter"
    ZIP_BASE_DIR="$leaf_symlink_install/resources/zip"
    BIN_YQ="$leaf_symlink_install/bin/yq"
    BIN_SUBCONVERTER="$leaf_symlink_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$leaf_symlink_install/bin/subconverter/pref.yml"
    _clashdeps_validate_managed_paths >/dev/null 2>"$leaf_symlink_tmp/err"
    [ "$?" -ne 0 ]
) || fail "dependency update should reject managed leaf file symlinks"

running_tmp=$(make_test_tmpdir "clash-deps-update-running")
(
    set +e
    . "$CLASHCTL_SH"

    _get_active_mode() { printf 'tmux\n'; }
    _download_zip() {
        printf 'download called\n' >"$running_tmp/download"
        return 1
    }
    clashdeps yq --no-gh-proxy >/dev/null 2>"$running_tmp/err"
    [ "$?" -ne 0 ]
) || fail "dependency update should refuse to run while the current install is active"
[ ! -e "$running_tmp/download" ] ||
    fail "dependency update should refuse before downloading when a service is active"
grep -q 'clashoff' "$running_tmp/err" ||
    fail "running-service rejection should tell users to stop the service explicitly"

unmanaged_tmp=$(make_test_tmpdir "clash-deps-update-unmanaged")
(
    set +e
    . "$CLASHCTL_SH"

    _get_active_mode() { return 1; }
    _current_kernel_pids() { printf '4242\n'; }
    _download_zip() {
        printf 'download called\n' >"$unmanaged_tmp/download"
        return 1
    }
    clashdeps yq --no-gh-proxy >/dev/null 2>"$unmanaged_tmp/err"
    [ "$?" -ne 0 ]
) || fail "dependency update should refuse when an unmanaged current-install kernel process is active"
[ ! -e "$unmanaged_tmp/download" ] ||
    fail "dependency update should refuse unmanaged kernel processes before downloading"
grep -q '未托管内核进程' "$unmanaged_tmp/err" ||
    fail "unmanaged kernel rejection should explain why update-deps refused"

race_tmp=$(make_test_tmpdir "clash-deps-update-race")
race_install="$race_tmp/install"
mkdir -p "$race_install/bin/subconverter" "$race_install/resources" "$race_install/config"
cp -a "$TEST_ROOT/scripts" "$race_install/scripts"
write_test_install_yq "$race_install"
race_yq_hash=$(sha256sum "$race_install/bin/yq" | awk '{print $1}')
cat >"$race_install/.env" <<EOF
KERNEL_NAME=mihomo
CLASH_BASE_DIR=$race_install
INIT_TYPE=tmux
VERSION_MIHOMO=v-old
VERSION_YQ=v-old
VERSION_SUBCONVERTER=v-old
SUBCONVERTER_REPO=tindy2013/subconverter
EOF
cat >"$race_install/resources/install-state.yaml" <<EOF
install_dir: "$race_install"
kernel_name: "mihomo"
default_mode: "tmux"
installed_systemd_service: false
versions:
  mihomo: "v-old"
  yq: "v-old"
  subconverter: "v-old"
EOF
(
    set +e
    . "$CLASHCTL_SH"

    CLASH_BASE_DIR="$race_install"
    CLASH_RESOURCES_DIR="$race_install/resources"
    CLASH_INSTALL_STATE="$race_install/resources/install-state.yaml"
    KERNEL_NAME=mihomo
    INIT_TYPE=tmux
    BIN_BASE_DIR="$race_install/bin"
    BIN_KERNEL="$race_install/bin/mihomo"
    BIN_YQ="$race_install/bin/yq"
    BIN_SUBCONVERTER_DIR="$race_install/bin/subconverter"
    BIN_SUBCONVERTER="$race_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$race_install/bin/subconverter/pref.yml"
    printf '0\n' >"$race_tmp/active-checks"

    _get_active_mode() {
        local active_checks
        active_checks=$(cat "$race_tmp/active-checks")
        active_checks=$((active_checks + 1))
        printf '%s\n' "$active_checks" >"$race_tmp/active-checks"
        if [ "$active_checks" -ge 2 ]; then
            printf 'tmux\n'
            return 0
        fi
        return 1
    }
    _clashdeps_source_preflight() {
        ZIP_BASE_DIR="$race_install/resources/zip"
        mkdir -p "$ZIP_BASE_DIR"
        ZIP_YQ="$deps_tmp/artifacts/yq.tar.gz"
    }
    _download_zip() { return 0; }
    _valid_zip() { return 0; }
    _extract_tar_archive() { tar -xf "$1" -C "$2"; }

    clashdeps yq --no-gh-proxy >/dev/null 2>"$race_tmp/err" && exit 1
    exit 0
) || fail "dependency update should abort if the service becomes active before binary replacement"
[ "$(sha256sum "$race_install/bin/yq" | awk '{print $1}')" = "$race_yq_hash" ] ||
    fail "dependency update should not replace yq after the service becomes active"
grep -q 'clashoff' "$race_tmp/err" ||
    fail "late running-service rejection should tell users to stop the service explicitly"

missing_created_tmp=$(make_test_tmpdir "clash-deps-update-missing-created")
missing_created_install="$missing_created_tmp/install"
mkdir -p "$missing_created_install/bin" "$missing_created_install/resources" "$missing_created_install/config"
cp -a "$TEST_ROOT/scripts" "$missing_created_install/scripts"
write_test_install_yq "$missing_created_install"
cat >"$missing_created_install/.env" <<EOF
KERNEL_NAME=mihomo
CLASH_BASE_DIR=$missing_created_install
INIT_TYPE=tmux
VERSION_MIHOMO=v-old
VERSION_YQ=v-old
VERSION_SUBCONVERTER=v-old
SUBCONVERTER_REPO=tindy2013/subconverter
EOF
cat >"$missing_created_install/resources/install-state.yaml" <<EOF
install_dir: "$missing_created_install"
kernel_name: "mihomo"
default_mode: "tmux"
installed_systemd_service: false
versions:
  mihomo: "v-old"
  yq: "v-old"
  subconverter: "v-old"
EOF
(
    set +e
    . "$CLASHCTL_SH"

    CLASH_BASE_DIR="$missing_created_install"
    CLASH_RESOURCES_DIR="$missing_created_install/resources"
    CLASH_INSTALL_STATE="$missing_created_install/resources/install-state.yaml"
    KERNEL_NAME=mihomo
    INIT_TYPE=tmux
    BIN_BASE_DIR="$missing_created_install/bin"
    BIN_KERNEL="$missing_created_install/bin/mihomo"
    BIN_YQ="$missing_created_install/bin/yq"
    BIN_SUBCONVERTER_DIR="$missing_created_install/bin/subconverter"
    BIN_SUBCONVERTER="$missing_created_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$missing_created_install/bin/subconverter/pref.yml"

    _clashdeps_source_preflight() {
        ZIP_BASE_DIR="$missing_created_install/resources/zip"
        mkdir -p "$ZIP_BASE_DIR"
        ZIP_SUBCONVERTER="$deps_tmp/artifacts/subconverter.tar.gz"
    }
    _download_zip() { return 0; }
    _valid_zip() { return 0; }
    _extract_tar_archive() { tar -xf "$1" -C "$2"; }
    _install_state_write() { return 1; }

    clashdeps subconverter --no-gh-proxy >/dev/null 2>"$missing_created_tmp/err" && exit 1
    exit 0
) || fail "dependency update should fail when metadata write fails after creating new files"
[ ! -e "$missing_created_install/bin/subconverter/subconverter" ] ||
    fail "failed dependency update should remove newly created subconverter binary"
[ ! -e "$missing_created_install/bin/subconverter/pref.example.yml" ] ||
    fail "failed dependency update should remove newly created pref.example.yml"
[ ! -e "$missing_created_install/bin/subconverter/pref.yml" ] ||
    fail "failed dependency update should remove newly created pref.yml"

symlink_tmp=$(make_test_tmpdir "clash-deps-update-symlink")
symlink_install="$symlink_tmp/install"
mkdir -p "$symlink_install/bin" "$symlink_install/resources" "$symlink_install/config" "$symlink_tmp/outside"
cp -a "$TEST_ROOT/scripts" "$symlink_install/scripts"
write_test_install_yq "$symlink_install"
rm -rf "$symlink_install/resources/zip"
ln -s "$symlink_tmp/outside" "$symlink_install/resources/zip"
(
    set +e
    . "$CLASHCTL_SH"
    CLASH_BASE_DIR="$symlink_install"
    CLASH_RESOURCES_DIR="$symlink_install/resources"
    ZIP_BASE_DIR="$symlink_install/resources/zip"
    BIN_BASE_DIR="$symlink_install/bin"
    BIN_YQ="$symlink_install/bin/yq"
    BIN_SUBCONVERTER_DIR="$symlink_install/bin/subconverter"
    BIN_SUBCONVERTER="$symlink_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$symlink_install/bin/subconverter/pref.yml"
    clashdeps yq --no-gh-proxy >/dev/null 2>"$symlink_tmp/err"
    [ "$?" -ne 0 ]
) || fail "dependency update should reject symlink zip cache directories"
grep -q '符号链接' "$symlink_tmp/err" ||
    fail "symlink zip cache rejection should explain the unsafe path"

resource_symlink_tmp=$(make_test_tmpdir "clash-deps-update-resource-symlink")
resource_symlink_install="$resource_symlink_tmp/install"
mkdir -p "$resource_symlink_install/bin" "$resource_symlink_tmp/outside"
cp -a "$TEST_ROOT/scripts" "$resource_symlink_install/scripts"
write_test_install_yq "$resource_symlink_install"
ln -s "$resource_symlink_tmp/outside" "$resource_symlink_install/resources"
(
    set +e
    . "$CLASHCTL_SH"
    CLASH_BASE_DIR="$resource_symlink_install"
    CLASH_RESOURCES_DIR="$resource_symlink_install/resources"
    CLASH_INSTALL_STATE="$resource_symlink_install/resources/install-state.yaml"
    BIN_BASE_DIR="$resource_symlink_install/bin"
    BIN_YQ="$resource_symlink_install/bin/yq"
    BIN_SUBCONVERTER_DIR="$resource_symlink_install/bin/subconverter"
    BIN_SUBCONVERTER="$resource_symlink_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$resource_symlink_install/bin/subconverter/pref.yml"
    clashdeps yq --no-gh-proxy >/dev/null 2>"$resource_symlink_tmp/err"
    [ "$?" -ne 0 ]
) || fail "dependency update should reject symlink resources before creating temp directories"
! find "$resource_symlink_tmp/outside" -maxdepth 1 -name '.deps-update.*' | grep -q . ||
    fail "dependency update should not create temp directories through symlinked resources"
[ ! -e "$resource_symlink_tmp/outside/service.lock" ] ||
    fail "dependency update should not create service.lock through symlinked resources"

restart_reject_tmp=$(make_test_tmpdir "clash-deps-update-restart-reject")
(
    set +e
    . "$CLASHCTL_SH"

    clashdeps mihomo --restart >/dev/null 2>"$restart_reject_tmp/err"
    [ "$?" -ne 0 ]
) || fail "update-deps should reject --restart instead of managing service lifecycle"
grep -q 'clashrestart' "$restart_reject_tmp/err" ||
    fail "update-deps --restart rejection should tell users to restart explicitly"

subconverter_active_tmp=$(make_test_tmpdir "clash-deps-update-subconverter-active")
subconverter_active_install="$subconverter_active_tmp/install"
(
    set +e
    mkdir -p "$subconverter_active_install/bin/subconverter" "$subconverter_active_install/resources/zip"
    cp -a "$TEST_ROOT/scripts" "$subconverter_active_install/scripts"
    write_test_install_yq "$subconverter_active_install"
    cp "${BASH:-/bin/bash}" "$subconverter_active_install/bin/subconverter/subconverter"
    chmod +x "$subconverter_active_install/bin/subconverter/subconverter"
    "$subconverter_active_install/bin/subconverter/subconverter" -c 'cleanup() { local pids; pids=$(jobs -p); [ -n "$pids" ] && kill $pids 2>/dev/null || true; }; trap cleanup EXIT; trap "cleanup; exit 0" INT TERM; while :; do sleep 30 & wait "$!" 2>/dev/null || true; done' &
    active_sub_pid=$!
    cleanup_active_subconverter() {
        kill "$active_sub_pid" 2>/dev/null || true
        wait "$active_sub_pid" 2>/dev/null || true
    }
    trap cleanup_active_subconverter EXIT INT TERM
    printf '%s\n' "$active_sub_pid" >"$subconverter_active_install/bin/subconverter/subconverter.pid"

    . "$CLASHCTL_SH"
    CLASH_BASE_DIR="$subconverter_active_install"
    CLASH_RESOURCES_DIR="$subconverter_active_install/resources"
    CLASH_INSTALL_STATE="$subconverter_active_install/resources/install-state.yaml"
    BIN_BASE_DIR="$subconverter_active_install/bin"
    BIN_YQ="$subconverter_active_install/bin/yq"
    BIN_SUBCONVERTER_DIR="$subconverter_active_install/bin/subconverter"
    BIN_SUBCONVERTER="$subconverter_active_install/bin/subconverter/subconverter"
    BIN_SUBCONVERTER_CONFIG="$subconverter_active_install/bin/subconverter/pref.yml"
    BIN_SUBCONVERTER_PID="$subconverter_active_install/bin/subconverter/subconverter.pid"
    _download_zip() {
        printf 'download called\n' >"$subconverter_active_tmp/download"
        return 1
    }
    clashdeps subconverter --no-gh-proxy >/dev/null 2>"$subconverter_active_tmp/err"
    [ "$?" -ne 0 ]
    status=$?
    [ "$status" -eq 0 ] ||
        fail "dependency update should reject active subconverter instead of stopping it"
    kill -0 "$active_sub_pid" 2>/dev/null ||
        fail "dependency update should not stop an active subconverter process"
    [ ! -e "$subconverter_active_tmp/download" ] ||
        fail "dependency update should reject active subconverter before downloading"
) || fail "dependency update should reject active subconverter instead of stopping it"

if command -v zsh >/dev/null 2>&1; then
    zsh_tmp=$(make_test_tmpdir "clash-deps-update-zsh")
    zsh_install="$zsh_tmp/install"
    mkdir -p "$zsh_install/bin/subconverter" "$zsh_install/resources" "$zsh_install/config"
    cp -a "$TEST_ROOT/scripts" "$zsh_install/scripts"
    write_test_install_yq "$zsh_install"
    cat >"$zsh_install/.env" <<EOF
KERNEL_NAME=mihomo
CLASH_BASE_DIR=$zsh_install
INIT_TYPE=tmux
VERSION_MIHOMO=v-old
VERSION_YQ=v-old
VERSION_SUBCONVERTER=v-old
SUBCONVERTER_REPO=tindy2013/subconverter
EOF
    cat >"$zsh_install/resources/install-state.yaml" <<EOF
install_dir: "$zsh_install"
kernel_name: "mihomo"
default_mode: "tmux"
installed_systemd_service: false
versions:
  mihomo: "v-old"
  yq: "v-old"
  subconverter: "v-old"
EOF
    zsh -fc '
        CLASHCTL_SH=$1
        install_dir=$2
        yq_archive=$3
        . "$CLASHCTL_SH" || exit 1
        _get_active_mode() { return 1; }
        _clashdeps_state_version() { return 1; }
        curl() {
            local output=
            while [ "$#" -gt 0 ]; do
                case "$1" in
                --output)
                    shift
                    output=$1
                    ;;
                esac
                shift
            done
            [ -n "$output" ] || return 1
            cp "$yq_archive" "$output"
        }
        clashdeps yq --no-gh-proxy >/dev/null 2>"$install_dir/zsh.err"
    ' zsh-test "$zsh_install/scripts/cmd/clashctl.sh" "$zsh_install" "$deps_tmp/artifacts/yq.tar.gz" ||
        fail "dependency update should work when clashctl.sh is sourced from zsh"
fi

assert_file_contains "$TEST_ROOT/scripts/lib/deps-update.sh" '_with_service_lock _clashdeps_main' \
    "dependency update should run under the service lock"
assert_file_contains "$CONFIG_SH" '_with_service_lock _merge_config_restart_impl' \
    "config merge restart should run under the service lock"
assert_file_contains "$COMMON_SH" '_with_service_lock _download_convert_config_impl' \
    "subscription conversion should run under the service lock"
assert_file_contains "$TUN_SH" '_with_service_lock _tunon_impl' \
    "tun enable should run under the service lock"
assert_file_contains "$TUN_SH" '_with_service_lock _tunoff_impl' \
    "tun disable should run under the service lock"
assert_file_not_contains "$TEST_ROOT/scripts/lib/deps-update.sh" 'mapfile' \
    "dependency update should not rely on bash-only mapfile"
assert_file_not_contains "$SERVICE_RUNTIME_SH" 'mapfile' \
    "service runtime should not rely on bash-only mapfile"

pass "dependency update checks"
