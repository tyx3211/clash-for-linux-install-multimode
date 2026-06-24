#!/usr/bin/env bash

set -euo pipefail

. "$(dirname "$0")/lib/test_helpers.bash"

ENV_FILE="$TEST_ROOT/.env"
INSTALL_SH="$TEST_ROOT/install.sh"
PREFLIGHT_SH="$TEST_ROOT/scripts/preflight.sh"
SERVICE_RENDER_SH="$TEST_ROOT/scripts/install/service-render.sh"
CLASHCTL_SH="$TEST_ROOT/scripts/cmd/clashctl.sh"
TUN_SH="$TEST_ROOT/scripts/lib/tun.sh"
SYSTEMD_SH="$TEST_ROOT/scripts/init/systemd.sh"
REFRESH_SYSTEMD_SH="$TEST_ROOT/scripts/tools/refresh-systemd-service.sh"

[ -f "$REFRESH_SYSTEMD_SH" ] ||
    fail "project should provide a dedicated systemd service refresh tool for existing installs"

assert_file_contains "$REFRESH_SYSTEMD_SH" 'command -v install' \
    "systemd refresh tool should check install command availability before writing units"

assert_file_contains "$ENV_FILE" '^INIT_TYPE=tmux$' \
    "tmux should remain the default init mode"

assert_file_contains "$SERVICE_RENDER_SH" 'tmux\)' \
    "_detect_init should support tmux mode"

assert_file_contains "$SERVICE_RENDER_SH" 'nohup\)' \
    "_detect_init should support explicit nohup mode"

assert_file_contains "$SERVICE_RENDER_SH" 'systemd\)' \
    "_detect_init should support explicit systemd mode"

assert_file_not_contains "$SYSTEMD_SH" '^Limit[A-Z]' \
    "systemd unit should not add project-level resource limits"

assert_file_not_contains "$SYSTEMD_SH" '^User=' \
    "systemd unit should default to root by omitting User= for systemd/Tun mode"

assert_file_not_contains "$SYSTEMD_SH" '^CapabilityBoundingSet=' \
    "systemd unit should not fake root-equivalent permissions through capability-only user mode"

assert_file_not_contains "$SYSTEMD_SH" '^AmbientCapabilities=' \
    "systemd unit should not rely on ambient capabilities for systemd/Tun mode"

systemd_render_tmp=$(make_test_tmpdir "clash-systemd-render")
systemd_rendered="$systemd_render_tmp/mihomo.service"
sed \
    -e 's#placeholder_kernel_desc#mihomo#' \
    -e 's#placeholder_run_as_user##' \
    -e 's#placeholder_cmd_full#/home/william/clashctl/bin/mihomo -d /home/william/clashctl/resources -f /home/william/clashctl/resources/runtime.yaml#' \
    "$SYSTEMD_SH" >"$systemd_rendered"

assert_file_not_contains "$systemd_rendered" '^User=' \
    "rendered systemd unit should omit User= so the system service runs as root"

assert_file_not_contains "$systemd_rendered" '^CapabilityBoundingSet=' \
    "rendered systemd unit should not include capability-only root emulation"

assert_file_not_contains "$systemd_rendered" '^AmbientCapabilities=' \
    "rendered systemd unit should not include ambient capabilities"

assert_file_not_contains "$systemd_rendered" '^Limit[A-Z]' \
    "rendered systemd unit should not add project-level resource limits"

assert_file_not_contains "$systemd_rendered" 'placeholder_' \
    "rendered systemd unit should not retain placeholders"

refresh_tool_tmp=$(make_test_tmpdir "clash-refresh-systemd")
refresh_install_dir="$refresh_tool_tmp/install"
refresh_target="$refresh_tool_tmp/mihomo.service"
mkdir -p \
    "$refresh_install_dir/bin" \
    "$refresh_install_dir/resources" \
    "$refresh_install_dir/scripts/init" \
    "$refresh_install_dir/scripts/tools"
cp "$SYSTEMD_SH" "$refresh_install_dir/scripts/init/systemd.sh"
cp "$REFRESH_SYSTEMD_SH" "$refresh_install_dir/scripts/tools/refresh-systemd-service.sh"
printf 'clash-for-linux-install-multimode\n' >"$refresh_install_dir/.clashctl-install-root"
cat >"$refresh_install_dir/resources/install-state.yaml" <<EOF
install_dir: "$refresh_install_dir"
kernel_name: "mihomo"
default_mode: "tmux"
installed_systemd_service: true
versions:
  mihomo: "v-test"
  yq: "v-test"
  subconverter: "v-test"
EOF
CLASHCTL_REFRESH_SYSTEMD_ALLOW_NON_ROOT=1 \
    CLASHCTL_REFRESH_SYSTEMD_TARGET="$refresh_target" \
    CLASHCTL_REFRESH_SYSTEMD_SKIP_DAEMON_RELOAD=1 \
    CLASHCTL_REFRESH_SYSTEMD_SKIP_SYSTEMCTL_CAT=1 \
    CLASHCTL_REFRESH_SYSTEMD_SKIP_VERIFY=1 \
    bash "$refresh_install_dir/scripts/tools/refresh-systemd-service.sh" >/dev/null

assert_file_not_contains "$refresh_target" '^User=' \
    "systemd refresh tool should render root-run systemd units by omitting User="

assert_file_not_contains "$refresh_target" '^CapabilityBoundingSet=' \
    "systemd refresh tool should not render capability-only root emulation"

assert_file_not_contains "$refresh_target" '^AmbientCapabilities=' \
    "systemd refresh tool should not render ambient capabilities"

assert_file_not_contains "$refresh_target" '^Limit[A-Z]' \
    "systemd refresh tool should not render project-level resource limits"

assert_file_not_contains "$refresh_target" 'placeholder_' \
    "systemd refresh tool should not leave placeholders in the unit"

assert_file_contains "$PREFLIGHT_SH" '--init=' \
    "_parse_args should accept --init=<mode>"

assert_file_contains "$PREFLIGHT_SH" '--init' \
    "_parse_args should accept --init <mode>"

clashtun_body=$(extract_function "clashtun" "$TUN_SH")
[ -n "$clashtun_body" ] ||
    fail "extract_function should read function-style clashtun definitions"
grep -q 'no-sudo 版已禁用' <<<"$clashtun_body" &&
    fail "clashtun should be mode-gated instead of permanently disabled"

assert_file_contains "$TUN_SH" 'tunon\(\)' \
    "clashctl should provide tunon implementation for sudo-capable mode"

assert_file_contains "$TUN_SH" 'resolvectl' \
    "tun status should inspect systemd-resolved instead of only checking the Tun link"

assert_file_contains "$INSTALL_SH" '_parse_args "\$@"' \
    "install.sh should parse command-line overrides before detecting init"

service_guard_tmp=$(make_test_tmpdir "clash-service-guard")
(
    set +e
    . "$CLASHCTL_SH"
    . "$PREFLIGHT_SH"

    KERNEL_NAME=mihomo
    INIT_TYPE=systemd
    CLASH_BASE_DIR="$service_guard_tmp/current"
    CLASH_RESOURCES_DIR="$CLASH_BASE_DIR/resources"
    CLASH_CONFIG_RUNTIME="$CLASH_RESOURCES_DIR/runtime.yaml"
    BIN_KERNEL="$CLASH_BASE_DIR/bin/mihomo"
    service_target="$service_guard_tmp/mihomo.service"
    service_src="$service_guard_tmp/systemd.sh"
    service_add=()
    service_enable=(true)
    service_reload=(true)
    mkdir -p "$service_guard_tmp" "$CLASH_RESOURCES_DIR" "$CLASH_BASE_DIR/bin"
    printf 'ExecStart=/opt/other/mihomo -d /opt/other/resources -f /opt/other/runtime.yaml\n' >"$service_target"
    printf 'ExecStart=placeholder_cmd_full\n' >"$service_src"
    _error_quit() {
        printf '%s\n' "$*" >"$service_guard_tmp/error.log"
        return 1
    }

    _install_service
    status=$?
    [ "$status" -ne 0 ] ||
        fail "_install_service should reject an existing systemd unit that belongs to another install"
    grep -qx 'ExecStart=/opt/other/mihomo -d /opt/other/resources -f /opt/other/runtime.yaml' "$service_target" ||
        fail "_install_service should not overwrite an unrelated existing systemd unit"
)

service_vendor_guard_tmp=$(make_test_tmpdir "clash-service-vendor-guard")
(
    set +e
    . "$CLASHCTL_SH"
    . "$PREFLIGHT_SH"

    KERNEL_NAME=mihomo
    INIT_TYPE=systemd
    CLASH_BASE_DIR="$service_vendor_guard_tmp/current"
    CLASH_RESOURCES_DIR="$CLASH_BASE_DIR/resources"
    CLASH_CONFIG_RUNTIME="$CLASH_RESOURCES_DIR/runtime.yaml"
    BIN_KERNEL="$CLASH_BASE_DIR/bin/mihomo"
    service_target="$service_vendor_guard_tmp/etc/mihomo.service"
    service_src="$service_vendor_guard_tmp/systemd.sh"
    service_add=()
    service_enable=(true)
    service_reload=(true)
    mkdir -p "$service_vendor_guard_tmp" "$CLASH_RESOURCES_DIR" "$CLASH_BASE_DIR/bin"
    printf 'ExecStart=placeholder_cmd_full\n' >"$service_src"
    systemctl() {
        case "$1" in
        cat)
            printf '# /lib/systemd/system/mihomo.service\n'
            printf 'ExecStart=/opt/vendor/mihomo -d /opt/vendor/resources -f /opt/vendor/runtime.yaml\n'
            return 0
            ;;
        *)
            return 1
            ;;
        esac
    }
    _error_quit() {
        printf '%s\n' "$*" >"$service_vendor_guard_tmp/error.log"
        return 1
    }

    _install_service
    status=$?
    [ "$status" -ne 0 ] ||
        fail "_install_service should reject an existing vendor systemd unit that belongs to another install"
    [ ! -e "$service_target" ] ||
        fail "_install_service should not shadow an unrelated vendor systemd unit by writing an /etc override"
)

service_uninstall_guard_tmp=$(make_test_tmpdir "clash-service-uninstall-guard")
(
    set +e
    . "$CLASHCTL_SH"
    . "$PREFLIGHT_SH"

    KERNEL_NAME=mihomo
    INIT_TYPE=systemd
    CLASH_BASE_DIR="$service_uninstall_guard_tmp/current"
    CLASH_RESOURCES_DIR="$CLASH_BASE_DIR/resources"
    CLASH_CONFIG_RUNTIME="$CLASH_RESOURCES_DIR/runtime.yaml"
    BIN_KERNEL="$CLASH_BASE_DIR/bin/mihomo"
    service_target="$service_uninstall_guard_tmp/mihomo.service"
    mkdir -p "$service_uninstall_guard_tmp" "$CLASH_RESOURCES_DIR" "$CLASH_BASE_DIR/bin"
    printf 'ExecStart=/opt/other/mihomo -d /opt/other/resources -f /opt/other/runtime.yaml\n' >"$service_target"
    _detect_init() {
        service_target="$service_uninstall_guard_tmp/mihomo.service"
        service_disable=(sh -c "printf disable >> '$service_uninstall_guard_tmp/calls'")
        service_del=()
        service_reload=()
    }

    _uninstall_service
    status=$?
    [ "$status" -eq 0 ] ||
        fail "_uninstall_service should skip unrelated systemd units without failing"
    [ -f "$service_target" ] ||
        fail "_uninstall_service should not delete an unrelated existing systemd unit"
    [ ! -e "$service_uninstall_guard_tmp/calls" ] ||
        fail "_uninstall_service should not disable an unrelated existing systemd unit"
)

service_uninstall_force_tmp=$(make_test_tmpdir "clash-service-uninstall-force")
(
    set +e
    . "$CLASHCTL_SH"
    . "$PREFLIGHT_SH"

    KERNEL_NAME=mihomo
    INIT_TYPE=systemd
    CLASH_BASE_DIR="$service_uninstall_force_tmp/current"
    CLASH_RESOURCES_DIR="$CLASH_BASE_DIR/resources"
    CLASH_CONFIG_RUNTIME="$CLASH_RESOURCES_DIR/runtime.yaml"
    BIN_KERNEL="$CLASH_BASE_DIR/bin/mihomo"
    service_target="$service_uninstall_force_tmp/mihomo.service"
    mkdir -p "$service_uninstall_force_tmp" "$CLASH_RESOURCES_DIR" "$CLASH_BASE_DIR/bin"
    printf 'ExecStart=placeholder_cmd_full\n' >"$service_target"
    _detect_init() {
        service_target="$service_uninstall_force_tmp/mihomo.service"
        service_disable=(true)
        service_del=()
        service_reload=()
    }

    _uninstall_service --force-current-attempt
    status=$?
    [ "$status" -eq 0 ] ||
        fail "_uninstall_service --force-current-attempt should remove a unit written by a failed install attempt"
    [ ! -e "$service_target" ] ||
        fail "_uninstall_service --force-current-attempt should remove a partially rendered unit"
)

pass "service mode checks"
