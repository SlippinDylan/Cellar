# cleanup.sh
# Sourced by main.sh; not meant to be executed directly.

collect_directory_immediate_children() {
    local directory_path="$1"

    if [ -d "$directory_path" ]; then
        find "$directory_path" -mindepth 1 -maxdepth 1 -print 2>/dev/null || true
    fi
}


collect_defined_homebrew_tmp_roots() {
    if [ -n "${HOMEBREW_TEMP:-}" ] && [ -d "${HOMEBREW_TEMP%/}" ]; then
        printf "%s\n" "${HOMEBREW_TEMP%/}"
    fi
}


collect_homebrew_tmp_fallback_roots() {
    local tmpdir_root="${TMPDIR:-}"

    if [ -n "$tmpdir_root" ]; then
        tmpdir_root="${tmpdir_root%/}"
        if [ -d "$tmpdir_root" ]; then
            printf "%s\n" "$tmpdir_root"
        fi
    fi

    if [ -d "/tmp" ] && [ "${tmpdir_root:-}" != "/tmp" ]; then
        printf "%s\n" "/tmp"
    fi
}


collect_homebrew_tmp_fallback_paths() {
    local temp_root=""

    while IFS= read -r temp_root; do
        [ -d "$temp_root" ] || continue
        find "$temp_root" -mindepth 1 -maxdepth 1 \( \
            -iname "brew*" -o \
            -iname "homebrew*" -o \
            -iname "*homebrew*" -o \
            -iname "org.homebrew.*" \
        \) -mtime +1 -print 2>/dev/null || true
    done < <(collect_homebrew_tmp_fallback_roots)
}


cleanup_homebrew_services() {
    brew services cleanup >/dev/null 2>&1
}


append_cleanup_step_status() {
    local array_name="$1"
    local command_label="$2"
    local step_status="$3"

    append_to_array "$array_name" "$command_label|$step_status"
}


run_cleanup_step() {
    local status_array_name="$1"
    shift
    local command_label="$1"
    shift

    if "$@"; then
        append_cleanup_step_status "$status_array_name" "$command_label" "success"
        return 0
    fi

    append_cleanup_step_status "$status_array_name" "$command_label" "failed"
    return 1
}


print_cleanup_step_status_report() {
    local entries=("$@")
    local entry=""
    local command_label=""
    local step_status=""

    print_message "Homebrew 命令执行状态："
    for entry in "${entries[@]+"${entries[@]}"}"; do
        [ -n "$entry" ] || continue
        command_label="${entry%%|*}"
        step_status="${entry#*|}"
        if [ "$step_status" = "success" ]; then
            print_status_message "ok" "$command_label"
        else
            print_status_message "err" "$command_label"
        fi
    done
}


collect_homebrew_tmp_cleanup_paths() {
    local temp_root=""

    if [ -n "${HOMEBREW_TEMP:-}" ] && [ -d "${HOMEBREW_TEMP%/}" ]; then
        while IFS= read -r temp_root; do
            [ -d "$temp_root" ] || continue
            find "$temp_root" -mindepth 1 -maxdepth 1 -mtime +1 -print 2>/dev/null || true
        done < <(collect_defined_homebrew_tmp_roots)
        return 0
    fi

    collect_homebrew_tmp_fallback_paths
}


collect_homebrew_local_cleanup_paths() {
    local homebrew_prefix=""
    local cache_dir=""
    local directory_path=""
    local temp_path=""

    homebrew_prefix="$(brew --prefix 2>/dev/null)" || return 1
    cache_dir="$(brew --cache 2>/dev/null)" || return 1
    [ -n "$homebrew_prefix" ] || return 1
    [ -n "$cache_dir" ] || return 1

    {
        for directory_path in \
            "$cache_dir" \
            "$HOME/.cache/Homebrew" \
            "$HOME/Library/Logs/Homebrew" \
            "${homebrew_prefix:+$homebrew_prefix/var/log}"
        do
            [ -n "$directory_path" ] || continue
            collect_directory_immediate_children "$directory_path"
        done

        while IFS= read -r temp_path; do
            [ -n "$temp_path" ] || continue
            printf "%s\n" "$temp_path"
        done < <(collect_homebrew_tmp_cleanup_paths)
    } | unique_lines
}


print_homebrew_counts() {
    local formulas=()
    local casks=()
    local formula_status=0
    local cask_status=0

    read_command_output_into_array formulas load_formula_inventory
    formula_status="$?"
    read_command_output_into_array casks load_cask_inventory
    cask_status="$?"

    if [ "$formula_status" -eq 0 ]; then
        print_message "已安装 formula 数量：${#formulas[@]}"
    else
        print_message "已安装 formula 数量：<unknown>"
        print_status_message "warn" "未能读取已安装 formula 数量。"
    fi

    if [ "$cask_status" -eq 0 ]; then
        print_message "已安装 cask 数量：${#casks[@]}"
    else
        print_message "已安装 cask 数量：<unknown>"
        print_status_message "warn" "未能读取已安装 cask 数量。"
    fi

    if [ "$formula_status" -ne 0 ] || [ "$cask_status" -ne 0 ]; then
        return 1
    fi

    return 0
}


run_cleanup_flow() {
    local homebrew_prefix=""
    local before_cleanup_kib="0"
    local after_cleanup_kib="0"
    local reclaimed_kib="0"
    local local_cleanup_paths=()
    local local_deleted=()
    local local_elevated=()
    local local_permission_skipped=()
    local local_failed=()
    local local_measurement_note=""
    local cleanup_step_statuses=()
    local cleanup_command_failed="0"

    if ! require_homebrew_for_feature "清理 Homebrew 环境"; then
        return 0
    fi

    homebrew_prefix="$(brew --prefix 2>/dev/null || true)"

    print_page_title "清理 Homebrew 环境"
    print_message "清理计划："
    printf "%s\n" "$(render_cleanup_plan)"
    print_message "附加本地清理："
    print_message "- brew --cache 目录"
    print_message "- ~/.cache/Homebrew"
    print_message "- ~/Library/Logs/Homebrew"
    if [ -n "$homebrew_prefix" ]; then
        print_message "- $homebrew_prefix/var/log"
    else
        print_message "- Homebrew prefix 下的 var/log"
    fi
    if [ -n "${HOMEBREW_TEMP:-}" ]; then
        print_message "- HOMEBREW_TEMP 下超过 1 天的临时文件"
    else
        print_message "- 未配置 HOMEBREW_TEMP 时，回退清理 TMPDIR 与 /tmp 下超过 1 天的 Homebrew 临时项"
    fi

    if ! prompt_yes_no "是否立即执行清理？" "n"; then
        print_message "已取消清理。"
        return 0
    fi

    if ! read_command_output_into_array local_cleanup_paths collect_homebrew_local_cleanup_paths; then
        print_status_message "err" "未能收集本地 Homebrew 清理路径，已取消清理。"
        print_message "请检查 brew --cache、brew --prefix 与本地目录访问是否正常。"
        return 0
    fi
    print_status_message "info" "正在统计清理前磁盘占用..."
    before_cleanup_kib="$(measure_cleanup_paths_footprint_kib "${local_cleanup_paths[@]+"${local_cleanup_paths[@]}"}")"
    print_output_boundary "开始执行 Homebrew 清理"
    if ! run_cleanup_step cleanup_step_statuses "brew cleanup --prune=all" brew cleanup --prune=all; then
        cleanup_command_failed="1"
    fi
    if ! run_cleanup_step cleanup_step_statuses "brew cleanup" brew cleanup; then
        cleanup_command_failed="1"
    fi
    if ! run_cleanup_step cleanup_step_statuses "brew autoremove" brew autoremove; then
        cleanup_command_failed="1"
    fi
    if ! run_cleanup_step cleanup_step_statuses "brew services cleanup" cleanup_homebrew_services; then
        cleanup_command_failed="1"
    fi
    delete_paths_with_optional_elevation "检测到权限问题，是否使用 sudo 继续清理这些 Homebrew 本地路径？" "${local_cleanup_paths[@]+"${local_cleanup_paths[@]}"}"
    local_deleted=("${DELETE_REPORT_DELETED[@]+"${DELETE_REPORT_DELETED[@]}"}")
    local_elevated=("${DELETE_REPORT_ELEVATED[@]+"${DELETE_REPORT_ELEVATED[@]}"}")
    local_permission_skipped=("${DELETE_REPORT_PERMISSION_SKIPPED[@]+"${DELETE_REPORT_PERMISSION_SKIPPED[@]}"}")
    local_failed=("${DELETE_REPORT_FAILED[@]+"${DELETE_REPORT_FAILED[@]}"}")
    print_output_boundary "Homebrew 清理执行结束"
    print_status_message "info" "正在统计清理后磁盘占用..."
    after_cleanup_kib="$(measure_cleanup_paths_footprint_kib "${local_cleanup_paths[@]+"${local_cleanup_paths[@]}"}")"
    reclaimed_kib="$(calculate_reclaimed_kib "$before_cleanup_kib" "$after_cleanup_kib")"
    local_measurement_note="统计范围仅覆盖本地缓存、日志与临时目录候选路径；Homebrew cleanup/autoremove 在其他位置释放的空间未计入下方统计。"

    print_page_title "清理总结"
    print_message "纳入本地路径统计的清理前空间：$(format_kib_human_readable "$before_cleanup_kib")"
    print_message "纳入本地路径统计的清理后空间：$(format_kib_human_readable "$after_cleanup_kib")"
    print_message "本地路径统计释放空间：$(format_kib_human_readable "$reclaimed_kib")"
    print_message "$local_measurement_note"
    print_cleanup_step_status_report "${cleanup_step_statuses[@]+"${cleanup_step_statuses[@]}"}"
    if [ "$cleanup_command_failed" = "1" ]; then
        print_status_message "warn" "有 Homebrew 清理命令执行失败，请结合上面的命令状态与终端输出检查。"
    fi
    print_message "附加本地普通删除成功路径数：${#local_deleted[@]}"
    print_message "附加本地提权删除成功路径数：${#local_elevated[@]}"
    print_message "附加本地因权限跳过路径数：${#local_permission_skipped[@]}"
    print_message "附加本地其他失败路径数：${#local_failed[@]}"
    print_path_report_if_any "附加本地提权删除路径：" "${local_elevated[@]+"${local_elevated[@]}"}"
    print_path_report_if_any "附加本地因权限跳过的路径：" "${local_permission_skipped[@]+"${local_permission_skipped[@]}"}"
    print_path_report_if_any "附加本地删除失败的路径：" "${local_failed[@]+"${local_failed[@]}"}"
    print_homebrew_counts
}

