# tap.sh
# Sourced by main.sh; not meant to be executed directly.

is_valid_tap_name() {
    local tap_name="$1"
    local owner=""
    local repo=""

    case "$tap_name" in
        ''|/*|*/|*//*|*/*/*|*[!A-Za-z0-9._/-]*)
            return 1
            ;;
    esac

    case "$tap_name" in
        */*)
            ;;
        *)
            return 1
            ;;
    esac

    owner="${tap_name%%/*}"
    repo="${tap_name#*/}"

    [ -n "$owner" ] && [ -n "$repo" ]
}


run_tap_add_flow() {
    local tap_name=""
    local add_status="failed"

    print_page_title "添加 Tap"
    printf "请输入要添加的 tap 名称（例如 owner/repo，b 返回）: "
    if ! read -r tap_name; then
        return 0
    fi

    tap_name="$(trim_whitespace "$tap_name")"
    if [ "$tap_name" = "b" ] || [ "$tap_name" = "B" ]; then
        return 0
    fi

    if ! is_valid_tap_name "$tap_name"; then
        print_status_message "warn" "tap 名称格式无效，请输入 owner/repo。"
        return 0
    fi

    print_output_boundary "开始执行 brew tap $tap_name"
    if brew tap "$tap_name"; then
        add_status="success"
    fi
    print_output_boundary "brew tap 执行结束"

    print_page_title "Tap 添加总结"
    print_message "目标 Tap：$tap_name"
    print_message "执行状态：$add_status"
}


run_tap_remove_flow() {
    local taps=()
    local tap_choice=""
    local parsed_choice=""
    local tap_name=""
    local associated_refs=()
    local associated_items=()
    local selected_refs=()
    local untap_status="failed"
    local scan_failed="0"

    if ! read_command_output_into_array taps load_tap_inventory; then
        print_command_query_failure "Tap 列表" "brew tap"
        return 0
    fi
    if [ "${#taps[@]}" -eq 0 ]; then
        print_status_message "info" "当前没有已添加的 tap。"
        return 0
    fi

    while true; do
        while true; do
            print_page_title "选择要删除的 Tap"
            print_numbered_entries "tap" "${taps[@]+"${taps[@]}"}"
            print_blank_line
            printf "请输入序号（b 返回）: "
            if ! read -r tap_choice; then
                return 0
            fi

            parsed_choice="$(parse_numeric_choice "$tap_choice" "${#taps[@]}")"
            case "$parsed_choice" in
                back)
                    return 0
                    ;;
                invalid)
                    print_status_message "warn" "输入无效，请输入正确的序号或 b。"
                    pause_before_return
                    ;;
                *)
                    tap_name="${taps[$((parsed_choice - 1))]}"
                    break
                    ;;
            esac
        done

        scan_failed="0"
        while true; do
            if ! read_command_output_into_array associated_refs collect_installed_items_for_tap "$tap_name"; then
                print_status_message "err" "未能扫描这个 tap 关联的已安装项目，已取消删除。"
                print_message "请检查 brew list 与安装记录是否可正常读取。"
                pause_before_return
                scan_failed="1"
                break
            fi
            build_tap_association_display_items associated_items "${associated_refs[@]+"${associated_refs[@]}"}"

            print_page_title "Tap 删除扫描结果"
            print_message "目标 Tap：$tap_name"
            if [ "${#associated_refs[@]}" -eq 0 ]; then
                print_message "当前未发现该 tap 下仍安装的项目。"
                break
            fi

            print_message "要删除这个 tap，需要先处理下面这些已安装项目："
            print_compact_value_list "关联项目：" "${associated_items[@]+"${associated_items[@]}"}"
            print_message "说明：标记为“仅 Homebrew 记录 / Caskroom 残留”的项目，可能已不在 Applications 中，但 Homebrew 仍将其视为已安装。"
            print_message "如果暂时不继续处理，可以输入 b 返回；脚本不会强制删除这个 tap。"
            # associated_items is only the user-facing label layer; keep its order aligned
            # with associated_refs so the chosen indexes can map back to typed refs safely.
            prompt_for_multi_selection "选择要先卸载的 Tap 关联项目" "请输入选择（all / 序号 / b）: " "${associated_items[@]+"${associated_items[@]}"}"
            parsed_choice="$PROMPT_MULTI_SELECT_RESULT"
            if [ "$parsed_choice" = "back" ]; then
                print_status_message "skip" "已取消 tap 删除。"
                return 0
            fi

            populate_array_from_selection selected_refs "$parsed_choice" "${associated_refs[@]+"${associated_refs[@]}"}"
            run_typed_uninstall_batch "${selected_refs[@]+"${selected_refs[@]}"}"

            if ! read_command_output_into_array associated_refs collect_installed_items_for_tap "$tap_name"; then
                print_status_message "err" "未能重新扫描 tap 关联项目，已停止后续 untap。"
                return 0
            fi
            if [ "${#associated_refs[@]}" -gt 0 ]; then
                print_status_message "warn" "仍有未清空的 Tap 关联项目，删除 tap 前需要继续处理，或输入 b 返回。"
            fi
        done

        if [ "$scan_failed" = "1" ]; then
            continue
        fi

        if ! prompt_yes_no "关联项目已清空，是否继续删除这个 tap？" "n"; then
            print_status_message "skip" "已取消删除 tap。"
            return 0
        fi

        print_output_boundary "开始执行 brew untap $tap_name"
        if brew untap "$tap_name"; then
            untap_status="success"
        fi
        print_output_boundary "brew untap 执行结束"

        print_page_title "Tap 删除总结"
        print_message "目标 Tap：$tap_name"
        print_message "执行状态：$untap_status"
        return 0
    done
}


run_tap_management_flow() {
    local taps=()
    local choice=""
    local action=""

    if ! require_homebrew_for_feature "Tap 管理"; then
        return 0
    fi

    while true; do
        if ! read_command_output_into_array taps load_tap_inventory; then
            print_command_query_failure "Tap 列表" "brew tap"
            pause_before_return
            return 0
        fi

        print_page_title "Tap 管理"
        print_message "当前 Tap 列表："
        if [ "${#taps[@]}" -eq 0 ]; then
            print_message "<none>"
        else
            print_numbered_entries "tap" "${taps[@]+"${taps[@]}"}"
        fi
        print_blank_line
        printf "%s\n" "$(render_tap_menu)"
        printf "请输入序号（b 返回）: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_tap_choice "$choice")"
        case "$action" in
            add)
                run_tap_add_flow
                pause_before_return
                ;;
            remove)
                run_tap_remove_flow
                pause_before_return
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

