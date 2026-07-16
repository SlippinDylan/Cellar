# uninstall_router.sh
# Sourced by main.sh; not meant to be executed directly.

describe_tap_associated_cask_state() {
    local cask="$1"
    local receipt_paths=()
    local receipt_path=""
    local app_name=""
    local app_path=""
    local caskroom_status=0

    if ! read_command_output_into_array receipt_paths find_cask_install_receipts "$cask"; then
        printf "扫描失败"
        return 1
    fi

    receipt_path="${receipt_paths[0]:-}"
    if [ -n "$receipt_path" ]; then
        app_name="$(load_cask_app_name_from_receipt "$receipt_path")"
    fi

    if [ -n "$app_name" ]; then
        app_path="$(find_app_bundle_path "$app_name" 2>/dev/null || true)"
    fi

    if [ -n "$app_path" ]; then
        printf "已安装"
        return 0
    fi

    caskroom_entry_exists "$cask"
    caskroom_status="$?"
    case "$caskroom_status" in
        0)
            printf "仅 Homebrew 记录 / Caskroom 残留"
            return 0
            ;;
        1)
            printf "仅 Homebrew 安装记录"
            return 0
            ;;
        *)
            printf "扫描失败"
            return 1
            ;;
    esac
}


build_tap_association_display_items() {
    local array_name="$1"
    shift
    local refs=("$@")
    local ref=""
    local item_type=""
    local item_name=""
    local item_state=""

    if ! reset_named_array "$array_name"; then
        return 1
    fi

    for ref in "${refs[@]+"${refs[@]}"}"; do
        [ -n "$ref" ] || continue
        item_type="${ref%%:*}"
        item_name="${ref#*:}"

        if [ "$item_type" = "cask" ]; then
            if ! item_state="$(describe_tap_associated_cask_state "$item_name")"; then
                item_state="${item_state:-扫描失败}"
            fi
            append_to_array "$array_name" "$item_name [$item_type, $item_state]"
        else
            append_to_array "$array_name" "$item_name [$item_type]"
        fi
    done
}


run_uninstall_menu() {
    local choice=""
    local action=""

    if ! require_homebrew_for_feature "卸载项目"; then
        return 0
    fi

    while true; do
        print_page_title "卸载项目"
        printf "%s\n" "$(render_uninstall_menu)"
        printf "请输入序号（b 返回）: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_uninstall_choice "$choice")"

        case "$action" in
            formula)
                run_formula_selection_menu
                ;;
            cask)
                run_cask_selection_menu
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


find_formula_install_receipts() {
    local formula="$1"
    local cellar_path=""

    cellar_path="$(brew --cellar "$formula" 2>/dev/null)" || return 1
    [ -n "$cellar_path" ] || return 1
    if [ -d "$cellar_path" ]; then
        find "$cellar_path" -maxdepth 2 -name INSTALL_RECEIPT.json -print 2>/dev/null || return 1
    fi

    return 0
}


find_cask_install_receipts() {
    local cask="$1"
    local homebrew_prefix=""
    local caskroom_path=""

    homebrew_prefix="$(brew --prefix 2>/dev/null)" || return 1
    [ -n "$homebrew_prefix" ] || return 1
    caskroom_path="$homebrew_prefix/Caskroom/$cask"
    if [ -d "$caskroom_path" ]; then
        find "$caskroom_path" -name INSTALL_RECEIPT.json -print 2>/dev/null || return 1
    fi

    return 0
}


extract_tap_from_install_receipt() {
    local receipt_path="$1"
    local source_tap=""

    if [ ! -f "$receipt_path" ]; then
        return 1
    fi

    source_tap="$(plutil_extract_raw_value "$receipt_path" "source.tap" 2>/dev/null || true)"
    if [ -z "$source_tap" ]; then
        source_tap="$(plutil_extract_raw_value "$receipt_path" "tap" 2>/dev/null || true)"
    fi
    [ -n "$source_tap" ] || return 1
    if ! is_valid_tap_name "$source_tap"; then
        return 1
    fi

    printf "%s" "$source_tap"
}


formula_belongs_to_tap() {
    local formula="$1"
    local tap="$2"
    local receipts=()
    local receipt_path=""
    local source_tap=""
    local parse_failed="0"

    if ! read_command_output_into_array receipts find_formula_install_receipts "$formula"; then
        return 2
    fi

    for receipt_path in "${receipts[@]+"${receipts[@]}"}"; do
        [ -n "$receipt_path" ] || continue
        if ! source_tap="$(extract_tap_from_install_receipt "$receipt_path")"; then
            parse_failed="1"
            continue
        fi
        if [ "$source_tap" = "$tap" ]; then
            return 0
        fi
    done

    if [ "$parse_failed" = "1" ]; then
        return 2
    fi

    return 1
}


cask_belongs_to_tap() {
    local cask="$1"
    local tap="$2"
    local receipts=()
    local receipt_path=""
    local source_tap=""
    local parse_failed="0"

    if ! read_command_output_into_array receipts find_cask_install_receipts "$cask"; then
        return 2
    fi

    for receipt_path in "${receipts[@]+"${receipts[@]}"}"; do
        [ -n "$receipt_path" ] || continue
        if ! source_tap="$(extract_tap_from_install_receipt "$receipt_path")"; then
            parse_failed="1"
            continue
        fi
        if [ "$source_tap" = "$tap" ]; then
            return 0
        fi
    done

    if [ "$parse_failed" = "1" ]; then
        return 2
    fi

    return 1
}


collect_installed_items_for_tap() {
    local tap="$1"
    local formulas=()
    local casks=()
    local formula=""
    local cask=""
    local association_status=0

    if ! read_command_output_into_array formulas load_formula_inventory; then
        return 1
    fi

    for formula in "${formulas[@]+"${formulas[@]}"}"; do
        [ -n "$formula" ] || continue
        formula_belongs_to_tap "$formula" "$tap"
        association_status="$?"
        case "$association_status" in
            0)
                printf "formula:%s\n" "$formula"
                ;;
            1)
                ;;
            *)
                return 1
                ;;
        esac
    done

    if ! read_command_output_into_array casks load_cask_inventory; then
        return 1
    fi

    for cask in "${casks[@]+"${casks[@]}"}"; do
        [ -n "$cask" ] || continue
        cask_belongs_to_tap "$cask" "$tap"
        association_status="$?"
        case "$association_status" in
            0)
                printf "cask:%s\n" "$cask"
                ;;
            1)
                ;;
            *)
                return 1
                ;;
        esac
    done
}


run_typed_uninstall_batch() {
    local refs=("$@")
    local total="${#refs[@]}"
    local index=0
    local ref=""
    local item_type=""
    local item_name=""
    local formulas=()
    local casks=()

    for ref in "${refs[@]+"${refs[@]}"}"; do
        [ -n "$ref" ] || continue
        item_type="${ref%%:*}"
        item_name="${ref#*:}"
        if [ "$item_type" = "formula" ]; then
            formulas+=("$item_name")
        else
            casks+=("$item_name")
        fi
    done

    if [ "${#formulas[@]}" -gt 0 ]; then
        run_formula_uninstall_batch "${formulas[@]+"${formulas[@]}"}"
    fi

    if [ "${#casks[@]}" -gt 0 ]; then
        run_cask_uninstall_batch "${casks[@]+"${casks[@]}"}"
    fi
}

