#!/usr/bin/env bash

_env_write_set() {
    [ "$#" -eq 3 ] || {
        printf 'usage: _env_write_set <env_path> <key> <value>\n' >&2
        return 1
    }

    local env_path=$1
    local key=$2
    local value=$3
    local escaped

    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        printf 'invalid env key: %s\n' "$key" >&2
        return 1
    }

    case "$value" in
    *$'\n'* | *$'\r'*)
        printf 'invalid env value for %s: only single-line values are supported\n' "$key" >&2
        return 1
        ;;
    esac

    if [ -f "$env_path" ] && grep -qE "^${key}=" "$env_path"; then
        escaped=$(printf '%s' "$value" | sed 's/[\\&|]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${escaped}|" "$env_path"
        return $?
    fi

    printf '%s=%s\n' "$key" "$value" >>"$env_path"
}
