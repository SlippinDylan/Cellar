#!/bin/bash

# Unified npm / Node global environment manager for macOS.
# Environment: local interactive shell on macOS.
# Purpose: manage nvm, Node.js versions, npm global packages, and npm registry configuration.

set -u
set -o pipefail

# ──────────────────────────────────────────────
# Constants & globals
# ──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
CONFIG_DIR="$SCRIPT_DIR/config"
DEFAULT_GLOBAL_PACKAGES_FILE="$CONFIG_DIR/global-packages.txt"

NVM_INSTALL_VERSION="${NVM_INSTALL_VERSION:-v0.40.5}"
NVM_INSTALL_URL="${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_INSTALL_VERSION}/install.sh}"
NVM_INSTALL_SHA256="${NVM_INSTALL_SHA256:-582070e4c44452c1d8d68e16fc786c2216ecba6bc6bf18dc280a03fdba6ed1a9}"
NVM_ALLOW_UNVERIFIED_INSTALL="${NVM_ALLOW_UNVERIFIED_INSTALL:-0}"

GLOBAL_PACKAGES_FILE="${GLOBAL_PACKAGES_FILE:-$DEFAULT_GLOBAL_PACKAGES_FILE}"
INSTALL_MAX_RETRIES=2

PROTECTED_GLOBAL_PACKAGES=("npm" "corepack")
HELD_RUNTIME_LOCKS=""
RUNTIME_LOCK_OWNER_TOKEN="${RUNTIME_LOCK_OWNER_TOKEN:-$$-$RANDOM-$RANDOM}"

# Feature modules are sourced into this process so they share the manager's
# configuration and runtime state while remaining organized by responsibility.
LIB_DIR="$SCRIPT_DIR/lib"

load_manager_modules() {
    # shellcheck source=lib/runtime.sh
    source "$LIB_DIR/runtime.sh" || return 1
    # shellcheck source=lib/ui.sh
    source "$LIB_DIR/ui.sh" || return 1
    # shellcheck source=lib/input.sh
    source "$LIB_DIR/input.sh" || return 1
    # shellcheck source=lib/nvm.sh
    source "$LIB_DIR/nvm.sh" || return 1
    # shellcheck source=lib/inventory.sh
    source "$LIB_DIR/inventory.sh" || return 1
    # shellcheck source=lib/package.sh
    source "$LIB_DIR/package.sh" || return 1
    # shellcheck source=lib/registry.sh
    source "$LIB_DIR/registry.sh" || return 1
    # shellcheck source=lib/node_actions.sh
    source "$LIB_DIR/node_actions.sh" || return 1
    # shellcheck source=lib/menu.sh
    source "$LIB_DIR/menu.sh" || return 1
    # shellcheck source=lib/install.sh
    source "$LIB_DIR/install.sh" || return 1
    # shellcheck source=lib/uninstall.sh
    source "$LIB_DIR/uninstall.sh" || return 1
    # shellcheck source=lib/update.sh
    source "$LIB_DIR/update.sh" || return 1
    # shellcheck source=lib/cleanup.sh
    source "$LIB_DIR/cleanup.sh" || return 1
    # shellcheck source=lib/node_install.sh
    source "$LIB_DIR/node_install.sh" || return 1
    # shellcheck source=lib/node_uninstall.sh
    source "$LIB_DIR/node_uninstall.sh" || return 1
    # shellcheck source=lib/project.sh
    source "$LIB_DIR/project.sh" || return 1
    # shellcheck source=lib/environment.sh
    source "$LIB_DIR/environment.sh" || return 1
    # shellcheck source=lib/json_common.sh
    source "$LIB_DIR/json_common.sh" || return 1
    # shellcheck source=lib/json_read.sh
    source "$LIB_DIR/json_read.sh" || return 1
    # shellcheck source=lib/json_plan.sh
    source "$LIB_DIR/json_plan.sh" || return 1
    # shellcheck source=lib/json_execute.sh
    source "$LIB_DIR/json_execute.sh" || return 1
    # shellcheck source=lib/json_cli.sh
    source "$LIB_DIR/json_cli.sh" || return 1
    # shellcheck source=lib/cli_info.sh
    source "$LIB_DIR/cli_info.sh" || return 1
}

if ! load_manager_modules; then
    printf 'Failed to load Node manager modules from %s\n' "$LIB_DIR" >&2
    if [ "${BASH_SOURCE[0]}" = "$0" ]; then
        exit 1
    fi
    return 1
fi
unset -f load_manager_modules

# ──────────────────────────────────────────────
# Main entrypoint
# ──────────────────────────────────────────────

main() {
    local choice=""
    local action=""
    local arg="${1:-}"

    case "$arg" in
        --help|-h)
            render_help
            return 0
            ;;
        --version|-v)
            manager_version
            return 0
            ;;
        ""|--info|--dry-run|--test-mode|--json)
            ;;
        *)
            print_status_message "fail" "未知参数: ${arg}，可用参数请见 --help"
            return 2
            ;;
    esac

    # --json is the only mode a future app wrapper parses as a machine
    # contract: preflight failures here must stay JSON-shaped too, not the
    # plain-text messages ensure_macos/ensure_runtime_dirs print for humans.
    if [ "$arg" = "--json" ]; then
        if ! ensure_macos >/dev/null 2>&1; then
            printf '{"ok":false,"schemaVersion":1,"command":"preflight","error":{"code":"unsupported-platform","platform":"%s"}}\n' "$(json_escape "$(platform_uname)")"
            return 1
        fi
        if [ "${2:-}" = "execute" ]; then
            trap 'release_all_runtime_locks' EXIT
            trap 'release_all_runtime_locks; exit 130' INT TERM
        fi
        run_json_command "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}"
        return $?
    fi

    ensure_macos || return 1
    case "$arg" in
        --info|--dry-run)
            DRY_RUN=1 render_dry_run_plan
            return $?
            ;;
        --test-mode)
            TEST_MODE=1 render_test_mode_status
            return $?
            ;;
    esac

    trap 'release_all_runtime_locks' EXIT
    trap 'release_all_runtime_locks; exit 130' INT TERM

    if ! ensure_runtime_dirs; then
        print_status_message "fail" "无法创建运行目录: $(manager_runtime_dir)"
        return 1
    fi

    if ! run_dependency_preflight; then
        print_status_message "fail" "依赖预检失败，已停止。"
        return 1
    fi

    while true; do
        render_startup_page
        printf "请输入序号(q 退出): "
        if ! read -r choice; then
            print_message "已退出。"
            break
        fi

        if [ "$(should_exit_menu main "$choice")" = "1" ]; then
            print_message "已退出。"
            break
        fi

        action="$(dispatch_main_choice "$choice")"

        case "$action" in
            install)
                run_install_menu
                ;;
            uninstall)
                run_uninstall_menu
                ;;
            update)
                run_update_menu
                ;;
            source-management)
                run_source_menu
                ;;
            environment)
                run_environment_menu
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1、2、3、4、5 或 q。"
                pause_before_return
                ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
