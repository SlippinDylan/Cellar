# shellcheck shell=bash

print_blank_line() {
    printf "\n"
}

print_message() {
    printf "%s\n" "$1"
}

print_separator() {
    local width="${1:-50}"
    printf '%*s\n' "$width" '' | tr ' ' '─'
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
        ok)    paint_text "1;32" "[OK]" ;;
        warn)  paint_text "1;33" "[WARN]" ;;
        fail)  paint_text "1;31" "[FAIL]" ;;
        skip)  paint_text "1;36" "[SKIP]" ;;
        *)     printf "[%s]" "$status" ;;
    esac
}

print_status_message() {
    local status="$1"
    local message="$2"

    printf "%s %s\n" "$(format_status_tag "$status")" "$message"
}

print_title_box() {
    local title="$1"
    local top="┌──────────────────────────────────────────────────────┐"
    local bottom="└──────────────────────────────────────────────────────┘"

    printf "%s\n" "$top"
    printf "│  %-52s│\n" "$title"
    printf "%s\n" "$bottom"
    print_blank_line
}

clear_screen() {
    if [ -t 1 ]; then
        printf '\033[2J\033[H'
    fi
}

print_page_title() {
    local title="$1"

    clear_screen
    print_title_box "$title"
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

    while true; do
        if [ "$default_answer" = "y" ]; then
            printf "%s [Y/n]: " "$prompt"
        else
            printf "%s [y/N]: " "$prompt"
        fi

        read -r answer || return 1
        answer="$(trim_whitespace "$answer")"
        [ -n "$answer" ] || answer="$default_answer"

        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)   return 1 ;;
            *)
                printf "请输入 y 或 n。\n"
                ;;
        esac
    done
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
}

normalize_dragged_path() {
    local path="$1"

    path="$(trim_whitespace "$path")"
    path="${path%/}"

    case "$path" in
        \"*\") path="${path#\"}"; path="${path%\"}" ;;
        \'*\') path="${path#\'}"; path="${path%\'}" ;;
    esac

    path="${path//\\ / }"
    path="${path//\\(/(}"
    path="${path//\\)/)}"
    path="${path//\\[/[}"
    path="${path//\\]/]}"
    path="${path//\\&/&}"
    path="${path//\\!/!}"
    path="${path//\\;/;}"
    path="${path//\\#/#}"
    path="${path//\\$/\$}"
    path="${path//\\*/*}"
    path="${path//\\?/?}"
    path="${path//\\~/~}"
    path="${path%/}"

    # Expand a leading `~` (bare home dir or `~/...`) since typed-path input
    # is a common alternative to drag-and-drop and the shell never gets a
    # chance to expand it itself (it's read as plain data via `read -r`).
    # `~otheruser` forms are intentionally left untouched, matching the
    # narrow, deterministic scope this script targets elsewhere.
    # shellcheck disable=SC2088 # quoting "~/"* below is deliberate: case
    # patterns undergo tilde expansion same as command words, so an unquoted
    # ~/* pattern would expand to the *shell's own* home dir glob before
    # matching; quoting keeps it a literal "~/" prefix match against $path,
    # which is then expanded manually on the right.
    case "$path" in
        "~") path="$HOME" ;;
        "~/"*) path="$HOME/${path#\~/}" ;;
    esac

    printf '%s\n' "$path"
}

is_nonnegative_integer() {
    local value="${1:-}"
    case "$value" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# Strips leading zeros from a validated digit string before it is ever used
# in bash arithmetic context: "08"/"09" are invalid octal literals in $((..))
# and crash the script under `set -u`, even though [ ] comparisons accept them.
strip_leading_zeros() {
    local value="${1:-0}"
    value="${value#"${value%%[!0]*}"}"
    [ -n "$value" ] || value=0
    printf '%s' "$value"
}

# `[ N -ge/-le/-lt/-gt ... ]` on a pasted digit string longer than ~18-19
# digits overflows test(1)'s internal arithmetic and prints "integer
# expression expected" noise to stderr on some platforms. No real menu ever
# has anywhere near that many items, so reject overlong digit strings
# outright before any arithmetic comparison touches them.
is_arithmetic_safe_digit_string() {
    local value="${1:-}"
    [ "${#value}" -le 15 ]
}
