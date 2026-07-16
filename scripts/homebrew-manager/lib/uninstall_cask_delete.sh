# uninstall_cask_delete.sh
# Sourced by main.sh; not meant to be executed directly.

reset_delete_report() {
    DELETE_REPORT_DELETED=()
    DELETE_REPORT_ELEVATED=()
    DELETE_REPORT_PERMISSION_SKIPPED=()
    DELETE_REPORT_FAILED=()
    DELETE_LAST_ERROR_MESSAGE=""
}


delete_error_requires_elevation() {
    local target_path="$1"
    local error_message="$2"
    local probe_path=""
    local probe_parent=""
    local owner_uid=""
    local current_uid=""

    probe_path="$target_path"
    while [ -n "$probe_path" ] && [ ! -e "$probe_path" ] && [ ! -L "$probe_path" ] && [ "$probe_path" != "/" ]; do
        probe_path="$(dirname "$probe_path")"
    done

    if [ -n "$probe_path" ] && [ "$probe_path" != "/" ]; then
        if [ ! -w "$probe_path" ]; then
            return 0
        fi

        probe_parent="$(dirname "$probe_path")"
        if [ -n "$probe_parent" ] && [ "$probe_parent" != "$probe_path" ] && [ ! -w "$probe_parent" ]; then
            return 0
        fi

        case "$probe_path" in
            /Applications/*|/Library/*|/private/var/db/*|/opt/homebrew/*|/usr/local/*)
                owner_uid="$(stat -f %u "$probe_path" 2>/dev/null || true)"
                current_uid="$(id -u 2>/dev/null || true)"
                if is_nonnegative_integer "$owner_uid" && is_nonnegative_integer "$current_uid" && [ "$owner_uid" != "$current_uid" ]; then
                    return 0
                fi
                ;;
        esac
    fi

    case "$error_message" in
        *"Operation not permitted"*|*"Permission denied"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


remove_path_without_elevation() {
    local target_path="$1"
    local error_file=""

    DELETE_LAST_ERROR_MESSAGE=""
    if ! error_file="$(mktemp "${TMPDIR:-/tmp}/brew-app-manager-delete.XXXXXX")"; then
        DELETE_LAST_ERROR_MESSAGE="未能创建删除错误日志临时文件。"
        return 1
    fi

    if env LC_ALL=C rm -rf "$target_path" 2>"$error_file"; then
        rm -f "$error_file"
        return 0
    fi

    DELETE_LAST_ERROR_MESSAGE="$(cat "$error_file" 2>/dev/null || true)"
    rm -f "$error_file"

    if delete_error_requires_elevation "$target_path" "$DELETE_LAST_ERROR_MESSAGE"; then
        return 10
    fi

    return 1
}


remove_path_with_elevation() {
    local target_path="$1"
    local error_file=""

    DELETE_LAST_ERROR_MESSAGE=""
    if ! error_file="$(mktemp "${TMPDIR:-/tmp}/brew-app-manager-sudo-delete.XXXXXX")"; then
        DELETE_LAST_ERROR_MESSAGE="未能创建提权删除错误日志临时文件。"
        return 1
    fi

    if env LC_ALL=C sudo rm -rf "$target_path" 2>"$error_file"; then
        rm -f "$error_file"
        return 0
    fi

    DELETE_LAST_ERROR_MESSAGE="$(cat "$error_file" 2>/dev/null || true)"
    rm -f "$error_file"
    return 1
}


print_path_report_if_any() {
    local title="$1"
    shift
    local items=("$@")

    if [ "${#items[@]}" -eq 0 ]; then
        return 0
    fi

    print_message "$title"
    printf "%s\n" "${items[@]+"${items[@]}"}"
}


print_item_report_if_any() {
    local title="$1"
    shift
    local items=("$@")

    if [ "${#items[@]}" -eq 0 ]; then
        return 0
    fi

    print_message "$title"
    printf "%s\n" "${items[@]+"${items[@]}"}"
}


delete_paths_with_optional_elevation() {
    local prompt_label="$1"
    shift
    local paths=("$@")
    local path=""
    local permission_pending=()
    local removal_status=0

    reset_delete_report

    for path in "${paths[@]+"${paths[@]}"}"; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || [ -L "$path" ] || continue

        if remove_path_without_elevation "$path"; then
            DELETE_REPORT_DELETED+=("$path")
            continue
        else
            removal_status="$?"
        fi

        case "$removal_status" in
            10)
                permission_pending+=("$path")
                ;;
            *)
                DELETE_REPORT_FAILED+=("$path")
                ;;
        esac
    done

    if [ "${#permission_pending[@]}" -eq 0 ]; then
        return 0
    fi

    print_status_message "warn" "以下路径删除时遇到权限限制："
    printf "%s\n" "${permission_pending[@]+"${permission_pending[@]}"}"

    if ! prompt_yes_no "$prompt_label" "n"; then
        DELETE_REPORT_PERMISSION_SKIPPED=("${permission_pending[@]+"${permission_pending[@]}"}")
        return 0
    fi

    for path in "${permission_pending[@]+"${permission_pending[@]}"}"; do
        if remove_path_with_elevation "$path"; then
            DELETE_REPORT_ELEVATED+=("$path")
        else
            DELETE_REPORT_FAILED+=("$path")
        fi
    done
}

