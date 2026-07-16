# update.sh
# Sourced by main.sh; not meant to be executed directly.

run_update_menu() {
    local choice=""
    local action=""

    if ! require_homebrew_for_feature "更新与升级"; then
        return 0
    fi

    while true; do
        print_page_title "更新与升级"
        printf "%s\n" "$(render_update_menu)"
        printf "请输入序号（b 返回）: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_update_choice "$choice")"
        case "$action" in
            update-homebrew)
                run_update_homebrew_flow
                pause_before_return
                ;;
            update-projects)
                run_update_projects_flow
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


run_update_homebrew_flow() {
    local update_status="failed"

    if ! require_homebrew_for_feature "更新 Homebrew"; then
        return 0
    fi

    print_page_title "更新 Homebrew"
    print_message "将执行：brew update"

    if ! prompt_yes_no "是否继续更新 Homebrew？" "n"; then
        print_status_message "skip" "已取消更新。"
        return 0
    fi

    print_output_boundary "开始执行 brew update"
    if brew update; then
        update_status="success"
    fi
    print_output_boundary "brew update 执行结束"

    print_page_title "更新 Homebrew 总结"
    if [ "$update_status" = "success" ]; then
        print_status_message "ok" "Homebrew 更新完成。"
    else
        print_status_message "err" "Homebrew 更新失败。"
    fi
}


run_update_projects_flow() {
    local choice=""
    local parsed_choice=""
    local token=""
    local selected_formulas=()
    local selected_casks=()
    local upgrade_formula_status="not-run"
    local upgrade_cask_status="not-run"
    local index=0
    local item_type=""
    local item_name=""

    if ! require_homebrew_for_feature "更新已安装项目"; then
        return 0
    fi

    if ! load_outdated_inventory; then
        print_command_query_failure "可升级项目列表" "brew outdated --formula / brew outdated --cask"
        pause_before_return
        return 0
    fi
    build_updatable_item_catalog

    while true; do
        selected_formulas=()
        selected_casks=()

        print_page_title "更新已安装项目"
        print_outdated_inventory_report

        if [ "${#UPDATABLE_ITEMS[@]}" -eq 0 ]; then
            print_status_message "ok" "当前没有可升级项目。"
            pause_before_return
            return 0
        fi

        print_message "可选择输入：all"
        print_message "也可以输入空格分隔的序号，例如：1 2 3"
        render_numbered_list "updatable" "${UPDATABLE_ITEMS[@]+"${UPDATABLE_ITEMS[@]}"}"
        print_blank_line
        printf "请输入选择（all / 序号 / b）: "
        if ! read -r choice; then
            return 0
        fi

        parsed_choice="$(parse_multi_numeric_choice "$choice" "${#UPDATABLE_ITEMS[@]}")"

        case "$parsed_choice" in
            back)
                return 0
                ;;
            invalid)
                print_status_message "warn" "输入无效，请输入 all、空格分隔序号或 b。"
                pause_before_return
                continue
                ;;
            all)
                selected_formulas=("${OUTDATED_FORMULAS[@]+"${OUTDATED_FORMULAS[@]}"}")
                selected_casks=("${OUTDATED_CASKS[@]+"${OUTDATED_CASKS[@]}"}")
                ;;
            *)
                for token in $parsed_choice; do
                    index=$((token - 1))
                    item_type="${UPDATABLE_TYPES[$index]%%:*}"
                    item_name="${UPDATABLE_TYPES[$index]#*:}"

                    if [ "$item_type" = "formula" ]; then
                        selected_formulas+=("$item_name")
                    else
                        selected_casks+=("$item_name")
                    fi
                done
                ;;
        esac

        break
    done

    if [ "${#selected_formulas[@]}" -gt 0 ]; then
        print_status_message "info" "将升级 formula：$(printf "%s " "${selected_formulas[@]+"${selected_formulas[@]}"}" | sed 's/[[:space:]]*$//')"
    fi
    if [ "${#selected_casks[@]}" -gt 0 ]; then
        print_status_message "info" "将升级 cask：$(printf "%s " "${selected_casks[@]+"${selected_casks[@]}"}" | sed 's/[[:space:]]*$//')"
    fi

    if ! prompt_yes_no "是否继续执行升级？" "n"; then
        print_status_message "skip" "已取消升级。"
        pause_before_return
        return 0
    fi

    print_output_boundary "开始执行 Homebrew 升级"
    if [ "${#selected_formulas[@]}" -gt 0 ]; then
        if brew upgrade "${selected_formulas[@]+"${selected_formulas[@]}"}"; then
            upgrade_formula_status="success"
        else
            upgrade_formula_status="failed"
        fi
    fi

    if [ "${#selected_casks[@]}" -gt 0 ]; then
        if brew upgrade --cask "${selected_casks[@]+"${selected_casks[@]}"}"; then
            upgrade_cask_status="success"
        else
            upgrade_cask_status="failed"
        fi
    fi
    print_output_boundary "Homebrew 升级执行结束"

    print_page_title "更新项目总结"
    print_message "本次选择 formula 数量：${#selected_formulas[@]}"
    print_message "本次选择 cask 数量：${#selected_casks[@]}"
    print_message "Formula 升级状态：$upgrade_formula_status"
    print_message "Cask 升级状态：$upgrade_cask_status"
    if load_outdated_inventory; then
        print_message "剩余可升级 formula 数量：${#OUTDATED_FORMULAS[@]}"
        print_message "剩余可升级 cask 数量：${#OUTDATED_CASKS[@]}"
    else
        print_status_message "warn" "升级已执行，但未能刷新可升级项目列表。"
        print_message "请稍后手动运行 brew outdated 再确认剩余项目。"
    fi
    pause_before_return
}

