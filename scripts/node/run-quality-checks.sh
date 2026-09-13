#!/bin/bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/npm-global-manager.sh"
MANAGER_DIR="$(cd "$SCRIPT_DIR/../node-manager" && pwd)"
MANAGER_PATH="$MANAGER_DIR/main.sh"
TEST_PATH="$SCRIPT_DIR/tests/npm-global-manager-test.sh"
INSTALL_SHELLCHECK_PATH="$SCRIPT_DIR/tools/install-shellcheck.sh"
LOCAL_SHELLCHECK="$MANAGER_DIR/.runtime/tools/shellcheck/shellcheck"
CHECK_PATHS=(
    "$SCRIPT_PATH"
    "$MANAGER_PATH"
    "$MANAGER_DIR"/lib/*.sh
    "$TEST_PATH"
    "$INSTALL_SHELLCHECK_PATH"
)

printf "== syntax ==\n"
bash -n "${CHECK_PATHS[@]}" || exit 1

if [ "${NODE_MANAGER_SKIP_TESTS:-0}" != "1" ]; then
    printf "\n== tests ==\n"
    bash "$TEST_PATH" || exit 1
fi

printf "\n== shellcheck ==\n"
if [ -x "$LOCAL_SHELLCHECK" ]; then
    "$LOCAL_SHELLCHECK" -x -P SCRIPTDIR "$SCRIPT_PATH" || exit 1
    "$LOCAL_SHELLCHECK" "$TEST_PATH" "$INSTALL_SHELLCHECK_PATH" || exit 1
elif command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -P SCRIPTDIR "$SCRIPT_PATH" || exit 1
    shellcheck "$TEST_PATH" "$INSTALL_SHELLCHECK_PATH" || exit 1
else
    portable_sort_pattern='sort -''V'
    printf "shellcheck not installed; running fallback static checks\n"
    if grep -n "$portable_sort_pattern" "${CHECK_PATHS[@]}"; then
        printf "fallback static check failed: GNU version sort is not portable on macOS\n" >&2
        exit 1
    fi
    if grep -n $'\t' "${CHECK_PATHS[@]}"; then
        printf "fallback static check failed: tab indentation found\n" >&2
        exit 1
    fi
fi
