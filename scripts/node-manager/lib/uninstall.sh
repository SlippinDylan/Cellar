# shellcheck shell=bash

# ──────────────────────────────────────────────
# Flow: uninstall
# ──────────────────────────────────────────────

run_uninstall_flow() {
    local packages_json=""
    local package_list=""
    local choice=""
    local index=0
    local package_name=""
    local total=0
    local succeeded=0
    local failed=0
    local warned=0
    local protected=0

    print_page_title "卸载 global package"

    # Scan installed packages
    if ! packages_json="$(load_global_package_inventory_json)"; then
        printf "npm 全局包列表命令执行失败。\n"
        pause_before_return
        return 1
    fi
    if [ -z "$packages_json" ]; then
        printf "npm 全局包列表为空，无法判断当前状态。\n"
        pause_before_return
        return 1
    fi
    if ! printf '%s' "$packages_json" | validate_json_text; then
        printf "npm 全局包列表 JSON 无法解析，已停止卸载流程。\n"
        pause_before_return
        return 1
    fi

    package_list="$(printf '%s' "$packages_json" | parse_global_package_versions_stdin)" || true

    if [ -z "$package_list" ]; then
        printf "当前没有已安装的全局包。\n"
        pause_before_return
        return 0
    fi

    # Display packages
    printf "已安装的全局包:\n"
    print_separator
    local -a pkg_names=()
    local -a pkg_versions=()
    index=0
    while IFS='|' read -r name ver; do
        index=$((index + 1))
        pkg_names+=("$name")
        pkg_versions+=("$ver")

        local size_hint=""
        size_hint="$(get_package_directory_size "$name" 2>/dev/null || true)"

        local protected_mark=""
        if is_protected_global_package "$name"; then
            protected_mark=" 受保护"
        fi

        local size_display=""
        if [ -n "$size_hint" ]; then
            size_display=" $size_hint"
        fi
        printf "  %2d  %-30s %s%s%s\n" "$index" "$name" "$ver" "$size_display" "$protected_mark"
    done <<< "$package_list"
    total=$index

    print_separator
    printf "输入序号选择要卸载的包(多个用空格分隔，输入 all 选择全部，b 返回): "
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

    # Build and show uninstall plan with full metadata
    print_blank_line
    printf "卸载计划 — 影响范围:\n"
    print_separator
    local -a plan_indices=()
    local global_root=""
    global_root="$(npm root -g 2>/dev/null || true)"
    local global_bin_dir=""
    if ! global_bin_dir="$(get_global_bin_dir)"; then
        printf "无法获取全局 bin 目录。\n"
        pause_before_return
        return 1
    fi

    # Pre-capture bin commands for ALL packages before any uninstall
    # (package.json will be gone after uninstall, so we must capture now)
    # Use parallel arrays for Bash 3.2 compatibility (no associative arrays)
    local -a cap_indices=()
    local -a cap_bin_cmds=()
    local -a cap_bin_snapshot_indices=()
    local -a cap_bin_snapshots=()
    local -a cap_dir_indices=()
    local -a cap_dir_snapshots=()

    for idx in "${selected[@]}"; do
        local pkg="${pkg_names[$((idx - 1))]}"
        local ver="${pkg_versions[$((idx - 1))]}"

        if is_protected_global_package "$pkg"; then
            print_status_message "warn" "$pkg 受保护，将跳过"
            protected=$((protected + 1))
            continue
        fi

        plan_indices+=("$idx")

        # Capture bin commands NOW while package.json still exists
        local bin_cmds=""
        bin_cmds="$(get_package_bin_commands "$pkg" 2>/dev/null || true)"
        cap_indices+=("$idx")
        cap_bin_cmds+=("$bin_cmds")

        # Full metadata for each package
        local install_path="$global_root/$pkg"
        local pkg_size=""
        pkg_size="$(get_package_directory_size "$pkg" 2>/dev/null || true)"
        local bin_entries=""
        bin_entries="$(check_bin_entries "$pkg" "$global_bin_dir" list)"
        local metadata_summary=""
        metadata_summary="$(summarize_package_metadata "$install_path/package.json" 2>/dev/null || true)"
        local dir_snapshot=""
        if dir_snapshot="$(capture_directory_snapshot "$install_path" "$global_root" 2>/dev/null)"; then
            cap_dir_indices+=("$idx")
            cap_dir_snapshots+=("$dir_snapshot")
        fi
        if [ -n "$bin_cmds" ] && [ -d "$global_bin_dir" ]; then
            while IFS= read -r cmd; do
                [ -n "$cmd" ] || continue
                local bin_path="$global_bin_dir/$cmd"
                local bin_snapshot=""
                if bin_snapshot="$(capture_symlink_snapshot "$bin_path" "$install_path" 2>/dev/null)"; then
                    cap_bin_snapshot_indices+=("$idx")
                    cap_bin_snapshots+=("$bin_snapshot")
                fi
            done <<< "$bin_cmds"
        fi

        printf "\n  [%d] %s %s\n" "$idx" "$pkg" "$ver"
        printf "      安装路径: %s\n" "${install_path:-<unknown>}"
        printf "      目录体积: %s\n" "${pkg_size:-<unknown>}"
        if [ -n "$metadata_summary" ]; then
            printf "%s\n" "$metadata_summary"
        else
            printf "      package.json 元数据: <unavailable>\n"
        fi
        if [ -n "$bin_cmds" ]; then
            printf "      bin 命令: %s\n" "$(printf '%s' "$bin_cmds" | tr '\n' ', ' | sed 's/,$//')"
        fi
        if [ -n "$bin_entries" ]; then
            printf "      全局 bin 入口:\n%s" "$bin_entries"
        fi
    done

    if [ ${#plan_indices[@]} -eq 0 ]; then
        printf "\n没有可卸载的包(全部受保护)。\n"
        pause_before_return
        return 0
    fi

    print_separator
    printf "\n共 %d 个包将被卸载。\n" "${#plan_indices[@]}"
    if ! prompt_yes_no "确认卸载？" "n"; then
        return 0
    fi

    # Execute uninstall
    print_blank_line
    printf "开始卸载...\n"
    print_separator
    if ! acquire_runtime_lock "npm-mutation"; then
        print_status_message "fail" "另一个 npm 变更操作正在运行，已取消卸载"
        pause_before_return
        return 1
    fi

    # Collect residue candidates for post-uninstall cleanup
    local -a residue_dirs=()
    local -a residue_dir_snapshots=()
    local -a residue_bins=()
    local -a residue_bin_snapshots=()

    for idx in "${plan_indices[@]}"; do
        package_name="${pkg_names[$((idx - 1))]}"
        local pkg_dir="$global_root/$package_name"
        local uninstall_log_file=""
        uninstall_log_file="$(create_log_file uninstall "$package_name")"

        printf "卸载 %s ...\n" "$package_name"
        printf "  日志: %s\n" "$uninstall_log_file"
        if uninstall_global_package "$package_name" "$uninstall_log_file"; then
            # Post-uninstall verification: package list, directory, bin residue
            local still_installed=""
            if npm_package_is_installed "$package_name"; then
                still_installed="yes"
            else
                still_installed="no"
            fi
            local dir_still_exists="no"
            [ -d "$pkg_dir" ] && dir_still_exists="yes"

            # Check bin residue using PRE-CAPTURED bin commands
            local bin_residue=""
            local saved_bin_cmds=""
            local ci=0
            while [ "$ci" -lt "${#cap_indices[@]}" ]; do
                if [ "${cap_indices[$ci]}" = "$idx" ]; then
                    saved_bin_cmds="${cap_bin_cmds[$ci]}"
                    break
                fi
                ci=$((ci + 1))
            done
            if [ -n "$saved_bin_cmds" ] && [ -d "$global_bin_dir" ]; then
                while IFS= read -r cmd; do
                    [ -n "$cmd" ] || continue
                    local bin_path="$global_bin_dir/$cmd"
                    local bs_i=0
                    while [ "$bs_i" -lt "${#cap_bin_snapshot_indices[@]}" ]; do
                        if [ "${cap_bin_snapshot_indices[$bs_i]}" = "$idx" ]; then
                            local snapshot="${cap_bin_snapshots[$bs_i]}"
                            local snapshot_path="${snapshot%%|*}"
                            if [ "$snapshot_path" = "$bin_path" ] && verify_symlink_snapshot_current "$snapshot"; then
                                bin_residue="${bin_residue}${cmd} "
                                residue_bins+=("$bin_path")
                                residue_bin_snapshots+=("$snapshot")
                            fi
                        fi
                        bs_i=$((bs_i + 1))
                    done
                done <<< "$saved_bin_cmds"
            fi

            local status="ok"
            local detail=""
            if [ "$still_installed" = "yes" ]; then
                status="warn"
                detail="npm 报告成功但仍出现在列表中"
            else
                # Dir residue and bin residue are independent conditions;
                # report both when both are present instead of only the
                # first one detected, so the confirmation-time summary
                # reflects the full impact (residue collection above
                # already tracks both regardless of this display).
                if [ "$dir_still_exists" = "yes" ]; then
                    status="warn"
                    detail="包目录仍存在"
                    local ds_i=0
                    while [ "$ds_i" -lt "${#cap_dir_indices[@]}" ]; do
                        if [ "${cap_dir_indices[$ds_i]}" = "$idx" ] && directory_snapshot_inode_matches "${cap_dir_snapshots[$ds_i]}"; then
                            residue_dirs+=("$pkg_dir")
                            residue_dir_snapshots+=("${cap_dir_snapshots[$ds_i]}")
                            break
                        fi
                        ds_i=$((ds_i + 1))
                    done
                fi
                if [ -n "$bin_residue" ]; then
                    status="warn"
                    detail="${detail:+$detail; }bin 残留: $(printf '%s' "$bin_residue" | sed 's/ $//')"
                fi
            fi

            print_status_message "$status" "$package_name${detail:+ $detail}"
            if [ "$status" = "ok" ]; then
                succeeded=$((succeeded + 1))
            else
                warned=$((warned + 1))
            fi
        else
            print_status_message "fail" "$package_name"
            failed=$((failed + 1))
        fi
    done

    # Post-uninstall residue cleanup
    local total_residue=$((${#residue_dirs[@]} + ${#residue_bins[@]}))
    if [ "$total_residue" -gt 0 ]; then
        print_blank_line
        print_separator
        printf "残留候选项 %d 个:\n" "$total_residue"

        if [ ${#residue_dirs[@]} -gt 0 ]; then
            printf "\n  包目录残留:\n"
            for rd in "${residue_dirs[@]}"; do
                local rd_size=""
                rd_size="$(du -sh "$rd" 2>/dev/null | awk '{print $1}')"
                printf "    %s %s\n" "$rd" "${rd_size:-<unknown>}"
            done
        fi

        if [ ${#residue_bins[@]} -gt 0 ]; then
            printf "\n  bin 入口残留:\n"
            for rb in "${residue_bins[@]}"; do
                local rb_type="file"
                [ -L "$rb" ] && rb_type="symlink"
                printf "    %s %s\n" "$rb" "$rb_type"
            done
        fi

        print_separator
        if prompt_yes_no "是否清理以上残留？" "n"; then
            print_blank_line
            printf "清理残留...\n"
            print_separator
            local cleaned=0
            local clean_failed=0

            local rd_index=0
            if [ "${#residue_dirs[@]}" -gt 0 ]; then
                for rd in "${residue_dirs[@]}"; do
                    local rd_snapshot="${residue_dir_snapshots[$rd_index]:-}"
                    rd_index=$((rd_index + 1))
                    if ! is_safe_removable_child_dir "$rd" "$global_root"; then
                        print_status_message "fail" "拒绝删除非 global root 子目录: $rd"
                        clean_failed=$((clean_failed + 1))
                        continue
                    fi
                    if ! verify_directory_snapshot_current "$rd_snapshot"; then
                        print_status_message "fail" "删除前目录快照复验失败，已跳过: $rd"
                        clean_failed=$((clean_failed + 1))
                        continue
                    fi

                    if rm -rf "$rd" 2>/dev/null; then
                        if [ ! -d "$rd" ]; then
                            print_status_message "ok" "已删除: $rd"
                            cleaned=$((cleaned + 1))
                        else
                            print_status_message "warn" "删除后仍存在: $rd"
                        fi
                    else
                        print_status_message "fail" "删除失败: $rd"
                        clean_failed=$((clean_failed + 1))
                    fi
                done
            fi

            local rb_index=0
            if [ "${#residue_bins[@]}" -gt 0 ]; then
                for rb in "${residue_bins[@]}"; do
                    local rb_snapshot="${residue_bin_snapshots[$rb_index]:-}"
                    rb_index=$((rb_index + 1))
                    if remove_snapshot_symlink_residue "$rb_snapshot"; then
                        if [ ! -e "$rb" ] && [ ! -L "$rb" ]; then
                            print_status_message "ok" "已删除: $rb"
                            cleaned=$((cleaned + 1))
                        else
                            print_status_message "warn" "删除后仍存在: $rb"
                        fi
                    else
                        print_status_message "fail" "删除前归属复验失败，已跳过: $rb"
                        clean_failed=$((clean_failed + 1))
                    fi
                done
            fi

            printf "\n残留清理: 成功 %d, 失败 %d\n" "$cleaned" "$clean_failed"
        else
            printf "跳过残留清理。\n"
        fi
    fi

    # Structured summary
    print_separator
    print_blank_line
    printf "卸载结果汇总:\n"
    printf "  选中: %d\n" "${#selected[@]}"
    printf "  成功: %d\n" "$succeeded"
    printf "  警告残留: %d\n" "$warned"
    printf "  失败: %d\n" "$failed"
    printf "  跳过受保护: %d\n" "$protected"
    release_runtime_lock "npm-mutation"

    print_blank_line
    printf "卸载后剩余全局包:\n"
    local remaining_packages_json=""
    local remaining_package_list=""
    if remaining_packages_json="$(load_global_package_inventory_json)" && [ -n "$remaining_packages_json" ] && printf '%s' "$remaining_packages_json" | validate_json_text; then
        remaining_package_list="$(printf '%s' "$remaining_packages_json" | parse_global_package_versions_stdin 2>/dev/null || true)"
        if [ -n "$remaining_package_list" ]; then
            printf "  数量: %s\n" "$(printf '%s\n' "$remaining_package_list" | sed '/^$/d' | wc -l | tr -d ' ')"
        else
            printf "  数量: 0\n"
        fi
    else
        printf "  <无法复扫>\n"
    fi

    pause_before_return
}

run_uninstall_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "卸载项目"
        render_uninstall_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_uninstall_choice "$choice")"
        case "$action" in
            uninstall-package)
                require_capabilities npm ruby || continue
                run_uninstall_flow
                ;;
            back)
                return 0
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1 或 b。"
                pause_before_return
                ;;
        esac
    done
}
