# shellcheck shell=bash

# ──────────────────────────────────────────────
# Flow: cleanup
# ──────────────────────────────────────────────

run_cleanup_menu() {
    printf "1) npm cache verify\n"
    printf "2) npm cache clean --force\n"
    printf "3) 清理 npm 用户缓存目录\n"
    printf "4) 清理 node-gyp 缓存\n"
    printf "5) 清理全局 bin 孤儿软链接\n"
    printf "6) 清理 nvm 旧版本残留\n"
    printf "b) 返回\n"
}

run_npm_cache_verify_cleanup() {
    local verify_output=""
    local verify_exit=0

    print_blank_line
    printf "执行 npm cache verify...\n"
    print_separator
    verify_output="$(npm cache verify 2>&1)" || verify_exit=$?
    printf "%s\n" "$verify_output"
    print_separator
    if [ "$verify_exit" -eq 0 ]; then
        print_status_message "ok" "缓存验证完成"
    else
        print_status_message "fail" "缓存验证失败 exit $verify_exit"
    fi
    pause_before_return
}

run_npm_cache_clean_cleanup() {
    print_blank_line
    printf "当前缓存状态 (npm cache verify):\n"
    print_separator
    local pre_clean_status=""
    pre_clean_status="$(npm cache verify 2>&1)" || true
    printf "%s\n" "$pre_clean_status"
    print_separator
    print_blank_line
    printf "将执行 npm cache clean --force\n"
    printf "这会清理 npm 缓存目录中的所有内容。\n"
    print_blank_line
    if ! prompt_yes_no "确认清理？" "n"; then
        return 0
    fi

    print_blank_line
    printf "执行清理...\n"
    print_separator
    if ! acquire_runtime_lock "npm-mutation"; then
        print_status_message "fail" "已有 npm cache 操作在运行"
        pause_before_return
        return 1
    fi
    npm cache clean --force 2>&1
    local clean_exit=$?
    release_runtime_lock "npm-mutation"
    if [ "$clean_exit" -eq 0 ]; then
        local cache_status=""
        local cache_verify_exit=0
        cache_status="$(npm cache verify 2>&1)" || cache_verify_exit=$?
        if [ "$cache_verify_exit" -eq 0 ]; then
            print_status_message "ok" "缓存清理完成"
        else
            print_status_message "warn" "缓存清理执行成功但验证失败 exit $cache_verify_exit"
        fi
        printf "  清理后状态:\n"
        printf "%s\n" "$cache_status" | head -3
    else
        print_status_message "fail" "缓存清理失败"
    fi
    pause_before_return
}

# Return codes: 0 = deleted (or nothing to delete), 1 = real failure
# (unsafe path, lock contention, rm failure, directory survived rm),
# 2 = user cancelled (EOF or confirmation path mismatch). Callers that
# tally success/failure counts must treat 2 as neither.
remove_confirmed_cache_directory() {
    local label="$1"
    local original_path="$2"
    local resolved_path=""
    local directory_snapshot=""
    local dir_size=""
    local confirm_path=""

    if [ ! -d "$original_path" ]; then
        printf "%s目录不存在，无需清理: %s\n" "$label" "$original_path"
        pause_before_return
        return 0
    fi

    if ! resolved_path="$(resolve_safe_user_cache_delete_path "$original_path")"; then
        print_status_message "fail" "${label}路径不在安全范围内，拒绝操作: $original_path"
        printf "  允许范围: HOME 子目录或 /tmp 子目录；拒绝 HOME、/tmp、/private/tmp 根目录\n"
        pause_before_return
        return 1
    fi
    directory_snapshot="$(capture_directory_snapshot "$resolved_path" "$(dirname "$resolved_path")" 2>/dev/null)" || {
        print_status_message "fail" "无法建立待删除目录快照，拒绝操作: $resolved_path"
        pause_before_return
        return 1
    }

    dir_size="$(du -sh "$resolved_path" 2>/dev/null | awk '{print $1}')"
    printf "%s路径: %s\n" "$label" "$resolved_path"
    printf "目录体积: %s\n" "${dir_size:-<unknown>}"
    print_blank_line
    printf "请输入完整路径确认删除: %s\n" "$resolved_path"
    printf "确认路径: "
    if ! read -r confirm_path; then
        printf "未读取到确认输入，取消删除。\n"
        return 2
    fi
    confirm_path="$(trim_whitespace "$confirm_path")"
    if [ "$confirm_path" != "$resolved_path" ]; then
        printf "确认路径不匹配，取消删除。\n"
        return 2
    fi

    print_blank_line
    printf "执行删除...\n"
    print_separator
    if ! acquire_runtime_lock "npm-mutation"; then
        print_status_message "fail" "已有 npm 变更操作在运行，已取消目录删除"
        pause_before_return
        return 1
    fi
    if ! verify_directory_snapshot_current "$directory_snapshot"; then
        release_runtime_lock "npm-mutation"
        print_status_message "fail" "确认后目录状态已变化，已取消删除: $resolved_path"
        pause_before_return
        return 1
    fi
    if rm -rf "$resolved_path"; then
        release_runtime_lock "npm-mutation"
        if [ -d "$resolved_path" ]; then
            print_status_message "warn" "删除命令执行成功但目录仍存在"
            pause_before_return
            return 1
        fi
        print_status_message "ok" "${label}已删除"
        printf "  路径: %s\n" "$resolved_path"
        printf "  释放空间: %s\n" "${dir_size:-<unknown>}"
        pause_before_return
        return 0
    fi
    release_runtime_lock "npm-mutation"
    print_status_message "fail" "${label}删除失败"
    printf "  路径: %s\n" "$resolved_path"
    pause_before_return
    return 1
}

run_npm_cache_dir_cleanup() {
    local cache_path=""

    print_page_title "清理 npm 用户缓存目录"
    if ! cache_path="$(get_npm_cache_path)"; then
        printf "无法获取 npm cache 路径。\n"
        pause_before_return
        return 0
    fi
    print_status_message "warn" "高级修复入口: 优先使用 npm cache verify / npm cache clean --force"
    printf "直接删除 cache 目录可能影响正在运行的 npm 进程。继续前请确认没有 npm install/update/cache 操作正在运行。\n"
    print_blank_line
    if ! prompt_yes_no "确认进入直接目录删除流程？" "n"; then
        return 0
    fi
    printf "npm cache 路径: %s\n" "$cache_path"
    remove_confirmed_cache_directory "npm cache 目录" "$cache_path"
}

run_node_gyp_cache_cleanup() {
    local candidates=""
    local nodegyp_path=""
    local source=""
    local resolved_path=""
    local dir_size=""
    local choice=""
    local parsed_choice=""
    local selected_index=""
    local cleaned=0
    local clean_failed=0
    local clean_skipped=0
    local -a existing_paths=()
    local -a existing_sources=()

    print_page_title "清理 node-gyp 缓存"
    candidates="$(detect_node_gyp_cache_dirs)"
    if [ -z "$candidates" ]; then
        printf "没有可检测的 node-gyp 缓存路径。\n"
        pause_before_return
        return 0
    fi

    while IFS='|' read -r nodegyp_path source; do
        [ -n "$nodegyp_path" ] || continue
        [ -d "$nodegyp_path" ] || continue
        existing_paths+=("$nodegyp_path")
        existing_sources+=("${source:-unknown}")
    done <<< "$candidates"

    if [ "${#existing_paths[@]}" -eq 0 ]; then
        printf "检测到候选路径，但当前都不存在，无需清理。\n"
        pause_before_return
        return 0
    fi

    printf "检测到的 node-gyp 缓存目录:\n"
    print_separator
    local i=0
    while [ "$i" -lt "${#existing_paths[@]}" ]; do
        nodegyp_path="${existing_paths[$i]}"
        source="${existing_sources[$i]}"
        resolved_path="$(resolve_safe_user_cache_delete_path "$nodegyp_path" 2>/dev/null || true)"
        if [ -n "$resolved_path" ]; then
            dir_size="$(du -sh "$resolved_path" 2>/dev/null | awk '{print $1}')"
        else
            dir_size="<unsafe>"
        fi
        printf "  %d) %s\n" "$((i + 1))" "$nodegyp_path"
        printf "     来源: %s  体积: %s\n" "$source" "${dir_size:-<unknown>}"
        i=$((i + 1))
    done
    print_separator
    printf "输入序号、范围或 all 全选；输入 b 返回。\n"
    printf "请选择要清理的目录: "
    read -r choice || return 0
    parsed_choice="$(parse_multi_numeric_choice "$choice" "${#existing_paths[@]}")"
    case "$parsed_choice" in
        back) return 0 ;;
        invalid)
            print_status_message "warn" "输入无效。"
            pause_before_return
            return 0
            ;;
        all)
            parsed_choice=""
            local all_index=1
            while [ "$all_index" -le "${#existing_paths[@]}" ]; do
                parsed_choice="${parsed_choice:+$parsed_choice }$all_index"
                all_index=$((all_index + 1))
            done
            ;;
    esac

    for selected_index in $parsed_choice; do
        i=$((selected_index - 1))
        remove_confirmed_cache_directory "node-gyp 缓存(${existing_sources[$i]})" "${existing_paths[$i]}"
        case "$?" in
            0) cleaned=$((cleaned + 1)) ;;
            2) clean_skipped=$((clean_skipped + 1)) ;;
            *) clean_failed=$((clean_failed + 1)) ;;
        esac
    done

    print_blank_line
    printf "清理完成: 成功 %d，取消 %d，失败 %d\n" "$cleaned" "$clean_skipped" "$clean_failed"
    pause_before_return
}

run_orphan_bin_cleanup() {
    local global_bin=""
    local orphan=""
    local orphan_choice=""
    local orphan_parsed=""
    local cleaned=0
    local clean_failed=0
    local clean_skipped=0
    local -a orphans=()
    local -a orphan_snapshots=()
    local -a selected_orphans=()

    print_page_title "清理全局 bin 孤儿软链接"
    if ! global_bin="$(get_global_bin_dir)"; then
        printf "无法获取全局 bin 目录。\n"
        pause_before_return
        return 1
    fi
    if [ ! -d "$global_bin" ]; then
        printf "全局 bin 目录不存在: %s\n" "$global_bin"
        pause_before_return
        return 0
    fi

    while IFS= read -r orphan; do
        [ -n "$orphan" ] || continue
        local orphan_snapshot=""
        orphan_snapshot="$(capture_orphan_symlink_snapshot "$orphan" 2>/dev/null || true)"
        if [ -n "$orphan_snapshot" ]; then
            orphans+=("$orphan")
            orphan_snapshots+=("$orphan_snapshot")
        fi
    done < <(find "$global_bin" -maxdepth 1 -type l 2>/dev/null)

    if [ ${#orphans[@]} -eq 0 ]; then
        printf "没有发现孤儿软链接。\n"
        pause_before_return
        return 0
    fi

    printf "发现 %d 个孤儿软链接:\n" "${#orphans[@]}"
    print_separator
    local oi=1
    for orphan in "${orphans[@]}"; do
        printf "  %d) %s -> %s\n" "$oi" "$orphan" "$(readlink "$orphan" 2>/dev/null || true)"
        oi=$((oi + 1))
    done
    print_separator

    printf "输入序号选择要删除的孤儿软链接(多个用空格、逗号或范围分隔，all 全部，b 返回): "
    read -r orphan_choice || return 0
    orphan_parsed="$(parse_multi_numeric_choice "$orphan_choice" "${#orphans[@]}")"
    case "$orphan_parsed" in
        back) return 0 ;;
        invalid)
            print_status_message "warn" "输入无效。"
            pause_before_return
            return 0
            ;;
        all)
            local soi=1
            while [ "$soi" -le "${#orphans[@]}" ]; do
                selected_orphans+=("$soi")
                soi=$((soi + 1))
            done
            ;;
        *)
            local token=""
            for token in $orphan_parsed; do
                selected_orphans+=("$token")
            done
            ;;
    esac

    if ! prompt_yes_no "确认删除选中的 ${#selected_orphans[@]} 个孤儿软链接？" "n"; then
        return 0
    fi

    print_blank_line
    printf "清理孤儿软链接...\n"
    print_separator
    if ! acquire_runtime_lock "npm-mutation"; then
        print_status_message "fail" "另一个 npm 变更操作正在运行，已取消清理"
        pause_before_return
        return 1
    fi
    local selected_idx=""
    for selected_idx in "${selected_orphans[@]}"; do
        orphan="${orphans[$((selected_idx - 1))]}"
        local orphan_snapshot="${orphan_snapshots[$((selected_idx - 1))]}"
        if ! verify_orphan_symlink_snapshot_current "$orphan_snapshot"; then
            print_status_message "warn" "跳过非孤儿软链接: $orphan"
            clean_skipped=$((clean_skipped + 1))
            continue
        fi
        if remove_orphan_symlink_snapshot "$orphan_snapshot"; then
            print_status_message "ok" "已删除: $orphan"
            cleaned=$((cleaned + 1))
        else
            print_status_message "fail" "删除失败: $orphan"
            clean_failed=$((clean_failed + 1))
        fi
    done
    release_runtime_lock "npm-mutation"
    printf "\n清理结果: 成功 %d, 跳过 %d, 失败 %d\n" "$cleaned" "$clean_skipped" "$clean_failed"
    pause_before_return
}

run_nvm_old_versions_cleanup() {
    print_page_title "清理 nvm 旧版本残留"
    if ! is_nvm_loaded && ! load_nvm_into_current_shell; then
        printf "nvm 未安装或无法加载。\n"
        pause_before_return
        return 1
    fi

    local current_ver=""
    local default_ver=""
    local default_info=""
    local default_status=""
    local ver=""
    local choice=""
    local parsed=""
    local cv_index=0
    local -a cleanup_versions=()
    local -a cleanup_dirs=()
    local -a cleanup_sizes=()
    local -a cleanup_size_kb=()

    if ! current_ver="$(read_nvm_current_state)"; then
        print_status_message "fail" "无法读取当前 Node 状态，旧版本清理已阻断"
        pause_before_return
        return 1
    fi
    default_info="$(get_nvm_default_info)"
    default_ver="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"
    printf "当前版本: %s\n" "${current_ver:-<unknown>}"
    printf "默认版本: %s\n" "${default_ver:-<unknown>}"
    if [ "$default_status" != "resolved" ]; then
        print_status_message "warn" "default alias 无法解析为具体版本，旧版本清理将禁止执行"
    fi
    print_blank_line
    printf "已安装的 Node 版本:\n"
    print_separator

    while IFS= read -r ver; do
        [ -n "$ver" ] || continue
        local vdir=""
        local vsize=""
        local vsize_kb="0"
        local skip_reason=""
        local pkg_summary=""
        vdir="$(nvm_version_dir "$ver")"
        vsize="$(du -sh "$vdir" 2>/dev/null | awk '{print $1}')"
        vsize_kb="$(du -sk "$vdir" 2>/dev/null | awk '{print $1}')"
        is_nonnegative_integer "$vsize_kb" || vsize_kb=0
        pkg_summary="$(nvm_version_package_summary "$vdir" 2>/dev/null || true)"
        if [ "$ver" = "$current_ver" ]; then
            skip_reason=" (当前版本，不可清理)"
        elif [ "$default_status" != "resolved" ]; then
            skip_reason=" (default alias 未解析，不可清理)"
        elif [ "$ver" = "$default_ver" ]; then
            skip_reason=" (默认版本，不可清理)"
        else
            local v_pkg_count=""
            if ! v_pkg_count="$(nvm_version_user_package_count "$vdir" 2>/dev/null)"; then
                skip_reason=" (npm 不可用或全局包不可验证，不可清理)"
            elif [ "$v_pkg_count" -gt 0 ] 2>/dev/null; then
                skip_reason=" (${v_pkg_count} 个用户全局包，不可清理)"
            fi
        fi
        cv_index=$((cv_index + 1))
        cleanup_versions+=("$ver")
        cleanup_dirs+=("$vdir")
        cleanup_sizes+=("$vsize")
        cleanup_size_kb+=("$vsize_kb")
        printf "  %d) %-15s %s%s\n" "$cv_index" "$ver" "${vsize:-<unknown>}" "$skip_reason"
        if [ -n "$pkg_summary" ]; then
            printf "      package summary: %s\n" "$pkg_summary"
        fi
    done <<< "$(get_installed_node_versions)"

    if [ "$cv_index" -eq 0 ]; then
        printf "  <none>\n"
        pause_before_return
        return 0
    fi

    print_separator
    printf "输入序号选择要清理的版本(多个用空格分隔，b 返回):\n"
    printf "注意: 当前版本和默认版本不可清理。\n\n请选择: "
    read -r choice || return 0
    parsed="$(parse_multi_numeric_choice "$choice" "$cv_index")"
    case "$parsed" in
        back) return 0 ;;
        invalid)
            print_status_message "warn" "输入无效。"
            pause_before_return
            return 0
            ;;
    esac

    local token=""
    local idx=""
    local -a selected=()
    local -a valid_indices=()
    if [ "$parsed" = "all" ]; then
        idx=1
        while [ "$idx" -le "$cv_index" ]; do
            selected+=("$idx")
            idx=$((idx + 1))
        done
    else
        for token in $parsed; do
            selected+=("$token")
        done
    fi

    print_blank_line
    printf "清理计划:\n"
    print_separator
    for idx in "${selected[@]}"; do
        ver="${cleanup_versions[$((idx - 1))]}"
        local vdir="${cleanup_dirs[$((idx - 1))]}"
        local v_pkg_count=""
        if [ "$ver" = "$current_ver" ]; then
            print_status_message "warn" "$ver 当前版本，跳过"
        elif [ "$default_status" != "resolved" ]; then
            print_status_message "warn" "$ver default alias 未解析，跳过"
        elif [ "$ver" = "$default_ver" ]; then
            print_status_message "warn" "$ver 默认版本，跳过"
        elif ! v_pkg_count="$(nvm_version_user_package_count "$vdir" 2>/dev/null)"; then
            print_status_message "warn" "$ver npm 不可用或全局包不可验证，跳过"
        elif [ "$v_pkg_count" -gt 0 ] 2>/dev/null; then
            print_status_message "warn" "$ver 仍有用户全局包，跳过"
        else
            local summary=""
            summary="$(nvm_version_package_summary "$vdir" 2>/dev/null || true)"
            printf "  将卸载: %s %s\n" "$ver" "${cleanup_sizes[$((idx - 1))]:-<unknown>}"
            if [ -n "$summary" ]; then
                printf "    package summary: %s\n" "$summary"
            fi
            valid_indices+=("$idx")
        fi
    done

    if [ ${#valid_indices[@]} -eq 0 ]; then
        printf "\n没有可清理的版本。\n"
        pause_before_return
        return 0
    fi

    print_separator
    if ! prompt_yes_no "确认卸载以上 ${#valid_indices[@]} 个版本？" "n"; then
        return 0
    fi

    local expected_versions=""
    for idx in "${valid_indices[@]}"; do
        ver="${cleanup_versions[$((idx - 1))]}"
        expected_versions="${expected_versions}${expected_versions:+ }${ver}"
    done
    printf "请输入完整版本号确认: %s\n确认版本: " "$expected_versions"
    local confirmed_versions=""
    read -r confirmed_versions || return 0
    confirmed_versions="$(trim_whitespace "$confirmed_versions")"
    if [ "$confirmed_versions" != "$expected_versions" ]; then
        printf "确认版本不匹配，取消卸载。\n"
        return 0
    fi

    print_blank_line
    printf "开始清理...\n"
    print_separator
    local cleaned=0
    local clean_warned=0
    local clean_failed=0
    local freed_kb=0
    if ! acquire_runtime_lock "nvm-mutation"; then
        print_status_message "fail" "已有 nvm 变更操作在运行，已取消清理"
        pause_before_return
        return 1
    fi
    for idx in "${valid_indices[@]}"; do
        ver="${cleanup_versions[$((idx - 1))]}"
        local vdir="${cleanup_dirs[$((idx - 1))]}"
        printf "卸载 %s ...\n" "$ver"
        if ! nvm_version_is_safe_cleanup_candidate "$ver"; then
            print_status_message "warn" "$ver 确认后状态已变化，跳过卸载"
            clean_warned=$((clean_warned + 1))
            continue
        fi
        nvm uninstall "$ver"
        local uninstall_exit=$?
        if [ "$uninstall_exit" -eq 0 ]; then
            if [ -d "$vdir" ]; then
                print_status_message "warn" "$ver: nvm uninstall 成功但目录仍存在"
                clean_warned=$((clean_warned + 1))
            else
                print_status_message "ok" "$ver 已卸载"
                cleaned=$((cleaned + 1))
                freed_kb=$((freed_kb + ${cleanup_size_kb[$((idx - 1))]:-0}))
            fi
        else
            print_status_message "fail" "$ver 卸载失败"
            clean_failed=$((clean_failed + 1))
        fi
    done
    release_runtime_lock "nvm-mutation"
    printf "\n清理结果: 成功 %d, 警告 %d, 失败 %d\n" "$cleaned" "$clean_warned" "$clean_failed"
    local freed_display=""
    freed_display="$(awk -v kb="$freed_kb" 'BEGIN {
      if (kb >= 1048576) printf "%.2f GB", kb / 1048576
      else if (kb >= 1024) printf "%.2f MB", kb / 1024
      else printf "%d KB", kb
    }')"
    printf "  估算释放空间: %s\n" "$freed_display"
    printf "  剩余可用 Node 版本:\n"
    local remaining_versions=""
    remaining_versions="$(get_installed_node_versions 2>/dev/null || true)"
    if [ -n "$remaining_versions" ]; then
        while IFS= read -r ver; do
            [ -n "$ver" ] && printf "    %s\n" "$ver"
        done <<< "$remaining_versions"
    else
        printf "    <none>\n"
    fi
    pause_before_return
}

run_cleanup_flow() {
    local choice=""

    while true; do
        print_page_title "清理 npm 环境"
        run_cleanup_menu
        print_blank_line
        printf "请选择: "
        read -r choice || return 0

        case "$choice" in
            1) run_npm_cache_verify_cleanup ;;
            2) run_npm_cache_clean_cleanup ;;
            3) run_npm_cache_dir_cleanup ;;
            4) run_node_gyp_cache_cleanup ;;
            5) run_orphan_bin_cleanup ;;
            6) run_nvm_old_versions_cleanup ;;
            b|B) return 0 ;;
            *)
                print_status_message "warn" "输入无效。"
                pause_before_return
                ;;
        esac
    done
}
