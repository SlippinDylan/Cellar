# shellcheck shell=bash

# ──────────────────────────────────────────────
# nvm & Node environment actions
# ──────────────────────────────────────────────

nvm_install_unverified_blocked() {
    [ -z "$NVM_INSTALL_SHA256" ] && [ "$NVM_ALLOW_UNVERIFIED_INSTALL" != "1" ]
}

render_nvm_install_unverified_blocked_json() {
    local subject="${1:-$NVM_INSTALL_VERSION}"

    printf '{'
    printf '"code":"nvm-install-unverified-blocked",'
    printf '"action":"nvm-install",'
    printf '"subject":"%s",' "$(json_escape "${subject:-$NVM_INSTALL_VERSION}")"
    printf '"version":"%s",' "$(json_escape "$NVM_INSTALL_VERSION")"
    printf '"installUrl":"%s",' "$(json_escape "$NVM_INSTALL_URL")"
    printf '"sha256Configured":false,'
    printf '"allowUnverified":%s' "$([ "$NVM_ALLOW_UNVERIFIED_INSTALL" = "1" ] && printf true || printf false)"
    printf '}\n'
}

install_nvm_official() {
    if nvm_install_unverified_blocked; then
        print_status_message "fail" "默认安装路径需要 NVM_INSTALL_SHA256 校验"
        printf "如需执行未校验下载脚本，请显式设置 NVM_ALLOW_UNVERIFIED_INSTALL=1 后重试。\n"
        return 1
    fi
    command_exists curl || {
        print_status_message "fail" "缺少 curl，无法下载安装脚本"
        return 127
    }
    command_exists bash || {
        print_status_message "fail" "缺少 bash，无法执行安装脚本"
        return 127
    }
    ensure_runtime_dirs || return 1

    local install_script=""
    install_script="$(mktemp "$(manager_tmp_dir)/nvm-install.sh.XXXXXX")" || return 1

    if ! curl -fsSL "$NVM_INSTALL_URL" -o "$install_script"; then
        print_status_message "fail" "nvm 安装脚本下载失败"
        rm -f "$install_script" 2>/dev/null || true
        return 1
    fi

    if [ -n "$NVM_INSTALL_SHA256" ]; then
        command_exists shasum || {
            print_status_message "fail" "配置了 NVM_INSTALL_SHA256 但缺少 shasum"
            rm -f "$install_script" 2>/dev/null || true
            return 127
        }
        local actual_sha=""
        actual_sha="$(shasum -a 256 "$install_script" 2>/dev/null | awk '{print $1}')"
        if [ "$actual_sha" != "$NVM_INSTALL_SHA256" ]; then
            print_status_message "fail" "nvm 安装脚本 SHA256 校验失败"
            printf "  期望: %s\n" "$NVM_INSTALL_SHA256"
            printf "  实际: %s\n" "${actual_sha:-<unknown>}"
            rm -f "$install_script" 2>/dev/null || true
            return 1
        fi
    fi

    if ! bash "$install_script"; then
        print_status_message "fail" "nvm 安装脚本执行失败"
        rm -f "$install_script" 2>/dev/null || true
        return 1
    fi

    rm -f "$install_script" 2>/dev/null || true
    return 0
}

get_installed_node_versions() {
    local dir_versions=""

    dir_versions="$(scan_installed_node_versions_from_dirs)"
    if [ -n "$dir_versions" ]; then
        printf '%s\n' "$dir_versions"
        return 0
    fi

    load_nvm_into_current_shell || return 1
    nvm ls --no-colors 2>/dev/null \
        | grep -E '^[[:space:]]*(->[[:space:]])?[[:space:]]*v[0-9]' \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | sort_node_versions \
        | uniq
}

get_nvm_current_version() {
    load_nvm_into_current_shell || return 1
    nvm current 2>/dev/null
}

get_nvm_default_alias() {
    load_nvm_into_current_shell || return 1
    nvm alias default 2>/dev/null
}

get_nvm_default_version() {
    local info=""
    local resolved=""

    info="$(get_nvm_default_info)"
    resolved="$(printf '%s' "$info" | awk -F'|' '{print $2}')"
    printf '%s' "$resolved"
}

install_node_lts() {
    local lts_target="${1:---lts}"
    local log_file="${2:-}"
    load_nvm_into_current_shell || return 1
    [ -n "$log_file" ] || log_file="$(create_log_file node-install "$lts_target")" || return 1
    acquire_runtime_lock "nvm-mutation" || return 1
    if ! run_logged_command "$log_file" nvm install "$lts_target"; then
        release_runtime_lock "nvm-mutation"
        return 1
    fi
    if ! run_logged_command "$log_file" nvm use "$lts_target"; then
        release_runtime_lock "nvm-mutation"
        return 1
    fi
    release_runtime_lock "nvm-mutation"
    local resolved=""
    resolved="$(nvm current 2>/dev/null || true)"
    [ -n "$resolved" ] && [[ "$resolved" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

install_node_version() {
    local version="$1"
    local log_file="${2:-}"
    load_nvm_into_current_shell || return 1
    [ -n "$log_file" ] || log_file="$(create_log_file node-install "$version")" || return 1
    acquire_runtime_lock "nvm-mutation" || return 1
    if ! run_logged_command "$log_file" nvm install "$version"; then
        release_runtime_lock "nvm-mutation"
        return 1
    fi
    if ! run_logged_command "$log_file" nvm use "$version"; then
        release_runtime_lock "nvm-mutation"
        return 1
    fi
    release_runtime_lock "nvm-mutation"
    local actual=""
    actual="$(node -v 2>/dev/null || true)"
    node_version_satisfies_request "$actual" "$version"
}

switch_node_version() {
    local version="$1"
    local log_file="${2:-}"
    load_nvm_into_current_shell || return 1
    [ -n "$log_file" ] || log_file="$(create_log_file node-use "$version")" || return 1
    # run_logged_command already acquires/releases "nvm-mutation" around
    # `nvm use` itself (see its dispatch table); no extra wrapping needed here.
    run_logged_command "$log_file" nvm use "$version"
}

set_node_default_alias() {
    local version="$1"
    local log_file="${2:-}"
    load_nvm_into_current_shell || return 1
    [ -n "$log_file" ] || log_file="$(create_log_file node-alias-default "$version")" || return 1
    # Same as switch_node_version: locking is handled by run_logged_command.
    run_logged_command "$log_file" nvm alias default "$version"
}

set_node_default_alias_verified() {
    local target_version="$1"
    if ! set_node_default_alias "$target_version"; then
        print_status_message "fail" "设置默认版本失败"
        return 1
    fi
    local actual_def=""
    actual_def="$(get_nvm_default_version)"
    if [ "$actual_def" = "$target_version" ]; then
        print_status_message "ok" "默认版本已设置为 $target_version"
        printf "  验证: default = %s\n" "$actual_def"
        return 0
    else
        print_status_message "warn" "设置命令成功但验证不一致"
        printf "  期望: %s\n" "$target_version"
        printf "  实际: %s\n" "${actual_def:-<unknown>}"
        return 1
    fi
}
