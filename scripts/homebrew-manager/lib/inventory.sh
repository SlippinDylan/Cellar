# inventory.sh
# Sourced by main.sh; not meant to be executed directly.

load_formula_inventory() {
    brew list --formula 2>/dev/null
}


load_cask_inventory() {
    brew list --cask 2>/dev/null
}


load_tap_inventory() {
    brew tap 2>/dev/null
}


load_outdated_formula_inventory() {
    brew outdated --formula 2>/dev/null
}


load_outdated_cask_inventory() {
    brew outdated --cask 2>/dev/null
}


load_outdated_inventory() {
    local formula_status=0
    local cask_status=0

    print_status_message "info" "正在检测可升级项目..."
    read_command_output_into_array OUTDATED_FORMULAS load_outdated_formula_inventory
    formula_status="$?"
    read_command_output_into_array OUTDATED_CASKS load_outdated_cask_inventory
    cask_status="$?"

    if [ "$formula_status" -ne 0 ] || [ "$cask_status" -ne 0 ]; then
        return 1
    fi

    return 0
}


print_outdated_inventory_report() {
    print_message "可升级 formula 数量：${#OUTDATED_FORMULAS[@]}"
    print_message "可升级 cask 数量：${#OUTDATED_CASKS[@]}"
    print_compact_value_list "Formula：" "${OUTDATED_FORMULAS[@]+"${OUTDATED_FORMULAS[@]}"}"
    print_compact_value_list "Cask：" "${OUTDATED_CASKS[@]+"${OUTDATED_CASKS[@]}"}"
}


build_updatable_item_catalog() {
    local formula=""
    local cask=""

    UPDATABLE_ITEMS=()
    UPDATABLE_TYPES=()

    for formula in "${OUTDATED_FORMULAS[@]+"${OUTDATED_FORMULAS[@]}"}"; do
        [ -n "$formula" ] || continue
        UPDATABLE_ITEMS+=("$formula [formula]")
        UPDATABLE_TYPES+=("formula:$formula")
    done

    for cask in "${OUTDATED_CASKS[@]+"${OUTDATED_CASKS[@]}"}"; do
        [ -n "$cask" ] || continue
        UPDATABLE_ITEMS+=("$cask [cask]")
        UPDATABLE_TYPES+=("cask:$cask")
    done
}

