#!/usr/bin/env bash

# Interactive Oh My Zsh bootstrap and configuration manager for macOS.

set -u
set -o pipefail

OMZ_INSTALL_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/70ad5e3df8f7bed68aa6672029496926e632aedd/tools/install.sh"
OMZ_DIR="$HOME/.oh-my-zsh"
ZSHRC_PATH="$HOME/.zshrc"
ZSH_TIDY_DIR="$HOME/.zsh"
ZSH_TIDY_BACKUP_DIR="$ZSH_TIDY_DIR/backups"
ZSH_COMPDUMP_EXPORT_LINE='export ZSH_COMPDUMP="$HOME/.zsh/zcompdump"'
CUSTOM_PLUGINS_DIR="${ZSH_CUSTOM:-$OMZ_DIR/custom}/plugins"
MANAGED_PLUGINS_START="# >>> omz-manager plugins >>>"
MANAGED_PLUGINS_END="# <<< omz-manager plugins <<<"
MANAGED_THEME_START="# >>> omz-manager theme >>>"
MANAGED_THEME_END="# <<< omz-manager theme <<<"
MANAGED_COMPDUMP_START="# >>> omz-manager compdump >>>"
MANAGED_COMPDUMP_END="# <<< omz-manager compdump <<<"

DEFAULT_PLUGIN_SPECS=(
    "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
    "zsh-autocomplete|https://github.com/marlonrichert/zsh-autocomplete"
)

SESSION_PLUGIN_SPECS=()
PLUGIN_CATALOG=()
THEME_OPTIONS=()
INSTALLED_CUSTOM_PLUGINS=()
PLUGIN_DISPLAY_LABELS=()
ZSHRC_BACKED_UP=0
LAST_ZSHRC_BACKUP_PATH=""
PAUSE_NAVIGATION_STATE="continue"

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

print_message() {
    printf "%s\n" "$1"
}

print_status_message() {
    local status="$1"
    local message="$2"

    print_message "$(format_status_tag "$status") $message"
}

print_blank_line() {
    printf "\n"
}

trim_whitespace() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
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

append_to_array() {
    local array_name="$1"
    local value="$2"
    local escaped_value=""

    # macOS ships Bash 3.2, so nameref (`local -n`) is unavailable here.
    if ! is_valid_shell_identifier "$array_name"; then
        return 1
    fi

    printf -v escaped_value '%q' "$value"
    eval "$array_name+=( $escaped_value )"
}

reset_named_array() {
    local array_name="$1"

    if ! is_valid_shell_identifier "$array_name"; then
        return 1
    fi

    eval "$array_name=()"
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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_terminal_width_from_stty() {
    local tty_size=""
    local tty_width=""

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

print_numbered_entries() {
    local items=("$@")
    local entries=()
    local index=1
    local terminal_width=0
    local columns=1
    local rendered_items=""
    local item=""

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
}

parse_numeric_choice() {
    local choice="$1"
    local max_index="$2"

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        printf "back"
        return 0
    fi

    case "$choice" in
        ''|*[!0-9]*)
            printf "invalid"
            return 0
            ;;
    esac

    if [ "$choice" -ge 1 ] && [ "$choice" -le "$max_index" ]; then
        printf "%s" "$choice"
        return 0
    fi

    printf "invalid"
}

parse_multi_numeric_choice() {
    local choice="$1"
    local max_index="$2"
    local token=""
    local normalized=""
    local noglob_was_set="0"

    choice="$(trim_whitespace "$choice")"

    if [ -z "$choice" ]; then
        printf "empty"
        return 0
    fi

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        printf "back"
        return 0
    fi

    if [ "$choice" = "all" ] || [ "$choice" = "ALL" ]; then
        printf "all"
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
                printf "invalid"
                return 0
                ;;
        esac

        if [ "$token" -lt 1 ] || [ "$token" -gt "$max_index" ]; then
            if [ "$noglob_was_set" != "1" ]; then
                set +f
            fi
            printf "invalid"
            return 0
        fi

        case " $normalized " in
            *" $token "*) ;;
            *) normalized="${normalized:+$normalized }$token" ;;
        esac
    done
    if [ "$noglob_was_set" != "1" ]; then
        set +f
    fi

    if [ -z "$normalized" ]; then
        printf "invalid"
        return 0
    fi

    printf "%s" "$normalized"
}

clear_screen() {
    if command_exists clear; then
        clear
    else
        printf "\033c"
    fi
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

    if ! is_positive_integer "$terminal_width"; then
        terminal_width="$(get_terminal_width)"
    fi

    printf "%s" "$(repeat_char "-" "$terminal_width")"
}

print_line() {
    local separator=""

    separator="$(render_separator "$(get_terminal_width)")"
    print_message "$(paint_text "2" "$separator")"
}

print_header() {
    clear_screen
    print_message "$(paint_text "1;36" "Oh My Zsh 配置管理器")"
    print_line
}

pause_with_back_option() {
    local answer=""

    PAUSE_NAVIGATION_STATE="continue"
    print_blank_line
    printf "按 Enter 继续，或输入 b 返回上一级: "
    read -r answer || true

    if [ "$answer" = "b" ] || [ "$answer" = "B" ]; then
        PAUSE_NAVIGATION_STATE="back"
    fi

    return 0
}

pause_requested_back() {
    [ "${PAUSE_NAVIGATION_STATE:-continue}" = "back" ]
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

    read -r answer || return 1
    answer="$(trim_whitespace "$answer")"

    if [ -z "$answer" ]; then
        answer="$default_answer"
    fi

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

is_omz_installed() {
    [ -d "$OMZ_DIR" ]
}

ensure_zshrc_exists() {
    if [ ! -e "$ZSHRC_PATH" ]; then
        : >"$ZSHRC_PATH" || return 1
    fi
}

backup_zshrc() {
    local backup_path=""

    if [ "${ZSHRC_BACKED_UP:-0}" = "1" ]; then
        return 0
    fi

    if [ ! -f "$ZSHRC_PATH" ]; then
        ZSHRC_BACKED_UP=1
        return 0
    fi

    backup_path="$HOME/.zshrc.bak.$(date '+%Y%m%d%H%M%S').$$"
    cp "$ZSHRC_PATH" "$backup_path" || return 1
    ZSHRC_BACKED_UP=1
    LAST_ZSHRC_BACKUP_PATH="$backup_path"
    print_status_message info "已备份 ~/.zshrc -> $backup_path"
}

remove_managed_block() {
    local file_path="$1"
    local start_marker="$2"
    local end_marker="$3"
    local temp_file=""
    local remove_status=0

    temp_file="$(mktemp "${TMPDIR:-/tmp}/omz-manager.zshrc.XXXXXX")" || return 1
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start {
            if (skip == 1) {
                error_code = 2
                exit 2
            }
            skip = 1
            next
        }
        $0 == end {
            if (skip != 1) {
                error_code = 3
                exit 3
            }
            skip = 0
            next
        }
        skip != 1 { print }
        END {
            if (error_code != 0) {
                exit error_code
            }
            if (skip == 1) {
                exit 4
            }
        }
    ' "$file_path" >"$temp_file" || remove_status="$?"

    if [ "$remove_status" -ne 0 ]; then
        rm -f "$temp_file"
        case "$remove_status" in
            2)
                print_status_message err "检测到重复的 managed block 开始标记: $start_marker"
                ;;
            3)
                print_status_message err "检测到孤立的 managed block 结束标记: $end_marker"
                ;;
            4)
                print_status_message err "检测到损坏的 managed block，缺少结束标记: $end_marker"
                ;;
            *)
                print_status_message err "移除 managed block 失败: $start_marker"
                ;;
        esac
        return 1
    fi

    mv "$temp_file" "$file_path"
}

write_managed_block() {
    local block_type="$1"
    local content_line="$2"
    local start_marker=""
    local end_marker=""

    case "$block_type" in
        plugins)
            start_marker="$MANAGED_PLUGINS_START"
            end_marker="$MANAGED_PLUGINS_END"
            ;;
        theme)
            start_marker="$MANAGED_THEME_START"
            end_marker="$MANAGED_THEME_END"
            ;;
        compdump)
            start_marker="$MANAGED_COMPDUMP_START"
            end_marker="$MANAGED_COMPDUMP_END"
            ;;
        *)
            return 1
            ;;
    esac

    case "$content_line" in
        *$'\n'*)
            print_status_message err "managed block 内容必须保持单行: $block_type"
            return 1
            ;;
    esac

    ensure_zshrc_exists || return 1
    backup_zshrc || return 1
    remove_managed_block "$ZSHRC_PATH" "$start_marker" "$end_marker" || return 1
    trim_trailing_blank_lines "$ZSHRC_PATH" || return 1
    if [ -s "$ZSHRC_PATH" ]; then
        printf "\n" >>"$ZSHRC_PATH" || return 1
    fi
    printf "%s\n%s\n%s\n" "$start_marker" "$content_line" "$end_marker" >>"$ZSHRC_PATH" || return 1
}

reload_zshrc() {
    print_status_message info "正在校验 ~/.zshrc"

    if ! command_exists zsh; then
        print_status_message warn "未检测到 zsh，无法自动校验 ~/.zshrc。请手动执行 zsh -n ~/.zshrc。"
        return 1
    fi

    if zsh -n "$ZSHRC_PATH" >/dev/null 2>&1; then
        print_status_message ok "语法校验通过。当前终端如需立即生效，请手动执行: source ~/.zshrc"
        return 0
    fi

    print_status_message warn "zsh 语法校验未通过。请手动执行 zsh -n ~/.zshrc 检查。"
    return 1
}

trim_trailing_blank_lines() {
    local file_path="$1"
    local temp_file=""

    temp_file="$(mktemp "${TMPDIR:-/tmp}/omz-manager.zshrc.XXXXXX")" || return 1
    # This helper only targets small config files such as ~/.zshrc.
    awk '
        { lines[NR] = $0 }
        END {
            last = NR
            while (last > 0 && lines[last] == "") {
                last--
            }
            for (i = 1; i <= last; i++) {
                print lines[i]
            }
        }
    ' "$file_path" >"$temp_file" || {
        rm -f "$temp_file"
        return 1
    }

    mv "$temp_file" "$file_path"
}

ensure_zsh_tidy_directories() {
    mkdir -p "$ZSH_TIDY_DIR" "$ZSH_TIDY_BACKUP_DIR" || {
        print_status_message err "无法创建整理目录: $ZSH_TIDY_DIR"
        return 1
    }
}

move_files_into_directory() {
    local destination_dir="$1"
    shift
    local moved_count=0
    local source_path=""

    for source_path in "$@"; do
        [ -f "$source_path" ] || continue
        if [ -n "${LAST_ZSHRC_BACKUP_PATH:-}" ] && [ "$source_path" = "$LAST_ZSHRC_BACKUP_PATH" ]; then
            continue
        fi
        mv "$source_path" "$destination_dir/" || return 1
        moved_count=$((moved_count + 1))
    done

    printf "%s" "$moved_count"
}

move_zsh_compdump_files() {
    move_files_into_directory "$ZSH_TIDY_DIR" "$HOME"/.zcompdump*
}

move_zsh_backup_files() {
    move_files_into_directory \
        "$ZSH_TIDY_BACKUP_DIR" \
        "$HOME"/.zshrc.backup-* \
        "$HOME"/.zshrc.backup.* \
        "$HOME"/.zshrc.bak.*
}

move_zprofile_backup_file() {
    if [ ! -f "$HOME/.zprofile.bak" ]; then
        printf "0"
        return 0
    fi

    mv "$HOME/.zprofile.bak" "$ZSH_TIDY_BACKUP_DIR/" || return 1
    printf "1"
}

ensure_zsh_compdump_export() {
    write_managed_block "compdump" "$ZSH_COMPDUMP_EXPORT_LINE" || return 1
    print_status_message ok "已整理 ZSH_COMPDUMP 到 $HOME/.zsh/zcompdump"
}

run_zsh_tidy_flow() {
    local moved_compdump=0
    local moved_backups=0
    local moved_zprofile_backup=0

    print_status_message info "开始整理 Zsh 文件"

    ensure_zsh_tidy_directories || return 1

    moved_compdump="$(move_zsh_compdump_files)" || return 1
    moved_backups="$(move_zsh_backup_files)" || return 1
    moved_zprofile_backup="$(move_zprofile_backup_file)" || return 1
    ensure_zsh_compdump_export || return 1
    # A zshrc mutation can surface additional historical backups after the first pass.
    # The current operation's fresh backup is skipped via LAST_ZSHRC_BACKUP_PATH.
    moved_backups=$((moved_backups + $(move_zsh_backup_files))) || return 1

    if [ "$moved_compdump" -gt 0 ]; then
        print_status_message ok "已移动 $moved_compdump 个 zcompdump 文件"
    fi

    if [ "$moved_backups" -gt 0 ]; then
        print_status_message ok "已移动 $moved_backups 个 Zsh 备份文件"
    fi

    if [ "$moved_zprofile_backup" -gt 0 ]; then
        print_status_message ok "已移动 .zprofile.bak"
    fi

    print_status_message ok "Zsh 文件已整理到 $ZSH_TIDY_DIR"
    print_status_message info "备份目录: $ZSH_TIDY_BACKUP_DIR"
    if ! reload_zshrc; then
        print_status_message warn "整理完成，但 ~/.zshrc 校验未通过。"
    fi
}

get_active_plugins_string() {
    if [ ! -f "$ZSHRC_PATH" ]; then
        return 0
    fi

    awk '
        function trim_value(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        function append_fragment(fragment) {
            sub(/[[:space:]]+#.*/, "", fragment)
            fragment = trim_value(fragment)
            if (fragment == "") {
                return
            }
            if (buffer == "") {
                buffer = fragment
            } else {
                buffer = buffer " " fragment
            }
        }
        /^[[:space:]]*#/ { next }
        in_plugins == 1 {
            line = $0
            if (line ~ /\)/) {
                sub(/\).*/, "", line)
                append_fragment(line)
                value = buffer
                buffer = ""
                in_plugins = 0
                next
            }
            append_fragment(line)
            next
        }
        /^[[:space:]]*plugins=[[:space:]]*\(/ {
            line = $0
            sub(/^[[:space:]]*plugins=[[:space:]]*\(/, "", line)
            buffer = ""
            if (line ~ /\)/) {
                sub(/\).*/, "", line)
                append_fragment(line)
                value = buffer
                buffer = ""
                next
            }
            append_fragment(line)
            in_plugins = 1
        }
        END { print trim_value(value) }
    ' "$ZSHRC_PATH"
}

get_current_theme() {
    if [ ! -f "$ZSHRC_PATH" ]; then
        return 0
    fi

    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*ZSH_THEME=/ {
            line = $0
            sub(/^[[:space:]]*ZSH_THEME=/, "", line)
            gsub(/^"/, "", line)
            gsub(/"$/, "", line)
            gsub(/^'\''/, "", line)
            gsub(/'\''$/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            value = line
        }
        END { print value }
    ' "$ZSHRC_PATH"
}

is_plugin_installed() {
    local plugin_name="$1"

    [ -d "$CUSTOM_PLUGINS_DIR/$plugin_name" ]
}

is_builtin_omz_plugin() {
    local plugin_name="$1"

    [ -d "$OMZ_DIR/plugins/$plugin_name" ]
}

should_keep_plugin_enabled() {
    local plugin_name="$1"

    case "$plugin_name" in
        git)
            return 0
            ;;
    esac

    if is_builtin_omz_plugin "$plugin_name"; then
        return 0
    fi

    if is_plugin_installed "$plugin_name"; then
        return 0
    fi

    return 1
}

plugin_spec_name() {
    printf "%s" "${1%%|*}"
}

plugin_spec_url() {
    local spec="$1"
    local remainder="${spec#*|}"

    if [ "$remainder" = "$spec" ]; then
        printf ""
        return 0
    fi

    printf "%s" "$remainder"
}

catalog_contains_plugin_name() {
    local plugin_name="$1"
    local spec=""
    local existing_name=""

    for spec in "${PLUGIN_CATALOG[@]+"${PLUGIN_CATALOG[@]}"}"; do
        existing_name="$(plugin_spec_name "$spec")"
        [ "$existing_name" = "$plugin_name" ] && return 0
    done

    return 1
}

session_contains_plugin_name() {
    local plugin_name="$1"
    local spec=""
    local existing_name=""

    for spec in "${SESSION_PLUGIN_SPECS[@]+"${SESSION_PLUGIN_SPECS[@]}"}"; do
        existing_name="$(plugin_spec_name "$spec")"
        [ "$existing_name" = "$plugin_name" ] && return 0
    done

    return 1
}

derive_plugin_name_from_url() {
    local plugin_url="${1%/}"
    local plugin_name=""

    plugin_name="${plugin_url##*/}"
    plugin_name="${plugin_name%.git}"

    if ! is_safe_plugin_name "$plugin_name"; then
        return 1
    fi

    printf "%s" "$plugin_name"
}

is_safe_plugin_name() {
    local plugin_name="$1"

    case "$plugin_name" in
        ''|.|..|*/*|*' '*|*$'\t'*|*[!A-Za-z0-9._-]*)
            return 1
            ;;
    esac

    return 0
}

safe_remove_plugin_destination() {
    local destination="$1"

    case "$destination" in
        "$CUSTOM_PLUGINS_DIR"/*)
            rm -rf "$destination" 2>/dev/null || return 1
            ;;
        *)
            print_status_message err "目标路径异常，拒绝清理: $destination"
            return 1
            ;;
    esac
}

collect_installed_custom_plugins() {
    local plugin_dir=""
    local plugin_name=""

    reset_named_array INSTALLED_CUSTOM_PLUGINS || return 1

    if [ ! -d "$CUSTOM_PLUGINS_DIR" ]; then
        return 0
    fi

    for plugin_dir in "$CUSTOM_PLUGINS_DIR"/*; do
        [ -d "$plugin_dir" ] || continue
        plugin_name="$(basename "$plugin_dir")"
        if ! is_safe_plugin_name "$plugin_name"; then
            print_status_message warn "忽略不合法插件目录名: $plugin_name"
            continue
        fi
        append_to_array INSTALLED_CUSTOM_PLUGINS "$plugin_name"
    done
}

build_plugin_catalog() {
    local spec=""
    local plugin_name=""
    local plugin_url=""

    reset_named_array PLUGIN_CATALOG || return 1
    collect_installed_custom_plugins || return 1

    for spec in "${DEFAULT_PLUGIN_SPECS[@]+"${DEFAULT_PLUGIN_SPECS[@]}"}"; do
        append_to_array PLUGIN_CATALOG "$spec"
    done

    for spec in "${SESSION_PLUGIN_SPECS[@]+"${SESSION_PLUGIN_SPECS[@]}"}"; do
        plugin_name="$(plugin_spec_name "$spec")"
        if ! catalog_contains_plugin_name "$plugin_name"; then
            append_to_array PLUGIN_CATALOG "$spec"
        fi
    done

    for plugin_name in "${INSTALLED_CUSTOM_PLUGINS[@]+"${INSTALLED_CUSTOM_PLUGINS[@]}"}"; do
        if ! catalog_contains_plugin_name "$plugin_name"; then
            plugin_url=""
            append_to_array PLUGIN_CATALOG "$plugin_name|$plugin_url"
        fi
    done
}

build_plugin_display_labels() {
    local spec=""
    local plugin_name=""
    local plugin_url=""
    local status_label=""
    local active_plugins_string=""

    reset_named_array PLUGIN_DISPLAY_LABELS || return 1
    active_plugins_string="$(get_active_plugins_string)"

    for spec in "${PLUGIN_CATALOG[@]+"${PLUGIN_CATALOG[@]}"}"; do
        plugin_name="$(plugin_spec_name "$spec")"
        plugin_url="$(plugin_spec_url "$spec")"

        # Intentional word splitting: active_plugins_string is a space-separated plugin list.
        if array_contains_exact "$plugin_name" $active_plugins_string; then
            status_label="[已启用]"
        elif is_plugin_installed "$plugin_name"; then
            status_label="[已安装未启用]"
        elif [ -n "$plugin_url" ]; then
            status_label="[未安装]"
        else
            status_label="[仅本地记录]"
        fi

        append_to_array PLUGIN_DISPLAY_LABELS "$plugin_name $status_label"
    done
}

join_array_with_separator() {
    local separator="$1"
    shift
    local items=("$@")
    local output=""
    local item=""

    for item in "${items[@]+"${items[@]}"}"; do
        if [ -n "$output" ]; then
            output="$output$separator$item"
        else
            output="$item"
        fi
    done

    printf "%s" "$output"
}

sync_plugins_config() {
    local requested_enable_plugins=("$@")
    local active_plugins_string=""
    local normalized_plugins=()
    local plugin_name=""
    local plugin_line=""

    active_plugins_string="$(get_active_plugins_string)"
    # Intentional word splitting: active_plugins_string is a space-separated plugin list.
    for plugin_name in $active_plugins_string; do
        if should_keep_plugin_enabled "$plugin_name" \
            && ! array_contains_exact "$plugin_name" "${normalized_plugins[@]+"${normalized_plugins[@]}"}"; then
            append_to_array normalized_plugins "$plugin_name"
        fi
    done

    if ! array_contains_exact "git" "${normalized_plugins[@]+"${normalized_plugins[@]}"}"; then
        append_to_array normalized_plugins "git"
    fi

    for plugin_name in "${requested_enable_plugins[@]+"${requested_enable_plugins[@]}"}"; do
        if should_keep_plugin_enabled "$plugin_name" \
            && ! array_contains_exact "$plugin_name" "${normalized_plugins[@]+"${normalized_plugins[@]}"}"; then
            append_to_array normalized_plugins "$plugin_name"
        fi
    done

    plugin_line="plugins=($(join_array_with_separator " " "${normalized_plugins[@]+"${normalized_plugins[@]}"}"))"
    print_status_message info "即将写入: $plugin_line"
    write_managed_block "plugins" "$plugin_line" || return 1
    reload_zshrc
}

collect_theme_options() {
    local theme_name=""

    reset_named_array THEME_OPTIONS || return 1

    if [ ! -d "$OMZ_DIR/themes" ]; then
        return 0
    fi

    while IFS= read -r theme_name; do
        [ -n "$theme_name" ] || continue
        append_to_array THEME_OPTIONS "$theme_name"
    done < <(
        for theme_path in "$OMZ_DIR"/themes/*.zsh-theme; do
            [ -e "$theme_path" ] || continue
            basename "$theme_path" .zsh-theme
        done | LC_ALL=C sort
    )
}

show_status() {
    local active_plugins=""
    local current_theme=""
    local installed_plugins_summary=""

    if is_omz_installed; then
        print_message "Oh My Zsh : $(paint_text "1;32" "已安装")"
    else
        print_message "Oh My Zsh : $(paint_text "1;31" "未安装")"
    fi

    active_plugins="$(get_active_plugins_string)"
    current_theme="$(get_current_theme)"
    if collect_installed_custom_plugins >/dev/null 2>&1; then
        installed_plugins_summary="$(join_array_with_separator ", " "${INSTALLED_CUSTOM_PLUGINS[@]+"${INSTALLED_CUSTOM_PLUGINS[@]}"}")"
        [ -n "$installed_plugins_summary" ] || installed_plugins_summary="无"
    else
        installed_plugins_summary="扫描失败"
    fi
    [ -n "$active_plugins" ] || active_plugins="无"
    [ -n "$current_theme" ] || current_theme="未设置"

    print_message "已激活插件 : $active_plugins"
    print_message "已装自定义插件 : $installed_plugins_summary"
    print_message "当前主题 : $current_theme"
}

main_menu_text() {
    printf "%s\n" \
        "1) 安装 Oh My Zsh" \
        "2) 管理插件" \
        "3) 切换主题" \
        "4) 整理 Zsh 文件" \
        "q) 退出"
}

dispatch_main_choice() {
    case "$1" in
        1) printf "install-omz" ;;
        2) printf "manage-plugins" ;;
        3) printf "switch-theme" ;;
        4) printf "tidy-zsh-files" ;;
        q|Q) printf "quit" ;;
        *) printf "invalid" ;;
    esac
}

clone_plugin_with_retry() {
    local plugin_name="$1"
    local plugin_url="$2"
    local destination="$CUSTOM_PLUGINS_DIR/$plugin_name"

    mkdir -p "$CUSTOM_PLUGINS_DIR" || {
        print_status_message err "无法创建插件目录: $CUSTOM_PLUGINS_DIR"
        return 1
    }

    while true; do
        print_status_message info "正在安装插件: $plugin_name"
        if git clone --depth=1 "$plugin_url" "$destination"; then
            print_status_message ok "插件安装完成: $plugin_name"
            return 0
        fi

        print_status_message err "插件安装失败: $plugin_name"
        if ! safe_remove_plugin_destination "$destination"; then
            print_status_message warn "插件目录清理未完成: $destination"
        fi
        if ! prompt_yes_no "是否重试安装 $plugin_name？" "y"; then
            return 1
        fi
    done
}

install_omz_with_retry() {
    local installer_path=""

    if ! command_exists curl; then
        print_status_message err "未检测到 curl，无法下载安装脚本。"
        return 1
    fi

    while true; do
        installer_path="$(mktemp "${TMPDIR:-/tmp}/omz-install.XXXXXX")" || return 1
        print_status_message info "正在下载 Oh My Zsh 安装脚本"

        if ! curl -fsSL "$OMZ_INSTALL_URL" -o "$installer_path"; then
            rm -f "$installer_path"
            print_status_message err "下载安装脚本失败。"
            if prompt_yes_no "是否重试下载？" "y"; then
                continue
            fi
            return 1
        fi

        print_status_message info "开始安装 Oh My Zsh"
        if RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$installer_path"; then
            rm -f "$installer_path"
            print_status_message ok "Oh My Zsh 安装完成。"
            return 0
        fi

        rm -f "$installer_path"
        print_status_message err "Oh My Zsh 安装失败。"
        if ! prompt_yes_no "是否重试安装？" "y"; then
            return 1
        fi
    done
}

menu_install_omz() {
    local answer=""

    while true; do
        print_header
        print_message "[1] 安装 Oh My Zsh"
        print_line

        if is_omz_installed; then
            print_status_message ok "已检测到 Oh My Zsh: $OMZ_DIR"
            pause_with_back_option
            pause_requested_back && return 0
            continue
        fi

        print_status_message warn "当前未安装 Oh My Zsh"
        print_blank_line
        printf "是否安装 Oh My Zsh？(y/n/b): "
        read -r answer || return 0
        answer="$(trim_whitespace "$answer")"

        case "$answer" in
            y|Y)
                if ! install_omz_with_retry; then
                    print_status_message warn "安装流程未完成，请先处理上面的错误。"
                fi
                pause_with_back_option
                pause_requested_back && return 0
                ;;
            n|N)
                print_status_message skip "本次跳过安装。"
                pause_with_back_option
                pause_requested_back && return 0
                ;;
            b|B)
                return 0
                ;;
            *)
                print_status_message warn "请输入 y、n 或 b。"
                continue
                ;;
        esac
    done
}

maybe_register_session_plugin() {
    local plugin_name="$1"
    local plugin_url="$2"

    if session_contains_plugin_name "$plugin_name"; then
        return 0
    fi

    append_to_array SESSION_PLUGIN_SPECS "$plugin_name|$plugin_url"
}

install_plugin_specs() {
    local specs=("$@")
    local spec=""
    local plugin_name=""
    local plugin_url=""
    local had_failure=0

    for spec in "${specs[@]+"${specs[@]}"}"; do
        plugin_name="$(plugin_spec_name "$spec")"
        plugin_url="$(plugin_spec_url "$spec")"

        if is_plugin_installed "$plugin_name"; then
            print_status_message skip "$plugin_name 已安装，跳过下载。"
            continue
        fi

        if [ -z "$plugin_url" ]; then
            print_status_message warn "$plugin_name 没有可用仓库地址，无法安装。"
            had_failure=1
            continue
        fi

        if ! clone_plugin_with_retry "$plugin_name" "$plugin_url"; then
            print_status_message warn "跳过 $plugin_name，继续处理其余插件。"
            had_failure=1
        fi
    done

    if [ "$had_failure" -ne 0 ]; then
        return 1
    fi

    return 0
}

handle_add_plugin() {
    local plugin_url=""
    local plugin_name=""

    print_blank_line
    printf "输入插件 Git 地址: "
    read -r plugin_url || return 0
    plugin_url="$(trim_whitespace "$plugin_url")"

    if [ -z "$plugin_url" ]; then
        print_status_message warn "地址为空，已取消。"
        pause_with_back_option
        pause_requested_back && return 0
        return 0
    fi

    plugin_name="$(derive_plugin_name_from_url "$plugin_url")"
    if [ -z "$plugin_name" ]; then
        print_status_message err "无法从地址推断插件名称。"
        pause_with_back_option
        pause_requested_back && return 0
        return 0
    fi

    maybe_register_session_plugin "$plugin_name" "$plugin_url"
    build_plugin_catalog || return 1
    if ! install_plugin_specs "$plugin_name|$plugin_url"; then
        print_status_message warn "插件安装未全部成功，仅同步当前可用插件。"
    fi
    if ! sync_plugins_config "$plugin_name"; then
        print_status_message warn "插件启用配置写入失败，请检查 ~/.zshrc。"
    fi
    pause_with_back_option
    pause_requested_back && return 0
}

menu_plugins() {
    local input=""
    local parsed=""
    local token=""
    local selected_specs=()
    local selected_plugin_names=()
    local selected_index=0
    local selected_plugin_name=""

    if ! is_omz_installed; then
        print_header
        print_message "[2] 管理插件"
        print_line
        print_status_message warn "请先安装 Oh My Zsh。"
        pause_with_back_option
        pause_requested_back && return 0
        return 0
    fi

    while true; do
        build_plugin_catalog || return 1
        build_plugin_display_labels || return 1

        print_header
        print_message "[2] 管理插件"
        print_line
        print_message "可输入多个序号，空格分隔；输入 all 安装并启用全部可管理插件。"
        print_message "输入 n 新增插件地址，输入 b 返回主菜单。"
        print_blank_line
        print_numbered_entries "${PLUGIN_DISPLAY_LABELS[@]+"${PLUGIN_DISPLAY_LABELS[@]}"}"
        print_blank_line
        printf "请选择 > "
        read -r input || return 0
        input="$(trim_whitespace "$input")"

        case "$input" in
            b|B)
                return 0
                ;;
            n|N)
                if ! handle_add_plugin; then
                    print_status_message warn "新增插件流程未完成，请先处理上面的错误。"
                fi
                continue
                ;;
        esac

        parsed="$(parse_multi_numeric_choice "$input" "${#PLUGIN_CATALOG[@]}")"
        case "$parsed" in
            back)
                return 0
                ;;
            empty)
                continue
                ;;
            invalid)
                print_status_message warn "输入无效，请重新选择。"
                pause_with_back_option
                pause_requested_back && return 0
                continue
                ;;
            all)
                if ! install_plugin_specs "${PLUGIN_CATALOG[@]+"${PLUGIN_CATALOG[@]}"}"; then
                    print_status_message warn "部分插件安装失败，仅同步当前可用插件。"
                fi
                selected_plugin_names=()
                for selected_plugin_name in "${PLUGIN_CATALOG[@]+"${PLUGIN_CATALOG[@]}"}"; do
                    append_to_array selected_plugin_names "$(plugin_spec_name "$selected_plugin_name")"
                done
                if ! sync_plugins_config "${selected_plugin_names[@]+"${selected_plugin_names[@]}"}"; then
                    print_status_message warn "插件启用配置写入失败，请检查 ~/.zshrc。"
                fi
                pause_with_back_option
                pause_requested_back && return 0
                continue
                ;;
        esac

        selected_specs=()
        selected_plugin_names=()
        # Intentional word splitting: parsed is a space-separated selection list.
        for token in $parsed; do
            selected_index=$((token - 1))
            append_to_array selected_specs "${PLUGIN_CATALOG[$selected_index]}"
            append_to_array selected_plugin_names "$(plugin_spec_name "${PLUGIN_CATALOG[$selected_index]}")"
        done

        if ! install_plugin_specs "${selected_specs[@]+"${selected_specs[@]}"}"; then
            print_status_message warn "部分插件安装失败，仅同步当前可用插件。"
        fi
        if ! sync_plugins_config "${selected_plugin_names[@]+"${selected_plugin_names[@]}"}"; then
            print_status_message warn "插件启用配置写入失败，请检查 ~/.zshrc。"
        fi
        pause_with_back_option
        pause_requested_back && return 0
    done
}

switch_theme() {
    local theme_name="$1"
    local theme_line=""

    theme_line="ZSH_THEME=\"$theme_name\""
    print_status_message info "即将写入: $theme_line"
    write_managed_block "theme" "$theme_line" || return 1
    reload_zshrc
}

menu_themes() {
    local current_theme=""
    local labels=()
    local input=""
    local parsed=""
    local index=0
    local theme_name=""

    if ! is_omz_installed; then
        print_header
        print_message "[3] 切换主题"
        print_line
        print_status_message warn "请先安装 Oh My Zsh。"
        pause_with_back_option
        pause_requested_back && return 0
        return 0
    fi

    while true; do
        collect_theme_options || return 1
        current_theme="$(get_current_theme)"
        labels=()

        for theme_name in "${THEME_OPTIONS[@]+"${THEME_OPTIONS[@]}"}"; do
            if [ "$theme_name" = "$current_theme" ]; then
                append_to_array labels "$theme_name [当前]"
            else
                append_to_array labels "$theme_name"
            fi
        done

        print_header
        print_message "[3] 切换主题"
        print_line
        print_message "当前主题: ${current_theme:-未设置}"
        print_message "输入序号切换主题，输入 b 返回主菜单。"
        print_blank_line
        print_numbered_entries "${labels[@]+"${labels[@]}"}"
        print_blank_line
        printf "请选择 > "
        read -r input || return 0
        input="$(trim_whitespace "$input")"

        parsed="$(parse_numeric_choice "$input" "${#THEME_OPTIONS[@]}")"
        case "$parsed" in
            back)
                return 0
                ;;
            invalid)
                print_status_message warn "输入无效，请重新选择。"
                pause_with_back_option
                pause_requested_back && return 0
                continue
                ;;
            *)
                index=$((parsed - 1))
                theme_name="${THEME_OPTIONS[$index]}"
                if ! switch_theme "$theme_name"; then
                    print_status_message warn "主题配置写入失败，请检查 ~/.zshrc。"
                fi
                pause_with_back_option
                pause_requested_back && return 0
                ;;
        esac
    done
}

main_menu() {
    local choice=""
    local action=""

    while true; do
        print_header
        show_status
        print_line
        main_menu_text
        print_blank_line
        printf "请选择 > "
        read -r choice || return 0
        choice="$(trim_whitespace "$choice")"

        action="$(dispatch_main_choice "$choice")"
        case "$action" in
            install-omz) menu_install_omz ;;
            manage-plugins) menu_plugins ;;
            switch-theme) menu_themes ;;
            tidy-zsh-files)
                if ! run_zsh_tidy_flow; then
                    print_status_message warn "整理流程未完成，请先处理上面的错误。"
                fi
                pause_with_back_option
                pause_requested_back && return 0
                ;;
            quit) return 0 ;;
            *)
                print_status_message warn "请输入 1、2、3、4 或 q。"
                pause_with_back_option
                pause_requested_back && return 0
                ;;
        esac
    done
}

main() {
    main_menu
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
