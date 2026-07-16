#!/bin/bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/npm-global-manager.sh"
TEST_PATH="$SCRIPT_DIR/tests/npm-global-manager-test.sh"
INSTALL_SHELLCHECK_PATH="$SCRIPT_DIR/tools/install-shellcheck.sh"
LOCAL_SHELLCHECK="$SCRIPT_DIR/.runtime/tools/shellcheck/shellcheck"

printf "== syntax ==\n"
bash -n "$SCRIPT_PATH" "$TEST_PATH" "$INSTALL_SHELLCHECK_PATH" || exit 1

if [ "${NODE_MANAGER_SKIP_TESTS:-0}" != "1" ]; then
    printf "\n== tests ==\n"
    bash "$TEST_PATH" || exit 1
fi

printf "\n== shellcheck ==\n"
if [ -x "$LOCAL_SHELLCHECK" ]; then
    "$LOCAL_SHELLCHECK" "$SCRIPT_PATH" "$TEST_PATH" "$INSTALL_SHELLCHECK_PATH"
elif command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$SCRIPT_PATH" "$TEST_PATH" "$INSTALL_SHELLCHECK_PATH"
else
    portable_sort_pattern='sort -''V'
    printf "shellcheck not installed; running fallback static checks\n"
    if grep -n "$portable_sort_pattern" "$SCRIPT_PATH" "$TEST_PATH" "$INSTALL_SHELLCHECK_PATH"; then
        printf "fallback static check failed: GNU version sort is not portable on macOS\n" >&2
        exit 1
    fi
    if grep -n $'\t' "$SCRIPT_PATH" "$TEST_PATH" "$INSTALL_SHELLCHECK_PATH"; then
        printf "fallback static check failed: tab indentation found\n" >&2
        exit 1
    fi
fi
