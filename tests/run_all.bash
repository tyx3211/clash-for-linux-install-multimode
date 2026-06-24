#!/usr/bin/env bash

set -euo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd -P)

cd "$REPO_ROOT"

_display_path() {
    local file=$1

    case "$file" in
    "$REPO_ROOT"/*)
        printf '%s\n' "${file#"$REPO_ROOT"/}"
        ;;
    *)
        printf '%s\n' "$file"
        ;;
    esac
}

_resolve_test_arg() {
    local arg=$1 resolved

    case "$arg" in
    /*)
        printf '%s\n' "$arg"
        ;;
    *)
        resolved="$REPO_ROOT/$arg"
        [ -f "$resolved" ] || resolved="$TESTS_DIR/$arg"
        printf '%s\n' "$resolved"
        ;;
    esac
}

_run_syntax_check() {
    echo "==> bash -n"
    bash -n \
        install.sh \
        update.sh \
        migrate.sh \
        uninstall.sh \
        scripts/cmd/*.sh \
        scripts/lib/*.sh \
        scripts/install/*.sh \
        scripts/preflight.sh \
        tests/*.bash \
        tests/lib/*.bash
}

_run_diff_check() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    echo "==> git diff --check"
    git diff --check
}

_run_tests() {
    local test_file

    echo "==> bash tests"
    for test_file in "$@"; do
        [ -f "$test_file" ] || {
            printf 'missing test file: %s\n' "$(_display_path "$test_file")" >&2
            printf 'test arguments are resolved relative to the repository root; bare names also try tests/<name>.\n' >&2
            return 1
        }

        printf 'RUN %s\n' "$(_display_path "$test_file")"
        bash "$test_file"
    done
}

main() {
    local tests=() arg

    if (($#)); then
        for arg in "$@"; do
            tests+=("$(_resolve_test_arg "$arg")")
        done
    else
        tests=("$TESTS_DIR"/test_*.bash)
    fi

    _run_syntax_check
    _run_tests "${tests[@]}"
    _run_diff_check
}

main "$@"
