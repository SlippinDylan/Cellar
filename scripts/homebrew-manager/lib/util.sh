# util.sh
# Sourced by main.sh; not meant to be executed directly.

command_exists() {
    command -v "$1" >/dev/null 2>&1
}


is_valid_shell_identifier() {
    local name="$1"

    case "$name" in
        [A-Za-z_][A-Za-z0-9_]*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


reset_named_array() {
    local array_name="$1"

    if ! is_valid_shell_identifier "$array_name"; then
        return 1
    fi

    eval "$array_name=()"
}


is_positive_integer() {
    local value="${1:-}"

    case "$value" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$value" -gt 0 ]
}


append_to_array() {
    local array_name="$1"
    local value="$2"
    local escaped_value=""

    if ! is_valid_shell_identifier "$array_name"; then
        return 1
    fi

    printf -v escaped_value '%q' "$value"
    eval "$array_name+=( $escaped_value )"
}


array_contains_exact() {
    local needle="$1"
    shift
    local item=""

    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done

    return 1
}


append_unique_to_array() {
    local array_name="$1"
    local value="$2"
    local existing=()

    if ! is_valid_shell_identifier "$array_name"; then
        return 1
    fi

    eval "existing=(\"\${${array_name}[@]+\"\${${array_name}[@]}\"}\")"
    if array_contains_exact "$value" "${existing[@]+"${existing[@]}"}"; then
        return 0
    fi

    append_to_array "$array_name" "$value"
}


read_command_output_into_array() {
    local array_name="$1"
    shift
    local line=""
    local temp_file=""
    local command_status=0

    if ! reset_named_array "$array_name"; then
        return 1
    fi

    temp_file="$(mktemp "${TMPDIR:-/tmp}/brew-app-manager-array.XXXXXX")" || return 1
    "$@" >"$temp_file"
    command_status="$?"

    while IFS= read -r line || [ -n "$line" ]; do
        append_to_array "$array_name" "$line"
    done < "$temp_file"

    rm -f "$temp_file"
    return "$command_status"
}


extract_key_value() {
    local lines="$1"
    local key="$2"

    printf "%s\n" "$lines" | sed -n "s/^${key}=//p" | head -n 1
}


unique_lines() {
    awk 'NF && !seen[$0]++'
}


normalize_name() {
    printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ._-'
}


trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
}


is_nonnegative_integer() {
    local value="${1:-}"

    case "$value" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    return 0
}


expand_home_path() {
    local raw_path="$1"

    case "$raw_path" in
        "~"/*)
            printf "%s/%s" "$HOME" "${raw_path#"~/"}"
            ;;
        "~")
            printf "%s" "$HOME"
            ;;
        *)
            printf "%s" "$raw_path"
            ;;
    esac
}


strip_app_bundle_suffix() {
    local app_name="$1"

    case "$app_name" in
        *.app|*.APP)
            printf "%s" "${app_name%.[aA][pP][pP]}"
            ;;
        *)
            printf "%s" "$app_name"
            ;;
    esac
}


build_typed_display_items() {
    local array_name="$1"
    shift
    local refs=("$@")
    local ref=""
    local item_type=""
    local item_name=""

    if ! reset_named_array "$array_name"; then
        return 1
    fi

    for ref in "${refs[@]+"${refs[@]}"}"; do
        [ -n "$ref" ] || continue
        item_type="${ref%%:*}"
        item_name="${ref#*:}"
        append_to_array "$array_name" "$item_name [$item_type]"
    done
}


exclude_exact_lines() {
    local excludes=("$@")
    local line=""

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if array_contains_exact "$line" "${excludes[@]+"${excludes[@]}"}"; then
            continue
        fi
        printf "%s\n" "$line"
    done
}

