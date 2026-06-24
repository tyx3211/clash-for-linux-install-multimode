#!/usr/bin/env bash

# root rc 同步工具只服务一个很窄的场景：单用户机器上，普通用户用
# systemd/Tun 运行 clashctl，但偶尔切到 root shell 时也想复用同一套代理入口。
# 这不是共享机默认路线，所以所有入口都要求显式 sudo；测试环境可以通过
# CLASHCTL_ROOT_RC_ALLOW_NON_ROOT=1 绕过 root 检查，但正式文档不暴露这个开关。

_root_rc_die() {
    printf '📢 %s\n' "$1" >&2
    exit 1
}

_root_rc_ok() {
    printf '😼 %s\n' "$1"
}

_root_rc_require_root_or_test() {
    # 真实使用时必须是 root，因为默认目标是 /root/.bashrc。测试里会把目标
    # rc 文件重定向到临时目录，因此允许显式测试开关跳过 root 检查。
    [ "$(id -u)" -eq 0 ] && return 0
    [ "${CLASHCTL_ROOT_RC_ALLOW_NON_ROOT:-}" = 1 ] && return 0
    _root_rc_die "请使用 sudo 执行：sudo $0"
}

_root_rc_install_dir() {
    # 脚本安装在 <install>/scripts/tools 下；从脚本自身位置反推安装目录，
    # 避免依赖调用者当前目录，也避免 root shell 中 HOME=/root 导致路径漂移。
    local tool_dir install_dir
    tool_dir=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd -P) ||
        _root_rc_die "无法定位工具脚本目录"
    install_dir=$(cd "$tool_dir/../.." && pwd -P) ||
        _root_rc_die "无法定位 clashctl 安装目录"
    printf '%s\n' "$install_dir"
}

_root_rc_cmd_dir_from_install() {
    # rc block 以 scripts/cmd 目录作为唯一身份标识。这样同一台机器上存在
    # 多个 clashctl 安装时，删除当前安装 block 不会误删其它安装的 block。
    local install_dir=$1
    printf '%s/scripts/cmd\n' "$install_dir"
}

_root_rc_recorded_install_dir() {
    # 安装脚本写入用户 rc 时使用的是 CLASH_BASE_DIR 字符串，不一定等同于
    # pwd -P 得到的真实路径。这里优先读取 install-state.yaml 中的 install_dir，
    # 让同步/删除工具使用和安装时同一条路径字符串匹配 rc block。
    local install_dir=$1 state_file value
    state_file="$install_dir/resources/install-state.yaml"
    if [ -r "$state_file" ]; then
        value=$(awk '
            $1 == "install_dir:" {
                sub(/^[^:]*:[[:space:]]*/, "", $0)
                sub(/^"/, "", $0)
                sub(/"$/, "", $0)
                print $0
                exit
            }
        ' "$state_file")
        [ -n "$value" ] && {
            printf '%s\n' "$value"
            return 0
        }
    fi

    # fallback：旧安装或源码仓库测试环境可能没有 install-state.yaml。
    # 这时退回工具脚本所在的真实安装目录，代价是父目录符号链接场景需要
    # 用户显式传 --cmd-dir 才能匹配旧 rc block。
    printf '%s\n' "$install_dir"
}

_root_rc_file_owner_home() {
    # sudo 执行时 SUDO_USER 不一定等于安装目录 owner，例如管理员从 A 用户
    # sudo 到 root 后维护 B 用户的安装目录。这里以安装目录 owner 为准，
    # 找不到 owner home 时才失败，避免把 B 的入口同步成 A 的 rc。
    local path=$1 uid home
    uid=$(stat -c '%u' "$path" 2>/dev/null) ||
        _root_rc_die "无法读取安装目录属主：$path"
    home=$(awk -F: -v uid="$uid" '$3 == uid { print $6; exit }' /etc/passwd)
    [ -n "$home" ] ||
        _root_rc_die "无法从 /etc/passwd 解析安装目录属主 uid：$uid"
    printf '%s\n' "$home"
}

_root_rc_source_file() {
    # 主路径：从安装目录 owner 的 ~/.bashrc 抽取用户安装时写入的 clashctl 块。
    # fallback：测试或特殊排障可以显式传 CLASHCTL_ROOT_RC_SOURCE，但正式使用
    # 不建议依赖它，避免把任意文件内容写入 root rc。
    local install_dir=$1 home
    if [ -n "${CLASHCTL_ROOT_RC_SOURCE:-}" ]; then
        printf '%s\n' "$CLASHCTL_ROOT_RC_SOURCE"
        return 0
    fi

    home=$(_root_rc_file_owner_home "$install_dir")
    printf '%s/.bashrc\n' "$home"
}

_root_rc_target_file() {
    # 默认目标是 root 的 bash rc。测试可以把目标重定向到临时文件；真实用户
    # 不需要设置这个变量，也不建议用它写其它用户的 rc 文件。
    printf '%s\n' "${CLASHCTL_ROOT_RC_TARGET:-/root/.bashrc}"
}

_root_rc_resolve_target_file() {
    local target_rc=$1 resolved

    # 如果 /root/.bashrc 是符号链接，必须写符号链接目标，不能用 mv 替换链接
    # 本身；否则会破坏用户或运维通过 dotfiles 管理 root rc 的关系。
    if [ -L "$target_rc" ]; then
        resolved=$(readlink -f "$target_rc") ||
            _root_rc_die "root bash rc 符号链接目标不可解析：$target_rc"
        [ -n "$resolved" ] ||
            _root_rc_die "root bash rc 符号链接目标为空：$target_rc"
        target_rc=$resolved
    fi

    # 目标存在时必须是普通文件。目录、设备文件等都拒绝，避免 mv 把临时文件
    # 塞进目录或覆盖不该覆盖的特殊路径。
    [ ! -e "$target_rc" ] || [ -f "$target_rc" ] ||
        _root_rc_die "root bash rc 不是普通文件：$target_rc"

    printf '%s\n' "$target_rc"
}

_root_rc_extract_block() {
    local source_rc=$1 cmd_dir=$2 source_line=". $cmd_dir/clashctl.sh"

    # 只抽取包含当前安装 source 行的 clashctl block。我们不按宽泛关键字匹配，
    # 是为了避免把其它 clashctl 安装、用户手写片段或旧目录片段同步到 root。
    awk -v source_line="$source_line" '
        /^# clashctl START/ {
            inside = 1
            matched = 0
            block = $0 ORS
            next
        }
        inside {
            block = block $0 ORS
            if ($0 == source_line) {
                matched = 1
            }
            if ($0 ~ /^# clashctl END/) {
                if (matched) {
                    printf "%s", block
                    found = 1
                    exit 0
                }
                inside = 0
                block = ""
            }
            next
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$source_rc"
}

_root_rc_remove_block_to_stdout() {
    local target_rc=$1 cmd_dir=$2 source_line=". $cmd_dir/clashctl.sh"

    # 删除逻辑和安装时 _revoke_rc_file 保持同一不变量：只删除包含当前安装
    # source 行的 block。其它 block 原样输出，未闭合的异常 block 也原样保留。
    awk -v source_line="$source_line" '
        /^# clashctl START/ {
            inside = 1
            matched = 0
            block = $0 ORS
            next
        }
        inside {
            block = block $0 ORS
            if ($0 == source_line) {
                matched = 1
            }
            if ($0 ~ /^# clashctl END/) {
                if (!matched) {
                    printf "%s", block
                } else {
                    found = 1
                }
                inside = 0
                block = ""
            }
            next
        }
        { print }
        END {
            if (inside) {
                printf "%s", block
            }
            exit found ? 0 : 2
        }
    ' "$target_rc"
}

_root_rc_copy_file_metadata() {
    local source=$1 target=$2 mode owner

    mode=$(stat -c '%a' "$source" 2>/dev/null || true)
    [ -n "$mode" ] && chmod "$mode" "$target" 2>/dev/null || true

    [ "$(id -u)" -eq 0 ] || return 0
    owner=$(stat -c '%u:%g' "$source" 2>/dev/null || true)
    [ -n "$owner" ] && chown "$owner" "$target" 2>/dev/null || true
}

_root_rc_write_atomic() {
    local target_rc=$1 content_file=$2 target_dir tmp_file

    # root rc 是用户启动 shell 的入口文件，写坏会影响后续登录体验，因此总是
    # 在同目录创建临时文件，再 mv 原子替换；已有文件的权限和属主会被继承。
    target_rc=$(_root_rc_resolve_target_file "$target_rc")
    target_dir=$(dirname "$target_rc")
    mkdir -p "$target_dir" || _root_rc_die "无法创建 root rc 目录：$target_dir"
    [ -e "$target_rc" ] || : >"$target_rc"

    tmp_file=$(mktemp "$target_dir/.clashctl-root-rc.XXXXXX") ||
        _root_rc_die "无法创建 root rc 临时文件：$target_dir"
    _root_rc_copy_file_metadata "$target_rc" "$tmp_file"

    cat "$content_file" >"$tmp_file" || {
        rm -f "$tmp_file"
        _root_rc_die "无法写入 root rc 临时文件：$tmp_file"
    }
    mv -f "$tmp_file" "$target_rc" || {
        rm -f "$tmp_file"
        _root_rc_die "无法替换 root rc：$target_rc"
    }
}
