# shellcheck shell=bash

# ──────────────────────────────────────────────
# nvm & Node environment actions
# ──────────────────────────────────────────────

nvm_install_unverified_blocked() {
    [ -z "$NVM_INSTALL_SHA256" ] && [ "$NVM_ALLOW_UNVERIFIED_INSTALL" != "1" ]
}

validate_nvm_install_configuration() {
    local expected_url=""

    [[ "$NVM_INSTALL_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    expected_url="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_INSTALL_VERSION}/install.sh"
    [ "$NVM_INSTALL_URL" = "$expected_url" ] || return 1
    case "$NVM_ALLOW_UNVERIFIED_INSTALL" in
        0|1) ;;
        *) return 1 ;;
    esac
    [ -z "$NVM_INSTALL_SHA256" ] || [[ "$NVM_INSTALL_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]
}

download_nvm_install_script() {
    local install_url="$1"
    local destination="$2"

    /usr/bin/curl -q -fsSL "$install_url" -o "$destination"
}

nvm_installation_version() {
    local nvm_version=""

    [ -s "$(nvm_script_path)" ] || return 1
    load_nvm_into_current_shell || return 1
    is_nvm_loaded || return 1
    nvm_version="$(nvm --version 2>/dev/null || true)"
    [ -n "$nvm_version" ] || return 1
    printf '%s\n' "$nvm_version"
}

nvm_installation_is_usable() {
    nvm_installation_version >/dev/null
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
    local safe_nvm_dir=""

    validate_nvm_install_configuration || {
        print_status_message "fail" "nvm 安装配置无效或不是官方版本 URL"
        return 1
    }
    if nvm_install_unverified_blocked; then
        print_status_message "fail" "默认安装路径需要 NVM_INSTALL_SHA256 校验"
        printf "如需执行未校验下载脚本，请显式设置 NVM_ALLOW_UNVERIFIED_INSTALL=1 后重试。\n"
        return 1
    fi
    safe_nvm_dir="$(resolve_safe_nvm_install_dir "${NVM_DIR:-$(detect_nvm_dir)}")" || {
        print_status_message "fail" "NVM_DIR 不在允许的安装范围内"
        return 1
    }
    export NVM_DIR="$safe_nvm_dir"
    [ -x /usr/bin/curl ] || {
        print_status_message "fail" "缺少 curl，无法下载安装脚本"
        return 127
    }
    [ -x /bin/bash ] || {
        print_status_message "fail" "缺少 bash，无法执行安装脚本"
        return 127
    }
    [ -x /usr/bin/env ] || {
        print_status_message "fail" "缺少 env，无法建立受控安装环境"
        return 127
    }
    ensure_runtime_dirs || return 1

    local install_script=""
    local curl_home=""
    install_script="$(mktemp "$(manager_tmp_dir)/nvm-install.sh.XXXXXX")" || return 1

    if ! download_nvm_install_script "$NVM_INSTALL_URL" "$install_script"; then
        print_status_message "fail" "nvm 安装脚本下载失败"
        rm -f "$install_script" 2>/dev/null || true
        return 1
    fi

    if [ -n "$NVM_INSTALL_SHA256" ]; then
        [ -x /usr/bin/shasum ] || {
            print_status_message "fail" "配置了 NVM_INSTALL_SHA256 但缺少 shasum"
            rm -f "$install_script" 2>/dev/null || true
            return 127
        }
        local actual_sha=""
        actual_sha="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/shasum -a 256 "$install_script" 2>/dev/null | /usr/bin/awk '{print $1}')"
        if [ "$actual_sha" != "$NVM_INSTALL_SHA256" ]; then
            print_status_message "fail" "nvm 安装脚本 SHA256 校验失败"
            printf "  期望: %s\n" "$NVM_INSTALL_SHA256"
            printf "  实际: %s\n" "${actual_sha:-<unknown>}"
            rm -f "$install_script" 2>/dev/null || true
            return 1
        fi
    fi

    curl_home="$(mktemp -d "$(manager_tmp_dir)/nvm-curl-home.XXXXXX")" || {
        rm -f "$install_script" 2>/dev/null || true
        return 1
    }
    local install_exit=0
    /usr/bin/env -i \
        HOME="$HOME" \
        NVM_DIR="$NVM_DIR" \
        SHELL="${SHELL:-/bin/zsh}" \
        CURL_HOME="$curl_home" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        METHOD=script \
        NVM_INSTALL_VERSION="$NVM_INSTALL_VERSION" \
        /bin/bash --noprofile --norc "$install_script" || install_exit=$?
    rmdir "$curl_home" 2>/dev/null || true
    if [ "$install_exit" -ne 0 ]; then
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

read_nvm_current_state() {
    local current_version=""

    current_version="$(nvm current 2>/dev/null)" || return 1
    case "$current_version" in
        system|none)
            printf '%s\n' "$current_version"
            ;;
        *)
            normalize_node_concrete_version "$current_version"
            ;;
    esac
}

resolve_installed_lts_target_version() {
    local install_target="$1"
    local lts_alias=""
    local resolved=""

    case "$install_target" in
        --lts) lts_alias='lts/*' ;;
        --lts=*) lts_alias="lts/${install_target#--lts=}" ;;
        *) return 1 ;;
    esac
    resolved="$(nvm version "$lts_alias" 2>/dev/null)" || return 1
    normalize_node_concrete_version "$resolved"
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
    local expected_version=""
    local actual_version=""

    case "$lts_target" in
        --lts) ;;
        --lts=*)
            [[ "${lts_target#--lts=}" =~ ^[a-z0-9._-]+$ ]] || return 2
            ;;
        *) return 2 ;;
    esac

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
    expected_version="$(resolve_installed_lts_target_version "$lts_target")" || {
        release_runtime_lock "nvm-mutation"
        return 1
    }
    actual_version="$(read_nvm_current_state)" || {
        release_runtime_lock "nvm-mutation"
        return 1
    }
    release_runtime_lock "nvm-mutation"
    [ "$actual_version" = "$expected_version" ]
}

install_node_version() {
    local version="$1"
    local log_file="${2:-}"

    normalize_node_version "$version" >/dev/null 2>&1 || return 2
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
    local actual=""
    actual="$(node -v 2>/dev/null || true)"
    local verified=1
    node_version_satisfies_request "$actual" "$version" || verified=0
    release_runtime_lock "nvm-mutation"
    [ "$verified" -eq 1 ]
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

nvm_version_is_safe_cleanup_candidate() {
    local version="$1"
    local version_dir=""
    local current_version=""
    local default_info=""
    local default_version=""
    local default_status=""
    local user_package_count=""

    version="$(normalize_node_concrete_version "$version")" || return 1
    version_dir="$(nvm_version_dir "$version")"
    [ -d "$version_dir" ] || return 1
    current_version="$(read_nvm_current_state)" || return 1
    default_info="$(get_nvm_default_info)"
    default_version="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"
    [ "$default_status" = "resolved" ] || return 1
    [ "$version" != "$current_version" ] && [ "$version" != "$default_version" ] || return 1
    user_package_count="$(nvm_version_user_package_count "$version_dir" 2>/dev/null)" || return 1
    [ "$user_package_count" -eq 0 ] 2>/dev/null
}
