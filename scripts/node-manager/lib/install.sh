# shellcheck shell=bash

# ──────────────────────────────────────────────
# Flow: single install
# ──────────────────────────────────────────────

run_single_install_flow() {
    local package_name=""
    local node_version=""
    local global_prefix=""
    local attempt=0
    local max_retries="$INSTALL_MAX_RETRIES"
    local log_file=""
    local target_version=""
    local target_is_pinned="no"
    local bare_name=""
    local installed_version=""
    local registry=""

    print_page_title "单独安装 global package"

    node_version="$(node -v 2>/dev/null || echo '<unavailable>')"
    global_prefix="$(npm prefix -g 2>/dev/null || echo '<unavailable>')"
    registry="$(npm config get registry 2>/dev/null || echo '<unavailable>')"

    printf "当前 Node 版本: %s\n" "$node_version"
    printf "npm global prefix: %s\n" "$global_prefix"
    print_blank_line

    printf "请输入包名(支持 package、@scope/package、package@version、package@tag): "
    read -r package_name || return 0
    package_name="$(trim_whitespace "$package_name")"
    [ -n "$package_name" ] || return 0
    if ! validate_package_spec "$package_name"; then
        print_status_message "fail" "包名格式不支持: $package_name"
        printf "仅支持安全 registry 子集: package、@scope/package、package@version、package@tag。\n"
        pause_before_return
        return 1
    fi

    bare_name="$(extract_package_name "$package_name")"
    if ! target_version="$(resolve_install_target_version "$package_name")"; then
        print_status_message "fail" "无法解析请求的目标版本: $package_name"
        pause_before_return
        return 1
    fi
    if package_spec_is_pinned_version "$package_name"; then
        target_is_pinned="yes"
    fi
    installed_version="$(get_installed_global_package_version "$bare_name")"

    print_blank_line
    printf "准备安装:\n"
    printf "  package spec: %s\n" "$package_name"
    printf "  package name: %s\n" "$bare_name"
    printf "  target version: %s\n" "$target_version"
    printf "  installed version: %s\n" "${installed_version:-<not installed>}"
    printf "  npm global prefix: %s\n" "$global_prefix"
    printf "  registry: %s\n" "$registry"
    printf "  log: 执行开始后创建\n"
    print_separator

    if ! prompt_yes_no "确认安装？" "n"; then
        return 0
    fi

    log_file="$(create_log_file install "$package_name")" || return 1

    attempt=0
    while [ "$attempt" -le "$max_retries" ]; do
        if [ "$attempt" -gt 0 ]; then
            printf "\n重试第 %d 次...\n" "$attempt"
        fi

        if install_global_package "$package_name" "$log_file"; then
            # Verify installation: version must be readable
            installed_version="$(get_installed_global_package_version "$bare_name")"

            local verify_result=""
            local verify_status=""
            local verify_message=""
            local verify_target=""
            if [ "$target_is_pinned" = "yes" ]; then
                verify_result="$(verify_install_result_for_spec "$package_name" "$installed_version" "$target_version" || true)"
            else
                # Non-pinned specs (bare name / @latest / dist-tag) resolve their
                # target fresh here instead of reusing the value cached before the
                # confirm prompt, since the registry's tag pointer can move between
                # confirm and this verification.
                verify_result="$(verify_install_result_for_spec "$package_name" "$installed_version" || true)"
            fi
            verify_status="$(printf '%s' "$verify_result" | awk -F'|' '{print $1}')"
            verify_message="$(printf '%s' "$verify_result" | awk -F'|' '{print $2}')"
            verify_target="$(printf '%s' "$verify_result" | awk -F'|' '{print $3}')"

            if [ "$verify_status" != "ok" ]; then
                print_blank_line
                print_status_message "warn" "$package_name: ${verify_message:-安装验证失败}"
                if [ -n "$verify_target" ]; then
                    printf "  期望版本: %s\n" "$verify_target"
                    printf "  实际版本: %s\n" "${installed_version:-<unknown>}"
                fi
                attempt=$((attempt + 1))
                if [ "$attempt" -gt "$max_retries" ]; then
                    break
                fi
                if ! prompt_yes_no "验证失败，是否重试？" "y"; then
                    break
                fi
                continue
            fi

            local bin_commands=""
            bin_commands="$(get_package_bin_commands "$bare_name" 2>/dev/null || true)"

            print_blank_line
            print_status_message "ok" "安装成功"
            printf "  包名: %s\n" "$bare_name"
            printf "  版本: %s\n" "$installed_version"
            printf "  日志文件: %s\n" "$log_file"
            if [ -n "$bin_commands" ]; then
                printf "  bin 命令:\n"
                while IFS= read -r cmd; do
                    [ -n "$cmd" ] || continue
                    printf "    - %s\n" "$cmd"
                done <<< "$bin_commands"
            fi
            pause_before_return
            return 0
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$max_retries" ]; then
            break
        fi

        if ! prompt_yes_no "安装失败，是否重试？" "y"; then
            break
        fi
    done

    print_blank_line
    print_status_message "fail" "安装失败: $package_name"
    printf "日志文件: %s\n" "$log_file"
    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: batch install
# ──────────────────────────────────────────────

run_batch_install_flow() {
    local package_name=""
    local total=0
    local installed=0
    local skipped=0
    local succeeded=0
    local failed=0
    local unknown=0
    local already_installed=""
    local -a batch_packages=()
    local -a batch_package_names=()
    local -a batch_target_versions=()
    local -a batch_target_pinned=()
    local -a batch_installed_flags=()

    print_page_title "批量安装内置清单"

    while IFS= read -r package_name; do
        [ -n "$package_name" ] || continue
        batch_packages+=("$package_name")
    done <<< "$(load_batch_package_list)"

    if [ ${#batch_packages[@]} -eq 0 ]; then
        printf "批量安装清单为空，请配置: %s\n" "$GLOBAL_PACKAGES_FILE"
        pause_before_return
        return 0
    fi

    for package_name in "${batch_packages[@]}"; do
        if ! validate_package_spec "$package_name"; then
            print_status_message "fail" "清单包含不支持的包名格式: $package_name"
            printf "请修改: %s\n" "$GLOBAL_PACKAGES_FILE"
            pause_before_return
            return 1
        fi
        batch_package_names+=("$(extract_package_name "$package_name")")
        local target_version=""
        if ! target_version="$(resolve_install_target_version "$package_name")"; then
            print_status_message "fail" "无法解析请求的目标版本: $package_name"
            pause_before_return
            return 1
        fi
        batch_target_versions+=("$target_version")
        if package_spec_is_pinned_version "$package_name"; then
            batch_target_pinned+=("yes")
        else
            batch_target_pinned+=("no")
        fi
    done

    total=${#batch_packages[@]}
    printf "内置清单共 %d 个包:\n" "$total"
    print_separator

    local pkg_index=0
    for package_name in "${batch_packages[@]}"; do
        local bare_package_name="${batch_package_names[$pkg_index]}"
        local target_version="${batch_target_versions[$pkg_index]}"
        local installed_version=""
        installed_version="$(get_installed_global_package_version "$bare_package_name")"
        if is_install_spec_satisfied "$package_name" "$installed_version" "$target_version"; then
            already_installed="yes"
        else
            already_installed="no"
        fi
        batch_installed_flags+=("$already_installed")
        if [ "$already_installed" = "yes" ]; then
            printf "  [已安装] %s -> target %s, installed %s\n" "$package_name" "$target_version" "${installed_version:-<unknown>}"
            installed=$((installed + 1))
        else
            printf "  [待安装] %s -> target %s, installed %s\n" "$package_name" "$target_version" "${installed_version:-<not installed>}"
        fi
        pkg_index=$((pkg_index + 1))
    done

    print_separator
    printf "已安装: %d | 待安装: %d\n" "$installed" $((total - installed))
    print_blank_line

    if [ "$installed" -eq "$total" ]; then
        printf "所有包均已安装，无需操作。\n"
        pause_before_return
        return 0
    fi

    printf "选择要安装的包(多个用空格、逗号或范围分隔，all 全部待安装，b 返回): "
    local batch_choice=""
    read -r batch_choice || return 0
    batch_choice="$(trim_whitespace "$batch_choice")"
    [ -n "$batch_choice" ] || batch_choice="all"

    local batch_parsed=""
    batch_parsed="$(parse_multi_numeric_choice "$batch_choice" "$total")"
    if [ "$batch_parsed" = "back" ]; then
        return 0
    fi
    if [ "$batch_parsed" = "invalid" ]; then
        print_status_message "warn" "输入无效。"
        pause_before_return
        return 0
    fi

    local -a selected_indices=()
    if [ "$batch_parsed" = "all" ]; then
        local pending_indices=""
        pending_indices="$(select_pending_indices_from_flags "${batch_installed_flags[*]}")"
        for token in $pending_indices; do
            selected_indices+=("$token")
        done
    else
        for token in $batch_parsed; do
            selected_indices+=("$token")
        done
    fi

    if ! prompt_yes_no "是否开始批量安装？" "y"; then
        return 0
    fi

    # Set up log file
    local log_file=""
    log_file="$(create_log_file batch-install summary)"

    print_blank_line
    printf "开始批量安装...\n"
    printf "日志文件: %s\n" "$log_file"
    print_separator

    # Log header
    {
        printf "=== 批量安装日志 ===\n"
        printf "时间: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "Node: %s\n" "$(node -v 2>/dev/null || echo 'N/A')"
        printf "npm: %s\n" "$(npm -v 2>/dev/null || echo 'N/A')"
        printf "========================\n\n"
    } >> "$log_file" 2>/dev/null || true

    for selected_index in "${selected_indices[@]}"; do
            package_name="${batch_packages[$((selected_index - 1))]}"
            local bare_package_name="${batch_package_names[$((selected_index - 1))]}"
            local target_version="${batch_target_versions[$((selected_index - 1))]}"
            local target_pinned="${batch_target_pinned[$((selected_index - 1))]}"
            local installed_version=""
            installed_version="$(get_installed_global_package_version "$bare_package_name")"
            if is_install_spec_satisfied "$package_name" "$installed_version" "$target_version"; then
                already_installed="yes"
            else
                already_installed="no"
            fi
            if [ "$already_installed" = "yes" ]; then
                print_status_message "skip" "$package_name 已安装"
                skipped=$((skipped + 1))
                printf "[%s] SKIP 已安装\n" "$package_name" >> "$log_file" 2>/dev/null || true
                continue
            fi

            local package_log_file=""
            package_log_file="$(create_log_file batch-package "$package_name")"
            printf "[%s] LOG %s\n" "$package_name" "$package_log_file" >> "$log_file" 2>/dev/null || true

            local attempt=0
            local installed_ok="no"
            while [ "$attempt" -le "$INSTALL_MAX_RETRIES" ]; do
                if [ "$attempt" -gt 0 ]; then
                    printf "  重试 %s 第 %d 次...\n" "$package_name" "$attempt"
                    printf "[%s] RETRY %d\n" "$package_name" "$attempt" >> "$log_file" 2>/dev/null || true
                else
                    printf "安装 %s ...\n" "$package_name"
                fi

                install_global_package "$package_name" "$package_log_file"
                local install_exit=$?
                printf "[%s] install attempt %d exit %d log %s\n" "$package_name" "$((attempt + 1))" "$install_exit" "$package_log_file" >> "$log_file" 2>/dev/null || true

                if [ "$install_exit" -eq 0 ]; then
                    # Verify installation actually succeeded
                    local new_ver=""
                    local verify_result=""
                    local verify_status=""
                    local verify_message=""
                    local verify_target=""
                    new_ver="$(get_installed_global_package_version "$bare_package_name")"
                    if [ "$target_pinned" = "yes" ]; then
                        verify_result="$(verify_install_result_for_spec "$package_name" "$new_ver" "$target_version" || true)"
                    else
                        verify_result="$(verify_install_result_for_spec "$package_name" "$new_ver" || true)"
                    fi
                    verify_status="$(printf '%s' "$verify_result" | awk -F'|' '{print $1}')"
                    verify_message="$(printf '%s' "$verify_result" | awk -F'|' '{print $2}')"
                    verify_target="$(printf '%s' "$verify_result" | awk -F'|' '{print $3}')"
                    if [ "$verify_status" = "ok" ]; then
                        print_status_message "ok" "$package_name $new_ver"
                        succeeded=$((succeeded + 1))
                        installed_ok="yes"
                        printf "[%s] OK version: %s\n" "$package_name" "${new_ver:-?}" >> "$log_file" 2>/dev/null || true
                        break
                    else
                        print_status_message "warn" "$package_name ${verify_message:-npm 报告成功但验证失败}"
                        if [ -n "$verify_target" ]; then
                            printf "  期望版本: %s\n" "$verify_target"
                            printf "  实际版本: %s\n" "${new_ver:-<unknown>}"
                        fi
                        printf "[%s] WARN npm ok but verification failed\n" "$package_name" >> "$log_file" 2>/dev/null || true
                    fi
                fi

                attempt=$((attempt + 1))
                if [ "$attempt" -le "$INSTALL_MAX_RETRIES" ]; then
                    printf "  %s 安装失败，自动重试...\n" "$package_name"
                fi
            done

            if [ "$installed_ok" = "no" ]; then
                local final_installed_version=""
                final_installed_version="$(get_installed_global_package_version "$bare_package_name")"
                if [ -z "$final_installed_version" ]; then
                    print_status_message "warn" "$package_name 已重试 $INSTALL_MAX_RETRIES 次，无法确认安装结果"
                    unknown=$((unknown + 1))
                    printf "[%s] UNKNOWN after %d retries (no installed version detected)\n" "$package_name" "$INSTALL_MAX_RETRIES" >> "$log_file" 2>/dev/null || true
                else
                    print_status_message "fail" "$package_name 已重试 $INSTALL_MAX_RETRIES 次"
                    failed=$((failed + 1))
                    printf "[%s] FAILED after %d retries (installed=%s, target=%s)\n" "$package_name" "$INSTALL_MAX_RETRIES" "$final_installed_version" "$target_version" >> "$log_file" 2>/dev/null || true
                fi
            fi
    done

    # Log footer
    {
        printf "\n========================\n"
        printf "=== 安装完成 ===\n"
    } >> "$log_file" 2>/dev/null || true

    print_separator
    print_blank_line
    printf "批量安装结果汇总:\n"
    printf "  清单总计: %d\n" "$total"
    printf "  选中: %d\n" "${#selected_indices[@]}"
    printf "  成功: %d\n" "$succeeded"
    printf "  未知版本: %d\n" "$unknown"
    printf "  跳过已安装: %d\n" "$skipped"
    printf "  失败: %d\n" "$failed"

    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: install menu
# ──────────────────────────────────────────────

run_install_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "安装项目"
        render_install_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_install_choice "$choice")"
        case "$action" in
            single-install)
                require_capabilities node npm ruby || continue
                run_single_install_flow
                ;;
            batch-install)
                require_capabilities node npm ruby || continue
                run_batch_install_flow
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
