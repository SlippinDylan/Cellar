# shellcheck shell=bash

# ──────────────────────────────────────────────
# Flow: install nvm
# ──────────────────────────────────────────────

run_install_nvm_flow() {
    local nvm_verified="no"
    print_page_title "安装 nvm"

    # Check if nvm is already installed
    export NVM_DIR="${NVM_DIR:-$(detect_nvm_dir)}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        printf "  NVM_DIR: %s\n" "$NVM_DIR"
        if nvm_installation_is_usable; then
            print_status_message "ok" "nvm 已安装且可用"
            printf "  nvm 版本: %s\n" "$(nvm --version 2>/dev/null || true)"
            print_blank_line
            printf "如需重新安装，请先删除 %s 目录。\n" "$NVM_DIR"
            pause_before_return
            return 0
        fi
        print_status_message "fail" "检测到 nvm.sh，但 nvm 无法加载或验证"
        printf "  请检查文件完整性与 shell 配置，不会自动覆盖现有安装。\n"
        print_blank_line
        pause_before_return
        return 1
    fi

    if ! validate_nvm_install_configuration; then
        print_status_message "fail" "nvm 安装配置无效；版本、官方 URL 与 SHA256 必须成套匹配"
        pause_before_return
        return 1
    fi

    local safe_nvm_dir=""
    safe_nvm_dir="$(resolve_safe_nvm_install_dir "$NVM_DIR")" || {
        print_status_message "fail" "NVM_DIR 不在允许的安装范围内: $NVM_DIR"
        printf "安装目标必须是 HOME 或 XDG_CONFIG_HOME 下的真实子目录，且不能是软链接。\n"
        pause_before_return
        return 1
    }
    export NVM_DIR="$safe_nvm_dir"

    printf "将使用官方安装脚本安装 nvm。\n"
    printf "安装脚本: %s\n" "$NVM_INSTALL_URL"
    printf "目标目录: %s\n" "$NVM_DIR"
    if [ -n "$NVM_INSTALL_SHA256" ]; then
        printf "SHA256 校验: enabled\n"
    else
        print_status_message "warn" "未配置 NVM_INSTALL_SHA256，下载脚本将无法做内容完整性校验"
        printf "版本: %s\n" "$NVM_INSTALL_VERSION"
        printf "URL: %s\n" "$NVM_INSTALL_URL"
    fi
    print_blank_line

    if ! prompt_yes_no "确认安装？" "y"; then
        return 0
    fi
    if [ -z "$NVM_INSTALL_SHA256" ] && [ "$NVM_ALLOW_UNVERIFIED_INSTALL" != "1" ]; then
        print_status_message "fail" "默认安装路径需要 NVM_INSTALL_SHA256 校验"
        printf "如需执行未校验下载脚本，请显式设置 NVM_ALLOW_UNVERIFIED_INSTALL=1 后重试。\n"
        pause_before_return
        return 1
    fi

    # Snapshot profile files BEFORE install so we can detect what changed
    # Use parallel arrays for Bash 3.2 compatibility
    local -a profile_files=("$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile")
    local -a profile_hashes_before=()
    for pf in "${profile_files[@]}"; do
        if [ -f "$pf" ]; then
            profile_hashes_before+=("$(md5 -q "$pf" 2>/dev/null || md5sum "$pf" 2>/dev/null | awk '{print $1}')")
        else
            profile_hashes_before+=("")
        fi
    done

    print_blank_line
    printf "正在安装 nvm...\n"

    if install_nvm_official; then
        print_blank_line
        print_status_message "ok" "nvm 安装完成"
    else
        print_status_message "fail" "nvm 安装失败"
        pause_before_return
        return 1
    fi

    # Load nvm into current script process
    print_blank_line
    printf "正在加载 nvm 到当前会话...\n"
    if load_nvm_into_current_shell && is_nvm_loaded && [ -n "$(nvm --version 2>/dev/null || true)" ]; then
        print_status_message "ok" "nvm 已加载到当前脚本进程"
        printf "  nvm 版本: %s\n" "$(nvm --version 2>/dev/null || true)"
        nvm_verified="yes"
    else
        print_status_message "warn" "nvm 安装成功但无法在当前进程加载"
    fi

    # Verify
    if command_exists nvm; then
        print_status_message "ok" "command -v nvm 验证通过"
    else
        print_status_message "warn" "command -v nvm 未通过(需要新开终端)"
    fi

    # Detect which profile file was actually modified by comparing before/after
    local nvm_profile=""
    local nvm_profile_state=""
    local pi=0
    for pf in "${profile_files[@]}"; do
        local after_hash=""
        if [ -f "$pf" ]; then
            after_hash="$(md5 -q "$pf" 2>/dev/null || md5sum "$pf" 2>/dev/null | awk '{print $1}')"
        fi
        local before_hash="${profile_hashes_before[$pi]:-}"
        if [ -n "$after_hash" ] && profile_has_complete_nvm_init "$pf"; then
            nvm_profile="$pf"
            if [ "$after_hash" != "$before_hash" ]; then
                nvm_profile_state="updated"
            else
                nvm_profile_state="existing"
            fi
            break
        fi
        pi=$((pi + 1))
    done

    print_blank_line
    print_separator
    printf "重要提示:\n"
    printf "  nvm 已安装到 %s\n" "$NVM_DIR"
    if [ -n "$nvm_profile" ]; then
        if [ "$nvm_profile_state" = "updated" ]; then
            printf "  初始化配置已写入: %s\n" "$nvm_profile"
        else
            printf "  已存在有效初始化配置: %s\n" "$nvm_profile"
        fi
        printf "  请执行以下操作之一使其在终端中永久生效:\n"
        printf "    1. 新开一个终端窗口\n"
        printf "    2. 手动执行: source %s\n" "$nvm_profile"
    else
        printf "  未检测到 profile 文件中的 nvm 配置\n"
        printf "  请手动将以下内容添加到你的 shell 配置文件:\n"
        printf "    export NVM_DIR=\"%s\"\n" "$NVM_DIR"
        printf "    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"\n"
    fi
    print_separator

    pause_before_return
    [ "$nvm_verified" = "yes" ]
}

# ──────────────────────────────────────────────
# Flow: install Node.js version
# ──────────────────────────────────────────────

run_install_node_flow() {
    local choice=""
    local version=""

    print_page_title "安装 Node.js 版本"

    if ! is_nvm_loaded; then
        if ! load_nvm_into_current_shell; then
            printf "nvm 未安装或无法加载。请先安装 nvm。\n"
            pause_before_return
            return 1
        fi
    fi

    # Show current versions
    printf "当前已安装的 Node 版本:\n"
    print_separator
    local installed_list=""
    installed_list="$(nvm ls --no-colors 2>/dev/null || true)"
    if [ -n "$installed_list" ]; then
        printf "%s\n" "$installed_list"
    else
        printf "  <none>\n"
    fi
    print_separator
    print_blank_line

    printf "1) 安装 LTS 版本\n"
    printf "2) 安装指定版本\n"
    printf "b) 返回\n"
    print_blank_line
    printf "请选择: "
    read -r choice || return 0

    case "$choice" in
        1)
            print_blank_line
            printf "正在安装最新 LTS 版本...\n"
            local lts_log_file=""
            lts_log_file="$(create_log_file node-install lts)" || return 1
            printf "日志文件: %s\n" "$lts_log_file"
            if install_node_lts "--lts" "$lts_log_file"; then
                local lts_actual=""
                lts_actual="$(node -v 2>/dev/null || true)"
                local lts_verified="no"
                print_blank_line
                if [ -n "$lts_actual" ] && [[ "$lts_actual" == v* ]]; then
                    print_status_message "ok" "LTS 版本安装完成"
                    lts_verified="yes"
                else
                    print_status_message "warn" "安装命令成功但无法读取 node -v"
                fi
                printf "  node 版本: %s\n" "${lts_actual:-<unknown>}"
                printf "  npm 版本: %s\n" "$(npm -v 2>/dev/null || true)"

                # Only offer to set default if verification passed
                if [ "$lts_verified" = "yes" ]; then
                    if prompt_yes_no "是否设置为默认版本？" "y"; then
                        set_node_default_alias_verified "$lts_actual"
                    fi
                else
                    printf "\n"
                    printf "  跳过设置默认版本(安装验证未通过)\n"
                fi
            else
                print_status_message "fail" "LTS 版本安装失败"
            fi
            pause_before_return
            ;;
        2)
            # Show available LTS versions for selection
            printf "\n可安装的 LTS 版本:\n"
            print_separator
            local -a lts_names=()
            local lts_list=""
            lts_list="$(nvm ls-remote --lts --no-colors 2>/dev/null | tail -20)" || true
            if [ -n "$lts_list" ]; then
                local lts_idx=0
                while IFS= read -r line; do
                    [ -n "$line" ] || continue
                    local lts_ver=""
                    lts_ver="$(printf '%s' "$line" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | tail -1)"
                    [ -n "$lts_ver" ] || continue
                    lts_idx=$((lts_idx + 1))
                    lts_names+=("$lts_ver")
                    printf "  %d) %s\n" "$lts_idx" "$lts_ver"
                done <<< "$lts_list"
                print_separator
                printf "输入序号或版本号(例如 20 或 20.11.0)，b 返回\n"
            else
                printf "  <无法获取远程版本列表>\n"
                print_separator
                printf "输入版本号(例如 20 或 20.11.0)，b 返回\n"
            fi
            print_blank_line
            printf "请选择: "
            read -r version || return 0
            version="$(trim_whitespace "$version")"
            [ -n "$version" ] || return 0

            # Handle "b" for back
            if [ "$version" = "b" ] || [ "$version" = "B" ]; then
                return 0
            fi

            if [ ${#lts_names[@]} -gt 0 ]; then
                version="$(select_version_from_number_or_literal "$version" "${lts_names[@]}")"
            fi

            local normalized_version=""
            if ! normalized_version="$(normalize_node_version "$version")"; then
                print_status_message "fail" "版本号无效: $version"
                pause_before_return
                return 1
            fi
            version="$normalized_version"

            print_blank_line
            printf "正在安装 Node.js %s ...\n" "$version"
            local node_install_log_file=""
            node_install_log_file="$(create_log_file node-install "$version")" || return 1
            printf "日志文件: %s\n" "$node_install_log_file"
            if install_node_version "$version" "$node_install_log_file"; then
                local actual_ver=""
                actual_ver="$(node -v 2>/dev/null || true)"
                local install_verified="no"
                print_blank_line
                if ! normalize_node_version "$version" >/dev/null 2>&1; then
                    print_status_message "warn" "版本号无效: $version"
                elif [ -n "$actual_ver" ] && node_version_satisfies_request "$actual_ver" "$version"; then
                    print_status_message "ok" "Node.js $version 安装完成"
                    install_verified="yes"
                elif [ -n "$actual_ver" ]; then
                    print_status_message "warn" "安装命令成功但 node -v 不匹配"
                    printf "  期望: %s\n" "$version"
                    printf "  实际: %s\n" "$actual_ver"
                else
                    print_status_message "warn" "安装命令成功但无法读取 node -v"
                fi
                printf "  node 版本: %s\n" "${actual_ver:-<unknown>}"
                printf "  npm 版本: %s\n" "$(npm -v 2>/dev/null || true)"

                # Only offer to set default if verification passed
                if [ "$install_verified" = "yes" ]; then
                    if prompt_yes_no "是否设置为默认版本？" "n"; then
                        set_node_default_alias_verified "$actual_ver"
                    fi
                else
                    printf "\n"
                    printf "  跳过设置默认版本(安装验证未通过)\n"
                fi
            else
                print_status_message "fail" "Node.js $version 安装失败"
            fi
            pause_before_return
            ;;
        b|B) return 0 ;;
        *)
            print_status_message "warn" "输入无效。"
            pause_before_return
            ;;
    esac
}

# ──────────────────────────────────────────────
# Flow: switch Node version
# ──────────────────────────────────────────────

run_switch_node_flow() {
    local choice=""
    local version=""
    local current_version=""
    local default_alias=""

    print_page_title "更改全局 Node 版本"

    if ! is_nvm_loaded; then
        if ! load_nvm_into_current_shell; then
            printf "nvm 未安装或无法加载。请先安装 nvm。\n"
            pause_before_return
            return 1
        fi
    fi

    current_version="$(nvm current 2>/dev/null || true)"
    default_alias="$(get_nvm_default_version)"

    printf "当前 Node 版本: %s\n" "${current_version:-<unknown>}"
    printf "默认 Node 版本: %s\n" "${default_alias:-<unknown>}"
    print_blank_line

    # List installed versions (reuse helper)
    printf "已安装的 Node 版本:\n"
    print_separator
    local -a versions=()
    local v_index=0
    while IFS= read -r ver; do
        [ -n "$ver" ] || continue
        v_index=$((v_index + 1))
        versions+=("$ver")
        local marker=""
        if [ "$ver" = "$current_version" ]; then
            marker=" (当前)"
        fi
        if [ "$ver" = "$default_alias" ]; then
            marker="${marker} (默认)"
        fi
        printf "  %d) %s%s\n" "$v_index" "$ver" "$marker"
    done <<< "$(get_installed_node_versions)"

    if [ "$v_index" -eq 0 ]; then
        printf "  <none>\n"
        pause_before_return
        return 0
    fi

    print_separator
    printf "输入序号选择版本(b 返回): "
    read -r choice || return 0

    local parsed=""
    parsed="$(parse_numeric_choice "$choice" "$v_index")"

    if [ "$parsed" = "back" ]; then
        return 0
    fi

    if [ "$parsed" = "invalid" ]; then
        print_status_message "warn" "输入无效。"
        pause_before_return
        return 0
    fi

    version="${versions[$((parsed - 1))]}"

    print_blank_line
    printf "切换计划:\n"
    print_separator
    printf "  当前版本: %s\n" "$current_version"
    printf "  目标版本: %s\n" "$version"
    print_separator
    if ! prompt_yes_no "确认切换？" "y"; then
        return 0
    fi

    print_blank_line
    printf "执行切换...\n"
    print_separator
    local switch_log_file=""
    switch_log_file="$(create_log_file node-use "$version")" || return 1
    printf "日志文件: %s\n" "$switch_log_file"
    if switch_node_version "$version" "$switch_log_file"; then
        local actual_version=""
        actual_version="$(node -v 2>/dev/null || true)"
        local switch_verified="no"
        print_blank_line
        if node_version_satisfies_request "$actual_version" "$version"; then
            print_status_message "ok" "版本切换成功"
            printf "  切换前: %s\n" "$current_version"
            printf "  切换后: %s\n" "$actual_version"
            switch_verified="yes"
        else
            print_status_message "warn" "nvm use 成功但 node -v 不匹配"
            printf "  期望: %s\n" "$version"
            printf "  实际: %s\n" "${actual_version:-<unknown>}"
        fi

        # Only offer to set default if verification passed
        if [ "$switch_verified" = "yes" ]; then
            if prompt_yes_no "是否同时设置为默认版本？" "n"; then
                set_node_default_alias_verified "$version"
            fi
        else
            printf "\n"
            printf "  跳过设置默认版本(切换验证未通过)\n"
        fi
    else
        print_status_message "fail" "版本切换失败"
        printf "  当前版本: %s\n" "$(node -v 2>/dev/null || true)"
    fi

    pause_before_return
}
