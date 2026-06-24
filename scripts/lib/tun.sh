_get_installed_init_type() {
    case "$CLASH_INSTALLED_INIT_TYPE" in
    "" | __CLASH_INIT_TYPE_UNSET__)
        echo "${INIT_TYPE:-tmux}"
        ;;
    *)
        echo "$CLASH_INSTALLED_INIT_TYPE"
        ;;
    esac
}

_tun_supported() {
    _clash_systemd_registered
}

_require_tun_runtime() {
    _tun_supported || {
        _failcat "当前安装未注册可用的 systemd 服务；如需 Tun，请先 sudo bash install.sh --init systemd"
        return 1
    }

    local active active_status
    active=$(_get_active_mode 2>/dev/null)
    active_status=$?
    [ "$active_status" -eq 0 ] && [ "$active" = systemd ] && return 0

    _failcat "Tun 需要当前内核以 systemd 模式运行；请先执行 clashrestart --mode systemd"
    return 1
}

_restore_tun_mixin() {
    local backup=$1
    local restart_after_restore=$2

    [ -f "$backup" ] || return 0
    /bin/mv -f "$backup" "$CLASH_CONFIG_MIXIN"
    _merge_config || return 1
    if [ "$restart_after_restore" = true ]; then
        _clash_service_stop systemd >/dev/null 2>&1 || true
        _clash_service_start systemd >/dev/null || {
            _failcat "Tun 配置已回滚，但 systemd 内核恢复启动失败"
            return 1
        }
    fi
    return 0
}

_tun_configured_device() {
    local device
    device=$("$BIN_YQ" '.tun.device // ""' "$CLASH_CONFIG_RUNTIME" 2>/dev/null || true)
    [ "$device" = "null" ] && device=
    printf '%s\n' "$device"
}

_tun_default_devices() {
    case "${KERNEL_NAME:-}" in
    mihomo)
        printf '%s\n' Mihomo Meta
        ;;
    *)
        printf '%s\n' Meta Mihomo
        ;;
    esac
}

_tun_device() {
    local device candidate
    device=$(_tun_configured_device)
    [ -n "$device" ] && {
        printf '%s\n' "$device"
        return 0
    }

    if command -v ip >/dev/null; then
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            ip link show "$candidate" >/dev/null 2>&1 && {
                printf '%s\n' "$candidate"
                return 0
            }
        done < <(_tun_default_devices)
    fi

    _tun_default_devices | head -n 1
}

_tun_link_is_up() {
    local device=${1:-}
    [ -n "$device" ] || device=$(_tun_device)

    command -v ip >/dev/null || {
        _failcat "未检测到 ip 命令，无法判断 Tun 状态"
        return 1
    }
    ip link show "$device" >/dev/null 2>&1
}

_tun_resolved_available() {
    command -v resolvectl >/dev/null
}

_tun_resolved_status_output() {
    local device=$1
    resolvectl status "$device" 2>/dev/null
}

_tun_resolved_output_healthy() {
    local output=$1

    grep -Eq 'Current Scopes:.*(^|[[:space:]])DNS([[:space:]]|$)' <<<"$output" &&
        grep -Eq 'DNS Servers?:' <<<"$output" &&
        grep -Eq 'DNS Domains?:.*(^|[[:space:]])~\.([[:space:]]|$)' <<<"$output"
}

_tun_resolved_healthy() {
    local device=$1 output

    _tun_resolved_available || return 2
    output=$(_tun_resolved_status_output "$device") || return 1
    _tun_resolved_output_healthy "$output"
}

_tun_resolved_wait() {
    local device=$1 deadline

    _tun_resolved_available || return 0
    deadline=$((SECONDS + 5))
    while [ "$SECONDS" -le "$deadline" ]; do
        _tun_resolved_healthy "$device" && return 0
        sleep 0.2
    done

    _failcat "Tun 设备已创建，但 systemd-resolved 未显示 DNS 接管：$device"
    _failcat "请执行：resolvectl status $device"
    _failcat "如果 unit 仍包含 User=，请先执行：sudo \"$CLASH_BASE_DIR/scripts/tools/refresh-systemd-service.sh\" && clashrestart --mode systemd"
    return 1
}

_tun_resolved_report() {
    local device=$1

    _tun_resolved_available || {
        _okcat "systemd-resolved：未检测到 resolvectl，跳过 DNS 接管检查"
        return 0
    }

    _tun_resolved_healthy "$device" && {
        _okcat "systemd-resolved：${device} DNS 已接管"
        return 0
    }

    _failcat "systemd-resolved：${device} DNS 未接管；请执行 resolvectl status $device"
    return 1
}

tunstatus() {
    _require_tun_runtime || return 1

    local device
    device=$(_tun_device)
    _tun_link_is_up "$device" && {
        _okcat "Tun 状态：启用（device=$device）"
        _tun_resolved_report "$device"
        return $?
    }
    _failcat 'Tun 状态：关闭'
    return 1
}

_is_tun_enabled() {
    "$BIN_YQ" -e '.tun.enable == true' "$CLASH_CONFIG_RUNTIME" >&/dev/null
}

_tunon_impl() {
    _require_tun_runtime || return 1

    local was_active=false backup="${CLASH_CONFIG_TEMP}.tun.bak" device
    _clash_service_is_active systemd >&/dev/null && was_active=true
    tunstatus 2>/dev/null && return 0
    cat "$CLASH_CONFIG_MIXIN" >"$backup" || return 1
    _clash_service_stop systemd >/dev/null
    "$BIN_YQ" -i '.tun.enable = true' "$CLASH_CONFIG_MIXIN"
    _merge_config || {
        _restore_tun_mixin "$backup" "$was_active"
        return 1
    }
    _clash_service_start systemd >/dev/null || {
        _restore_tun_mixin "$backup" "$was_active"
        _failcat 'Tun 模式开启失败'
        return 1
    }
    sleep 1
    device=$(_tun_device)
    _tun_link_is_up "$device" || {
        [ "$KERNEL_NAME" = 'mihomo' ] && {
            "$BIN_YQ" -i '.tun.auto-redirect = false' "$CLASH_CONFIG_MIXIN"
            _merge_config || {
                _restore_tun_mixin "$backup" "$was_active"
                return 1
            }
            _clash_service_stop systemd >/dev/null
            _clash_service_start systemd >/dev/null || {
                _restore_tun_mixin "$backup" "$was_active"
                _failcat 'Tun 模式开启失败，请检查代理内核日志'
                return 1
            }
            sleep 1
            device=$(_tun_device)
            _tun_link_is_up "$device" || {
                _restore_tun_mixin "$backup" "$was_active"
                _failcat 'Tun 模式开启失败，请检查代理内核日志'
                return 1
            }
            _tun_resolved_wait "$device" || {
                _restore_tun_mixin "$backup" "$was_active"
                return 1
            }
            /usr/bin/rm -f "$backup"
            _okcat "Tun 模式已开启"
            return 0
        }
        _restore_tun_mixin "$backup" "$was_active"
        _failcat 'Tun 模式开启失败，请检查代理内核日志'
        return 1
    }
    _tun_resolved_wait "$device" || {
        _restore_tun_mixin "$backup" "$was_active"
        return 1
    }
    /usr/bin/rm -f "$backup"
    _okcat "Tun 模式已开启"
}

tunon() {
    _with_service_lock _tunon_impl "$@"
}

_tunoff_impl() {
    _tun_supported || {
        _failcat "当前安装未注册可用的 systemd 服务；如需 Tun，请先 sudo bash install.sh --init systemd"
        return 1
    }

    local was_active=false backup="${CLASH_CONFIG_TEMP}.tun.bak" device
    device=$(_tun_device)
    _is_tun_enabled || {
        _tun_link_is_up "$device" >/dev/null 2>&1 || return 0
    }
    _clash_service_is_active systemd >&/dev/null && was_active=true
    cat "$CLASH_CONFIG_MIXIN" >"$backup" || return 1
    [ "$was_active" = true ] && _clash_service_stop systemd >/dev/null
    "$BIN_YQ" -i '.tun.enable = false' "$CLASH_CONFIG_MIXIN"
    _merge_config || {
        _restore_tun_mixin "$backup" "$was_active"
        return 1
    }
    if [ "$was_active" = true ]; then
        _clash_service_start systemd >/dev/null || {
            _restore_tun_mixin "$backup" "$was_active"
            _failcat "Tun 模式关闭失败，内核未能恢复启动"
            return 1
        }
        _tun_link_is_up "$device" >/dev/null 2>&1 && {
            _restore_tun_mixin "$backup" "$was_active"
            _failcat "Tun 模式关闭失败"
            return 1
        }
    fi
    /usr/bin/rm -f "$backup"
    _okcat "Tun 模式已关闭"
}

tunoff() {
    _with_service_lock _tunoff_impl "$@"
}

function clashtun() {
    case "${1:-}" in
    -h | --help)
        cat <<EOF

- 查看 Tun 状态和 systemd-resolved DNS 接管状态
  clashtun
  clashtun status

- 开启 Tun 模式（需要当前内核以 systemd 模式运行）
  clashtun on

- 关闭 Tun 模式（需要已注册 systemd 服务）
  clashtun off

EOF
        return 0
        ;;
    on)
        tunon
        ;;
    off)
        tunoff
        ;;
    status | "")
        tunstatus
        ;;
    *)
        tunstatus
        ;;
    esac
}
