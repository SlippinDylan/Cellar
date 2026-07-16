# uninstall_cask_flow.sh
# Sourced by main.sh; not meant to be executed directly.

run_cask_uninstall_flow() {
    local cask="$1"
    local app_name="$2"
    local app_path="$3"
    local scanned_total_kib="${4:-0}"
    local scanned_count="${5:-0}"
    local candidates=("${@:6}")
    local candidate=""
    local removed=()
    local elevated_removed=()
    local permission_skipped=()
    local skipped=()
    local uninstall_status="not-run"
    local homebrew_prefix=""
    local caskroom_entry=""
    local deletion_targets=()
    local postcheck_residual_paths=()
    local postcheck_manual_items=()
    local postcheck_cleared_items=()
    local postcheck_delegated_items=()

    reset_cask_uninstall_last_report_state
    brew services stop "$cask" >/dev/null 2>&1 || true

    if brew uninstall --zap "$cask"; then
        uninstall_status="success"
    elif brew uninstall --zap --force "$cask" >/dev/null 2>&1; then
        uninstall_status="forced"
    else
        uninstall_status="failed"
    fi

    if [ "$uninstall_status" = "failed" ]; then
        print_page_title "Cask 卸载总结"
        print_message "目标：$cask"
        print_message "应用名：${app_name:-<unknown>}"
        print_message "Homebrew 卸载状态：$uninstall_status"
        print_message "脚本补充清理候选项数量：$scanned_count"
        print_message "本次卸载预计释放空间：$(format_kib_human_readable "$scanned_total_kib")"
        print_message "Homebrew 卸载失败，未继续删除扫描到的残留路径。"
        return 1
    fi

    homebrew_prefix="$(brew --prefix 2>/dev/null || true)"
    collect_cask_post_uninstall_artifact_state "$homebrew_prefix" "$app_path"
    postcheck_residual_paths=("${CASK_POSTCHECK_RESIDUAL_DELETE_PATHS[@]+"${CASK_POSTCHECK_RESIDUAL_DELETE_PATHS[@]}"}")
    postcheck_manual_items=("${CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS[@]+"${CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS[@]}"}")
    postcheck_cleared_items=("${CASK_POSTCHECK_CLEARED_ITEMS[@]+"${CASK_POSTCHECK_CLEARED_ITEMS[@]}"}")
    postcheck_delegated_items=("${CASK_POSTCHECK_DELEGATED_ITEMS[@]+"${CASK_POSTCHECK_DELEGATED_ITEMS[@]}"}")

    for candidate in "${candidates[@]+"${candidates[@]}"}"; do
        [ -n "$candidate" ] || continue
        append_unique_to_array deletion_targets "$candidate"
    done

    for candidate in "${postcheck_residual_paths[@]+"${postcheck_residual_paths[@]}"}"; do
        [ -n "$candidate" ] || continue
        append_unique_to_array deletion_targets "$candidate"
    done

    if [ -n "$homebrew_prefix" ]; then
        caskroom_entry="$homebrew_prefix/Caskroom/$cask"
        if [ -e "$caskroom_entry" ]; then
            append_unique_to_array deletion_targets "$caskroom_entry"
        fi
    fi

    delete_paths_with_optional_elevation "检测到权限问题，是否使用 sudo 删除这些 cask 残留路径？" "${deletion_targets[@]+"${deletion_targets[@]}"}"
    removed=("${DELETE_REPORT_DELETED[@]+"${DELETE_REPORT_DELETED[@]}"}")
    elevated_removed=("${DELETE_REPORT_ELEVATED[@]+"${DELETE_REPORT_ELEVATED[@]}"}")
    permission_skipped=("${DELETE_REPORT_PERMISSION_SKIPPED[@]+"${DELETE_REPORT_PERMISSION_SKIPPED[@]}"}")
    skipped=("${DELETE_REPORT_FAILED[@]+"${DELETE_REPORT_FAILED[@]}"}")

    print_page_title "Cask 卸载总结"
    print_message "目标：$cask"
    print_message "应用名：${app_name:-<unknown>}"
    print_message "Homebrew 卸载状态：$uninstall_status"
    print_message "脚本补充清理候选项数量：$scanned_count"
    print_message "本次卸载预计释放空间：$(format_kib_human_readable "$scanned_total_kib")"
    print_message "Homebrew 管理 artifact 已验证清除数量：${#postcheck_cleared_items[@]}"
    print_message "Homebrew 管理 artifact 仍需人工处理数量：${#postcheck_manual_items[@]}"
    print_message "Homebrew 委托执行卸载脚本数量：${#postcheck_delegated_items[@]}"
    print_message "普通删除成功路径数：${#removed[@]}"
    print_message "提权删除成功路径数：${#elevated_removed[@]}"
    print_message "因权限跳过路径数：${#permission_skipped[@]}"
    print_message "其他失败路径数：${#skipped[@]}"
    print_item_report_if_any "已由 Homebrew 清除的 managed artifact：" "${postcheck_cleared_items[@]+"${postcheck_cleared_items[@]}"}"
    print_item_report_if_any "仍需人工处理的 Homebrew 管理 artifact：" "${postcheck_manual_items[@]+"${postcheck_manual_items[@]}"}"
    print_item_report_if_any "已委托 Homebrew 执行的卸载脚本：" "${postcheck_delegated_items[@]+"${postcheck_delegated_items[@]}"}"
    print_path_report_if_any "普通删除路径：" "${removed[@]+"${removed[@]}"}"
    print_path_report_if_any "提权删除路径：" "${elevated_removed[@]+"${elevated_removed[@]}"}"
    print_path_report_if_any "因权限跳过的路径：" "${permission_skipped[@]+"${permission_skipped[@]}"}"
    print_path_report_if_any "删除失败的路径：" "${skipped[@]+"${skipped[@]}"}"

    CASK_UNINSTALL_LAST_CLEARED_ARTIFACTS=("${postcheck_cleared_items[@]+"${postcheck_cleared_items[@]}"}")
    CASK_UNINSTALL_LAST_DELETED_PATHS=("${removed[@]+"${removed[@]}"}")
    CASK_UNINSTALL_LAST_ELEVATED_DELETED_PATHS=("${elevated_removed[@]+"${elevated_removed[@]}"}")
    CASK_UNINSTALL_LAST_PERMISSION_SKIPPED_PATHS=("${permission_skipped[@]+"${permission_skipped[@]}"}")
    CASK_UNINSTALL_LAST_FAILED_PATHS=("${skipped[@]+"${skipped[@]}"}")
    CASK_UNINSTALL_LAST_MANUAL_ATTENTION_ITEMS=("${postcheck_manual_items[@]+"${postcheck_manual_items[@]}"}")
    CASK_UNINSTALL_LAST_DELEGATED_ITEMS=("${postcheck_delegated_items[@]+"${postcheck_delegated_items[@]}"}")

    if brew list --cask "$cask" >/dev/null 2>&1; then
        return 1
    fi

    return 0
}


print_candidate_list() {
    local title="$1"
    local size_label="预计释放空间"
    shift
    if [ "$#" -gt 0 ]; then
        size_label="$1"
        shift
    fi
    local items=("$@")
    local summary=""
    local count="0"
    local total_kib="0"
    local unreadable="0"

    print_blank_line
    print_message "$title"
    if [ "${#items[@]}" -eq 0 ]; then
        print_message "<none>"
        return 0
    fi

    summary="$(collect_disk_usage_summary "${items[@]+"${items[@]}"}")"
    count="$(extract_key_value "$summary" "count")"
    total_kib="$(extract_key_value "$summary" "total_kib")"
    unreadable="$(extract_key_value "$summary" "unreadable")"
    print_message "候选项数量：$count"
    print_message "${size_label}：$(format_kib_human_readable "$total_kib")"
    if [ "${unreadable:-0}" -gt 0 ]; then
        print_message "有 $unreadable 个路径无法统计大小，未计入总空间。"
    fi

    printf "%s\n" "${items[@]+"${items[@]}"}"
}


print_cask_managed_artifact_list() {
    local title="$1"
    shift
    local items=("$@")

    print_blank_line
    print_message "$title"
    if [ "${#items[@]}" -eq 0 ]; then
        print_message "<none>"
        return 0
    fi

    print_message "artifact 数量：${#items[@]}"
    printf "%s\n" "${items[@]+"${items[@]}"}"
}


run_cask_uninstall_batch() {
    local casks=("$@")
    local total="${#casks[@]}"
    local index=0
    local cask=""
    local metadata_json=""
    local app_name=""
    local app_path=""
    local bundle_id=""
    local candidates=()
    local candidate_summary=""
    local candidate_count="0"
    local total_preview_paths=()
    local total_preview_summary=""
    local total_preview_kib="0"
    local removed_targets=()
    local skipped_targets=()
    local metadata_mode="full"
    local receipt_paths=()
    local receipt_path=""
    local metadata_status=0
    local scan_title=""
    local homebrew_prefix=""
    local managed_artifact_labels=()
    local managed_paths=()
    local local_cleanup_candidates=()
    local receipt_status=0
    local structured_mode="full"
    local candidate=""
    local aggregated_cleared_artifacts=()
    local aggregated_deleted_paths=()
    local aggregated_elevated_deleted_paths=()
    local aggregated_permission_skipped_paths=()
    local aggregated_failed_paths=()
    local aggregated_manual_attention_items=()
    local aggregated_delegated_items=()

    removed_targets=()
    skipped_targets=()
    index=0
    homebrew_prefix="$(brew --prefix 2>/dev/null || true)"

    for cask in "${casks[@]+"${casks[@]}"}"; do
        [ -n "$cask" ] || continue
        index=$((index + 1))

        reset_cask_receipt_artifact_state
        reset_cask_postcheck_state
        reset_cask_uninstall_last_report_state
        metadata_json=""
        metadata_status=0
        app_name=""
        app_path=""
        bundle_id=""
        candidates=()
        local_cleanup_candidates=()
        candidate_summary=""
        candidate_count="0"
        total_preview_paths=()
        total_preview_summary=""
        total_preview_kib="0"
        metadata_mode="full"
        receipt_paths=()
        receipt_path=""
        scan_title="Cask 卸载扫描结果 $index/$total"
        managed_artifact_labels=()
        managed_paths=()
        receipt_status=0
        structured_mode="full"

        print_page_title "$scan_title"

        if metadata_json="$(fetch_cask_metadata_json "$cask")"; then
            if load_cask_metadata_from_json "$metadata_json"; then
                app_name="$CASK_METADATA_APP_NAME"
            else
                rm -f "$metadata_json"
                metadata_json=""
                metadata_mode="fallback"
            fi
        else
            metadata_status="$?"
            metadata_mode="fallback"
        fi

        if ! read_command_output_into_array receipt_paths find_cask_install_receipts "$cask"; then
            receipt_status=1
        fi
        receipt_path="${receipt_paths[0]:-}"

        if [ -n "$receipt_path" ] && ! load_cask_receipt_artifacts "$receipt_path"; then
            receipt_status=2
        elif [ -z "$receipt_path" ]; then
            receipt_status=3
        fi

        if [ "$metadata_mode" = "fallback" ]; then
            if [ "$metadata_status" -eq 2 ]; then
                print_status_message "warn" "未能创建 cask 元数据临时文件，将降级为 Homebrew 卸载 + 本地残留探测。"
            else
                print_status_message "warn" "未能加载完整 cask 元数据，将降级为 Homebrew 卸载 + 本地残留探测。"
            fi
            if [ "$receipt_status" -eq 1 ]; then
                print_status_message "err" "未能读取这个 cask 的安装记录，已跳过：$cask"
                print_message "当前已进入降级模式，且 receipt 发现失败，无法可靠生成本地残留清理候选项。"
                skipped_targets+=("$cask")
                [ -n "$metadata_json" ] && rm -f "$metadata_json"
                continue
            fi
            if [ -n "$receipt_path" ]; then
                app_name="$(load_cask_app_name_from_receipt "$receipt_path" 2>/dev/null || true)"
            else
                print_status_message "warn" "未找到这个 cask 的安装记录，将继续以有限信息探测本地残留。"
            fi
        fi

        if [ -z "$app_name" ] && [ -n "$receipt_path" ] && [ "$receipt_status" -eq 0 ]; then
            app_name="$(load_cask_app_name_from_receipt "$receipt_path" 2>/dev/null || true)"
        fi

        if [ "$receipt_status" -eq 1 ]; then
            structured_mode="degraded"
            print_status_message "warn" "未能读取这个 cask 的安装记录，Homebrew 管理 artifact 将无法完整校验。"
        elif [ "$receipt_status" -eq 2 ]; then
            structured_mode="degraded"
            print_status_message "warn" "已找到这个 cask 的安装记录，但未能完整解析其中的 uninstall artifact。"
        elif [ "$receipt_status" -eq 3 ]; then
            structured_mode="degraded"
            print_status_message "warn" "未找到这个 cask 的安装记录，Homebrew 管理 artifact 将无法完整校验。"
        fi

        app_path="$(find_app_bundle_path "$app_name" 2>/dev/null || true)"
        bundle_id="$(get_bundle_identifier_for_app_path "$app_path" 2>/dev/null || true)"
        if ! read_command_output_into_array local_cleanup_candidates collect_cask_cleanup_candidates "$app_name" "$bundle_id" "$metadata_json"; then
            print_status_message "err" "未能扫描这个 cask 的清理候选项，已跳过：$cask"
            print_message "请检查本地路径探测与 cask 元数据读取是否正常。"
            skipped_targets+=("$cask")
            [ -n "$metadata_json" ] && rm -f "$metadata_json"
            continue
        fi

        if [ "$receipt_status" -eq 0 ]; then
            read_command_output_into_array managed_paths build_cask_managed_path_candidates "$homebrew_prefix" "$app_path"
            read_command_output_into_array managed_artifact_labels build_cask_homebrew_managed_artifact_labels "$homebrew_prefix" "$app_path" "$app_name"
        else
            reset_named_array managed_paths
            reset_named_array managed_artifact_labels
        fi

        candidates=()
        for candidate in "${local_cleanup_candidates[@]+"${local_cleanup_candidates[@]}"}"; do
            [ -n "$candidate" ] || continue
            if [ "${#managed_paths[@]}" -gt 0 ] && array_contains_exact "$candidate" "${managed_paths[@]+"${managed_paths[@]}"}"; then
                continue
            fi
            append_unique_to_array candidates "$candidate"
        done

        if read_command_output_into_array total_preview_paths build_cask_release_size_preview_paths "$homebrew_prefix" "$cask" "$app_path" "${local_cleanup_candidates[@]+"${local_cleanup_candidates[@]}"}"; then
            total_preview_summary="$(collect_disk_usage_summary "${total_preview_paths[@]+"${total_preview_paths[@]}"}")"
            total_preview_kib="$(extract_key_value "$total_preview_summary" "total_kib")"
        else
            total_preview_kib="0"
        fi

        candidate_summary="$(collect_disk_usage_summary "${candidates[@]+"${candidates[@]}"}")"
        candidate_count="$(extract_key_value "$candidate_summary" "count")"

        print_message "目标：$cask"
        print_message "应用名：${app_name:-<unknown>}"
        print_message "Bundle Identifier：${bundle_id:-<unknown>}"
        print_message "本次卸载预计释放空间：$(format_kib_human_readable "$total_preview_kib")"
        if [ "$metadata_mode" = "fallback" ]; then
            print_message "元数据模式：降级模式（未使用 brew info 的完整 cask 元数据）"
        fi
        if [ "$structured_mode" = "degraded" ]; then
            print_message "artifact 校验模式：降级模式（无法完整依赖 INSTALL_RECEIPT.json 校验 Homebrew 管理 artifact）"
        fi
        print_cask_managed_artifact_list "Homebrew 管理 artifact" "${managed_artifact_labels[@]+"${managed_artifact_labels[@]}"}"
        print_candidate_list "脚本补充清理候选项" "脚本补充清理预计释放空间" "${candidates[@]+"${candidates[@]}"}"

        if ! prompt_yes_no "是否继续卸载这个 cask，并删除上面列出的候选项？" "n"; then
            print_status_message "skip" "已跳过当前 cask：$cask"
            skipped_targets+=("$cask")
            [ -n "$metadata_json" ] && rm -f "$metadata_json"
            continue
        fi

        if run_cask_uninstall_flow "$cask" "$app_name" "$app_path" "$total_preview_kib" "$candidate_count" "${candidates[@]+"${candidates[@]}"}"; then
            removed_targets+=("$cask")
        else
            skipped_targets+=("$cask")
        fi
        append_prefixed_items_to_array aggregated_cleared_artifacts "$cask" "${CASK_UNINSTALL_LAST_CLEARED_ARTIFACTS[@]+"${CASK_UNINSTALL_LAST_CLEARED_ARTIFACTS[@]}"}"
        append_prefixed_items_to_array aggregated_deleted_paths "$cask" "${CASK_UNINSTALL_LAST_DELETED_PATHS[@]+"${CASK_UNINSTALL_LAST_DELETED_PATHS[@]}"}"
        append_prefixed_items_to_array aggregated_elevated_deleted_paths "$cask" "${CASK_UNINSTALL_LAST_ELEVATED_DELETED_PATHS[@]+"${CASK_UNINSTALL_LAST_ELEVATED_DELETED_PATHS[@]}"}"
        append_prefixed_items_to_array aggregated_permission_skipped_paths "$cask" "${CASK_UNINSTALL_LAST_PERMISSION_SKIPPED_PATHS[@]+"${CASK_UNINSTALL_LAST_PERMISSION_SKIPPED_PATHS[@]}"}"
        append_prefixed_items_to_array aggregated_failed_paths "$cask" "${CASK_UNINSTALL_LAST_FAILED_PATHS[@]+"${CASK_UNINSTALL_LAST_FAILED_PATHS[@]}"}"
        append_prefixed_items_to_array aggregated_manual_attention_items "$cask" "${CASK_UNINSTALL_LAST_MANUAL_ATTENTION_ITEMS[@]+"${CASK_UNINSTALL_LAST_MANUAL_ATTENTION_ITEMS[@]}"}"
        append_prefixed_items_to_array aggregated_delegated_items "$cask" "${CASK_UNINSTALL_LAST_DELEGATED_ITEMS[@]+"${CASK_UNINSTALL_LAST_DELEGATED_ITEMS[@]}"}"

        [ -n "$metadata_json" ] && rm -f "$metadata_json"
    done

    print_page_title "Cask 批量卸载总结"
    print_message "选择目标数量：$total"
    print_message "成功卸载目标数量：${#removed_targets[@]}"
    print_message "跳过或失败目标数量：${#skipped_targets[@]}"
    print_compact_value_list "已卸载目标：" "${removed_targets[@]+"${removed_targets[@]}"}"
    print_compact_value_list "未完成目标：" "${skipped_targets[@]+"${skipped_targets[@]}"}"
    print_item_report_if_any "已由 Homebrew 清除的 managed artifact：" "${aggregated_cleared_artifacts[@]+"${aggregated_cleared_artifacts[@]}"}"
    print_item_report_if_any "仍需人工处理的 Homebrew 管理 artifact：" "${aggregated_manual_attention_items[@]+"${aggregated_manual_attention_items[@]}"}"
    print_item_report_if_any "已委托 Homebrew 执行的卸载脚本：" "${aggregated_delegated_items[@]+"${aggregated_delegated_items[@]}"}"
    print_path_report_if_any "普通删除路径：" "${aggregated_deleted_paths[@]+"${aggregated_deleted_paths[@]}"}"
    print_path_report_if_any "提权删除路径：" "${aggregated_elevated_deleted_paths[@]+"${aggregated_elevated_deleted_paths[@]}"}"
    print_path_report_if_any "因权限跳过的路径：" "${aggregated_permission_skipped_paths[@]+"${aggregated_permission_skipped_paths[@]}"}"
    print_path_report_if_any "删除失败的路径：" "${aggregated_failed_paths[@]+"${aggregated_failed_paths[@]}"}"
}


run_cask_selection_menu() {
    local casks=()
    local selected_casks=()
    local parsed_choice=""

    while true; do
        if ! read_command_output_into_array casks load_cask_inventory; then
            print_command_query_failure "已安装 cask 列表" "brew list --cask"
            pause_before_return
            return 0
        fi
        if [ "${#casks[@]}" -eq 0 ]; then
            print_message "当前没有已安装的 cask 项目。"
            pause_before_return
            return 0
        fi

        prompt_for_multi_selection "当前已安装的 cask 列表" "请输入选择（all / 序号 / b）: " "${casks[@]+"${casks[@]}"}"
        parsed_choice="$PROMPT_MULTI_SELECT_RESULT"
        if [ "$parsed_choice" = "back" ]; then
            return 0
        fi

        populate_array_from_selection selected_casks "$parsed_choice" "${casks[@]+"${casks[@]}"}"
        print_page_title "Cask 批量卸载确认"
        print_compact_value_list "已选择的 cask：" "${selected_casks[@]+"${selected_casks[@]}"}"

        if prompt_yes_no "是否继续卸载这些 cask，并删除各自扫描到的全部候选项？" "n"; then
            run_cask_uninstall_batch "${selected_casks[@]+"${selected_casks[@]}"}"
        else
            print_message "已取消 Cask 批量卸载。"
        fi

        pause_before_return
    done
}

