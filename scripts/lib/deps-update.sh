#!/usr/bin/env bash

CLASHCTL_DEFAULT_VERSION_MIHOMO=v1.19.27
CLASHCTL_DEFAULT_VERSION_YQ=v4.53.3
CLASHCTL_DEFAULT_VERSION_SUBCONVERTER=v0.9.0

_clashdeps_usage() {
    cat <<EOF
Usage:
  clashctl update-deps [TARGET] [OPTIONS]
  clashdeps [TARGET] [OPTIONS]

Targets:
  all                  更新当前支持的依赖；mihomo 安装会包含 mihomo
  kernel, mihomo       更新当前 mihomo 内核二进制
  yq                   更新 yq
  subconverter         更新 subconverter

Options:
  download TARGET --dir <dir>
                       只下载依赖归档到暂存目录，不替换当前安装
  apply --dir <dir> [TARGET]
                       从暂存目录应用依赖替换，要求当前安装已停止
  --latest             解析 GitHub releases/latest，而不是使用项目固定稳定版本
  --gh-proxy <url>     本次依赖下载使用 GitHub 代理前缀
  --no-gh-proxy        本次依赖下载直连 GitHub
  -h, --help           显示帮助信息

Notes:
  update-self 只刷新项目脚本；update-deps 才会替换 bin/ 下的二进制。
  update-deps 不管理运行态；请先 clashoff，更新后用 clashrestart 或 clashrestart --mode <mode> 拉起。
  网络不佳但仍需要当前 Clash 代理时，可先 download 到暂存目录，停服务后再 apply。
  默认版本固定到项目确认可用的稳定 release；--latest 才追 GitHub latest。
EOF
}

_clashdeps_source_preflight() {
    local preflight="$CLASH_BASE_DIR/scripts/preflight.sh"
    [ -r "$preflight" ] || {
        _failcat "缺少安装下载函数：$preflight"
        return 1
    }
    . "$preflight"
    _error_quit() {
        [ $# -gt 0 ] && _failcat "${*: -1}"
        return 1
    }
    RESOURCES_BASE_DIR="$CLASH_RESOURCES_DIR"
    ZIP_BASE_DIR="$CLASH_RESOURCES_DIR/zip"
}

_clashdeps_stage_dir() {
    local dir=$1 create=${2:-false} real
    [ -n "$dir" ] || {
        _failcat "update-deps 需要 --dir <暂存目录>"
        return 1
    }
    case "$dir" in
    "" | "/" | "$HOME" | "$HOME/" | . | ..)
        _failcat "update-deps 暂存目录不安全：$dir"
        return 1
        ;;
    esac
    [ ! -L "$dir" ] || {
        _failcat "update-deps 暂存目录不能是符号链接：$dir"
        return 1
    }
    if [ "$create" = true ]; then
        mkdir -p "$dir" || return 1
    else
        [ -d "$dir" ] || {
            _failcat "update-deps 暂存目录不存在：$dir"
            return 1
        }
    fi
    real=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
    case "$real" in
    "" | "/" | "$HOME" | "$HOME/")
        _failcat "update-deps 暂存目录不安全：$real"
        return 1
        ;;
    esac
    printf '%s\n' "$real"
}

_clashdeps_stage_manifest() {
    printf '%s/deps-manifest.env\n' "$1"
}

_clashdeps_write_stage_manifest() {
    local stage_dir=$1 manifest
    manifest=$(_clashdeps_stage_manifest "$stage_dir")
    {
        printf 'VERSION_MIHOMO=%s\n' "${VERSION_MIHOMO##*-}"
        printf 'VERSION_YQ=%s\n' "$VERSION_YQ"
        printf 'VERSION_SUBCONVERTER=%s\n' "$VERSION_SUBCONVERTER"
    } >"$manifest"
}

_clashdeps_read_stage_manifest() {
    local manifest=$1 key value
    [ -f "$manifest" ] || {
        _failcat "暂存目录缺少依赖清单：$manifest"
        return 1
    }
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in
        VERSION_MIHOMO | VERSION_YQ | VERSION_SUBCONVERTER)
            case "$value" in
            "" | *[!a-zA-Z0-9._-]*)
                _failcat "暂存依赖清单版本值不安全：$key=$value"
                return 1
                ;;
            esac
            printf -v "$key" '%s' "$value"
            ;;
        "" | \#*)
            ;;
        *)
            _failcat "暂存依赖清单包含未知字段：$key"
            return 1
            ;;
        esac
    done <"$manifest"
}

_clashdeps_require_stage_zips() {
    local item
    _load_zip >&/dev/null
    for item in "${targets[@]}"; do
        case "$item" in
        mihomo)
            [ -n "$ZIP_MIHOMO" ] || {
                _failcat "暂存目录缺少 mihomo 归档：$ZIP_BASE_DIR"
                return 1
            }
            ;;
        yq)
            [ -n "$ZIP_YQ" ] || {
                _failcat "暂存目录缺少 yq 归档：$ZIP_BASE_DIR"
                return 1
            }
            ;;
        subconverter)
            [ -n "$ZIP_SUBCONVERTER" ] || {
                _failcat "暂存目录缺少 subconverter 归档：$ZIP_BASE_DIR"
                return 1
            }
            ;;
        esac
    done
}

_clashdeps_has_target() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

_clashdeps_normalize_targets() {
    local raw item targets=() printed=()
    (($#)) || set -- all

    for raw in "$@"; do
        case "$raw" in
        all)
            [ "$KERNEL_NAME" = mihomo ] && targets+=(mihomo)
            targets+=(yq subconverter)
            ;;
        kernel | mihomo)
            [ "$KERNEL_NAME" = mihomo ] || {
                _failcat "update-deps 目前只支持更新 mihomo 内核；当前内核：$KERNEL_NAME"
                return 1
            }
            targets+=(mihomo)
            ;;
        yq | subconverter)
            targets+=("$raw")
            ;;
        *)
            _failcat "未知依赖目标：$raw"
            return 1
            ;;
        esac
    done

    for item in "${targets[@]}"; do
        _clashdeps_has_target "$item" "${printed[@]:-}" && continue
        printed+=("$item")
        printf '%s\n' "$item"
    done
}

_clashdeps_collect_targets() {
    local target_output item
    target_output=$(_clashdeps_normalize_targets "$@") || return 1
    targets=()
    while IFS= read -r item; do
        [ -n "$item" ] && targets+=("$item")
    done <<EOF
$target_output
EOF
    ((${#targets[@]})) || return 1
}

_clashdeps_state_version() {
    local key=$1 value
    [ -f "$CLASH_INSTALL_STATE" ] || return 1
    value=$("$BIN_YQ" ".versions.${key} // \"\"" "$CLASH_INSTALL_STATE" 2>/dev/null) || return 1
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

_clashdeps_clear_zip_cache() {
    local item
    [ ! -L "$ZIP_BASE_DIR" ] || {
        _failcat "依赖缓存目录不能是符号链接：$ZIP_BASE_DIR"
        return 1
    }
    case "$ZIP_BASE_DIR" in
    "" | "/" | "$HOME" | "$HOME/" | . | .. | ./* | ../*)
        _failcat "依赖缓存目录不安全：${ZIP_BASE_DIR:-<empty>}"
        return 1
        ;;
    esac
    mkdir -p "$ZIP_BASE_DIR" || return 1

    for item in "$@"; do
        case "$item" in
        mihomo)
            find "$ZIP_BASE_DIR" -maxdepth 1 \( -type f -o -type l \) -name 'mihomo*' -exec rm -f {} +
            ;;
        yq)
            find "$ZIP_BASE_DIR" -maxdepth 1 \( -type f -o -type l \) -name 'yq*' -exec rm -f {} +
            ;;
        subconverter)
            find "$ZIP_BASE_DIR" -maxdepth 1 \( -type f -o -type l \) -name 'subconverter*' -exec rm -f {} +
            ;;
        esac
    done
}

_clashdeps_path_in_install() {
    local target_path=$1 base_real parent real suffix

    [ ! -L "$target_path" ] || {
        _failcat "依赖更新拒绝使用符号链接路径：$target_path"
        return 1
    }

    base_real=$(cd "$CLASH_BASE_DIR" 2>/dev/null && pwd -P) || return 1
    if [ -d "$target_path" ]; then
        real=$(cd "$target_path" 2>/dev/null && pwd -P) || return 1
    else
        parent=$(dirname "$target_path")
        while :; do
            [ ! -L "$parent" ] || {
                _failcat "依赖更新拒绝使用符号链接路径：$parent"
                return 1
            }
            [ -d "$parent" ] && break
            [ "$parent" != "/" ] || return 1
            parent=$(dirname "$parent")
        done
        real=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
        suffix=${target_path#"$parent"/}
        real="${real}/${suffix}"
    fi

    case "$real" in
    "$base_real"/*)
        return 0
        ;;
    *)
        _failcat "依赖更新路径不属于当前安装目录：$target_path"
        return 1
        ;;
    esac
}

_clashdeps_validate_managed_paths() {
    local target_path
    for target_path in \
        "$BIN_BASE_DIR" \
        "$BIN_YQ" \
        "$BIN_BASE_DIR/mihomo" \
        "$BIN_SUBCONVERTER_DIR" \
        "$BIN_SUBCONVERTER" \
        "$BIN_SUBCONVERTER_DIR/pref.example.yml" \
        "$BIN_SUBCONVERTER_CONFIG" \
        "$ZIP_BASE_DIR" \
        "$CLASH_BASE_DIR/.env" \
        "$CLASH_INSTALL_STATE"; do
        _clashdeps_path_in_install "$target_path" || return 1
    done
    return 0
}

_clashdeps_reject_root_for_user_install() {
    local owner_uid
    [ "$(id -u)" -eq 0 ] || return 0
    owner_uid=$(stat -c '%u' "$CLASH_BASE_DIR" 2>/dev/null) || return 1
    [ "$owner_uid" = 0 ] && return 0
    _failcat "update-deps 不需要 sudo；请切回安装目录属主执行：$CLASH_BASE_DIR"
    return 1
}

_clashdeps_reject_if_active() {
    local modes active_status unmanaged_pids unmanaged_summary
    modes=$(_get_active_mode 2>/dev/null)
    active_status=$?
    if [ "$active_status" -eq 0 ] || [ "$active_status" -eq 2 ]; then
        _failcat "检测到当前安装仍在运行：${modes:-unknown}。请先执行 clashoff，更新后再 clashrestart 或 clashrestart --mode <mode>。"
        return 1
    fi

    unmanaged_pids=$(_current_kernel_pids 2>/dev/null || true)
    [ -z "$unmanaged_pids" ] && return 0
    unmanaged_summary=$(printf '%s\n' "$unmanaged_pids" | awk 'NF { printf "%s%s", sep, $0; sep = ", " }')

    _failcat "检测到当前安装存在未托管内核进程：${unmanaged_summary:-unknown}。update-deps 不会终止进程；请先执行 clashrestart 接管后再 clashoff，或手动停止该进程。"
    return 1
}

_clashdeps_pre_lock_check() {
    _clashdeps_reject_root_for_user_install || return 1
    _clashdeps_path_in_install "$CLASH_RESOURCES_DIR" || return 1
    return 0
}

_clashdeps_reject_if_subconverter_active() {
    local pid exe
    [ -f "$BIN_SUBCONVERTER_PID" ] || return 0
    read -r pid <"$BIN_SUBCONVERTER_PID" || return 0
    case "$pid" in
    '' | *[!0-9]*)
        return 0
        ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 0
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    [ "$exe" = "$BIN_SUBCONVERTER" ] || return 0
    _failcat "subconverter 正在运行，update-deps 不会主动停止它；请稍后重试或先结束转换进程"
    return 1
}

_clashdeps_backup_file() {
    local src=$1 dst=$2 marker=$3

    if [ -e "$src" ]; then
        cp -p "$src" "$dst"
        return $?
    fi

    : >"$CLASHDEPS_BACKUP/missing/$marker"
}

_clashdeps_backup_current() {
    CLASHDEPS_BACKUP="$CLASHDEPS_TMP/backup"
    mkdir -p "$CLASHDEPS_BACKUP/subconverter" "$CLASHDEPS_BACKUP/missing" || return 1
    [ -d "$BIN_SUBCONVERTER_DIR" ] || : >"$CLASHDEPS_BACKUP/missing/subconverter-dir"
    _clashdeps_backup_file "$BIN_BASE_DIR/mihomo" "$CLASHDEPS_BACKUP/mihomo" mihomo || return 1
    _clashdeps_backup_file "$BIN_YQ" "$CLASHDEPS_BACKUP/yq" yq || return 1
    _clashdeps_backup_file "$BIN_SUBCONVERTER" "$CLASHDEPS_BACKUP/subconverter/subconverter" subconverter-bin || return 1
    _clashdeps_backup_file "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$CLASHDEPS_BACKUP/subconverter/pref.example.yml" subconverter-pref-example || return 1
    _clashdeps_backup_file "$BIN_SUBCONVERTER_CONFIG" "$CLASHDEPS_BACKUP/subconverter/pref.yml" subconverter-pref || return 1
    _clashdeps_backup_file "$CLASH_BASE_DIR/.env" "$CLASHDEPS_BACKUP/env" env || return 1
    _clashdeps_backup_file "$CLASH_INSTALL_STATE" "$CLASHDEPS_BACKUP/install-state.yaml" install-state || return 1
}

_clashdeps_restore_file() {
    local dst=$1 backup=$2 marker=$3

    if [ -e "$backup" ]; then
        cp -p "$backup" "$dst" 2>/dev/null || {
            _failcat "依赖更新回滚失败：$dst"
            return 1
        }
        return 0
    fi

    if [ -e "$CLASHDEPS_BACKUP/missing/$marker" ]; then
        rm -f "$dst" 2>/dev/null || {
            _failcat "依赖更新回滚失败：$dst"
            return 1
        }
    fi
}

_clashdeps_restore_current() {
    local restore_status=0

    [ -n "${CLASHDEPS_BACKUP:-}" ] && [ -d "$CLASHDEPS_BACKUP" ] || return 0
    _clashdeps_restore_file "$BIN_BASE_DIR/mihomo" "$CLASHDEPS_BACKUP/mihomo" mihomo || restore_status=1
    _clashdeps_restore_file "$BIN_YQ" "$CLASHDEPS_BACKUP/yq" yq || restore_status=1
    _clashdeps_restore_file "$BIN_SUBCONVERTER" "$CLASHDEPS_BACKUP/subconverter/subconverter" subconverter-bin || restore_status=1
    _clashdeps_restore_file "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$CLASHDEPS_BACKUP/subconverter/pref.example.yml" subconverter-pref-example || restore_status=1
    _clashdeps_restore_file "$BIN_SUBCONVERTER_CONFIG" "$CLASHDEPS_BACKUP/subconverter/pref.yml" subconverter-pref || restore_status=1
    _clashdeps_restore_file "$CLASH_BASE_DIR/.env" "$CLASHDEPS_BACKUP/env" env || restore_status=1
    _clashdeps_restore_file "$CLASH_INSTALL_STATE" "$CLASHDEPS_BACKUP/install-state.yaml" install-state || restore_status=1
    if [ -e "$CLASHDEPS_BACKUP/missing/subconverter-dir" ] && [ -d "$BIN_SUBCONVERTER_DIR" ]; then
        rmdir "$BIN_SUBCONVERTER_DIR" 2>/dev/null || true
    fi
    return "$restore_status"
}

_clashdeps_install_mihomo() {
    local tmp="$CLASHDEPS_TMP/mihomo"
    _valid_zip "$ZIP_MIHOMO" || return 1
    gzip -dc "$ZIP_MIHOMO" >"$tmp" || return 1
    chmod +x "$tmp" || return 1
    _clashdeps_reject_if_active || return 1
    mv -f "$tmp" "$BIN_BASE_DIR/mihomo" || return 1
}

_clashdeps_install_yq() {
    local dir="$CLASHDEPS_TMP/yq" candidate
    mkdir -p "$dir"
    _valid_zip "$ZIP_YQ" || return 1
    _extract_tar_archive "$ZIP_YQ" "$dir" || return 1
    candidate=$(find "$dir" -maxdepth 1 -type f -name 'yq_*' -print -quit)
    [ -n "$candidate" ] || {
        _failcat "yq 归档中未找到可执行文件"
        return 1
    }
    chmod +x "$candidate" || return 1
    _clashdeps_reject_if_active || return 1
    mv -f "$candidate" "$BIN_YQ" || return 1
}

_clashdeps_install_subconverter() {
    local dir="$CLASHDEPS_TMP/subconverter"
    mkdir -p "$dir"
    _valid_zip "$ZIP_SUBCONVERTER" || return 1
    _extract_tar_archive "$ZIP_SUBCONVERTER" "$dir" || return 1
    [ -x "$dir/subconverter/subconverter" ] || {
        _failcat "subconverter 归档中未找到可执行文件"
        return 1
    }

    _clashdeps_reject_if_active || return 1
    _clashdeps_reject_if_subconverter_active || return 1
    mkdir -p "$BIN_SUBCONVERTER_DIR" || return 1
    mv -f "$dir/subconverter/subconverter" "$BIN_SUBCONVERTER" || return 1
    chmod +x "$BIN_SUBCONVERTER" || return 1
    if [ -f "$dir/subconverter/pref.example.yml" ]; then
        cp -f "$dir/subconverter/pref.example.yml" "$BIN_SUBCONVERTER_DIR/pref.example.yml" || return 1
    fi
    if [ ! -f "$BIN_SUBCONVERTER_CONFIG" ] && [ -f "$BIN_SUBCONVERTER_DIR/pref.example.yml" ]; then
        cp -f "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG" || return 1
    fi
}

_clashdeps_write_env_versions() {
    _set_env VERSION_MIHOMO "$1" || return 1
    _set_env VERSION_YQ "$2" || return 1
    _set_env VERSION_SUBCONVERTER "$3" || return 1
}

_clashdeps_write_versions() {
    local new_mihomo=$1 new_yq=$2 new_subconverter=$3 installed_systemd=false

    [ "${CLASH_INSTALLED_INIT_TYPE:-${INIT_TYPE:-tmux}}" = systemd ] && installed_systemd=true
    _install_state_write \
        "$CLASH_INSTALL_STATE" \
        "$CLASH_BASE_DIR" \
        "$KERNEL_NAME" \
        "${INIT_TYPE:-tmux}" \
        "$installed_systemd" \
        "$new_mihomo" \
        "$new_yq" \
        "$new_subconverter" || {
        _failcat "安装状态写入失败：$CLASH_INSTALL_STATE"
        return 1
    }

    _clashdeps_write_env_versions "$new_mihomo" "$new_yq" "$new_subconverter" || {
        _failcat "版本状态写入失败：$CLASH_BASE_DIR/.env"
        return 1
    }
}

_clashdeps_main() {
    local mode=direct latest=false gh_proxy="${URL_GH_PROXY:-}" arg stage_dir= stage_real=
    local raw_targets=() targets=() item
    local current_mihomo current_yq current_subconverter
    local new_mihomo new_yq new_subconverter

    case "${1:-}" in
    download | apply)
        mode=$1
        shift
        ;;
    esac

    while (($#)); do
        arg=$1
        shift
        case "$arg" in
        -h | --help)
            _clashdeps_usage
            return 0
            ;;
        --latest)
            [ "$mode" != apply ] || {
                _failcat "update-deps apply 只从暂存目录应用依赖，不接受下载参数：$arg"
                return 1
            }
            latest=true
            ;;
        --restart)
            _failcat "update-deps 不再管理运行态；请先 clashoff，更新后再 clashrestart 或 clashrestart --mode <mode>"
            return 1
            ;;
        --dir)
            (($#)) || {
                _failcat "--dir 需要指定暂存目录"
                return 1
            }
            stage_dir=$1
            shift
            ;;
        --dir=*)
            stage_dir=${arg#--dir=}
            ;;
        --gh-proxy)
            [ "$mode" != apply ] || {
                _failcat "update-deps apply 只从暂存目录应用依赖，不接受下载参数：$arg"
                return 1
            }
            (($#)) || {
                _failcat "--gh-proxy 需要 URL 参数"
                return 1
            }
            gh_proxy=$1
            shift
            ;;
        --gh-proxy=*)
            [ "$mode" != apply ] || {
                _failcat "update-deps apply 只从暂存目录应用依赖，不接受下载参数：$arg"
                return 1
            }
            gh_proxy=${arg#--gh-proxy=}
            ;;
        --no-gh-proxy)
            [ "$mode" != apply ] || {
                _failcat "update-deps apply 只从暂存目录应用依赖，不接受下载参数：$arg"
                return 1
            }
            gh_proxy=
            ;;
        all | kernel | mihomo | yq | subconverter)
            raw_targets+=("$arg")
            ;;
        *)
            _failcat "未知 update-deps 参数：$arg"
            return 1
            ;;
        esac
    done

    if [ "$mode" = apply ] && [ -z "$stage_dir" ]; then
        _failcat "update-deps apply 需要 --dir <暂存目录>"
        return 1
    fi
    if [ "$mode" = download ] && [ -z "$stage_dir" ]; then
        _failcat "update-deps download 需要 --dir <暂存目录>"
        return 1
    fi

    if ((${#raw_targets[@]})); then
        _clashdeps_collect_targets "${raw_targets[@]}" || return 1
    else
        _clashdeps_collect_targets all || return 1
    fi

    _clashdeps_reject_root_for_user_install || return 1
    if [ "$mode" != download ]; then
        _clashdeps_reject_if_active || return 1
    fi
    _clashdeps_source_preflight || return 1

    if [ "$mode" = download ]; then
        stage_real=$(_clashdeps_stage_dir "$stage_dir" true) || return 1
        ZIP_BASE_DIR="$stage_real/zip"
    elif [ "$mode" = apply ]; then
        _clashdeps_validate_managed_paths || return 1
        stage_real=$(_clashdeps_stage_dir "$stage_dir" false) || return 1
        ZIP_BASE_DIR="$stage_real/zip"
        [ -d "$ZIP_BASE_DIR" ] && [ ! -L "$ZIP_BASE_DIR" ] || {
            _failcat "暂存目录缺少安全的 zip 子目录：$ZIP_BASE_DIR"
            return 1
        }
        _clashdeps_read_stage_manifest "$(_clashdeps_stage_manifest "$stage_real")" || return 1
        _clashdeps_require_stage_zips || return 1
    else
        _clashdeps_validate_managed_paths || return 1
    fi

    if [ "$mode" != download ] && _clashdeps_has_target subconverter "${targets[@]}"; then
        _clashdeps_reject_if_subconverter_active || return 1
    fi
    mkdir -p "$ZIP_BASE_DIR" "$BIN_BASE_DIR" || return 1

    current_mihomo=$(_clashdeps_state_version mihomo 2>/dev/null || printf '%s\n' "${VERSION_MIHOMO:-}")
    current_yq=$(_clashdeps_state_version yq 2>/dev/null || printf '%s\n' "${VERSION_YQ:-}")
    current_subconverter=$(_clashdeps_state_version subconverter 2>/dev/null || printf '%s\n' "${VERSION_SUBCONVERTER:-}")

    if [ "$mode" != apply ]; then
        VERSION_MIHOMO=$CLASHCTL_DEFAULT_VERSION_MIHOMO
        VERSION_YQ=$CLASHCTL_DEFAULT_VERSION_YQ
        VERSION_SUBCONVERTER=$CLASHCTL_DEFAULT_VERSION_SUBCONVERTER
        [ "$latest" = true ] && VERSION_MIHOMO= VERSION_YQ= VERSION_SUBCONVERTER=
        URL_GH_PROXY=$gh_proxy
    fi

    if [ "$mode" != apply ]; then
        _clashdeps_clear_zip_cache "${targets[@]}" || return 1
        _download_zip "${targets[@]}" || return 1
    fi
    if [ "$mode" = download ]; then
        _clashdeps_write_stage_manifest "$stage_real" || return 1
        _okcat "依赖归档已下载到暂存目录：$stage_real"
        _okcat "停服务后执行：clashctl update-deps apply --dir \"$stage_real\""
        return 0
    fi

    CLASHDEPS_TMP=$(mktemp -d "${CLASH_RESOURCES_DIR}/.deps-update.XXXXXX") || return 1
    trap 'rm -rf "$CLASHDEPS_TMP" 2>/dev/null || true' EXIT

    _clashdeps_backup_current || return 1

    for item in "${targets[@]}"; do
        case "$item" in
        mihomo)
            _clashdeps_install_mihomo || {
                _clashdeps_restore_current
                return 1
            }
            ;;
        yq)
            _clashdeps_install_yq || {
                _clashdeps_restore_current
                return 1
            }
            ;;
        subconverter)
            _clashdeps_install_subconverter || {
                _clashdeps_restore_current
                return 1
            }
            ;;
        esac
    done

    new_mihomo=$current_mihomo
    new_yq=$current_yq
    new_subconverter=$current_subconverter
    _clashdeps_has_target mihomo "${targets[@]}" && new_mihomo=${VERSION_MIHOMO##*-}
    _clashdeps_has_target yq "${targets[@]}" && new_yq=$VERSION_YQ
    _clashdeps_has_target subconverter "${targets[@]}" && new_subconverter=$VERSION_SUBCONVERTER
    _clashdeps_write_versions "$new_mihomo" "$new_yq" "$new_subconverter" || {
        _clashdeps_restore_current
        return 1
    }

    _clashctl_chown_sudo_user_tree "$BIN_BASE_DIR" || true
    _clashctl_chown_sudo_user_path "$CLASH_INSTALL_STATE" || true
    _clashctl_chown_sudo_user_path "$CLASH_BASE_DIR/.env" || true

    if _clashdeps_has_target mihomo "${targets[@]}"; then
        _okcat "mihomo 磁盘二进制已更新；执行 clashrestart 或 clashrestart --mode <mode> 后生效"
    fi

    _okcat "依赖更新完成：${targets[*]}"
}

clashdeps() {
    case "${1:-}" in
    -h | --help)
        _clashdeps_usage
        return 0
        ;;
    download)
        _clashdeps_main "$@"
        return
        ;;
    esac
    ( _clashdeps_pre_lock_check && _with_service_lock _clashdeps_main "$@" )
}
