# ui.sh
# Sourced by main.sh; not meant to be executed directly.

print_numbered_entries() {
    local label="$1"
    shift

    local items=("$@")
    local index=1
    local entries=()
    local terminal_width=0
    local columns=1
    local rendered_items=""

    for item in "${items[@]+"${items[@]}"}"; do
        append_to_array entries "$index) $item"
        index=$((index + 1))
    done

    terminal_width="$(get_terminal_width)"
    columns="$(calculate_column_count "$terminal_width" 8 6 "${entries[@]+"${entries[@]}"}")"
    rendered_items="$(render_entries_in_columns "$columns" "${entries[@]+"${entries[@]}"}")"

    if [ -n "$rendered_items" ]; then
        printf "%s\n" "$rendered_items"
    fi
    print_layout_debug_if_enabled "$terminal_width" "$columns" "${entries[@]+"${entries[@]}"}"
}


render_numbered_list() {
    local label="$1"
    shift

    print_numbered_entries "$label" "$@"
    printf "b) 返回上一级"
}


join_lines() {
    awk 'NF { if (count++) printf " "; printf "%s", $0 } END { if (count == 0) printf "" }'
}


print_message() {
    printf "%s\n" "$1"
}


supports_color_output() {
    [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]
}


paint_text() {
    local style_code="$1"
    local text="$2"

    if supports_color_output; then
        printf '\033[%sm%s\033[0m' "$style_code" "$text"
        return 0
    fi

    printf "%s" "$text"
}


format_status_tag() {
    local status="$1"

    case "$status" in
        ok) paint_text "1;32" "[OK]" ;;
        warn) paint_text "1;33" "[WARN]" ;;
        err) paint_text "1;31" "[ERR]" ;;
        skip) paint_text "1;35" "[SKIP]" ;;
        info|*) paint_text "1;36" "[INFO]" ;;
    esac
}


print_status_message() {
    local status="$1"
    local message="$2"

    print_message "$(format_status_tag "$status") $message"
}


print_blank_line() {
    printf "\n"
}


repeat_char() {
    local character="$1"
    local count="$2"
    local buffer=""

    if ! is_positive_integer "$count"; then
        printf ""
        return 0
    fi

    printf -v buffer "%*s" "$count" ""
    printf "%s" "${buffer// /$character}"
}


render_separator() {
    local terminal_width="${1:-0}"
    local separator_width=0

    if ! is_positive_integer "$terminal_width"; then
        terminal_width="$(get_terminal_width)"
    fi

    if is_positive_integer "$terminal_width"; then
        separator_width="$terminal_width"
    else
        separator_width=80
    fi

    printf "%s" "$(repeat_char "-" "$separator_width")"
}


clear_screen() {
    if command_exists clear; then
        clear
    else
        printf "\033c"
    fi
}


print_section_title() {
    print_blank_line
    print_title_box "$1"
}


print_title_box() {
    local title="$1"
    local terminal_width=0
    local inner_width=0
    local border=""
    local title_line=""

    terminal_width="$(get_terminal_width)"
    if ! is_positive_integer "$terminal_width"; then
        terminal_width=80
    fi

    if [ "$terminal_width" -lt $(( ${#title} + 4 )) ]; then
        terminal_width=$(( ${#title} + 4 ))
    fi

    inner_width=$((terminal_width - 4))
    border="+$(repeat_char "=" "$((terminal_width - 2))")+"
    printf -v title_line "| %-*s |" "$inner_width" "$title"

    print_message "$(paint_text "2" "$border")"
    print_message "$(paint_text "1;36" "$title_line")"
    print_message "$(paint_text "2" "$border")"
}


print_page_title() {
    local title="$1"

    clear_screen
    print_title_box "$title"
}


print_output_boundary() {
    local label="$1"
    local terminal_width=0
    local separator=""

    terminal_width="$(get_terminal_width)"
    separator="$(render_separator "$terminal_width")"
    print_message "$(paint_text "2" "$separator")"
    print_status_message "info" "$label"
    print_message "$(paint_text "2" "$separator")"
}


print_layout_debug_if_enabled() {
    local terminal_width="$1"
    local columns="$2"
    shift 2

    if [ "${BREW_APP_MANAGER_LAYOUT_DEBUG:-0}" != "1" ]; then
        return 0
    fi

    print_message "布局诊断：终端宽度=${terminal_width}，最长项宽度=$(max_entry_width "$@")，当前列数=${columns}"
}


get_terminal_width_from_stty() {
    local tty_size=""
    local tty_width=""

    if ! tty -s; then
        return 1
    fi

    tty_size="$(stty size </dev/tty 2>/dev/null || true)"
    tty_width="$(printf "%s\n" "$tty_size" | awk 'NF >= 2 { print $2; exit }')"

    if is_positive_integer "$tty_width"; then
        printf "%s" "$tty_width"
        return 0
    fi

    return 1
}


get_terminal_width_from_tput() {
    local tty_width=""

    if ! command_exists tput; then
        return 1
    fi

    tty_width="$(tput cols 2>/dev/null || true)"
    if is_positive_integer "$tty_width"; then
        printf "%s" "$tty_width"
        return 0
    fi

    return 1
}


get_terminal_width() {
    local terminal_width=""

    if terminal_width="$(get_terminal_width_from_stty)"; then
        printf "%s" "$terminal_width"
        return 0
    fi

    if terminal_width="$(get_terminal_width_from_tput)"; then
        printf "%s" "$terminal_width"
        return 0
    fi

    if is_positive_integer "${COLUMNS:-}"; then
        printf "%s" "$COLUMNS"
        return 0
    fi

    printf "80"
}


print_command_query_failure() {
    local description="$1"
    local detail="$2"

    print_status_message "err" "未能读取${description}。"
    print_message "失败命令：$detail"
}


max_entry_width() {
    local item=""
    local max_width=0

    for item in "$@"; do
        [ -n "$item" ] || continue
        if [ "${#item}" -gt "$max_width" ]; then
            max_width="${#item}"
        fi
    done

    printf "%s" "$max_width"
}


calculate_column_count() {
    local terminal_width="$1"
    local min_items="${2:-8}"
    local max_columns="${3:-6}"
    shift 3
    local entries=("$@")
    local entry_count="${#entries[@]}"
    local max_width=0
    local gutter=2
    local cell_width=0
    local columns=1

    if [ "$entry_count" -lt "$min_items" ]; then
        printf "1"
        return 0
    fi

    max_width="$(max_entry_width "${entries[@]+"${entries[@]}"}")"
    cell_width=$((max_width + gutter))

    if [ "$cell_width" -le 0 ] || [ "$terminal_width" -lt "$cell_width" ]; then
        printf "1"
        return 0
    fi

    columns=$(((terminal_width + gutter) / cell_width))

    if [ "$columns" -lt 1 ]; then
        columns=1
    fi

    if [ "$columns" -gt "$entry_count" ]; then
        columns="$entry_count"
    fi

    if [ "$columns" -gt "$max_columns" ]; then
        columns="$max_columns"
    fi

    printf "%s" "$columns"
}


render_entries_in_columns() {
    local columns="$1"
    shift
    local entries=("$@")
    local count="${#entries[@]}"
    local rows=0
    local max_width=0
    local gutter=2
    local row=0
    local col=0
    local idx=0
    local next_idx=0
    local line=""

    if [ "$count" -eq 0 ]; then
        printf ""
        return 0
    fi

    if [ "$columns" -le 1 ]; then
        printf "%s\n" "${entries[@]+"${entries[@]}"}"
        return 0
    fi

    rows=$(((count + columns - 1) / columns))
    max_width="$(max_entry_width "${entries[@]+"${entries[@]}"}")"

    for ((row = 0; row < rows; row++)); do
        line=""
        for ((col = 0; col < columns; col++)); do
            idx=$((row + col * rows))
            if [ "$idx" -ge "$count" ]; then
                continue
            fi

            next_idx=$((row + (col + 1) * rows))
            if [ "$next_idx" -lt "$count" ]; then
                printf -v line "%s%-*s" "$line" $((max_width + gutter)) "${entries[$idx]}"
            else
                printf -v line "%s%s" "$line" "${entries[$idx]}"
            fi
        done
        printf "%s" "$line"
        if [ "$row" -lt $((rows - 1)) ]; then
            printf "\n"
        fi
    done
}


pause_before_return() {
    print_blank_line
    printf "按回车继续..."
    read -r _ || true
}


prompt_yes_no() {
    local prompt="$1"
    local default_answer="${2:-n}"
    local answer=""

    if [ "$default_answer" = "y" ]; then
        printf "%s [Y/n]: " "$prompt"
    else
        printf "%s [y/N]: " "$prompt"
    fi

    if ! read -r answer; then
        return 1
    fi

    if [ -z "$answer" ]; then
        answer="$default_answer"
    fi

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}


print_compact_value_list() {
    local title="$1"
    shift
    local items=("$@")
    local terminal_width=0
    local columns=1
    local rendered_items=""

    print_message "$title"

    if [ "${#items[@]}" -eq 0 ]; then
        print_message "<none>"
        return 0
    fi

    terminal_width="$(get_terminal_width)"
    columns="$(calculate_column_count "$terminal_width" 4 6 "${items[@]+"${items[@]}"}")"
    rendered_items="$(render_entries_in_columns "$columns" "${items[@]+"${items[@]}"}")"
    printf "%s\n" "$rendered_items"
    print_layout_debug_if_enabled "$terminal_width" "$columns" "${items[@]+"${items[@]}"}"
}


print_multi_select_hint() {
    print_message "可选择输入：all"
    print_message "也可以输入空格分隔的序号，例如：1 2 3"
}

