# shellcheck shell=bash

# ──────────────────────────────────────────────
# Flow: upgrade scan & execute
# ──────────────────────────────────────────────

run_upgrade_scan_flow() {
    local outdated_json=""
    local outdated_stderr=""
    local outdated_stderr_file=""
    local outdated_exit=0
    local outdated_rows=""
    local choice=""
    local total=0
    local succeeded=0
    local failed=0
    local warned=0

    print_page_title "扫描并升级 global package"

    printf "正在扫描可升级包...\n"
    print_blank_line

    # Capture stdout, stderr, and exit code separately
    # npm outdated returns exit 1 when there ARE outdated packages (not an error)
    # exit 0 means truly nothing outdated
    # Non-empty stderr or exit >1 means a real failure
    outdated_json=""
    outdated_stderr=""
    outdated_exit=0
    ensure_runtime_dirs || return 1
    outdated_stderr_file="$(mktemp "$(manager_tmp_dir)/npm-outdated-stderr.XXXXXX")" || {
        print_status_message "fail" "无法创建临时文件"
        pause_before_return
        return 1
    }
    outdated_json="$(npm outdated -g --depth=0 --json 2>"$outdated_stderr_file")" || outdated_exit=$?
    outdated_stderr="$(cat "$outdated_stderr_file" 2>/dev/null || true)"
    rm -f "$outdated_stderr_file" 2>/dev/null || true

    # Detect real failures vs "has outdated packages" vs "nothing outdated"
    if [ "$outdated_exit" -gt 1 ] || { [ "$outdated_exit" -eq 1 ] && [ -n "$outdated_stderr" ] && [ -z "$outdated_json" ]; }; then
        # Real failure: exit >1, or exit 1 with stderr but no stdout
        print_status_message "fail" "扫描失败"
        if [ -n "$outdated_stderr" ]; then
            printf "错误信息:\n"
            printf "%s\n" "$outdated_stderr"
        fi
        printf "可能原因: 网络问题、registry 异常、认证失败\n"
        pause_before_return
        return 1
    fi

    # exit 1 with empty json object or empty stdout = genuinely no outdated
    if [ -z "$outdated_json" ] || [ "$outdated_json" = "{}" ]; then
        printf "没有可升级的全局包。\n"
        pause_before_return
        return 0
    fi

    # Validate that stdout is actually valid JSON before parsing
    if ! printf '%s' "$outdated_json" | ruby -rjson -e 'JSON.parse(STDIN.read)' 2>/dev/null; then
        # Non-empty but not valid JSON — this is a real error, not "no outdated"
        print_status_message "fail" "扫描返回了无法解析的数据"
        printf "原始输出:\n"
        printf "%s\n" "$outdated_json" | head -10
        printf "可能原因: npm 命令异常、输出格式错误\n"
        pause_before_return
        return 1
    fi

    outdated_rows="$(printf '%s' "$outdated_json" | parse_outdated_package_rows_stdin)" || true

    if [ -z "$outdated_rows" ]; then
        printf "没有可升级的全局包。\n"
        pause_before_return
        return 0
    fi

    # Display outdated packages with row numbers
    printf "  %-4s %-28s %-14s %-14s %-14s\n" "#" "包名" "当前版本" "wanted" "latest"
    print_separator

    local -a out_names=()
    local -a out_current=()
    local -a out_wanted=()
    local -a out_latest=()
    total=0
    while IFS='|' read -r name current wanted latest; do
        total=$((total + 1))
        out_names+=("$name")
        out_current+=("$current")
        out_wanted+=("$wanted")
        out_latest+=("$latest")
        printf "%2d  %-28s %-14s %-14s %-14s\n" "$total" "$name" "$current" "$wanted" "$latest"
    done <<< "$outdated_rows"

    print_separator
    printf "共 %d 个可升级包\n" "$total"
    print_blank_line
    printf "输入序号选择要升级的包(多个用空格分隔，all 全部升级，b 返回): "
    read -r choice || return 0

    choice="$(trim_whitespace "$choice")"
    [ -n "$choice" ] || return 0

    local parsed=""
    parsed="$(parse_multi_numeric_choice "$choice" "$total")"

    if [ "$parsed" = "back" ]; then
        return 0
    fi

    if [ "$parsed" = "invalid" ]; then
        print_status_message "warn" "输入无效。"
        pause_before_return
        return 0
    fi

    local -a selected=()
    if [ "$parsed" = "all" ]; then
        local i=1
        while [ "$i" -le "$total" ]; do
            selected+=("$i")
            i=$((i + 1))
        done
    else
        for token in $parsed; do
            selected+=("$token")
        done
    fi

    # Show upgrade plan (wanted, not latest)
    print_blank_line
    printf "升级计划 wanted:\n"
    print_separator
    for idx in "${selected[@]}"; do
        printf "  %s: %s -> %s\n" \
            "${out_names[$((idx - 1))]}" \
            "${out_current[$((idx - 1))]}" \
            "${out_wanted[$((idx - 1))]}"
    done
    print_separator

    if ! prompt_yes_no "确认升级以上 ${#selected[@]} 个包？" "y"; then
        return 0
    fi

    # Execute upgrade using npm update (wanted semantics, not @latest)
    print_blank_line
    printf "开始升级...\n"
    print_separator

    for idx in "${selected[@]}"; do
        local pkg="${out_names[$((idx - 1))]}"
        local old_ver="${out_current[$((idx - 1))]}"
        local wanted_ver="${out_wanted[$((idx - 1))]}"
        local upgrade_log_file=""
        upgrade_log_file="$(create_log_file upgrade "$pkg")"
        printf "升级 %s ...\n" "$pkg"
        printf "  日志: %s\n" "$upgrade_log_file"
        if upgrade_global_package "$pkg" "$upgrade_log_file"; then
            local verify_result=""
            local verify_status=""
            local verify_detail=""
            local new_version=""
            verify_result="$(verify_global_package_update_result "$pkg" "$old_ver" "$wanted_ver")"
            verify_status="$(printf '%s' "$verify_result" | awk -F'|' '{print $1}')"
            verify_detail="$(printf '%s' "$verify_result" | awk -F'|' '{print $2}')"
            new_version="$(printf '%s' "$verify_result" | awk -F'|' '{print $3}')"
            if [ "$verify_status" = "ok" ]; then
                print_status_message "ok" "$pkg: $old_ver -> $new_version"
                printf "  验证: %s\n" "$verify_detail"
                succeeded=$((succeeded + 1))
            elif [ "$verify_status" = "warn" ]; then
                print_status_message "warn" "$pkg: $old_ver -> ${new_version:-<unknown>}"
                printf "  验证: %s\n" "$verify_detail"
                warned=$((warned + 1))
            else
                print_status_message "fail" "$pkg: $verify_detail"
                printf "  当前版本: %s\n" "${new_version:-<unknown>}"
                failed=$((failed + 1))
            fi
        else
            print_status_message "fail" "$pkg"
            failed=$((failed + 1))
        fi
    done

    # Summary
    print_separator
    print_blank_line
    printf "升级结果汇总:\n"
    printf "  选中: %d\n" "${#selected[@]}"
    printf "  成功: %d\n" "$succeeded"
    printf "  警告: %d\n" "$warned"
    printf "  失败: %d\n" "$failed"

    local remaining_json=""
    local remaining_rows=""
    # Reuse the same careful exit-code handling as the initial scan (real
    # failure vs "nothing outdated") instead of treating a failed rescan as
    # a silent "0 remaining".
    if remaining_json="$(render_outdated_json 2>/dev/null)"; then
        if [ -n "$remaining_json" ] && [ "$remaining_json" != "{}" ]; then
            remaining_rows="$(printf '%s' "$remaining_json" | parse_outdated_package_rows_stdin 2>/dev/null || true)"
        fi
        if [ -n "$remaining_rows" ]; then
            printf "  剩余可升级: %s\n" "$(printf '%s\n' "$remaining_rows" | sed '/^$/d' | wc -l | tr -d ' ')"
        else
            printf "  剩余可升级: 0\n"
        fi
    else
        printf "  剩余可升级: <扫描失败，无法确认>\n"
    fi

    pause_before_return
}

run_upgrade_latest_flow() {
    local package_name=""
    local current_version=""
    local latest_version=""

    print_page_title "指定包升级到 latest"

    printf "请输入包名: "
    read -r package_name || return 0
    package_name="$(trim_whitespace "$package_name")"
    [ -n "$package_name" ] || return 0
    if ! validate_package_name_only "$package_name"; then
        print_status_message "fail" "包名格式不支持: $package_name"
        printf "latest 升级只支持 package 或 @scope/package，不接受 version/tag spec。\n"
        pause_before_return
        return 1
    fi

    # Check if installed
    current_version="$(get_installed_global_package_version "$package_name")"

    if [ -z "$current_version" ]; then
        printf "包 %s 未安装。\n" "$package_name"
        pause_before_return
        return 0
    fi

    # Get latest version from registry
    latest_version="$(get_registry_latest_version "$package_name" || true)"

    print_blank_line
    printf "当前版本: %s\n" "$current_version"
    printf "latest 版本: %s\n" "${latest_version:-<unknown>}"
    print_blank_line

    if [ -z "$latest_version" ]; then
        print_status_message "fail" "无法获取 latest 版本，已取消升级"
        pause_before_return
        return 1
    fi

    if [ "$current_version" = "$latest_version" ]; then
        printf "已经是最新版本，无需升级。\n"
        pause_before_return
        return 0
    fi

    if ! prompt_yes_no "确认升级到 latest？" "y"; then
        return 0
    fi

    print_blank_line
    printf "升级 %s ...\n" "$package_name"
    local upgrade_log_file=""
    upgrade_log_file="$(create_log_file upgrade-latest "$package_name")"
    printf "日志文件: %s\n" "$upgrade_log_file"
    if upgrade_global_package_to_latest "$package_name" "$upgrade_log_file"; then
        local new_version=""
        new_version="$(get_installed_global_package_version "$package_name")"
        print_blank_line
        if [ -z "$new_version" ]; then
            print_status_message "warn" "升级后无法读取版本"
        elif [ "$new_version" = "$current_version" ]; then
            print_status_message "warn" "版本未变化 $current_version"
        elif [ "$new_version" != "$latest_version" ]; then
            print_status_message "fail" "升级后版本不是 latest"
            printf "  期望: %s\n" "$latest_version"
            printf "  实际: %s\n" "$new_version"
        else
            print_status_message "ok" "升级成功"
            printf "  %s: %s -> %s\n" "$package_name" "$current_version" "$new_version"
        fi
    else
        print_status_message "fail" "升级失败: $package_name"
    fi

    pause_before_return
}

run_update_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "更新与升级"
        render_update_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_update_choice "$choice")"
        case "$action" in
            scan-upgrade)
                require_capabilities npm ruby || continue
                run_upgrade_scan_flow
                ;;
            upgrade-latest)
                require_capabilities npm ruby || continue
                run_upgrade_latest_flow
                ;;
            back)
                return 0
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1、2 或 b。"
                pause_before_return
                ;;
        esac
    done
}
