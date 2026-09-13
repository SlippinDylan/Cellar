# shellcheck shell=bash

# ──────────────────────────────────────────────
# Environment info collection (read-only)
# ──────────────────────────────────────────────

collect_env_value() {
    local label="$1"
    local value="${2:-}"

    if [ -z "$value" ]; then
        value="<unavailable>"
    fi

    printf "%-28s %s\n" "$label:" "$value"
}

collect_startup_summary() {
    local node_path=""
    local npm_path=""
    local node_version=""
    local npm_version=""
    local nvm_status=""
    local current_node=""
    local default_node=""
    local global_prefix=""
    local global_root=""
    local registry=""
    local nvm_managed=""

    node_path="$(command -v node 2>/dev/null || true)"
    npm_path="$(command -v npm 2>/dev/null || true)"
    node_version="$(node -v 2>/dev/null || true)"
    npm_version="$(npm -v 2>/dev/null || true)"

    if is_nvm_loaded; then
        local nvm_ver=""
        nvm_ver="$(nvm --version 2>/dev/null || true)"
        nvm_status="loaded${nvm_ver:+ (v$nvm_ver)}"
        current_node="$(nvm current 2>/dev/null || true)"
        default_node="$(get_nvm_default_version)"
    else
        local nvm_script=""
        local default_info=""
        nvm_script="$(nvm_script_path)"
        if [ -s "$nvm_script" ]; then
            nvm_status="installed-not-loaded"
        else
            nvm_status="<not-loaded>"
        fi
        current_node="<not-loaded>"
        default_info="$(read_nvm_default_alias_file_info)"
        default_node="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
        [ -n "$default_node" ] || default_node="<unresolved>"
    fi

    global_prefix="$(npm prefix -g 2>/dev/null || true)"
    global_root="$(npm root -g 2>/dev/null || true)"
    registry="$(npm config get registry 2>/dev/null || true)"

    # Detect if current node is nvm-managed without sourcing nvm.
    if [ -n "$node_path" ] && is_node_path_nvm_managed "$node_path"; then
        nvm_managed="yes"
    elif [ -n "$node_path" ]; then
        nvm_managed="no"
    else
        nvm_managed="<unknown>"
    fi

    collect_env_value "node 路径" "$node_path"
    collect_env_value "npm 路径" "$npm_path"
    collect_env_value "node 版本" "$node_version"
    collect_env_value "npm 版本" "$npm_version"
    collect_env_value "nvm 状态" "$nvm_status"
    collect_env_value "当前 Node 版本" "$current_node"
    collect_env_value "默认 Node 版本" "$default_node"
    collect_env_value "npm global prefix" "$global_prefix"
    collect_env_value "npm global root" "$global_root"
    collect_env_value "当前 registry" "$registry"
    collect_env_value "nvm 管理" "$nvm_managed"
    if [ "$nvm_managed" = "no" ]; then
        print_status_message "warn" "当前 node 不是由 nvm 管理，本脚本的版本切换/卸载/清理功能对它不生效"
    fi
}

# ──────────────────────────────────────────────
# Flow: startup page
# ──────────────────────────────────────────────

render_startup_page() {
    print_page_title "npm / Node 全局环境管理"
    printf "当前环境摘要\n"
    print_separator
    collect_startup_summary
    print_separator
    print_blank_line
    render_main_menu
}

# ──────────────────────────────────────────────
# Flow: environment overview
# ──────────────────────────────────────────────

run_environment_overview() {
    print_page_title "环境总览"
    printf "环境总览\n"
    print_separator
    collect_startup_summary
    print_separator

    print_blank_line
    printf "nvm 诊断:\n"
    local detected_nvm_dir=""
    local detected_nvm_script=""
    detected_nvm_dir="$(detect_nvm_dir)"
    detected_nvm_script="$(nvm_script_path)"
    printf "  NVM_DIR: %s\n" "$detected_nvm_dir"
    printf "  nvm_script_path: %s\n" "$detected_nvm_script"
    if [ -s "$detected_nvm_script" ]; then
        printf "  nvm.sh: 存在\n"
    else
        printf "  nvm.sh: 不存在或不可读\n"
    fi
    if is_nvm_loaded; then
        printf "  loaded: yes\n"
    else
        printf "  loaded: no\n"
    fi

    local scanned_versions=""
    scanned_versions="$(scan_installed_node_versions_from_dirs)"
    print_blank_line
    printf "nvm versions 目录扫描:\n"
    if [ -n "$scanned_versions" ]; then
        printf "%s\n" "$scanned_versions"
    else
        printf "  <none>\n"
    fi

    # nvm installed versions detail
    if is_nvm_loaded; then
        print_blank_line
        printf "nvm 已安装的 Node 版本:\n"
        local versions=""
        versions="$(nvm ls --no-colors 2>/dev/null || true)"
        if [ -n "$versions" ]; then
            printf "%s\n" "$versions"
        else
            printf "  <none>\n"
        fi
    fi

    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: environment menu
# ──────────────────────────────────────────────

run_environment_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "环境与依赖"
        render_environment_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_environment_choice "$choice")"
        case "$action" in
            overview)
                run_environment_overview
                ;;
            install-nvm)
                run_install_nvm_flow
                ;;
            install-node)
                run_install_node_flow
                ;;
            switch-node)
                run_switch_node_flow
                ;;
            uninstall-node)
                run_uninstall_node_flow
                ;;
            project-node)
                run_project_node_flow
                ;;
            cleanup)
                run_cleanup_flow
                ;;
            back)
                return 0
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1-7 或 b。"
                pause_before_return
                ;;
        esac
    done
}
