#!/usr/bin/env bash

_DEPENDENCY_DOWNLOADS_SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE:-${(%):-%N}}")")" && pwd -P)
. "$_DEPENDENCY_DOWNLOADS_SCRIPT_DIR/archive-safe.sh"
unset _DEPENDENCY_DOWNLOADS_SCRIPT_DIR

_prepare_zip() {
    _load_zip >&/dev/null
    local required_zips=()
    case "${KERNEL_NAME}" in
    clash)
        [ ! -f "$ZIP_CLASH" ] && required_zips+=("clash")
        ;;
    mihomo | *)
        [ ! -f "$ZIP_MIHOMO" ] && required_zips+=("mihomo")
        ;;
    esac
    [ ! -f "$ZIP_YQ" ] && required_zips+=("yq")
    [ ! -f "$ZIP_SUBCONVERTER" ] && required_zips+=("subconverter")

    _download_zip "${required_zips[@]}"

    case "${KERNEL_NAME}" in
    clash)
        ZIP_KERNEL="$ZIP_CLASH"
        ;;
    mihomo | *)
        ZIP_KERNEL="$ZIP_MIHOMO"
        ;;
    esac
    BIN_KERNEL="${BIN_BASE_DIR}/$KERNEL_NAME"
    _unzip_zip
}

_first_zip_match() {
    find "$ZIP_BASE_DIR" -maxdepth 1 \( -type f -o -type l \) -name "$1" -print -quit
}

_load_zip() {
    ZIP_CLASH=$(_first_zip_match 'clash*')
    ZIP_MIHOMO=$(_first_zip_match 'mihomo*')
    ZIP_YQ=$(_first_zip_match 'yq*')
    ZIP_SUBCONVERTER=$(_first_zip_match 'subconverter*')
}

_fetch_latest_tag() {
    local repo=$1 body tag url
    url="https://api.github.com/repos/${repo}/releases/latest"
    [ -n "${URL_GH_PROXY:-}" ] && url="${URL_GH_PROXY%/}/${url}"
    body=$(
        curl \
            --silent \
            --location \
            --max-time 10 \
            --retry 1 \
            -H 'Accept: application/vnd.github+json' \
            "$url" 2>/dev/null
    ) || return 1
    tag=$(
        printf '%s' "$body" |
            grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' |
            head -1 |
            sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/'
    )
    [ -n "$tag" ] && printf '%s\n' "$tag"
}

_version_var_value() {
    case "$1" in
    VERSION_MIHOMO)
        printf '%s\n' "${VERSION_MIHOMO:-}"
        ;;
    VERSION_YQ)
        printf '%s\n' "${VERSION_YQ:-}"
        ;;
    VERSION_SUBCONVERTER)
        printf '%s\n' "${VERSION_SUBCONVERTER:-}"
        ;;
    *)
        return 1
        ;;
    esac
}

_set_version_var() {
    case "$1" in
    VERSION_MIHOMO)
        VERSION_MIHOMO=$2
        ;;
    VERSION_YQ)
        VERSION_YQ=$2
        ;;
    VERSION_SUBCONVERTER)
        VERSION_SUBCONVERTER=$2
        ;;
    *)
        return 1
        ;;
    esac
}

_resolve_version() {
    local varname=$1 repo=$2 tag
    [ -n "$(_version_var_value "$varname")" ] && return 0

    tag=$(_fetch_latest_tag "$repo") || {
        _error_quit "${repo} 版本获取失败，请在 .env 中手动指定 $varname"
        return 1
    }
    _set_version_var "$varname" "$tag" || return 1
    _okcat '🏷️ ' "${repo} -> $tag"
}

_download_zip() {
    (($#)) || return 0
    local url_clash url_mihomo url_yq url_subconverter
    local subconverter_repo=${SUBCONVERTER_REPO:-tindy2013/subconverter}
    local download_timeout=${CLASHCTL_DOWNLOAD_TIMEOUT:-60}
    local arch=$(uname -m)
    local item
    for item in "$@"; do
        case $item in
        mihomo)
            _resolve_version VERSION_MIHOMO MetaCubeX/mihomo || return 1
            ;;
        yq)
            _resolve_version VERSION_YQ mikefarah/yq || return 1
            ;;
        subconverter)
            _resolve_version VERSION_SUBCONVERTER "$subconverter_repo" || return 1
            ;;
        esac
    done

    case "$arch" in
    x86_64)
        local flags=$(grep -m1 '^flags' /proc/cpuinfo)
        local level=v1
        grep -qw sse4_2 <<<"$flags" && grep -qw popcnt <<<"$flags" && level=v2
        grep -qw avx2 <<<"$flags" && grep -qw fma <<<"$flags" && level=v3
        VERSION_MIHOMO=${level}-$VERSION_MIHOMO

        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-amd64-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_amd64.tar.gz
        url_subconverter=https://github.com/${subconverter_repo}/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux64.tar.gz
        ;;
    *86*)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-386-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_386.tar.gz
        url_subconverter=https://github.com/${subconverter_repo}/releases/download/${VERSION_SUBCONVERTER}/subconverter_linux32.tar.gz
        ;;
    armv*)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-armv7-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_arm.tar.gz
        url_subconverter=https://github.com/${subconverter_repo}/releases/download/${VERSION_SUBCONVERTER}/subconverter_armv7.tar.gz
        ;;
    aarch64)
        url_clash=https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz
        url_mihomo=https://github.com/MetaCubeX/mihomo/releases/download/${VERSION_MIHOMO##*-}/mihomo-linux-arm64-${VERSION_MIHOMO}.gz
        url_yq=https://github.com/mikefarah/yq/releases/download/${VERSION_YQ}/yq_linux_arm64.tar.gz
        url_subconverter=https://github.com/${subconverter_repo}/releases/download/${VERSION_SUBCONVERTER}/subconverter_aarch64.tar.gz
        ;;
    *)
        _error_quit "未知的架构版本：$arch，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录"
        ;;
    esac

    local -A urls=(
        [clash]="$url_clash"
        [mihomo]="$url_mihomo"
        [yq]="$url_yq"
        [subconverter]="$url_subconverter"
    )

    local target_zips=()
    _okcat '🖥️ ' "系统架构：$arch $level"
    for item in "$@"; do
        local url="${urls[$item]}"
        local proxy_url="${URL_GH_PROXY:+${URL_GH_PROXY%/}/}${url}"
        [ "$item" != 'clash' ] && url="$proxy_url"
        _okcat '⏳' "正在下载：${item}：$url"
        local target="${ZIP_BASE_DIR}/$(basename "$url")"
        curl \
            --progress-bar \
            --show-error \
            --fail \
            --location \
            --max-time "$download_timeout" \
            --retry 1 \
            --output "$target" \
            "$url"
        target_zips+=("$target")
    done
    _valid_zip "${target_zips[@]}"
    _load_zip >&/dev/null
}

_valid_zip() {
    (($#)) || return 1
    local zip fail_zips=()
    for zip in "$@"; do
        gzip -tq "$zip" || unzip -tqq "$zip" || fail_zips+=("$zip")
    done

    if ((${#fail_zips[@]})); then
        _error_quit "文件验证失败：${fail_zips[*]} 请删除后重试，或自行下载对应版本至 ${ZIP_BASE_DIR} 目录"
        return $?
    fi
    return 0
}

_unzip_zip() {
    _valid_zip "$ZIP_KERNEL" "$ZIP_YQ" "$ZIP_SUBCONVERTER" "$ZIP_UI"
    install -D <(gzip -dc "$ZIP_KERNEL") "$BIN_KERNEL" || return 1
    _extract_tar_archive "$ZIP_YQ" "${BIN_BASE_DIR}" || return 1
    mv -f "${BIN_BASE_DIR}"/yq_* "${BIN_BASE_DIR}/yq" || return 1
    _extract_tar_archive "$ZIP_SUBCONVERTER" "$BIN_BASE_DIR" || return 1
    cp "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG" || return 1
    _extract_zip_archive "$ZIP_UI" "$RESOURCES_BASE_DIR" 2>/dev/null ||
        _extract_tar_archive "$ZIP_UI" "$RESOURCES_BASE_DIR" || return 1
    [ -x "$BIN_KERNEL" ] || return 1
    [ -x "$BIN_YQ" ] || return 1
    [ -x "$BIN_SUBCONVERTER" ] || return 1
}
