#!/bin/bash

# Unified Homebrew manager for macOS.
# Environment: local interactive shell on macOS.
# Purpose: provide one entry point for Homebrew project management and environment bootstrap.
#
# This is the entry point. Feature code lives in lib/*.sh and is loaded via
# `source` below, so it all runs in this one process (shared functions,
# globals, and colors). lib/*.sh files are not meant to be executed directly.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
MANAGER_SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

OUTDATED_FORMULAS=()
OUTDATED_CASKS=()
UPDATABLE_ITEMS=()
UPDATABLE_TYPES=()
PROMPT_MULTI_SELECT_RESULT=""
INSTALL_PARALLEL_JOBS=5
INSTALL_MAX_RETRIES=2
DELETE_REPORT_DELETED=()
DELETE_REPORT_ELEVATED=()
DELETE_REPORT_PERMISSION_SKIPPED=()
DELETE_REPORT_FAILED=()
DELETE_LAST_ERROR_MESSAGE=""
FORMULA_PLAN_TARGET=""
FORMULA_PLAN_DEPENDENCIES=()
FORMULA_PLAN_ORPHANS=()
HOMEBREW_INSTALL_SCRIPT_REF="${HOMEBREW_INSTALL_SCRIPT_REF:-93a25fd2d2fdb86422303c292b9223f84ef23eaf}"
HOMEBREW_INSTALL_SCRIPT_URL="${HOMEBREW_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/Homebrew/install/$HOMEBREW_INSTALL_SCRIPT_REF/install.sh}"
CASK_METADATA_TOKEN=""
CASK_METADATA_APP_NAME=""
CASK_METADATA_ZAP_PATHS=()
CASK_RECEIPT_APP_ARTIFACTS=()
CASK_RECEIPT_BINARY_ARTIFACTS=()
CASK_RECEIPT_MANPAGE_ARTIFACTS=()
CASK_RECEIPT_PKGUTIL_ARTIFACTS=()
CASK_RECEIPT_LAUNCHCTL_ARTIFACTS=()
CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS=()
CASK_POSTCHECK_RESIDUAL_DELETE_PATHS=()
CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS=()
CASK_POSTCHECK_CLEARED_ITEMS=()
CASK_POSTCHECK_DELEGATED_ITEMS=()
CASK_UNINSTALL_LAST_CLEARED_ARTIFACTS=()
CASK_UNINSTALL_LAST_DELETED_PATHS=()
CASK_UNINSTALL_LAST_ELEVATED_DELETED_PATHS=()
CASK_UNINSTALL_LAST_PERMISSION_SKIPPED_PATHS=()
CASK_UNINSTALL_LAST_FAILED_PATHS=()
CASK_UNINSTALL_LAST_MANUAL_ATTENTION_ITEMS=()
CASK_UNINSTALL_LAST_DELEGATED_ITEMS=()
INSTALLABLE_CASKS=(
    "1password"
    "airbuddy"
    "aldente"
    "aliwangwang"
    "android-platform-tools"
    "appcleaner"
    "baidunetdisk"
    "bettermouse"
    "bluestacks"
    "cleanmymac-zh"
    "coteditor"
    "dockdoor"
    "downie"
    "feishu"
    "google-chrome"
    "google-chrome@beta"
    "icollections"
    "iina"
    "jetbrains-toolbox"
    "microsoft-edge"
    "monitorcontrol"
    "obsidian"
    "one-switch"
    "pastenow"
    "permute"
    "progressive-downloader"
    "qq"
    "qspace-pro"
    "reqable"
    "spotify"
    "stats"
    "switchhosts"
    "tailscale-app"
    "termius"
    "the-unarchiver"
    "thunder"
    "tower"
    "typora"
    "videofusion"
    "visual-studio-code"
    "warp"
    "wechat"
    "wechatwebdevtools"
    "windows-app"
    "wpsoffice-cn"
    "zed"
)

# shellcheck source=lib/ui.sh
source "$LIB_DIR/ui.sh"
# shellcheck source=lib/menu.sh
source "$LIB_DIR/menu.sh"
# shellcheck source=lib/util.sh
source "$LIB_DIR/util.sh"
# shellcheck source=lib/plist.sh
source "$LIB_DIR/plist.sh"
# shellcheck source=lib/disk_usage.sh
source "$LIB_DIR/disk_usage.sh"
# shellcheck source=lib/bootstrap.sh
source "$LIB_DIR/bootstrap.sh"
# shellcheck source=lib/inventory.sh
source "$LIB_DIR/inventory.sh"
# shellcheck source=lib/install.sh
source "$LIB_DIR/install.sh"
# shellcheck source=lib/uninstall_formula.sh
source "$LIB_DIR/uninstall_formula.sh"
# shellcheck source=lib/uninstall_cask_receipt.sh
source "$LIB_DIR/uninstall_cask_receipt.sh"
# shellcheck source=lib/uninstall_cask_metadata.sh
source "$LIB_DIR/uninstall_cask_metadata.sh"
# shellcheck source=lib/uninstall_cask_delete.sh
source "$LIB_DIR/uninstall_cask_delete.sh"
# shellcheck source=lib/uninstall_cask_flow.sh
source "$LIB_DIR/uninstall_cask_flow.sh"
# shellcheck source=lib/uninstall_router.sh
source "$LIB_DIR/uninstall_router.sh"
# shellcheck source=lib/tap.sh
source "$LIB_DIR/tap.sh"
# shellcheck source=lib/update.sh
source "$LIB_DIR/update.sh"
# shellcheck source=lib/cleanup.sh
source "$LIB_DIR/cleanup.sh"

main() {
    local choice=""
    local action=""

    initialize_homebrew_shellenv || true

    while true; do
        print_page_title "Homebrew 管理"
        printf "%s\n" "$(render_main_menu)"
        printf "请输入序号（q 退出）: "
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
                run_install_flow
                pause_before_return
                ;;
            uninstall)
                run_uninstall_menu
                ;;
            update)
                run_update_menu
                ;;
            tap-management)
                run_tap_management_flow
                ;;
            environment)
                run_environment_menu
                ;;
            back)
                print_status_message "warn" "输入无效，请输入 1、2、3、4、5 或 q。"
                pause_before_return
                ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
