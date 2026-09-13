# shellcheck shell=bash

# ──────────────────────────────────────────────
# Flow: project Node version (.nvmrc)
# ──────────────────────────────────────────────

run_project_node_flow() {
    local project_path=""
    local version=""

    print_page_title "指定项目 Node 版本"
    if [ "${NODE_MANAGER_ALLOW_PROJECT_WRITE:-0}" != "1" ]; then
        print_status_message "warn" "该功能会写入所选项目目录，默认已禁用以保持 scripts/node 输出边界"
        printf "如需启用，请在明确授权后设置 NODE_MANAGER_ALLOW_PROJECT_WRITE=1。\n"
        pause_before_return
        return 0
    fi

    if ! is_nvm_loaded; then
        if ! load_nvm_into_current_shell; then
            printf "nvm 未安装或无法加载。请先安装 nvm。\n"
            pause_before_return
            return 1
        fi
    fi

    printf "请输入项目路径(或拖拽文件夹到终端): "
    read -r project_path || return 0
    project_path="$(normalize_dragged_path "$project_path")"
    [ -n "$project_path" ] || return 0

    # Validate path
    if [ ! -e "$project_path" ]; then
        print_status_message "fail" "路径不存在: $project_path"
        pause_before_return
        return 1
    fi

    if [ ! -d "$project_path" ]; then
        print_status_message "fail" "不是目录: $project_path"
        pause_before_return
        return 1
    fi

    # Check for package.json
    local pkg_json="$project_path/package.json"
    local nvmrc="$project_path/.nvmrc"
    local engines_node=""

    print_blank_line
    printf "项目路径: %s\n" "$project_path"

    if [ -f "$pkg_json" ]; then
        printf "package.json: 存在\n"
        engines_node="$(ruby -rjson -e '
            d = JSON.parse(File.read(ARGV[0]))
            puts d.dig("engines","node") || ""
        ' "$pkg_json" 2>/dev/null || true)"
        if [ -n "$engines_node" ]; then
            printf "  engines.node: %s\n" "$engines_node"
        fi
    else
        printf "package.json: 不存在\n"
    fi

    if [ -f "$nvmrc" ]; then
        local current_nvmrc=""
        current_nvmrc="$(cat "$nvmrc" 2>/dev/null)"
        printf ".nvmrc: 存在 %s\n" "$current_nvmrc"
    else
        printf ".nvmrc: 不存在\n"
    fi

    print_blank_line

    # List installed versions for selection
    printf "已安装的 Node 版本:\n"
    print_separator
    local -a versions=()
    local v_index=0
    while IFS= read -r ver; do
        [ -n "$ver" ] || continue
        v_index=$((v_index + 1))
        versions+=("$ver")
        printf "  %d) %s\n" "$v_index" "$ver"
    done <<< "$(get_installed_node_versions)"

    if [ "$v_index" -eq 0 ]; then
        printf "  <none>\n"
    fi

    print_separator
    printf "输入序号或具体版本号(例如 20.11.0)。20 / 20.11 仅在唯一匹配已安装版本时可用，b 返回\n"
    print_blank_line
    printf "请选择: "
    read -r choice || return 0
    choice="$(trim_whitespace "$choice")"

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        return 0
    fi

    if [ "$v_index" -gt 0 ]; then
        version="$(select_version_from_number_or_literal "$choice" "${versions[@]}")"
    else
        version="$(select_version_from_number_or_literal "$choice")"
    fi
    local requested_version="$version"

    [ -n "$version" ] || return 0
    local resolve_ok="no"
    if [ "$v_index" -gt 0 ]; then
        version="$(resolve_project_nvmrc_concrete_version "$version" "${versions[@]}" 2>/dev/null)" && resolve_ok="yes"
    else
        version="$(resolve_project_nvmrc_concrete_version "$version" 2>/dev/null)" && resolve_ok="yes"
    fi
    if [ "$resolve_ok" != "yes" ]; then
        print_status_message "fail" "版本号格式不支持或无法唯一解析: $requested_version"
        printf "请使用具体版本号 X.Y.Z；major/minor 简写必须唯一匹配已安装版本。\n"
        pause_before_return
        return 1
    fi

    print_blank_line
    printf "准备写入 .nvmrc: %s\n" "$version"
    printf "注意: 该功能会写入所选项目目录，不属于 scripts/node 运行产物边界。\n"
    printf "请输入完整项目路径确认: %s\n" "$project_path"
    printf "确认路径: "
    local confirmed_project_path=""
    read -r confirmed_project_path || return 0
    confirmed_project_path="$(trim_whitespace "$confirmed_project_path")"
    if [ "$confirmed_project_path" != "$project_path" ]; then
        printf "确认路径不匹配，取消写入。\n"
        return 0
    fi

    if [ -f "$nvmrc" ]; then
        local existing=""
        existing="$(cat "$nvmrc" 2>/dev/null)"
        printf "  现有内容: %s\n" "$existing"
        if ! prompt_yes_no "是否覆盖？" "y"; then
            return 0
        fi
    fi

    local installed_versions=""
    installed_versions="$(get_installed_node_versions)"
    if ! installed_node_versions_satisfy_request "$version" "$installed_versions"; then
        print_blank_line
        if prompt_yes_no "版本 $version 未安装，是否现在安装？" "y"; then
            local project_node_install_log_file=""
            project_node_install_log_file="$(create_log_file node-install "$version")" || return 1
            printf "日志文件: %s\n" "$project_node_install_log_file"
            if install_node_version "$version" "$project_node_install_log_file"; then
                local installed_actual=""
                installed_actual="$(node -v 2>/dev/null || true)"
                if [ -n "$installed_actual" ] && node_version_satisfies_request "$installed_actual" "$version"; then
                    print_status_message "ok" "Node.js $version 安装完成"
                else
                    print_status_message "fail" "安装后版本验证失败"
                    printf "  请求: %s\n" "$version"
                    printf "  实际: %s\n" "${installed_actual:-<unknown>}"
                    pause_before_return
                    return 1
                fi
            else
                print_status_message "fail" "安装失败"
                pause_before_return
                return 1
            fi
        else
            printf "版本未安装，已取消写入 .nvmrc。\n"
            pause_before_return
            return 0
        fi
    fi

    if atomic_write_file "$nvmrc" "$version"; then
        print_status_message "ok" ".nvmrc 已写入"
        printf "  路径: %s\n" "$nvmrc"
        printf "  内容: %s\n" "$version"
    else
        print_status_message "fail" ".nvmrc 写入失败"
        pause_before_return
        return 1
    fi

    # Optional: use now
    print_blank_line
    if prompt_yes_no "是否在当前 shell 切换到 ${version}？" "y"; then
        local project_node_switch_log_file=""
        project_node_switch_log_file="$(create_log_file node-use "$version")" || return 1
        printf "日志文件: %s\n" "$project_node_switch_log_file"
        if switch_node_version "$version" "$project_node_switch_log_file"; then
            local actual_ver=""
            actual_ver="$(node -v 2>/dev/null || true)"
            if [ -n "$actual_ver" ] && node_version_satisfies_request "$actual_ver" "$version"; then
                print_status_message "ok" "已切换到 $actual_ver"
            elif [ -n "$actual_ver" ]; then
                print_status_message "warn" "nvm use 成功但 node -v 不匹配"
                printf "  期望: %s\n" "$version"
                printf "  实际: %s\n" "$actual_ver"
            else
                print_status_message "warn" "nvm use 成功但无法读取 node -v"
            fi
        else
            # The .nvmrc write above already succeeded and was already
            # reported to the user; switching the *current* shell to it now
            # is a separate, optional convenience the user just opted into.
            # Its failure must not silently undo the already-confirmed,
            # already-persisted project pin.
            print_status_message "fail" "当前 shell 切换失败，.nvmrc 已保存但当前 shell 未切换"
            printf "  可稍后手动执行: nvm use %s\n" "$version"
            pause_before_return
            return 1
        fi
    fi

    pause_before_return
}
