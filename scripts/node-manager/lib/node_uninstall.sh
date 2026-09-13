# shellcheck shell=bash

# ──────────────────────────────────────────────
# Flow: uninstall Node.js version
# ──────────────────────────────────────────────

run_uninstall_node_flow() {
    local choice=""
    local version=""
    local current_version=""
    local default_alias=""
    local default_info=""
    local default_status=""
    local v_index=0
    local -a versions=()

    print_page_title "卸载 Node.js 版本"

    if ! is_nvm_loaded; then
        if ! load_nvm_into_current_shell; then
            printf "nvm 未安装或无法加载。\n"
            pause_before_return
            return 1
        fi
    fi

    current_version="$(nvm current 2>/dev/null || true)"
    default_info="$(get_nvm_default_info)"
    default_alias="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"

    printf "当前版本: %s\n" "${current_version:-<unknown>}"
    printf "默认版本: %s\n" "${default_alias:-<unknown>}"
    if [ "$default_status" != "resolved" ]; then
        print_status_message "warn" "default alias 无法解析为具体版本，卸载操作将被阻断"
    fi
    print_blank_line
    printf "已安装的 Node 版本:\n"
    print_separator

    while IFS= read -r version; do
        [ -n "$version" ] || continue
        v_index=$((v_index + 1))
        versions+=("$version")
        printf "  %d) %s\n" "$v_index" "$version"
    done <<< "$(get_installed_node_versions)"

    if [ "$v_index" -eq 0 ]; then
        printf "  <none>\n"
        pause_before_return
        return 0
    fi

    print_separator
    printf "输入序号选择要卸载的版本，b 返回: "
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

    # Safety checks
    if [ "$default_status" != "resolved" ]; then
        print_blank_line
        print_status_message "fail" "default alias 未解析，无法安全判断默认版本"
        printf "  请先用 nvm alias default <version> 绑定具体已安装版本。\n"
        pause_before_return
        return 1
    fi

    if [ "$version" = "$current_version" ]; then
        print_blank_line
        print_status_message "fail" "不能卸载当前正在使用的版本 $version"
        printf "  请先切换到其他版本后再卸载。\n"
        pause_before_return
        return 1
    fi

    if [ "$version" = "$default_alias" ]; then
        print_blank_line
        print_status_message "fail" "不能直接卸载默认版本 $version"
        printf "  请先使用「更改全局 Node 版本」将默认版本切换到其他版本。\n"
        printf "  切换后再次执行卸载。\n"
        pause_before_return
        return 1
    fi

    # Show version details
    local version_dir=""
    version_dir="$(nvm_version_dir "$version")"
    print_blank_line
    printf "卸载计划:\n"
    print_separator
    printf "  版本: %s\n" "$version"
    printf "  目录: %s\n" "$version_dir"

    if [ -d "$version_dir" ]; then
        local dir_size=""
        dir_size="$(du -sh "$version_dir" 2>/dev/null | awk '{print $1}')"
        printf "  目录体积: %s\n" "${dir_size:-<unknown>}"
    fi

    # Show global packages under this version
    local version_npm="$version_dir/bin/npm"
    if [ -x "$version_npm" ]; then
        local version_packages=""
        local version_json=""
        version_json="$("$version_npm" ls -g --depth=0 --json 2>/dev/null || true)"
        version_packages="$(printf '%s' "$version_json" \
            | ruby -rjson -e '
                d = JSON.parse(STDIN.read)
                deps = d["dependencies"] || {}
                deps.keys.sort.each do |n|
                  v = deps[n]["version"] rescue "?"
                  puts "#{n} #{v}"
                end
            ' 2>/dev/null || true)"
        if [ -z "$version_packages" ] && ! printf '%s' "$version_json" | validate_json_text; then
            print_blank_line
            print_status_message "fail" "无法解析该版本的全局包列表，取消卸载"
            pause_before_return
            return 1
        fi
        if [ -n "$version_packages" ]; then
            printf "\n  该版本下的全局包:\n"
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                printf "    %s\n" "$line"
            done <<< "$version_packages"
            print_blank_line
            print_status_message "warn" "卸载此版本将同时删除以上全局包"
        fi
    fi

    print_separator
    printf "\n"
    printf "此操作不可逆。请输入版本号确认卸载: "
    read -r choice || return 0
    choice="$(trim_whitespace "$choice")"
    if [ "$choice" != "$version" ]; then
        printf "确认不匹配，取消卸载。\n"
        pause_before_return
        return 0
    fi

    # Execute uninstall
    print_blank_line
    printf "卸载 %s ...\n" "$version"
    print_separator
    if ! acquire_runtime_lock "nvm-mutation"; then
        print_status_message "fail" "已有 nvm uninstall 操作在运行"
        pause_before_return
        return 1
    fi
    nvm uninstall "$version"
    local uninstall_exit=$?
    release_runtime_lock "nvm-mutation"
    if [ "$uninstall_exit" -eq 0 ]; then
        # Verify
        if [ -d "$version_dir" ]; then
            print_status_message "warn" "nvm uninstall 成功但目录仍存在"
        else
            print_status_message "ok" "版本 $version 已卸载"
        fi
    else
        print_status_message "fail" "卸载失败"
    fi

    pause_before_return
}
