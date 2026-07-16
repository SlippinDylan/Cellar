#!/bin/bash

# Unified Homebrew manager for macOS.
# Environment: local interactive shell on macOS.
# Purpose: provide one entry point for Homebrew project management and environment bootstrap.

set -u
set -o pipefail

MANAGER_SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
OUTDATED_FORMULAS=()
OUTDATED_CASKS=()
UPDATABLE_ITEMS=()
UPDATABLE_TYPES=()
PROMPT_MULTI_SELECT_RESULT=""
INSTALL_PARALLEL_JOBS=5
INSTALL_MAX_RETRIES=2
DELETE_REPORT_DELETED=()
DELETE_REPORT_ELEVATED=()
DELETE_REPORT_PERMISSION_SKIPPED=()
DELETE_REPORT_FAILED=()
DELETE_LAST_ERROR_MESSAGE=""
FORMULA_PLAN_TARGET=""
FORMULA_PLAN_DEPENDENCIES=()
FORMULA_PLAN_ORPHANS=()
HOMEBREW_INSTALL_SCRIPT_REF="${HOMEBREW_INSTALL_SCRIPT_REF:-93a25fd2d2fdb86422303c292b9223f84ef23eaf}"
HOMEBREW_INSTALL_SCRIPT_URL="${HOMEBREW_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/Homebrew/install/$HOMEBREW_INSTALL_SCRIPT_REF/install.sh}"
CASK_METADATA_TOKEN=""
CASK_METADATA_APP_NAME=""
CASK_METADATA_ZAP_PATHS=()
CASK_RECEIPT_APP_ARTIFACTS=()
CASK_RECEIPT_BINARY_ARTIFACTS=()
CASK_RECEIPT_MANPAGE_ARTIFACTS=()
CASK_RECEIPT_PKGUTIL_ARTIFACTS=()
CASK_RECEIPT_LAUNCHCTL_ARTIFACTS=()
CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS=()
CASK_POSTCHECK_RESIDUAL_DELETE_PATHS=()
CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS=()
CASK_POSTCHECK_CLEARED_ITEMS=()
CASK_POSTCHECK_DELEGATED_ITEMS=()
CASK_UNINSTALL_LAST_CLEARED_ARTIFACTS=()
CASK_UNINSTALL_LAST_DELETED_PATHS=()
CASK_UNINSTALL_LAST_ELEVATED_DELETED_PATHS=()
CASK_UNINSTALL_LAST_PERMISSION_SKIPPED_PATHS=()
CASK_UNINSTALL_LAST_FAILED_PATHS=()
CASK_UNINSTALL_LAST_MANUAL_ATTENTION_ITEMS=()
CASK_UNINSTALL_LAST_DELEGATED_ITEMS=()
INSTALLABLE_CASKS=(
    "1password"
    "airbuddy"
    "aldente"
    "aliwangwang"
    "android-platform-tools"
    "appcleaner"
    "baidunetdisk"
    "bettermouse"
    "bluestacks"
    "cleanmymac-zh"
    "coteditor"
    "dockdoor"
    "downie"
    "feishu"
    "google-chrome"
    "google-chrome@beta"
    "icollections"
    "iina"
    "jetbrains-toolbox"
    "microsoft-edge"
    "monitorcontrol"
    "obsidian"
    "one-switch"
    "pastenow"
    "permute"
    "progressive-downloader"
    "qq"
    "qspace-pro"
    "reqable"
    "spotify"
    "stats"
    "switchhosts"
    "tailscale-app"
    "termius"
    "the-unarchiver"
    "thunder"
    "tower"
    "typora"
    "videofusion"
    "visual-studio-code"
    "warp"
    "wechat"
    "wechatwebdevtools"
    "windows-app"
    "wpsoffice-cn"
    "zed"
)

render_main_menu() {
    cat <<'EOF'
1) 安装项目
2) 卸载项目
3) 更新与升级
4) Tap 管理
5) 环境与依赖
q) 退出
EOF
}

render_uninstall_menu() {
    cat <<'EOF'
1) Formula
2) Cask
b) 返回上一级
EOF
}

render_cleanup_plan() {
    cat <<'EOF'
brew cleanup --prune=all
brew cleanup
brew autoremove
brew services cleanup
EOF
}

render_tap_menu() {
    cat <<'EOF'
1) 添加 Tap
2) 删除 Tap
b) 返回上一级
EOF
}

render_update_menu() {
    cat <<'EOF'
1) 更新 Homebrew
2) 更新已安装项目
b) 返回上一级
EOF
}

render_environment_menu() {
    cat <<'EOF'
1) 清理 Homebrew 环境
2) 安装 Xcode Command Line Tools
3) 安装 Homebrew
b) 返回上一级
EOF
}

should_exit_menu() {
    local menu_name="$1"
    local choice="$2"

    if [ "$menu_name" = "main" ] && { [ "$choice" = "q" ] || [ "$choice" = "Q" ]; }; then
        echo "1"
        return 0
    fi

    echo "0"
}

dispatch_main_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "install" ;;
        2) echo "uninstall" ;;
        3) echo "update" ;;
        4) echo "tap-management" ;;
        5) echo "environment" ;;
        *) echo "back" ;;
    esac
}

dispatch_uninstall_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "formula" ;;
        2) echo "cask" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_tap_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "add" ;;
        2) echo "remove" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_update_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "update-homebrew" ;;
        2) echo "update-projects" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_environment_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "cleanup" ;;
        2) echo "install-clt" ;;
        3) echo "install-homebrew" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

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

parse_numeric_choice() {
    local choice="$1"
    local max_index="$2"

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        echo "back"
        return 0
    fi

    case "$choice" in
        ''|*[!0-9]*)
            echo "invalid"
            return 0
            ;;
    esac

    if [ "$choice" -ge 1 ] && [ "$choice" -le "$max_index" ]; then
        echo "$choice"
        return 0
    fi

    echo "invalid"
}

parse_multi_numeric_choice() {
    local choice="$1"
    local max_index="$2"
    local token=""
    local normalized=""
    local noglob_was_set="0"

    choice="$(trim_whitespace "$choice")"

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        echo "back"
        return 0
    fi

    if [ "$choice" = "all" ] || [ "$choice" = "ALL" ]; then
        echo "all"
        return 0
    fi

    case "$-" in
        *f*) noglob_was_set="1" ;;
    esac
    set -f
    for token in $choice; do
        case "$token" in
            ''|*[!0-9]*)
                if [ "$noglob_was_set" != "1" ]; then
                    set +f
                fi
                echo "invalid"
                return 0
                ;;
        esac

        if [ "$token" -lt 1 ] || [ "$token" -gt "$max_index" ]; then
            if [ "$noglob_was_set" != "1" ]; then
                set +f
            fi
            echo "invalid"
            return 0
        fi

        case " $normalized " in
            *" $token "*) ;;
            *)
                normalized="${normalized:+$normalized }$token"
                ;;
        esac
    done
    if [ "$noglob_was_set" != "1" ]; then
        set +f
    fi

    if [ -z "$normalized" ]; then
        echo "invalid"
        return 0
    fi

    echo "$normalized"
}

join_lines() {
    awk 'NF { if (count++) printf " "; printf "%s", $0 } END { if (count == 0) printf "" }'
}

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

resolve_homebrew_binary_path() {
    local candidate=""

    if command_exists brew; then
        command -v brew
        return 0
    fi

    for candidate in \
        /opt/homebrew/bin/brew \
        /usr/local/bin/brew
    do
        if [ -x "$candidate" ]; then
            printf "%s" "$candidate"
            return 0
        fi
    done

    return 1
}

is_homebrew_installed() {
    resolve_homebrew_binary_path >/dev/null 2>&1
}

initialize_homebrew_shellenv() {
    local brew_bin=""
    local shellenv_output=""

    if ! brew_bin="$(resolve_homebrew_binary_path 2>/dev/null)"; then
        return 1
    fi

    shellenv_output="$(env SHELL=/bin/bash "$brew_bin" shellenv 2>/dev/null)" || return 1

    if [ -n "$shellenv_output" ]; then
        eval "$shellenv_output" || return 1
    fi

    command_exists brew || return 1
    return 0
}

current_login_shell_name() {
    local shell_path="${SHELL:-}"

    shell_path="${shell_path##*/}"
    printf "%s" "$shell_path"
}

homebrew_shellenv_line() {
    local brew_bin=""

    if ! brew_bin="$(resolve_homebrew_binary_path 2>/dev/null)"; then
        return 1
    fi
    [ -n "$brew_bin" ] || return 1

    printf 'eval "$(%s shellenv)"' "$brew_bin"
}

file_contains_exact_line() {
    local file_path="$1"
    local expected_line="$2"

    [ -f "$file_path" ] || return 1
    grep -Fqx "$expected_line" "$file_path" 2>/dev/null
}

ensure_file_ends_with_newline() {
    local file_path="$1"
    local last_byte_hex=""

    [ -f "$file_path" ] || return 1
    [ -s "$file_path" ] || return 0

    last_byte_hex="$(tail -c 1 "$file_path" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')"
    [ -n "$last_byte_hex" ] || return 1

    if [ "$last_byte_hex" != "0a" ]; then
        printf "\n" >>"$file_path" || return 1
    fi

    return 0
}

persist_homebrew_shellenv_to_zprofile() {
    local profile_path="$HOME/.zprofile"
    local shellenv_line=""

    if ! shellenv_line="$(homebrew_shellenv_line 2>/dev/null)"; then
        return 1
    fi

    if file_contains_exact_line "$profile_path" "$shellenv_line"; then
        return 2
    fi

    if ! prompt_yes_no "是否将 Homebrew 环境写入 ~/.zprofile，以便以后打开终端即可直接使用 brew？" "y"; then
        return 10
    fi

    if [ ! -e "$profile_path" ] && ! : >"$profile_path"; then
        return 1
    fi

    ensure_file_ends_with_newline "$profile_path" || return 1

    if ! printf "%s\n" "$shellenv_line" >>"$profile_path"; then
        return 1
    fi

    initialize_homebrew_shellenv || return 1
    return 0
}

configure_homebrew_shellenv_persistence() {
    if [ "$(current_login_shell_name)" != "zsh" ]; then
        return 11
    fi

    persist_homebrew_shellenv_to_zprofile
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

is_positive_integer() {
    local value="${1:-}"

    case "$value" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$value" -gt 0 ]
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

ensure_homebrew_available() {
    if ! is_homebrew_installed; then
        print_message "未检测到 Homebrew，或 PATH 中找不到 brew。"
        return 1
    fi

    if initialize_homebrew_shellenv; then
        return 0
    fi

    print_message "已检测到 Homebrew 二进制，但当前 shell 无法初始化 Homebrew 环境。"
    print_message "请检查 brew shellenv 是否可正常执行。"
    return 1
}

require_homebrew_for_feature() {
    local feature_name="$1"

    if ensure_homebrew_available; then
        return 0
    fi

    print_status_message "warn" "当前 Homebrew 不可用，无法执行「${feature_name}」。"
    print_message "请先进入「环境与依赖」检查或安装 Homebrew。"
    return 1
}

is_xcode_command_line_tools_installed() {
    xcode-select -p >/dev/null 2>&1
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

plutil_extract_raw_value() {
    local file_path="$1"
    local key_path="$2"

    plutil -extract "$key_path" raw -o - "$file_path" 2>/dev/null
}

plutil_extract_array_count() {
    local file_path="$1"
    local key_path="$2"

    plutil -extract "$key_path" raw -expect array -o - "$file_path" 2>/dev/null
}

plutil_extract_string_array_values() {
    local file_path="$1"
    local key_path="$2"
    local count="0"
    local index=0
    local value=""

    count="$(plutil_extract_array_count "$file_path" "$key_path" 2>/dev/null || true)"
    if ! is_nonnegative_integer "$count"; then
        return 0
    fi

    while [ "$index" -lt "$count" ]; do
        value="$(plutil_extract_raw_value "$file_path" "$key_path.$index" 2>/dev/null || true)"
        if [ -n "$value" ]; then
            printf "%s\n" "$value"
        fi
        index=$((index + 1))
    done
}

disk_usage_kib_for_path() {
    local target_path="$1"
    du -sk "$target_path" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

collect_disk_usage_summary() {
    local total_kib=0
    local unreadable=0
    local count=0
    local target_path=""
    local path_kib=""

    for target_path in "$@"; do
        [ -n "$target_path" ] || continue
        count=$((count + 1))
        path_kib="$(disk_usage_kib_for_path "$target_path" 2>/dev/null || true)"
        if [ -n "$path_kib" ]; then
            total_kib=$((total_kib + path_kib))
        else
            unreadable=$((unreadable + 1))
        fi
    done

    printf "count=%s\n" "$count"
    printf "total_kib=%s\n" "$total_kib"
    printf "unreadable=%s" "$unreadable"
}

calculate_reclaimed_kib() {
    local before_kib="${1:-0}"
    local after_kib="${2:-0}"

    if ! is_positive_integer "$before_kib"; then
        before_kib=0
    fi

    if ! is_positive_integer "$after_kib"; then
        after_kib=0
    fi

    if [ "$before_kib" -le "$after_kib" ]; then
        printf "0"
        return 0
    fi

    printf "%s" $((before_kib - after_kib))
}

format_kib_human_readable() {
    local total_kib="$1"

    awk -v kib="$total_kib" '
        BEGIN {
            split("KiB MiB GiB TiB PiB", units, " ")
            value = kib + 0
            unit = 1
            while (value >= 1024 && unit < 5) {
                value /= 1024
                unit++
            }
            if (unit == 1 || value >= 10) {
                printf "%.0f %s", value, units[unit]
            } else {
                printf "%.1f %s", value, units[unit]
            }
        }
    '
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

prompt_for_multi_selection() {
    local title="$1"
    local prompt="$2"
    shift 2
    local items=("$@")
    local choice=""
    local parsed_choice=""

    PROMPT_MULTI_SELECT_RESULT=""

    while true; do
        print_page_title "$title"
        print_multi_select_hint
        render_numbered_list "selection" "${items[@]+"${items[@]}"}"
        print_blank_line
        printf "%s" "$prompt"
        if ! read -r choice; then
            PROMPT_MULTI_SELECT_RESULT="back"
            return 0
        fi

        parsed_choice="$(parse_multi_numeric_choice "$choice" "${#items[@]}")"
        case "$parsed_choice" in
            invalid)
                print_status_message "warn" "输入无效，请输入 all、空格分隔序号或 b。"
                pause_before_return
                ;;
            *)
                PROMPT_MULTI_SELECT_RESULT="$parsed_choice"
                return 0
                ;;
        esac
    done
}

populate_array_from_selection() {
    local array_name="$1"
    local parsed_choice="$2"
    shift 2
    local items=("$@")
    local token=""
    local index=0
    local item=""

    if ! reset_named_array "$array_name"; then
        return 1
    fi

    if [ "$parsed_choice" = "all" ]; then
        for item in "${items[@]+"${items[@]}"}"; do
            append_to_array "$array_name" "$item"
        done
        return 0
    fi

    for token in $parsed_choice; do
        index=$((token - 1))
        append_to_array "$array_name" "${items[$index]}"
    done
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

load_cask_app_name_from_receipt() {
    local receipt_path="$1"

    if ! load_cask_receipt_artifacts "$receipt_path"; then
        return 1
    fi

    if [ "${#CASK_RECEIPT_APP_ARTIFACTS[@]}" -eq 0 ]; then
        return 1
    fi

    strip_app_bundle_suffix "${CASK_RECEIPT_APP_ARTIFACTS[0]}"
    return 0
}

reset_cask_receipt_artifact_state() {
    CASK_RECEIPT_APP_ARTIFACTS=()
    CASK_RECEIPT_BINARY_ARTIFACTS=()
    CASK_RECEIPT_MANPAGE_ARTIFACTS=()
    CASK_RECEIPT_PKGUTIL_ARTIFACTS=()
    CASK_RECEIPT_LAUNCHCTL_ARTIFACTS=()
    CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS=()
}

load_cask_receipt_artifacts() {
    local receipt_path="$1"
    local artifact_count="0"
    local artifact_index=0
    local uninstall_count="0"
    local uninstall_index=0
    local value=""

    reset_cask_receipt_artifact_state

    if [ ! -f "$receipt_path" ]; then
        return 1
    fi

    artifact_count="$(plutil_extract_array_count "$receipt_path" "uninstall_artifacts" 2>/dev/null || true)"
    if ! is_nonnegative_integer "$artifact_count"; then
        return 1
    fi

    while [ "$artifact_index" -lt "$artifact_count" ]; do
        while IFS= read -r value; do
            [ -n "$value" ] || continue
            append_unique_to_array CASK_RECEIPT_APP_ARTIFACTS "$value"
        done < <(plutil_extract_string_array_values "$receipt_path" "uninstall_artifacts.$artifact_index.app")

        while IFS= read -r value; do
            [ -n "$value" ] || continue
            append_unique_to_array CASK_RECEIPT_BINARY_ARTIFACTS "$value"
        done < <(plutil_extract_string_array_values "$receipt_path" "uninstall_artifacts.$artifact_index.binary")

        while IFS= read -r value; do
            [ -n "$value" ] || continue
            append_unique_to_array CASK_RECEIPT_MANPAGE_ARTIFACTS "$value"
        done < <(plutil_extract_string_array_values "$receipt_path" "uninstall_artifacts.$artifact_index.manpage")

        uninstall_count="$(plutil_extract_array_count "$receipt_path" "uninstall_artifacts.$artifact_index.uninstall" 2>/dev/null || true)"
        if is_nonnegative_integer "$uninstall_count"; then
            uninstall_index=0
            while [ "$uninstall_index" -lt "$uninstall_count" ]; do
                value="$(plutil_extract_raw_value "$receipt_path" "uninstall_artifacts.$artifact_index.uninstall.$uninstall_index.pkgutil" 2>/dev/null || true)"
                if [ -n "$value" ]; then
                    append_unique_to_array CASK_RECEIPT_PKGUTIL_ARTIFACTS "$value"
                fi

                value="$(plutil_extract_raw_value "$receipt_path" "uninstall_artifacts.$artifact_index.uninstall.$uninstall_index.launchctl" 2>/dev/null || true)"
                if [ -n "$value" ]; then
                    append_unique_to_array CASK_RECEIPT_LAUNCHCTL_ARTIFACTS "$value"
                fi

                value="$(plutil_extract_raw_value "$receipt_path" "uninstall_artifacts.$artifact_index.uninstall.$uninstall_index.early_script.executable" 2>/dev/null || true)"
                if [ -n "$value" ]; then
                    append_unique_to_array CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS "$value"
                fi

                uninstall_index=$((uninstall_index + 1))
            done
        fi

        artifact_index=$((artifact_index + 1))
    done

    return 0
}

serialize_cask_receipt_artifact_state() {
    printf "apps=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_APP_ARTIFACTS[@]+"${CASK_RECEIPT_APP_ARTIFACTS[@]}"}" | join_lines)"
    printf "binaries=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_BINARY_ARTIFACTS[@]+"${CASK_RECEIPT_BINARY_ARTIFACTS[@]}"}" | join_lines)"
    printf "manpages=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]+"${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]}"}" | join_lines)"
    printf "pkgutil=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]+"${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]}"}" | join_lines)"
    printf "launchctl=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]+"${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]}"}" | join_lines)"
    printf "early_scripts=%s" "$(printf "%s\n" "${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]+"${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]}"}" | join_lines)"
}

reset_cask_postcheck_state() {
    CASK_POSTCHECK_RESIDUAL_DELETE_PATHS=()
    CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS=()
    CASK_POSTCHECK_CLEARED_ITEMS=()
    CASK_POSTCHECK_DELEGATED_ITEMS=()
}

reset_cask_uninstall_last_report_state() {
    CASK_UNINSTALL_LAST_CLEARED_ARTIFACTS=()
    CASK_UNINSTALL_LAST_DELETED_PATHS=()
    CASK_UNINSTALL_LAST_ELEVATED_DELETED_PATHS=()
    CASK_UNINSTALL_LAST_PERMISSION_SKIPPED_PATHS=()
    CASK_UNINSTALL_LAST_FAILED_PATHS=()
    CASK_UNINSTALL_LAST_MANUAL_ATTENTION_ITEMS=()
    CASK_UNINSTALL_LAST_DELEGATED_ITEMS=()
}

append_prefixed_items_to_array() {
    local array_name="$1"
    local prefix="$2"
    shift 2
    local item=""

    for item in "$@"; do
        [ -n "$item" ] || continue
        append_to_array "$array_name" "[$prefix] $item"
    done
}

derive_cask_binary_link_path() {
    local homebrew_prefix="$1"
    local source_path="$2"
    local binary_name=""

    [ -n "$homebrew_prefix" ] || return 1
    binary_name="$(basename "$source_path")"
    [ -n "$binary_name" ] || return 1
    printf "%s/bin/%s" "$homebrew_prefix" "$binary_name"
}

derive_cask_manpage_link_path() {
    local homebrew_prefix="$1"
    local source_path="$2"
    local section_dir=""
    local manpage_name=""

    [ -n "$homebrew_prefix" ] || return 1
    section_dir="$(basename "$(dirname "$source_path")")"
    manpage_name="$(basename "$source_path")"
    [ -n "$section_dir" ] || return 1
    [ -n "$manpage_name" ] || return 1
    printf "%s/share/man/%s/%s" "$homebrew_prefix" "$section_dir" "$manpage_name"
}

symlink_points_to_exact_path() {
    local link_path="$1"
    local expected_target="$2"
    local actual_target=""

    [ -L "$link_path" ] || return 1
    actual_target="$(readlink "$link_path" 2>/dev/null || true)"
    [ "$actual_target" = "$expected_target" ]
}

find_launchctl_plist_paths_for_label() {
    local label="$1"
    local candidate=""

    for candidate in \
        "/Library/LaunchDaemons/$label.plist" \
        "/Library/LaunchAgents/$label.plist" \
        "$HOME/Library/LaunchAgents/$label.plist"
    do
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            printf "%s\n" "$candidate"
        fi
    done
}

launchctl_label_exists() {
    local label="$1"
    local current_uid=""

    if ! command_exists launchctl; then
        return 1
    fi

    if launchctl print "system/$label" >/dev/null 2>&1; then
        return 0
    fi

    current_uid="$(id -u 2>/dev/null || true)"
    if is_nonnegative_integer "$current_uid" && launchctl print "gui/$current_uid/$label" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

pkgutil_receipts_matching_pattern() {
    local pattern="$1"
    local receipt=""

    if ! command_exists pkgutil; then
        return 0
    fi

    while IFS= read -r receipt; do
        [ -n "$receipt" ] || continue
        case "$receipt" in
            $pattern)
                printf "%s\n" "$receipt"
                ;;
        esac
    done < <(pkgutil --pkgs 2>/dev/null || true)
}

build_cask_managed_path_candidates() {
    local homebrew_prefix="$1"
    local app_path="$2"
    local source_path=""
    local derived_path=""

    [ -n "$app_path" ] && printf "%s\n" "$app_path"

    for source_path in "${CASK_RECEIPT_BINARY_ARTIFACTS[@]+"${CASK_RECEIPT_BINARY_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_binary_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        [ -n "$derived_path" ] && printf "%s\n" "$derived_path"
    done

    for source_path in "${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]+"${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_manpage_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        [ -n "$derived_path" ] && printf "%s\n" "$derived_path"
    done
}

build_cask_release_size_preview_paths() {
    local homebrew_prefix="$1"
    local cask="$2"
    local app_path="$3"
    shift 3
    local local_cleanup_candidates=("$@")
    local candidate=""
    local caskroom_entry=""

    {
        if [ -n "$app_path" ] && { [ -e "$app_path" ] || [ -L "$app_path" ]; }; then
            printf "%s\n" "$app_path"
        fi

        if [ -n "$homebrew_prefix" ]; then
            caskroom_entry="$homebrew_prefix/Caskroom/$cask"
            if [ -e "$caskroom_entry" ] || [ -L "$caskroom_entry" ]; then
                printf "%s\n" "$caskroom_entry"
            fi
        fi

        for candidate in "${local_cleanup_candidates[@]+"${local_cleanup_candidates[@]}"}"; do
            [ -n "$candidate" ] || continue
            printf "%s\n" "$candidate"
        done
    } | unique_lines | prune_nested_cask_candidates
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

build_cask_homebrew_managed_artifact_labels() {
    local homebrew_prefix="$1"
    local app_path="$2"
    local app_name="$3"
    local source_path=""
    local derived_path=""
    local label=""

    if [ -n "$app_path" ]; then
        printf "app: %s\n" "$app_path"
    elif [ -n "$app_name" ]; then
        printf "app: %s.app\n" "$app_name"
    fi

    for source_path in "${CASK_RECEIPT_BINARY_ARTIFACTS[@]+"${CASK_RECEIPT_BINARY_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_binary_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        if [ -n "$derived_path" ]; then
            printf "binary: %s\n" "$derived_path"
        fi
    done

    for source_path in "${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]+"${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_manpage_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        if [ -n "$derived_path" ]; then
            printf "manpage: %s\n" "$derived_path"
        fi
    done

    for label in "${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]+"${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]}"}"; do
        printf "launchctl: %s\n" "$label"
    done

    for label in "${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]+"${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]}"}"; do
        printf "pkgutil: %s\n" "$label"
    done

    for label in "${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]+"${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]}"}"; do
        printf "uninstall-script: %s\n" "$label"
    done
}

collect_cask_post_uninstall_artifact_state() {
    local homebrew_prefix="$1"
    local app_path="$2"
    local source_path=""
    local derived_path=""
    local label=""
    local pkg_receipts=""
    local plist_paths=""

    reset_cask_postcheck_state

    if [ -n "$app_path" ]; then
        if [ -e "$app_path" ] || [ -L "$app_path" ]; then
            append_unique_to_array CASK_POSTCHECK_RESIDUAL_DELETE_PATHS "$app_path"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "app: $app_path"
        fi
    fi

    for source_path in "${CASK_RECEIPT_BINARY_ARTIFACTS[@]+"${CASK_RECEIPT_BINARY_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_binary_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        [ -n "$derived_path" ] || continue
        if symlink_points_to_exact_path "$derived_path" "$source_path"; then
            append_unique_to_array CASK_POSTCHECK_RESIDUAL_DELETE_PATHS "$derived_path"
        elif [ -e "$derived_path" ] || [ -L "$derived_path" ]; then
            append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "binary: $derived_path"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "binary: $derived_path"
        fi
    done

    for source_path in "${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]+"${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_manpage_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        [ -n "$derived_path" ] || continue
        if symlink_points_to_exact_path "$derived_path" "$source_path"; then
            append_unique_to_array CASK_POSTCHECK_RESIDUAL_DELETE_PATHS "$derived_path"
        elif [ -e "$derived_path" ] || [ -L "$derived_path" ]; then
            append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "manpage: $derived_path"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "manpage: $derived_path"
        fi
    done

    for label in "${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]+"${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]}"}"; do
        plist_paths="$(find_launchctl_plist_paths_for_label "$label" 2>/dev/null || true)"
        if [ -n "$plist_paths" ]; then
            append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "launchctl: $label"
            while IFS= read -r derived_path; do
                [ -n "$derived_path" ] || continue
                append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "launchctl-plist: $derived_path"
            done <<< "$plist_paths"
        elif launchctl_label_exists "$label"; then
            append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "launchctl: $label"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "launchctl: $label"
        fi
    done

    for label in "${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]+"${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]}"}"; do
        pkg_receipts="$(pkgutil_receipts_matching_pattern "$label" 2>/dev/null || true)"
        if [ -n "$pkg_receipts" ]; then
            while IFS= read -r derived_path; do
                [ -n "$derived_path" ] || continue
                append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "pkgutil: $derived_path"
            done <<< "$pkg_receipts"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "pkgutil: $label"
        fi
    done

    for label in "${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]+"${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]}"}"; do
        append_unique_to_array CASK_POSTCHECK_DELEGATED_ITEMS "uninstall-script: $label"
    done
}

caskroom_entry_exists() {
    local cask="$1"
    local homebrew_prefix=""
    local caskroom_path=""

    homebrew_prefix="$(brew --prefix 2>/dev/null)" || return 2
    [ -n "$homebrew_prefix" ] || return 2
    caskroom_path="$homebrew_prefix/Caskroom/$cask"

    [ -d "$caskroom_path" ]
}

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

install_package_with_retries() {
    local package="$1"
    local logs_dir="$2"
    local status_dir="$3"
    local retry_count=0
    local success="0"
    local log_file="$logs_dir/${package}.log"
    local status_file="$status_dir/${package}.status"

    if brew list --cask "$package" >/dev/null 2>&1; then
        print_status_message "ok" "$package 已安装，跳过"
        printf "already-installed\n" >"$status_file"
        return 0
    fi

    while [ "$retry_count" -le "$INSTALL_MAX_RETRIES" ] && [ "$success" != "1" ]; do
        if [ "$retry_count" -gt 0 ]; then
            print_status_message "warn" "重试安装 ${package}（第 $retry_count 次）"
            sleep 3
        else
            print_status_message "info" "开始安装 $package"
        fi

        if brew install --cask "$package" >"$log_file" 2>&1; then
            print_status_message "ok" "$package 安装成功"
            success="1"
            break
        fi

        if brew list --cask "$package" >/dev/null 2>&1; then
            print_status_message "ok" "$package 已处于安装状态"
            success="1"
            break
        fi

        retry_count=$((retry_count + 1))
    done

    if [ "$success" = "1" ]; then
        if grep -qi "already installed" "$log_file" 2>/dev/null; then
            printf "already-installed\n" >"$status_file"
        else
            printf "installed\n" >"$status_file"
        fi
        return 0
    fi

    print_status_message "err" "$package 安装失败（已重试 $INSTALL_MAX_RETRIES 次）"
    printf "failed\n" >"$status_file"
    return 1
}

install_packages_serially() {
    local logs_dir="$1"
    local status_dir="$2"
    local package=""

    for package in "${INSTALLABLE_CASKS[@]+"${INSTALLABLE_CASKS[@]}"}"; do
        [ -n "$package" ] || continue
        install_package_with_retries "$package" "$logs_dir" "$status_dir"
    done
}

build_install_parallel_command() {
    local logs_dir="$1"
    local status_dir="$2"
    local package=""
    local command_script=""
    local escaped_script_path=""
    local escaped_package=""
    local escaped_logs_dir=""
    local escaped_status_dir=""

    printf -v escaped_script_path '%q' "$MANAGER_SCRIPT_PATH"
    printf -v escaped_logs_dir '%q' "$logs_dir"
    printf -v escaped_status_dir '%q' "$status_dir"

    for package in "${INSTALLABLE_CASKS[@]+"${INSTALLABLE_CASKS[@]}"}"; do
        [ -n "$package" ] || continue
        printf -v escaped_package '%q' "$package"
        command_script="${command_script}bash -c 'source $escaped_script_path && install_package_with_retries $escaped_package $escaped_logs_dir $escaped_status_dir'"$'\n'
    done

    printf "%s" "$command_script"
}

install_packages_with_parallel() {
    local logs_dir="$1"
    local status_dir="$2"
    local command_script=""

    command_script="$(build_install_parallel_command "$logs_dir" "$status_dir")"
    if [ -z "$command_script" ]; then
        return 0
    fi

    printf "%s" "$command_script" | parallel -j "$INSTALL_PARALLEL_JOBS"
}

print_installation_summary() {
    local logs_dir="$1"
    local status_dir="$2"
    local executor_status="${3:-0}"
    local total="${#INSTALLABLE_CASKS[@]}"
    local installed_count=0
    local already_installed_count=0
    local failed_count=0
    local unknown_count=0
    local package=""
    local package_status=""
    local status_file=""
    local failed_packages=()
    local unknown_packages=()

    for package in "${INSTALLABLE_CASKS[@]+"${INSTALLABLE_CASKS[@]}"}"; do
        [ -n "$package" ] || continue
        status_file="$status_dir/${package}.status"
        if [ ! -f "$status_file" ]; then
            unknown_count=$((unknown_count + 1))
            unknown_packages+=("$package")
            continue
        fi

        package_status="$(head -n 1 "$status_file" 2>/dev/null || true)"
        case "$package_status" in
            installed)
                installed_count=$((installed_count + 1))
                ;;
            already-installed)
                already_installed_count=$((already_installed_count + 1))
                ;;
            failed)
                failed_count=$((failed_count + 1))
                failed_packages+=("$package")
                ;;
            *)
                unknown_count=$((unknown_count + 1))
                unknown_packages+=("$package")
                ;;
        esac
    done

    print_page_title "安装项目总结"
    print_message "计划安装数量：$total"
    print_message "新安装数量：$installed_count"
    print_message "已满足数量：$already_installed_count"
    print_message "安装失败数量：$failed_count"
    print_message "结果未知数量：$unknown_count"
    print_message "日志目录：$logs_dir"

    if [ "$executor_status" -ne 0 ]; then
        print_status_message "warn" "安装执行器返回非零状态，部分 worker 可能在写入结果前异常退出。"
    fi

    if [ "$failed_count" -gt 0 ]; then
        print_message "安装失败项目："
        for package in "${failed_packages[@]+"${failed_packages[@]}"}"; do
            print_message "- ${package}（日志：$logs_dir/$package.log）"
        done
    fi

    if [ "$unknown_count" -gt 0 ]; then
        print_message "结果未知项目："
        for package in "${unknown_packages[@]+"${unknown_packages[@]}"}"; do
            print_message "- ${package}（日志：$logs_dir/$package.log）"
        done
    fi
}

run_install_flow() {
    if ! require_homebrew_for_feature "安装项目"; then
        return 0
    fi

    local logs_dir=""
    local status_dir=""
    local total="${#INSTALLABLE_CASKS[@]}"
    local executor_status=0

    print_page_title "安装项目"
    print_message "将按内置清单安装以下 Homebrew cask 项目："
    print_compact_value_list "待安装项目：" "${INSTALLABLE_CASKS[@]+"${INSTALLABLE_CASKS[@]}"}"
    print_message "计划安装数量：$total"
    if command_exists parallel; then
        print_message "执行模式：并行安装（$INSTALL_PARALLEL_JOBS 个任务）"
    else
        print_message "执行模式：串行安装（未检测到 parallel）"
    fi
    print_message "失败重试次数：$INSTALL_MAX_RETRIES"

    if ! prompt_yes_no "是否继续安装这些项目？" "n"; then
        print_message "已取消安装。"
        return 0
    fi

    if ! logs_dir="$(mktemp -d "${TMPDIR:-/tmp}/brew-app-manager-install.XXXXXX")"; then
        print_status_message "err" "未能创建安装日志目录，已取消安装。"
        return 1
    fi
    status_dir="$logs_dir/status"
    if ! mkdir -p "$status_dir"; then
        print_status_message "err" "未能创建安装状态目录，已取消安装。"
        rmdir "$logs_dir" >/dev/null 2>&1 || true
        return 1
    fi

    print_output_boundary "开始执行安装"
    if command_exists parallel; then
        install_packages_with_parallel "$logs_dir" "$status_dir"
        executor_status="$?"
    else
        install_packages_serially "$logs_dir" "$status_dir"
        executor_status="$?"
    fi
    print_output_boundary "安装执行结束"

    print_installation_summary "$logs_dir" "$status_dir" "$executor_status"
}

brew_dependencies_for_formula() {
    local formula="$1"
    brew deps --installed "$formula" 2>/dev/null
}

brew_installed_users_for_formula() {
    local dependency="$1"
    brew uses --installed "$dependency" 2>/dev/null
}

exclude_formula_users_from_removal_set() {
    local users_text="$1"
    shift
    local removal_set=("$@")
    local user=""
    local kept_users=()

    while IFS= read -r user; do
        [ -n "$user" ] || continue
        if array_contains_exact "$user" "${removal_set[@]+"${removal_set[@]}"}"; then
            continue
        fi
        kept_users+=("$user")
    done <<< "$users_text"

    printf "%s\n" "${kept_users[@]+"${kept_users[@]}"}"
}

reset_formula_plan_state() {
    FORMULA_PLAN_TARGET=""
    FORMULA_PLAN_DEPENDENCIES=()
    FORMULA_PLAN_ORPHANS=()
}

serialize_formula_plan_state() {
    printf "target=%s\n" "$FORMULA_PLAN_TARGET"
    printf "dependencies=%s\n" "$(printf "%s\n" "${FORMULA_PLAN_DEPENDENCIES[@]+"${FORMULA_PLAN_DEPENDENCIES[@]}"}" | join_lines)"
    printf "orphans=%s" "$(printf "%s\n" "${FORMULA_PLAN_ORPHANS[@]+"${FORMULA_PLAN_ORPHANS[@]}"}" | join_lines)"
}

load_formula_uninstall_plan() {
    local formula="$1"
    local direct_dependency=""
    local dependencies=()
    local orphan_candidates=()
    local pending_dependencies=()
    local seen_dependencies=()
    local removal_set=()
    local dependency=""
    local dependency_users=""
    local remaining_users=""
    local dependency_users_array=()
    local child_dependencies=()
    local index=0
    local child_dependency=""

    reset_formula_plan_state
    removal_set=("$formula")

    if ! read_command_output_into_array dependencies brew_dependencies_for_formula "$formula"; then
        return 1
    fi

    for direct_dependency in "${dependencies[@]+"${dependencies[@]}"}"; do
        [ -n "$direct_dependency" ] || continue
        pending_dependencies+=("$direct_dependency")
    done

    while [ "$index" -lt "${#pending_dependencies[@]}" ]; do
        dependency="${pending_dependencies[$index]}"
        index=$((index + 1))

        if array_contains_exact "$dependency" "${seen_dependencies[@]+"${seen_dependencies[@]}"}"; then
            continue
        fi
        seen_dependencies+=("$dependency")

        if ! read_command_output_into_array dependency_users_array brew_installed_users_for_formula "$dependency"; then
            return 1
        fi

        dependency_users="$(printf "%s\n" "${dependency_users_array[@]+"${dependency_users_array[@]}"}")"
        remaining_users="$(exclude_formula_users_from_removal_set "$dependency_users" "${removal_set[@]+"${removal_set[@]}"}")"

        if [ -n "$remaining_users" ]; then
            continue
        fi

        orphan_candidates+=("$dependency")
        removal_set+=("$dependency")
        if ! read_command_output_into_array child_dependencies brew_dependencies_for_formula "$dependency"; then
            return 1
        fi

        for child_dependency in "${child_dependencies[@]+"${child_dependencies[@]}"}"; do
            [ -n "$child_dependency" ] || continue
            if array_contains_exact "$child_dependency" "${seen_dependencies[@]+"${seen_dependencies[@]}"}"; then
                continue
            fi
            pending_dependencies+=("$child_dependency")
        done
    done

    FORMULA_PLAN_TARGET="$formula"
    FORMULA_PLAN_DEPENDENCIES=("${dependencies[@]+"${dependencies[@]}"}")
    FORMULA_PLAN_ORPHANS=("${orphan_candidates[@]+"${orphan_candidates[@]}"}")
}

collect_formula_uninstall_plan() {
    if ! load_formula_uninstall_plan "$1"; then
        return 1
    fi

    serialize_formula_plan_state
}

stop_formula_service_if_needed() {
    local formula="$1"
    brew services stop "$formula" >/dev/null 2>&1 || true
}

collect_formula_managed_paths() {
    local formula="$1"
    local formula_prefix=""
    local formula_cellar=""
    local homebrew_prefix=""

    formula_prefix="$(brew --prefix "$formula" 2>/dev/null)" || return 1
    formula_cellar="$(brew --cellar "$formula" 2>/dev/null)" || return 1
    homebrew_prefix="$(brew --prefix 2>/dev/null)" || return 1

    {
        [ -n "$formula_prefix" ] && [ -e "$formula_prefix" ] && printf "%s\n" "$formula_prefix"
        [ -n "$formula_cellar" ] && [ -e "$formula_cellar" ] && printf "%s\n" "$formula_cellar"
        if [ -n "$homebrew_prefix" ] && [ -e "$homebrew_prefix/etc/$formula" ]; then
            printf "%s\n" "$homebrew_prefix/etc/$formula"
        fi
        if [ -n "$homebrew_prefix" ] && [ -e "$homebrew_prefix/var/$formula" ]; then
            printf "%s\n" "$homebrew_prefix/var/$formula"
        fi
    } | unique_lines
}

print_formula_plan() {
    local formula="${1:-$FORMULA_PLAN_TARGET}"
    local title="${2:-Formula 卸载扫描结果}"
    local managed_paths=()
    local managed_paths_status=0

    read_command_output_into_array managed_paths collect_formula_managed_paths "$formula"
    managed_paths_status="$?"

    print_page_title "$title"
    print_message "目标：$formula"
    print_compact_value_list "直接依赖：" "${FORMULA_PLAN_DEPENDENCIES[@]+"${FORMULA_PLAN_DEPENDENCIES[@]}"}"
    print_compact_value_list "可一并移除的孤儿依赖：" "${FORMULA_PLAN_ORPHANS[@]+"${FORMULA_PLAN_ORPHANS[@]}"}"

    if [ "$managed_paths_status" -ne 0 ]; then
        print_message "相关 Homebrew 管理路径：<scan-failed>"
        print_status_message "warn" "未能扫描这个 formula 的 Homebrew 管理路径。"
    elif [ "${#managed_paths[@]}" -gt 0 ]; then
        print_message "相关 Homebrew 管理路径："
        printf "%s\n" "${managed_paths[@]+"${managed_paths[@]}"}"
    else
        print_message "相关 Homebrew 管理路径：<none>"
    fi
}

run_formula_uninstall_flow() {
    local formula="$1"
    local orphan=""
    local removed=()
    local skipped=()
    local main_uninstall_succeeded="0"

    stop_formula_service_if_needed "$formula"

    if brew uninstall "$formula"; then
        removed+=("$formula")
        main_uninstall_succeeded="1"
    else
        skipped+=("$formula")
    fi

    if [ "$main_uninstall_succeeded" != "1" ]; then
        print_page_title "Formula 卸载总结"
        print_message "已移除：${removed[*]:-<none>}"
        print_message "已跳过：${skipped[*]:-<none>}"
        print_message "主 formula 卸载失败，未继续移除孤儿依赖，也未执行 brew autoremove。"
        return 1
    fi

    for orphan in "${FORMULA_PLAN_ORPHANS[@]+"${FORMULA_PLAN_ORPHANS[@]}"}"; do
        if brew list --formula "$orphan" >/dev/null 2>&1; then
            if brew uninstall "$orphan"; then
                removed+=("$orphan")
            else
                skipped+=("$orphan")
            fi
        fi
    done

    brew autoremove >/dev/null 2>&1 || true

    print_page_title "Formula 卸载总结"
    print_message "已移除：${removed[*]:-<none>}"
    print_message "已跳过：${skipped[*]:-<none>}"

    if brew list --formula "$formula" >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

run_formula_uninstall_batch() {
    local formulas=("$@")
    local total="${#formulas[@]}"
    local index=0
    local formula=""
    local removed_targets=()
    local skipped_targets=()

    for formula in "${formulas[@]+"${formulas[@]}"}"; do
        [ -n "$formula" ] || continue
        index=$((index + 1))

        if ! brew list --formula "$formula" >/dev/null 2>&1; then
            print_page_title "Formula 卸载扫描结果 $index/$total"
            print_status_message "skip" "formula 未安装，跳过：$formula"
            skipped_targets+=("$formula")
            continue
        fi

        if ! load_formula_uninstall_plan "$formula"; then
            print_page_title "Formula 卸载扫描结果 $index/$total"
            print_status_message "err" "未能生成 formula 卸载计划，已跳过：$formula"
            print_message "请检查 brew deps / brew uses 是否能正常返回该项目的依赖关系。"
            skipped_targets+=("$formula")
            continue
        fi
        print_formula_plan "$formula" "Formula 卸载扫描结果 $index/$total"

        if ! prompt_yes_no "是否继续卸载这个 formula，并按上面扫描结果移除可清理的孤儿依赖？" "n"; then
            print_status_message "skip" "已跳过当前 formula：$formula"
            skipped_targets+=("$formula")
            continue
        fi

        if run_formula_uninstall_flow "$formula"; then
            removed_targets+=("$formula")
        else
            skipped_targets+=("$formula")
        fi
    done

    print_page_title "Formula 批量卸载总结"
    print_message "选择目标数量：$total"
    print_message "成功卸载目标数量：${#removed_targets[@]}"
    print_message "跳过或失败目标数量：${#skipped_targets[@]}"
    print_compact_value_list "已卸载目标：" "${removed_targets[@]+"${removed_targets[@]}"}"
    print_compact_value_list "未完成目标：" "${skipped_targets[@]+"${skipped_targets[@]}"}"
}

reset_cask_metadata_state() {
    CASK_METADATA_TOKEN=""
    CASK_METADATA_APP_NAME=""
    CASK_METADATA_ZAP_PATHS=()
}

load_cask_metadata_from_json() {
    local json_path="$1"
    local artifact_count="0"
    local artifact_index=0
    local zap_count="0"
    local zap_index=0
    local trash_key_path=""
    local trash_path=""
    local raw_app_name=""

    reset_cask_metadata_state
    CASK_METADATA_TOKEN="$(plutil_extract_raw_value "$json_path" "casks.0.token" 2>/dev/null || true)"
    if [ -z "$CASK_METADATA_TOKEN" ]; then
        return 1
    fi

    artifact_count="$(plutil_extract_array_count "$json_path" "casks.0.artifacts" 2>/dev/null || true)"
    if ! is_nonnegative_integer "$artifact_count"; then
        artifact_count=0
    fi

    while [ "$artifact_index" -lt "$artifact_count" ]; do
        if [ -z "$CASK_METADATA_APP_NAME" ]; then
            raw_app_name="$(plutil_extract_raw_value "$json_path" "casks.0.artifacts.$artifact_index.app.0" 2>/dev/null || true)"
            if [ -n "$raw_app_name" ]; then
                CASK_METADATA_APP_NAME="$(strip_app_bundle_suffix "$raw_app_name")"
            fi
        fi

        zap_count="$(plutil_extract_array_count "$json_path" "casks.0.artifacts.$artifact_index.zap" 2>/dev/null || true)"
        if is_nonnegative_integer "$zap_count"; then
            zap_index=0
            while [ "$zap_index" -lt "$zap_count" ]; do
                trash_key_path="casks.0.artifacts.$artifact_index.zap.$zap_index.trash"
                while IFS= read -r trash_path; do
                    [ -n "$trash_path" ] || continue
                    append_to_array CASK_METADATA_ZAP_PATHS "$(expand_home_path "$trash_path")"
                done < <(plutil_extract_string_array_values "$json_path" "$trash_key_path")
                zap_index=$((zap_index + 1))
            done
        fi

        artifact_index=$((artifact_index + 1))
    done

    return 0
}

serialize_cask_metadata_state() {
    printf "token=%s\n" "$CASK_METADATA_TOKEN"
    printf "app_name=%s\n" "$CASK_METADATA_APP_NAME"
    printf "zap_paths=%s" "$(printf "%s\n" "${CASK_METADATA_ZAP_PATHS[@]+"${CASK_METADATA_ZAP_PATHS[@]}"}" | join_lines)"
}

parse_cask_metadata_from_json() {
    if ! load_cask_metadata_from_json "$1"; then
        return 1
    fi

    serialize_cask_metadata_state
}

load_cask_zap_paths_from_json() {
    if ! load_cask_metadata_from_json "$1"; then
        return 1
    fi

    printf "%s\n" "${CASK_METADATA_ZAP_PATHS[@]+"${CASK_METADATA_ZAP_PATHS[@]}"}"
}

build_cask_temp_scan_roots() {
    local temp_root="${TMPDIR:-}"
    local temp_parent=""

    if [ -z "$temp_root" ]; then
        return 0
    fi

    temp_root="${temp_root%/}"
    temp_parent="$(dirname "$temp_root")"

    [ -d "$temp_parent" ] && printf "%s\n" "$temp_parent"
    [ -d "$temp_parent/C" ] && printf "%s\n" "$temp_parent/C"
    [ -d "$temp_parent/T" ] && printf "%s\n" "$temp_parent/T"
    [ -d "$temp_parent/X" ] && printf "%s\n" "$temp_parent/X"

    return 0
}

build_cask_scan_roots() {
    {
        cat <<EOF
/Applications
$HOME/Applications
/Library/Application Support
$HOME/Library/Application Support
$HOME/Library/Application Scripts
$HOME/Library/Caches
$HOME/Library/Cookies
$HOME/Library/Containers
$HOME/Library/HTTPStorages
/Library/LaunchAgents
/Library/LaunchDaemons
$HOME/Library/Preferences
$HOME/Library/Logs
$HOME/Library/LaunchAgents
$HOME/Library/Group Containers
$HOME/Library/Saved Application State
$HOME/Library/WebKit
/Library/PrivilegedHelperTools
/private/var/db/receipts
EOF
        build_cask_temp_scan_roots
    } | unique_lines
}

create_temp_cask_metadata_file() {
    mktemp "${TMPDIR:-/tmp}/brew-app-manager-cask.XXXXXX"
}

is_valid_bundle_identifier() {
    local bundle_id="$1"

    case "$bundle_id" in
        ''|*[!A-Za-z0-9.-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

fetch_cask_metadata_json() {
    local cask="$1"
    local temp_json=""

    if ! temp_json="$(create_temp_cask_metadata_file 2>/dev/null)"; then
        return 2
    fi
    [ -n "$temp_json" ] || return 2

    if brew info "$cask" --json=v2 >"$temp_json" 2>/dev/null; then
        printf "%s" "$temp_json"
        return 0
    fi

    rm -f "$temp_json"
    return 1
}

find_app_bundle_path() {
    local app_name="$1"
    local candidate=""
    local escaped_app_name=""

    for candidate in \
        "/Applications/$app_name.app" \
        "$HOME/Applications/$app_name.app"
    do
        if [ -d "$candidate" ]; then
            printf "%s" "$candidate"
            return 0
        fi
    done

    if command_exists mdfind; then
        escaped_app_name="${app_name//\\/\\\\}"
        escaped_app_name="${escaped_app_name//\"/\\\"}"

        while IFS= read -r candidate; do
            [ -d "$candidate" ] || continue
            case "$candidate" in
                *.app)
                    printf "%s" "$candidate"
                    return 0
                    ;;
            esac
        done < <(mdfind "kMDItemFSName == \"$escaped_app_name.app\"" 2>/dev/null || true)
    fi

    return 1
}

get_bundle_identifier_for_app_path() {
    local app_path="$1"
    local bundle_id=""

    if [ ! -d "$app_path" ]; then
        return 1
    fi

    bundle_id="$(mdls -name kMDItemCFBundleIdentifier -raw "$app_path" 2>/dev/null || true)"

    if [ -n "$bundle_id" ] && [ "$bundle_id" != "(null)" ] && is_valid_bundle_identifier "$bundle_id"; then
        printf "%s" "$bundle_id"
        return 0
    fi

    if [ -f "$app_path/Contents/Info.plist" ]; then
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
        if [ -n "$bundle_id" ] && is_valid_bundle_identifier "$bundle_id"; then
            printf "%s" "$bundle_id"
            return 0
        fi
    fi

    return 1
}

build_cask_candidate_patterns() {
    local app_name="$1"
    local bundle_id="$2"

    {
        [ -n "$app_name" ] && printf "%s\n" "/Applications/$app_name.app"
        [ -n "$app_name" ] && printf "%s\n" "$HOME/Applications/$app_name.app"
        [ -n "$app_name" ] && printf "%s\n" "$HOME/Library/Application Support/$app_name"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/Application Support/$bundle_id"
        [ -n "$app_name" ] && printf "%s\n" "/Library/Application Support/$app_name"
        [ -n "$bundle_id" ] && printf "%s\n" "/Library/Application Support/$bundle_id"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/Application Scripts/$bundle_id"
        [ -n "$app_name" ] && printf "%s\n" "$HOME/Library/Caches/$app_name"
        [ -n "$app_name" ] && printf "%s\n" "$HOME/Library/Logs/$app_name"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/Caches/$bundle_id"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/Containers/$bundle_id"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/HTTPStorages/$bundle_id"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/Cookies/$bundle_id.binarycookies"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/Preferences/$bundle_id.plist"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/Saved Application State/$bundle_id.savedState"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/WebKit/$bundle_id"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/LaunchAgents/${bundle_id}"'*.plist'
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/Logs/DiagnosticReports/*$bundle_id*"
        [ -n "$bundle_id" ] && printf "%s\n" "/Library/LaunchAgents/*$bundle_id*.plist"
        [ -n "$bundle_id" ] && printf "%s\n" "/Library/LaunchDaemons/*$bundle_id*.plist"
        [ -n "$bundle_id" ] && printf "%s\n" "/Library/PrivilegedHelperTools/*$bundle_id*"
        [ -n "$bundle_id" ] && printf "%s\n" "$HOME/Library/Group Containers/*$bundle_id*"
        [ -n "$bundle_id" ] && printf "%s\n" "/private/var/db/receipts/*$bundle_id*"
    }

    return 0
}

build_cask_temp_candidate_patterns() {
    local app_name="$1"
    local bundle_id="$2"
    local temp_root="${TMPDIR:-}"
    local temp_parent=""

    if [ -z "$temp_root" ]; then
        return 0
    fi

    temp_root="${temp_root%/}"
    temp_parent="$(dirname "$temp_root")"

    {
        [ -n "$bundle_id" ] && printf "%s\n" "$temp_parent/C/*$bundle_id*"
        [ -n "$bundle_id" ] && printf "%s\n" "$temp_parent/T/*$bundle_id*"
        [ -n "$bundle_id" ] && printf "%s\n" "$temp_parent/X/*$bundle_id*"
    }

    return 0
}

expand_existing_glob() {
    local pattern="$1"
    compgen -G "$pattern" 2>/dev/null || true
}

pattern_contains_glob() {
    local pattern="$1"

    case "$pattern" in
        *'*'*|*'?'*|*'['*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

emit_existing_path_matches() {
    local pattern="$1"

    if pattern_contains_glob "$pattern"; then
        expand_existing_glob "$pattern"
        return 0
    fi

    if [ -e "$pattern" ] || [ -L "$pattern" ]; then
        printf "%s\n" "$pattern"
    fi
}

should_exclude_cask_candidate() {
    local candidate="$1"

    case "$candidate" in
        */com.nektony.App-Cleaner-S*/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

filter_cask_candidates() {
    local candidate=""

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if should_exclude_cask_candidate "$candidate"; then
            continue
        fi
        printf "%s\n" "$candidate"
    done
}

is_descendant_path() {
    local candidate="$1"
    local parent="$2"

    case "$candidate" in
        "$parent"/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

prune_nested_cask_candidates() {
    local candidate=""
    local candidates=()
    local kept=()
    local existing=""
    local should_skip="0"
    local sorted_candidates=""

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        candidates+=("$candidate")
    done

    if [ "${#candidates[@]}" -eq 0 ]; then
        return 0
    fi

    sorted_candidates="$(printf "%s\n" "${candidates[@]+"${candidates[@]}"}" | awk 'NF { print length($0) "\t" $0 }' | sort -n | cut -f2-)"

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        should_skip="0"

        if [ "${#kept[@]}" -gt 0 ]; then
            for existing in "${kept[@]+"${kept[@]}"}"; do
                if is_descendant_path "$candidate" "$existing"; then
                    should_skip="1"
                    break
                fi
            done
        fi

        if [ "$should_skip" = "1" ]; then
            continue
        fi

        kept+=("$candidate")
        printf "%s\n" "$candidate"
    done < <(printf "%s\n" "$sorted_candidates")
}

build_cask_scan_terms() {
    local app_name="$1"
    local bundle_id="$2"
    local trimmed_app_name=""

    trimmed_app_name="$(trim_whitespace "$app_name")"

    {
        [ -n "$bundle_id" ] && printf "%s\n" "$bundle_id"
        if [ -z "$bundle_id" ] && [ "${#trimmed_app_name}" -ge 4 ]; then
            printf "%s\n" "$trimmed_app_name"
        fi
    } | unique_lines

    return 0
}

scan_cask_roots_for_terms() {
    local app_name="$1"
    local bundle_id="$2"
    local root=""
    local term=""

    while IFS= read -r root; do
        [ -d "$root" ] || continue

        while IFS= read -r term; do
            [ -n "$term" ] || continue
            find "$root" -mindepth 1 -maxdepth 3 -iname "*$term*" -print 2>/dev/null || true
        done < <(build_cask_scan_terms "$app_name" "$bundle_id")
    done < <(build_cask_scan_roots)
}

collect_cask_cleanup_candidates() {
    local app_name="$1"
    local bundle_id="$2"
    local json_path="$3"
    local pattern=""

    {
        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            emit_existing_path_matches "$pattern"
        done < <(build_cask_candidate_patterns "$app_name" "$bundle_id")

        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            emit_existing_path_matches "$pattern"
        done < <(build_cask_temp_candidate_patterns "$app_name" "$bundle_id")

        if [ -n "$json_path" ] && [ -f "$json_path" ]; then
            while IFS= read -r pattern; do
                [ -n "$pattern" ] || continue
                emit_existing_path_matches "$pattern"
            done < <(load_cask_zap_paths_from_json "$json_path")
        fi

        scan_cask_roots_for_terms "$app_name" "$bundle_id"
    } | filter_cask_candidates | prune_nested_cask_candidates | unique_lines
}

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

run_formula_selection_menu() {
    local formulas=()
    local selected_formulas=()
    local parsed_choice=""

    while true; do
        if ! read_command_output_into_array formulas load_formula_inventory; then
            print_command_query_failure "已安装 formula 列表" "brew list --formula"
            pause_before_return
            return 0
        fi
        if [ "${#formulas[@]}" -eq 0 ]; then
            print_message "当前没有已安装的 formula 项目。"
            pause_before_return
            return 0
        fi

        prompt_for_multi_selection "当前已安装的 formula 列表" "请输入选择（all / 序号 / b）: " "${formulas[@]+"${formulas[@]}"}"
        parsed_choice="$PROMPT_MULTI_SELECT_RESULT"
        if [ "$parsed_choice" = "back" ]; then
            return 0
        fi

        populate_array_from_selection selected_formulas "$parsed_choice" "${formulas[@]+"${formulas[@]}"}"
        print_page_title "Formula 批量卸载确认"
        print_compact_value_list "已选择的 formula：" "${selected_formulas[@]+"${selected_formulas[@]}"}"

        if prompt_yes_no "是否继续卸载这些 formula，并按当前依赖关系逐个处理？" "n"; then
            run_formula_uninstall_batch "${selected_formulas[@]+"${selected_formulas[@]}"}"
        else
            print_message "已取消 Formula 批量卸载。"
        fi

        pause_before_return
    done
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

run_install_xcode_command_line_tools_flow() {
    print_page_title "安装 Xcode Command Line Tools"

    if is_xcode_command_line_tools_installed; then
        print_status_message "ok" "已检测到 Xcode Command Line Tools。"
        return 0
    fi

    print_status_message "info" "当前未检测到 Xcode Command Line Tools。"
    print_message "将调用系统安装器：xcode-select --install"

    if ! prompt_yes_no "是否继续唤起系统安装器？" "n"; then
        print_status_message "skip" "已取消安装 Xcode Command Line Tools。"
        return 1
    fi

    if ! xcode-select --install >/dev/null 2>&1; then
        print_status_message "err" "未能成功发起 Xcode Command Line Tools 系统安装器。"
        print_message "请手动执行 xcode-select --install，或检查当前系统是否禁止重复发起安装。"
        return 1
    fi
    print_status_message "info" "系统安装器已发起，请在弹出的窗口中完成安装。"

    while ! is_xcode_command_line_tools_installed; do
        if ! prompt_yes_no "安装完成后是否立即重新检测？选择 n 返回。" "y"; then
            print_status_message "skip" "尚未完成 Xcode Command Line Tools 安装。"
            return 1
        fi

        if ! is_xcode_command_line_tools_installed; then
            print_status_message "warn" "尚未检测到 Xcode Command Line Tools，请先完成系统安装。"
        fi
    done

    print_status_message "ok" "已检测到 Xcode Command Line Tools。"
    return 0
}

run_install_homebrew_flow() {
    local install_status="failed"
    local install_script_path=""
    local version_line=""
    local shellenv_line=""
    local shell_name=""
    local shellenv_config_status=1

    print_page_title "安装 Homebrew"

    if is_homebrew_installed; then
        if initialize_homebrew_shellenv; then
            print_status_message "ok" "已检测到 Homebrew。"
            if command_exists brew; then
                print_message "$(brew --version | head -n 1)"
            fi
        else
            print_status_message "warn" "已检测到 Homebrew 二进制，但当前 shell 无法初始化 Homebrew 环境。"
            print_message "请先确认 brew shellenv 可正常执行，再决定是否重新安装。"
        fi
        return 0
    fi

    print_status_message "info" "当前未检测到 Homebrew。"

    if ! is_xcode_command_line_tools_installed; then
        print_status_message "warn" "安装 Homebrew 前需要先安装 Xcode Command Line Tools。"
        if ! prompt_yes_no "是否先安装 Xcode Command Line Tools？" "y"; then
            print_status_message "skip" "已取消安装 Homebrew。"
            return 0
        fi

        if ! run_install_xcode_command_line_tools_flow; then
            print_status_message "warn" "尚未完成 Xcode Command Line Tools 安装，暂不继续安装 Homebrew。"
            return 0
        fi

        if ! prompt_yes_no "Xcode Command Line Tools 已就绪，是否继续安装 Homebrew？" "n"; then
            print_status_message "skip" "已取消安装 Homebrew。"
            return 0
        fi
    else
        if ! prompt_yes_no "是否继续安装 Homebrew？" "n"; then
            print_status_message "skip" "已取消安装 Homebrew。"
            return 0
        fi
    fi

    if ! install_script_path="$(mktemp "${TMPDIR:-/tmp}/brew-install-script.XXXXXX")"; then
        print_status_message "err" "未能创建 Homebrew 安装脚本临时文件，已取消安装。"
        return 1
    fi
    print_message "安装脚本来源：$HOMEBREW_INSTALL_SCRIPT_URL"
    print_message "已钉住 Homebrew/install 提交：$HOMEBREW_INSTALL_SCRIPT_REF"
    print_output_boundary "开始执行 Homebrew 官方安装脚本"
    if curl -fsSL "$HOMEBREW_INSTALL_SCRIPT_URL" -o "$install_script_path" && /bin/bash "$install_script_path"; then
        install_status="success"
        initialize_homebrew_shellenv || true
    fi
    print_output_boundary "Homebrew 官方安装脚本执行结束"
    rm -f "$install_script_path"

    print_page_title "安装 Homebrew 总结"
    if [ "$install_status" = "success" ] && ensure_homebrew_available; then
        version_line="$(brew --version | head -n 1 2>/dev/null || true)"
        shell_name="$(current_login_shell_name)"
        shellenv_line="$(homebrew_shellenv_line 2>/dev/null || true)"
        configure_homebrew_shellenv_persistence
        shellenv_config_status="$?"

        print_status_message "ok" "Homebrew 安装完成。"
        if [ -n "$version_line" ]; then
            print_message "版本：$version_line"
        fi

        case "$shellenv_config_status" in
            0)
                print_status_message "ok" "Homebrew 环境已配置完成。以后重新打开终端即可直接使用 brew。"
                ;;
            2)
                print_status_message "ok" "Homebrew 环境已配置完成。当前 ~/.zprofile 已包含 shellenv 设置。"
                ;;
            10)
                print_status_message "warn" "Homebrew 已安装完成，但你选择了不写入 ~/.zprofile。当前仅保证本次脚本会话可用。"
                ;;
            11)
                print_status_message "info" "Homebrew 已安装完成。当前默认 shell 不是 zsh，脚本未自动修改 shell 配置。"
                if [ -n "$shellenv_line" ]; then
                    print_message "如需持久化 Homebrew 环境，请将下面这行加入你的 ${shell_name:-当前} 登录配置文件："
                    print_message "$shellenv_line"
                fi
                ;;
            *)
                print_status_message "warn" "Homebrew 已安装完成，但未能完成 shell 环境持久化配置。"
                if [ -n "$shellenv_line" ]; then
                    print_message "你可以手动将下面这行加入 ~/.zprofile："
                    print_message "$shellenv_line"
                fi
                ;;
        esac

        if [ "$shellenv_config_status" -eq 0 ] || [ "$shellenv_config_status" -eq 2 ]; then
            print_message "当前会话与后续新的 zsh 终端都可以直接使用 brew。"
        fi
    else
        print_status_message "err" "Homebrew 安装失败，或当前 shell 尚未加载 Homebrew 环境。"
        print_message "如安装已成功，请重新打开终端后再执行脚本。"
    fi
}

run_environment_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "环境与依赖"
        printf "%s\n" "$(render_environment_menu)"
        printf "请输入序号（b 返回）: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_environment_choice "$choice")"
        case "$action" in
            cleanup)
                run_cleanup_flow
                pause_before_return
                ;;
            install-clt)
                run_install_xcode_command_line_tools_flow
                pause_before_return
                ;;
            install-homebrew)
                run_install_homebrew_flow
                pause_before_return
                ;;
            back)
                return 0
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1、2、3 或 b。"
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

measure_cleanup_paths_footprint_kib() {
    local summary=""

    summary="$(collect_disk_usage_summary "$@")"
    extract_key_value "$summary" "total_kib"
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

main() {
    local choice=""
    local action=""

    initialize_homebrew_shellenv || true

    while true; do
        print_page_title "Homebrew 管理"
        printf "%s\n" "$(render_main_menu)"
        printf "请输入序号（q 退出）: "
        if ! read -r choice; then
            print_message "已退出。"
            break
        fi

        if [ "$(should_exit_menu main "$choice")" = "1" ]; then
            print_message "已退出。"
            break
        fi

        action="$(dispatch_main_choice "$choice")"

        case "$action" in
            install)
                run_install_flow
                pause_before_return
                ;;
            uninstall)
                run_uninstall_menu
                ;;
            update)
                run_update_menu
                ;;
            tap-management)
                run_tap_management_flow
                ;;
            environment)
                run_environment_menu
                ;;
            back)
                print_status_message "warn" "输入无效，请输入 1、2、3、4、5 或 q。"
                pause_before_return
                ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
