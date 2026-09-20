# uninstall_formula.sh
# Sourced by main.sh; not meant to be executed directly.

brew_dependencies_for_formula() {
    local formula="$1"
    brew deps --installed "$formula" 2>/dev/null
}


brew_installed_users_for_formula() {
    local dependency="$1"
    brew uses --installed "$dependency" 2>/dev/null
}


exclude_formula_users_from_removal_set() {
    local users_text="$1"
    shift
    local removal_set=("$@")
    local user=""
    local kept_users=()

    while IFS= read -r user; do
        [ -n "$user" ] || continue
        if array_contains_exact "$user" "${removal_set[@]+"${removal_set[@]}"}"; then
            continue
        fi
        kept_users+=("$user")
    done <<< "$users_text"

    printf "%s\n" "${kept_users[@]+"${kept_users[@]}"}"
}


reset_formula_plan_state() {
    FORMULA_PLAN_TARGET=""
    FORMULA_PLAN_DEPENDENCIES=()
    FORMULA_PLAN_ORPHANS=()
}


serialize_formula_plan_state() {
    printf "target=%s\n" "$FORMULA_PLAN_TARGET"
    printf "dependencies=%s\n" "$(printf "%s\n" "${FORMULA_PLAN_DEPENDENCIES[@]+"${FORMULA_PLAN_DEPENDENCIES[@]}"}" | join_lines)"
    printf "orphans=%s" "$(printf "%s\n" "${FORMULA_PLAN_ORPHANS[@]+"${FORMULA_PLAN_ORPHANS[@]}"}" | join_lines)"
}


load_formula_uninstall_plan() {
    local formula="$1"
    local direct_dependency=""
    local dependencies=()
    local orphan_candidates=()
    local pending_dependencies=()
    local seen_dependencies=()
    local removal_set=()
    local dependency=""
    local dependency_users=""
    local remaining_users=""
    local dependency_users_array=()
    local child_dependencies=()
    local index=0
    local child_dependency=""

    reset_formula_plan_state
    removal_set=("$formula")

    if ! read_command_output_into_array dependencies brew_dependencies_for_formula "$formula"; then
        return 1
    fi

    for direct_dependency in "${dependencies[@]+"${dependencies[@]}"}"; do
        [ -n "$direct_dependency" ] || continue
        pending_dependencies+=("$direct_dependency")
    done

    while [ "$index" -lt "${#pending_dependencies[@]}" ]; do
        dependency="${pending_dependencies[$index]}"
        index=$((index + 1))

        if array_contains_exact "$dependency" "${seen_dependencies[@]+"${seen_dependencies[@]}"}"; then
            continue
        fi
        seen_dependencies+=("$dependency")

        if ! read_command_output_into_array dependency_users_array brew_installed_users_for_formula "$dependency"; then
            return 1
        fi

        dependency_users="$(printf "%s\n" "${dependency_users_array[@]+"${dependency_users_array[@]}"}")"
        remaining_users="$(exclude_formula_users_from_removal_set "$dependency_users" "${removal_set[@]+"${removal_set[@]}"}")"

        if [ -n "$remaining_users" ]; then
            continue
        fi

        orphan_candidates+=("$dependency")
        removal_set+=("$dependency")
        if ! read_command_output_into_array child_dependencies brew_dependencies_for_formula "$dependency"; then
            return 1
        fi

        for child_dependency in "${child_dependencies[@]+"${child_dependencies[@]}"}"; do
            [ -n "$child_dependency" ] || continue
            if array_contains_exact "$child_dependency" "${seen_dependencies[@]+"${seen_dependencies[@]}"}"; then
                continue
            fi
            pending_dependencies+=("$child_dependency")
        done
    done

    FORMULA_PLAN_TARGET="$formula"
    FORMULA_PLAN_DEPENDENCIES=("${dependencies[@]+"${dependencies[@]}"}")
    FORMULA_PLAN_ORPHANS=("${orphan_candidates[@]+"${orphan_candidates[@]}"}")
}


collect_formula_uninstall_plan() {
    if ! load_formula_uninstall_plan "$1"; then
        return 1
    fi

    serialize_formula_plan_state
}


stop_formula_service_if_needed() {
    local formula="$1"
    brew services stop "$formula" >/dev/null 2>&1 || true
}


collect_formula_managed_paths() {
    local formula="$1"
    local formula_prefix=""
    local formula_cellar=""
    local homebrew_prefix=""

    formula_prefix="$(brew --prefix "$formula" 2>/dev/null)" || return 1
    formula_cellar="$(brew --cellar "$formula" 2>/dev/null)" || return 1
    homebrew_prefix="$(brew --prefix 2>/dev/null)" || return 1

    {
        [ -n "$formula_prefix" ] && [ -e "$formula_prefix" ] && printf "%s\n" "$formula_prefix"
        [ -n "$formula_cellar" ] && [ -e "$formula_cellar" ] && printf "%s\n" "$formula_cellar"
        if [ -n "$homebrew_prefix" ] && [ -e "$homebrew_prefix/etc/$formula" ]; then
            printf "%s\n" "$homebrew_prefix/etc/$formula"
        fi
        if [ -n "$homebrew_prefix" ] && [ -e "$homebrew_prefix/var/$formula" ]; then
            printf "%s\n" "$homebrew_prefix/var/$formula"
        fi
    } | unique_lines
}


print_formula_plan() {
    local formula="${1:-$FORMULA_PLAN_TARGET}"
    local title="${2:-Formula 卸载扫描结果}"
    local managed_paths=()
    local managed_paths_status=0

    read_command_output_into_array managed_paths collect_formula_managed_paths "$formula"
    managed_paths_status="$?"

    print_page_title "$title"
    print_message "目标：$formula"
    print_compact_value_list "直接依赖：" "${FORMULA_PLAN_DEPENDENCIES[@]+"${FORMULA_PLAN_DEPENDENCIES[@]}"}"
    print_compact_value_list "可一并移除的孤儿依赖：" "${FORMULA_PLAN_ORPHANS[@]+"${FORMULA_PLAN_ORPHANS[@]}"}"

    if [ "$managed_paths_status" -ne 0 ]; then
        print_message "相关 Homebrew 管理路径：<scan-failed>"
        print_status_message "warn" "未能扫描这个 formula 的 Homebrew 管理路径。"
    elif [ "${#managed_paths[@]}" -gt 0 ]; then
        print_message "相关 Homebrew 管理路径："
        printf "%s\n" "${managed_paths[@]+"${managed_paths[@]}"}"
    else
        print_message "相关 Homebrew 管理路径：<none>"
    fi
}


run_formula_uninstall_flow() {
    local formula="$1"
    local orphan=""
    local removed=()
    local skipped=()
    local main_uninstall_succeeded="0"

    stop_formula_service_if_needed "$formula"

    if brew uninstall "$formula"; then
        removed+=("$formula")
        main_uninstall_succeeded="1"
    else
        skipped+=("$formula")
    fi

    if [ "$main_uninstall_succeeded" != "1" ]; then
        print_page_title "Formula 卸载总结"
        print_message "已移除：${removed[*]:-<none>}"
        print_message "已跳过：${skipped[*]:-<none>}"
        print_message "主 formula 卸载失败，未继续移除孤儿依赖，也未执行 brew autoremove。"
        return 1
    fi

    for orphan in "${FORMULA_PLAN_ORPHANS[@]+"${FORMULA_PLAN_ORPHANS[@]}"}"; do
        if brew list --formula "$orphan" >/dev/null 2>&1; then
            if brew uninstall "$orphan"; then
                removed+=("$orphan")
            else
                skipped+=("$orphan")
            fi
        fi
    done

    brew autoremove >/dev/null 2>&1 || true

    print_page_title "Formula 卸载总结"
    print_message "已移除：${removed[*]:-<none>}"
    print_message "已跳过：${skipped[*]:-<none>}"

    if brew list --formula "$formula" >/dev/null 2>&1; then
        return 1
    fi

    return 0
}


run_formula_uninstall_batch() {
    local formulas=("$@")
    local total="${#formulas[@]}"
    local index=0
    local formula=""
    local removed_targets=()
    local skipped_targets=()

    for formula in "${formulas[@]+"${formulas[@]}"}"; do
        [ -n "$formula" ] || continue
        index=$((index + 1))

        if ! brew list --formula "$formula" >/dev/null 2>&1; then
            print_page_title "Formula 卸载扫描结果 $index/$total"
            print_status_message "skip" "formula 未安装，跳过：$formula"
            skipped_targets+=("$formula")
            continue
        fi

        if ! load_formula_uninstall_plan "$formula"; then
            print_page_title "Formula 卸载扫描结果 $index/$total"
            print_status_message "err" "未能生成 formula 卸载计划，已跳过：$formula"
            print_message "请检查 brew deps / brew uses 是否能正常返回该项目的依赖关系。"
            skipped_targets+=("$formula")
            continue
        fi
        print_formula_plan "$formula" "Formula 卸载扫描结果 $index/$total"

        if ! prompt_yes_no "是否继续卸载这个 formula，并按上面扫描结果移除可清理的孤儿依赖？" "n"; then
            print_status_message "skip" "已跳过当前 formula：$formula"
            skipped_targets+=("$formula")
            continue
        fi

        if run_formula_uninstall_flow "$formula"; then
            removed_targets+=("$formula")
        else
            skipped_targets+=("$formula")
        fi
    done

    print_page_title "Formula 批量卸载总结"
    print_message "选择目标数量：$total"
    print_message "成功卸载目标数量：${#removed_targets[@]}"
    print_message "跳过或失败目标数量：${#skipped_targets[@]}"
    print_compact_value_list "已卸载目标：" "${removed_targets[@]+"${removed_targets[@]}"}"
    print_compact_value_list "未完成目标：" "${skipped_targets[@]+"${skipped_targets[@]}"}"
}


run_formula_selection_menu() {
    local formulas=()
    local selected_formulas=()
    local parsed_choice=""

    while true; do
        if ! read_command_output_into_array formulas load_formula_inventory; then
            print_command_query_failure "已安装 formula 列表" "brew list --formula"
            pause_before_return
            return 0
        fi
        if [ "${#formulas[@]}" -eq 0 ]; then
            print_message "当前没有已安装的 formula 项目。"
            pause_before_return
            return 0
        fi

        prompt_for_multi_selection "当前已安装的 formula 列表" "请输入选择（all / 序号 / b）: " "${formulas[@]+"${formulas[@]}"}"
        parsed_choice="$PROMPT_MULTI_SELECT_RESULT"
        if [ "$parsed_choice" = "back" ]; then
            return 0
        fi

        populate_array_from_selection selected_formulas "$parsed_choice" "${formulas[@]+"${formulas[@]}"}"
        print_page_title "Formula 批量卸载确认"
        print_compact_value_list "已选择的 formula：" "${selected_formulas[@]+"${selected_formulas[@]}"}"

        if prompt_yes_no "是否继续卸载这些 formula，并按当前依赖关系逐个处理？" "n"; then
            run_formula_uninstall_batch "${selected_formulas[@]+"${selected_formulas[@]}"}"
        else
            print_message "已取消 Formula 批量卸载。"
        fi

        pause_before_return
    done
}

