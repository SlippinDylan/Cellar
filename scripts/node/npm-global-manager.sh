#!/bin/bash

# Unified npm / Node global environment manager for macOS.
# Environment: local interactive shell on macOS.
# Purpose: manage nvm, Node.js versions, npm global packages, and npm registry configuration.

set -u
set -o pipefail

# ──────────────────────────────────────────────
# Constants & globals
# ──────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
CONFIG_DIR="$SCRIPT_DIR/config"
DEFAULT_GLOBAL_PACKAGES_FILE="$CONFIG_DIR/global-packages.txt"

NVM_INSTALL_VERSION="${NVM_INSTALL_VERSION:-v0.40.5}"
NVM_INSTALL_URL="${NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_INSTALL_VERSION}/install.sh}"
NVM_INSTALL_SHA256="${NVM_INSTALL_SHA256:-582070e4c44452c1d8d68e16fc786c2216ecba6bc6bf18dc280a03fdba6ed1a9}"
NVM_ALLOW_UNVERIFIED_INSTALL="${NVM_ALLOW_UNVERIFIED_INSTALL:-0}"

INSTALLABLE_GLOBAL_PACKAGES=()
GLOBAL_PACKAGES_FILE="${GLOBAL_PACKAGES_FILE:-$DEFAULT_GLOBAL_PACKAGES_FILE}"
INSTALL_MAX_RETRIES=2

PROTECTED_GLOBAL_PACKAGES=("npm" "corepack")
HELD_RUNTIME_LOCKS=""

# ──────────────────────────────────────────────
# Low-level utility helpers
# ──────────────────────────────────────────────

command_exists() {
    [ -n "${1:-}" ] || return 1
    command -v "$1" >/dev/null 2>&1
}

manager_runtime_dir() {
    printf '%s\n' "$RUNTIME_DIR"
}

manager_log_dir() {
    printf '%s\n' "$RUNTIME_DIR/logs"
}

manager_tmp_dir() {
    printf '%s\n' "$RUNTIME_DIR/tmp"
}

ensure_runtime_dirs() {
    mkdir -p "$(manager_log_dir)" "$(manager_tmp_dir)" "$CONFIG_DIR" || return 1
}

manager_lock_dir() {
    local lock_name="${1:-global}"
    printf '%s/%s.lock\n' "$(manager_tmp_dir)" "$(sanitize_filename_component "$lock_name")"
}

held_runtime_locks_contains() {
    local wanted="${1:-}"
    local lock_name=""
    for lock_name in $HELD_RUNTIME_LOCKS; do
        [ "$lock_name" = "$wanted" ] && return 0
    done
    return 1
}

add_held_runtime_lock() {
    local lock_name="${1:-}"
    [ -n "$lock_name" ] || return 0
    if ! held_runtime_locks_contains "$lock_name"; then
        HELD_RUNTIME_LOCKS="${HELD_RUNTIME_LOCKS:+$HELD_RUNTIME_LOCKS }$lock_name"
    fi
}

remove_held_runtime_lock() {
    local wanted="${1:-}"
    local lock_name=""
    local remaining=""
    for lock_name in $HELD_RUNTIME_LOCKS; do
        if [ "$lock_name" != "$wanted" ]; then
            remaining="${remaining:+$remaining }$lock_name"
        fi
    done
    HELD_RUNTIME_LOCKS="$remaining"
}

runtime_lock_owner_pid() {
    local lock_dir="$1"
    sed -n '1p' "$lock_dir/pid" 2>/dev/null || sed -n 's/^pid=//p' "$lock_dir/metadata" 2>/dev/null | head -1 || true
}

runtime_lock_owned_by_current_process() {
    local lock_name="${1:-global}"
    local lock_dir=""
    local lock_pid=""

    lock_dir="$(manager_lock_dir "$lock_name")"
    [ -d "$lock_dir" ] || return 1
    lock_pid="$(runtime_lock_owner_pid "$lock_dir")"
    [ "$lock_pid" = "$$" ]
}

acquire_runtime_lock() {
    local lock_name="${1:-global}"
    local lock_dir=""
    local lock_pid=""

    ensure_runtime_dirs || return 1
    lock_dir="$(manager_lock_dir "$lock_name")"
    if runtime_lock_owned_by_current_process "$lock_name"; then
        add_held_runtime_lock "$lock_name"
        return 0
    fi

    if mkdir "$lock_dir" 2>/dev/null; then
        {
            printf 'pid=%s\n' "$$"
            printf 'created=%s\n' "$(date +%s)"
            printf 'action=%s\n' "$lock_name"
        } > "$lock_dir/metadata" 2>/dev/null || true
        printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
        add_held_runtime_lock "$lock_name"
        return 0
    fi

    lock_pid="$(runtime_lock_owner_pid "$lock_dir")"
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -rf "$lock_dir" 2>/dev/null || return 1
        if mkdir "$lock_dir" 2>/dev/null; then
            {
                printf 'pid=%s\n' "$$"
                printf 'created=%s\n' "$(date +%s)"
                printf 'action=%s\n' "$lock_name"
                printf 'recoveredStalePid=%s\n' "$lock_pid"
            } > "$lock_dir/metadata" 2>/dev/null || true
            printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
            add_held_runtime_lock "$lock_name"
            return 0
        fi
    fi

    return 1
}

release_runtime_lock() {
    local lock_name="${1:-global}"
    local lock_dir=""

    lock_dir="$(manager_lock_dir "$lock_name")"
    [ -d "$lock_dir" ] || return 0
    if ! runtime_lock_owned_by_current_process "$lock_name"; then
        remove_held_runtime_lock "$lock_name"
        return 0
    fi
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rm -f "$lock_dir/metadata" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    remove_held_runtime_lock "$lock_name"
}

release_all_runtime_locks() {
    local lock_name=""
    local held_locks="$HELD_RUNTIME_LOCKS"
    for lock_name in $held_locks; do
        release_runtime_lock "$lock_name"
    done
    HELD_RUNTIME_LOCKS=""
}

trap 'release_all_runtime_locks' EXIT
trap 'release_all_runtime_locks; exit 130' INT TERM

platform_uname() {
    printf '%s\n' "${MANAGER_TEST_UNAME:-$(uname -s 2>/dev/null || true)}"
}

ensure_macos() {
    local system_name=""
    system_name="$(platform_uname)"
    if [ "$system_name" != "Darwin" ]; then
        print_status_message "fail" "仅支持 macOS，本机系统: ${system_name:-<unknown>}"
        return 1
    fi
    return 0
}

run_dependency_preflight() {
    local missing_required=0
    local cmd=""

    for cmd in find readlink du md5 mktemp sed awk grep; do
        if ! command_exists "$cmd"; then
            print_status_message "fail" "缺少必需命令: $cmd"
            missing_required=$((missing_required + 1))
        fi
    done

    for cmd in ruby node npm curl shasum; do
        if ! command_exists "$cmd"; then
            print_status_message "warn" "命令不可用，相关功能会受限: $cmd"
        fi
    done

    [ "$missing_required" -eq 0 ]
}

require_capabilities() {
    local capability=""
    local missing=0

    for capability in "$@"; do
        case "$capability" in
            npm)
                if ! command_exists npm; then
                    print_status_message "fail" "此功能需要 npm。请先进入「环境与依赖」安装 nvm 和 Node.js。"
                    missing=$((missing + 1))
                fi
                ;;
            node)
                if ! command_exists node; then
                    print_status_message "fail" "此功能需要 node。请先进入「环境与依赖」安装 nvm 和 Node.js。"
                    missing=$((missing + 1))
                fi
                ;;
            curl)
                if ! command_exists curl; then
                    print_status_message "fail" "此功能需要 curl。"
                    missing=$((missing + 1))
                fi
                ;;
            shasum)
                if ! command_exists shasum; then
                    print_status_message "fail" "此功能需要 shasum。"
                    missing=$((missing + 1))
                fi
                ;;
            ruby)
                if ! command_exists ruby; then
                    print_status_message "fail" "此功能需要 Ruby 解析 npm JSON 输出。"
                    missing=$((missing + 1))
                fi
                ;;
        esac
    done

    if [ "$missing" -gt 0 ]; then
        pause_before_return
        return 1
    fi
    return 0
}

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

        if ! read -r answer; then
            answer="$default_answer"
        fi
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
    printf '%s\n' "$path"
}

is_nonnegative_integer() {
    local value="${1:-}"
    case "$value" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# ──────────────────────────────────────────────
# Input parsing helpers
# ──────────────────────────────────────────────

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

    choice="$(trim_whitespace "$choice")"

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        echo "back"
        return 0
    fi

    if [ "$choice" = "all" ] || [ "$choice" = "ALL" ]; then
        echo "all"
        return 0
    fi

    choice="$(printf '%s' "$choice" | tr ',' ' ')"

    local noglob_was_set="0"
    case "$-" in
        *f*) noglob_was_set="1" ;;
    esac
    set -f
    for token in $choice; do
        if printf '%s' "$token" | grep -Eq '^[0-9]+-[0-9]+$'; then
            local range_start="${token%-*}"
            local range_end="${token#*-}"
            if [ "$range_start" -gt "$range_end" ] || [ "$range_start" -lt 1 ] || [ "$range_end" -gt "$max_index" ]; then
                if [ "$noglob_was_set" != "1" ]; then
                    set +f
                fi
                echo "invalid"
                return 0
            fi

            local current="$range_start"
            while [ "$current" -le "$range_end" ]; do
                case " $normalized " in
                    *" $current "*) ;;
                    *) normalized="${normalized:+$normalized }$current" ;;
                esac
                current=$((current + 1))
            done
            continue
        fi

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

# ──────────────────────────────────────────────
# nvm loading & detection
# ──────────────────────────────────────────────

load_nvm_into_current_shell() {
    export NVM_DIR="${NVM_DIR:-$(detect_nvm_dir)}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1090,SC1091
        . "$NVM_DIR/nvm.sh" --no-use
        return 0
    fi
    return 1
}

detect_nvm_dir() {
    if [ -n "${NVM_DIR:-}" ]; then
        printf '%s\n' "$NVM_DIR"
        return 0
    fi

    if [ -n "${XDG_CONFIG_HOME:-}" ] && [ -s "$XDG_CONFIG_HOME/nvm/nvm.sh" ]; then
        printf '%s\n' "$XDG_CONFIG_HOME/nvm"
        return 0
    fi

    printf '%s\n' "$HOME/.nvm"
}

nvm_script_path() {
    local dir=""
    dir="$(detect_nvm_dir)"
    printf '%s\n' "$dir/nvm.sh"
}

profile_has_complete_nvm_init() {
    local profile_file="$1"
    [ -f "$profile_file" ] || return 1
    grep -F 'NVM_DIR' "$profile_file" >/dev/null 2>&1 || return 1
    grep -F 'nvm.sh' "$profile_file" >/dev/null 2>&1 || return 1
    return 0
}

nvm_versions_root() {
    printf '%s/versions/node\n' "$(detect_nvm_dir)"
}

nvm_version_dir() {
    local version="$1"
    printf '%s/%s\n' "$(nvm_versions_root)" "$version"
}

sort_node_versions() {
    ruby -e '
      versions = STDIN.read.lines.map(&:strip).reject(&:empty?)
      versions.sort_by! { |v| v.sub(/^v/, "").split(".").map(&:to_i) }
      puts versions
    ' 2>/dev/null || sort
}

scan_installed_node_versions_from_dirs() {
    local versions_root=""
    local entry=""
    local version=""

    versions_root="$(nvm_versions_root)"
    [ -d "$versions_root" ] || return 0

    find "$versions_root" -mindepth 1 -maxdepth 1 -type d -name 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null \
        | while IFS= read -r entry; do
            version="$(basename "$entry")"
            if [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                printf '%s\n' "$version"
            fi
        done \
        | sort_node_versions \
        | uniq
}

parse_nvm_default_alias_output() {
    local alias_output="${1:-}"
    local alias_value=""
    local resolved_version=""
    local status="unresolved"

    alias_output="$(trim_whitespace "$alias_output")"
    [ -n "$alias_output" ] || {
        printf '||unresolved\n'
        return 0
    }

    alias_value="$(printf '%s' "$alias_output" | sed -n 's/^default[[:space:]]*->[[:space:]]*\([^[:space:](]*\).*$/\1/p')"
    resolved_version="$(printf '%s' "$alias_output" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || true)"
    if [ -n "$resolved_version" ]; then
        status="resolved"
    fi

    printf '%s|%s|%s\n' "$alias_value" "$resolved_version" "$status"
}

get_nvm_default_info() {
    local alias_output=""

    alias_output="$(get_nvm_default_alias 2>/dev/null || true)"
    parse_nvm_default_alias_output "$alias_output"
}

read_nvm_default_alias_file_info() {
    local alias_file=""
    local alias_value=""
    local resolved=""

    alias_file="$(detect_nvm_dir)/alias/default"
    [ -f "$alias_file" ] || {
        printf '||unresolved\n'
        return 0
    }
    alias_value="$(sed -n '1p' "$alias_file" 2>/dev/null | awk '{print $1}')"
    if [[ "$alias_value" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        resolved="$alias_value"
    elif [[ "$alias_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        resolved="v$alias_value"
    elif [[ "$alias_value" =~ ^[0-9]+$ ]]; then
        local match=""
        match="$(scan_installed_node_versions_from_dirs | grep -E "^v${alias_value}\." | tail -1 || true)"
        resolved="$match"
    fi

    if [ -n "$resolved" ]; then
        printf '%s|%s|resolved\n' "$alias_value" "$resolved"
    else
        printf '%s||unresolved\n' "$alias_value"
    fi
}

is_node_path_nvm_managed() {
    local node_path="${1:-}"
    local nvm_dir=""
    local real_node=""
    local real_nvm=""

    [ -n "$node_path" ] || return 1
    [ -e "$node_path" ] || return 1
    nvm_dir="$(detect_nvm_dir)"
    [ -d "$nvm_dir" ] || return 1

    real_node="$(resolve_existing_path "$node_path")" || return 1
    real_nvm="$(cd "$nvm_dir" 2>/dev/null && pwd -P)" || return 1
    case "$real_node" in
        "$real_nvm"/versions/node/*/bin/node|"$real_nvm"/*/bin/node) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_node_version() {
    local version="${1:-}"
    version="${version#v}"
    [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
    printf 'v%s\n' "$version"
}

normalize_node_concrete_version() {
    local version="${1:-}"
    version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf 'v%s\n' "$version"
}

node_version_matches() {
    local actual=""
    local expected=""

    actual="$(normalize_node_version "$1")" || return 1
    expected="$(normalize_node_version "$2")" || return 1
    [ "$actual" = "$expected" ]
}

node_version_satisfies_request() {
    local actual=""
    local request=""
    local actual_part=""
    local request_part=""
    local index=1

    actual="$(normalize_node_version "$1")" || return 1
    request="$(normalize_node_version "$2")" || return 1
    actual="${actual#v}"
    request="${request#v}"

    IFS='.' read -r -a actual_parts <<< "$actual"
    IFS='.' read -r -a request_parts <<< "$request"

    for request_part in "${request_parts[@]}"; do
        actual_part="${actual_parts[$((index - 1))]:-}"
        [ "$actual_part" = "$request_part" ] || return 1
        index=$((index + 1))
    done

    return 0
}

installed_node_versions_satisfy_request() {
    local request="$1"
    local installed_versions="${2:-}"
    local installed_version=""

    normalize_node_version "$request" >/dev/null 2>&1 || return 1
    while IFS= read -r installed_version; do
        [ -n "$installed_version" ] || continue
        node_version_satisfies_request "$installed_version" "$request" && return 0
    done <<< "$installed_versions"

    return 1
}

select_version_from_number_or_literal() {
    local choice="$1"
    shift

    if is_nonnegative_integer "$choice" && [ "$choice" -ge 1 ] && [ "$choice" -le "$#" ]; then
        local current_index=1
        local version=""
        for version in "$@"; do
            if [ "$current_index" -eq "$choice" ]; then
                printf '%s\n' "$version"
                return 0
            fi
            current_index=$((current_index + 1))
        done
    fi

    printf '%s\n' "$choice"
}

resolve_project_nvmrc_concrete_version() {
    local requested="$1"
    shift || true
    local normalized=""
    local matched=""
    local match_count=0
    local installed_version=""

    if normalized="$(normalize_node_concrete_version "$requested" 2>/dev/null)"; then
        printf '%s\n' "$normalized"
        return 0
    fi

    normalize_node_version "$requested" >/dev/null 2>&1 || return 1
    for installed_version in "$@"; do
        [ -n "$installed_version" ] || continue
        if node_version_satisfies_request "$installed_version" "$requested"; then
            matched="$installed_version"
            match_count=$((match_count + 1))
        fi
    done

    [ "$match_count" -eq 1 ] || return 1
    normalize_node_concrete_version "$matched"
}

is_nvm_loaded() {
    command_exists nvm
}

# ──────────────────────────────────────────────
# Environment info collection (read-only)
# ──────────────────────────────────────────────

collect_env_value() {
    local label="$1"
    local value="${2:-}"

    if [ -z "$value" ]; then
        value="<unavailable>"
    fi

    printf "%-28s %s\n" "$label:" "$value"
}

collect_startup_summary() {
    local node_path=""
    local npm_path=""
    local node_version=""
    local npm_version=""
    local nvm_status=""
    local current_node=""
    local default_node=""
    local global_prefix=""
    local global_root=""
    local registry=""
    local nvm_managed=""

    node_path="$(command -v node 2>/dev/null || true)"
    npm_path="$(command -v npm 2>/dev/null || true)"
    node_version="$(node -v 2>/dev/null || true)"
    npm_version="$(npm -v 2>/dev/null || true)"

    if is_nvm_loaded; then
        local nvm_ver=""
        nvm_ver="$(nvm --version 2>/dev/null || true)"
        nvm_status="loaded${nvm_ver:+ (v$nvm_ver)}"
        current_node="$(nvm current 2>/dev/null || true)"
        default_node="$(get_nvm_default_version)"
    else
        local nvm_script=""
        local default_info=""
        nvm_script="$(nvm_script_path)"
        if [ -s "$nvm_script" ]; then
            nvm_status="installed-not-loaded"
        else
            nvm_status="<not-loaded>"
        fi
        current_node="<not-loaded>"
        default_info="$(read_nvm_default_alias_file_info)"
        default_node="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
        [ -n "$default_node" ] || default_node="<unresolved>"
    fi

    global_prefix="$(npm prefix -g 2>/dev/null || true)"
    global_root="$(npm root -g 2>/dev/null || true)"
    registry="$(npm config get registry 2>/dev/null || true)"

    # Detect if current node is nvm-managed without sourcing nvm.
    if [ -n "$node_path" ] && is_node_path_nvm_managed "$node_path"; then
        nvm_managed="yes"
    elif [ -n "$node_path" ]; then
        nvm_managed="no"
    else
        nvm_managed="<unknown>"
    fi

    collect_env_value "node 路径" "$node_path"
    collect_env_value "npm 路径" "$npm_path"
    collect_env_value "node 版本" "$node_version"
    collect_env_value "npm 版本" "$npm_version"
    collect_env_value "nvm 状态" "$nvm_status"
    collect_env_value "当前 Node 版本" "$current_node"
    collect_env_value "默认 Node 版本" "$default_node"
    collect_env_value "npm global prefix" "$global_prefix"
    collect_env_value "npm global root" "$global_root"
    collect_env_value "当前 registry" "$registry"
    collect_env_value "nvm 管理" "$nvm_managed"
}

# ──────────────────────────────────────────────
# Menu rendering
# ──────────────────────────────────────────────

render_main_menu() {
    cat <<'EOF'
1) 安装项目
2) 卸载项目
3) 更新与升级
4) 源管理
5) 环境与依赖
q) 退出
EOF
}

render_install_menu() {
    cat <<'EOF'
1) 单独安装 global package
2) 批量安装内置清单
b) 返回上一级
EOF
}

render_uninstall_menu() {
    cat <<'EOF'
1) 卸载 global package
b) 返回上一级
EOF
}

render_update_menu() {
    cat <<'EOF'
1) 扫描并升级已安装 global package
2) 指定包升级到 latest
b) 返回上一级
EOF
}

render_source_menu() {
    cat <<'EOF'
1) 查看源配置
2) 切换 registry
3) 管理 scope registry
4) 删除用户级 registry
b) 返回上一级
EOF
}

render_environment_menu() {
    cat <<'EOF'
1) 环境总览
2) 安装 nvm
3) 安装 Node.js 版本
4) 更改全局 Node 版本
5) 卸载 Node.js 版本
6) 指定项目 Node 版本
7) 清理 npm 环境
b) 返回上一级
EOF
}

# ──────────────────────────────────────────────
# Menu dispatch helpers
# ──────────────────────────────────────────────

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
        4) echo "source-management" ;;
        5) echo "environment" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_install_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "single-install" ;;
        2) echo "batch-install" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_uninstall_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "uninstall-package" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_update_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "scan-upgrade" ;;
        2) echo "upgrade-latest" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_source_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "view-source" ;;
        2) echo "switch-registry" ;;
        3) echo "scope-registry" ;;
        4) echo "reset-registry" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

dispatch_environment_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "overview" ;;
        2) echo "install-nvm" ;;
        3) echo "install-node" ;;
        4) echo "switch-node" ;;
        5) echo "uninstall-node" ;;
        6) echo "project-node" ;;
        7) echo "cleanup" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}

# ──────────────────────────────────────────────
# JSON / output parsers (deterministic, read-only)
# ──────────────────────────────────────────────

parse_global_package_names() {
    local json_path="$1"
    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        deps = data["dependencies"] || {}
        puts deps.keys.sort
    ' "$json_path" 2>/dev/null
}

parse_global_package_versions() {
    local json_path="$1"
    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        deps = data["dependencies"] || {}
        deps.keys.sort.each do |name|
          ver = deps[name]["version"] rescue "?"
          puts "#{name}|#{ver}"
        end
    ' "$json_path" 2>/dev/null
}

parse_global_package_versions_stdin() {
    ruby -rjson -e '
        data = JSON.parse(STDIN.read)
        deps = data["dependencies"] || {}
        deps.keys.sort.each do |name|
          ver = deps[name]["version"] rescue "?"
          puts "#{name}|#{ver}"
        end
    ' 2>/dev/null
}

parse_outdated_package_rows() {
    local json_path="$1"
    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        data.keys.sort.each do |name|
          row = data[name] || {}
          puts [name, row["current"], row["wanted"], row["latest"]].join("|")
        end
    ' "$json_path" 2>/dev/null
}

parse_scope_registry_lines() {
    local file_path="$1"
    sed -e 's/[[:space:]]#.*$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' "$file_path" \
        | sed -n 's/^\(@[A-Za-z0-9._-][A-Za-z0-9._-]*:registry\)[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1=\2/p'
}

parse_outdated_package_rows_stdin() {
    ruby -rjson -e '
        data = JSON.parse(STDIN.read)
        data.keys.sort.each do |name|
          row = data[name] || {}
          puts [name, row["current"], row["wanted"], row["latest"]].join("|")
        end
    ' 2>/dev/null
}

# ──────────────────────────────────────────────
# npm global package inventory (read-only)
# ──────────────────────────────────────────────

load_global_package_inventory_json() {
    npm ls -g --depth=0 --json 2>/dev/null
}

get_global_package_names() {
    local json=""
    json="$(load_global_package_inventory_json)" || true
    if [ -n "$json" ]; then
        printf '%s' "$json" | ruby -rjson -e '
            data = JSON.parse(STDIN.read)
            deps = data["dependencies"] || {}
            puts deps.keys.sort
        ' 2>/dev/null
    fi
}

get_global_package_versions() {
    local json=""
    json="$(load_global_package_inventory_json)" || true
    if [ -n "$json" ]; then
        printf '%s' "$json" | ruby -rjson -e '
            data = JSON.parse(STDIN.read)
            deps = data["dependencies"] || {}
            deps.keys.sort.each do |name|
              ver = deps[name]["version"] rescue "?"
              puts "#{name}|#{ver}"
            end
        ' 2>/dev/null
    fi
}

get_package_bin_commands() {
    local package_name="$1"
    local global_root=""
    global_root="$(npm root -g 2>/dev/null || true)"
    local pkg_json="$global_root/$package_name/package.json"

    if [ -f "$pkg_json" ]; then
        parse_package_bin_names "$pkg_json"
    fi
}

parse_package_bin_names() {
    local pkg_json="$1"
    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        name = data["name"].to_s
        bin = data["bin"]
        case bin
        when Hash
          puts bin.keys.sort
        when String
          puts name unless name.empty?
        end
    ' "$pkg_json" 2>/dev/null
}

summarize_package_metadata() {
    local pkg_json="$1"
    [ -f "$pkg_json" ] || return 1

    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        deps = data["dependencies"] || {}
        dev_deps = data["devDependencies"] || {}
        peer_deps = data["peerDependencies"] || {}
        puts "      package.json name: #{data["name"] || "<unknown>"}"
        puts "      package.json version: #{data["version"] || "<unknown>"}"
        puts "      dependencies: #{deps.length}"
        puts "      devDependencies: #{dev_deps.length}"
        puts "      peerDependencies: #{peer_deps.length}"
    ' "$pkg_json" 2>/dev/null
}

resolve_existing_path() {
    local path="$1"
    local dir=""
    local base=""

    dir="$(dirname "$path")"
    base="$(basename "$path")"
    [ -d "$dir" ] || return 1
    printf '%s/%s\n' "$(cd "$dir" 2>/dev/null && pwd -P)" "$base"
}

is_path_within_dir() {
    local path="$1"
    local dir="$2"
    local real_path=""
    local real_dir=""

    real_path="$(resolve_existing_path "$path")" || return 1
    real_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1

    case "$real_path" in
        "$real_dir"/*) return 0 ;;
        *) return 1 ;;
    esac
}

is_safe_removable_child_dir() {
    local path="$1"
    local parent_dir="$2"
    local real_path=""
    local real_parent=""

    [ -d "$path" ] || return 1
    [ -d "$parent_dir" ] || return 1
    real_path="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
    real_parent="$(cd "$parent_dir" 2>/dev/null && pwd -P)" || return 1
    [ "$real_path" != "$real_parent" ] || return 1

    case "$real_path" in
        "$real_parent"/*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_safe_user_cache_delete_path() {
    local path="$1"
    local resolved_path=""

    [ -n "$path" ] || return 1
    [ -d "$path" ] || return 1

    resolved_path="$(cd "$path" 2>/dev/null && pwd -P)" || return 1

    case "$resolved_path" in
        "$HOME"|"/"|"/tmp"|"/private/tmp")
            return 1
            ;;
        "$HOME"/*|"/tmp"/*|"/private/tmp"/*)
            printf '%s\n' "$resolved_path"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_owned_symlink() {
    local symlink_path="$1"
    local package_dir="$2"
    local target=""

    [ -L "$symlink_path" ] || return 1
    target="$(readlink "$symlink_path" 2>/dev/null)" || return 1
    case "$target" in
        /*) ;;
        *) target="$(dirname "$symlink_path")/$target" ;;
    esac

    is_path_within_dir "$target" "$package_dir"
}

resolve_symlink_target_path() {
    local symlink_path="$1"
    local target=""

    [ -L "$symlink_path" ] || return 1
    target="$(readlink "$symlink_path" 2>/dev/null)" || return 1
    case "$target" in
        /*) ;;
        *) target="$(dirname "$symlink_path")/$target" ;;
    esac
    resolve_existing_path "$target"
}

capture_symlink_snapshot() {
    local symlink_path="$1"
    local package_dir="$2"
    local target=""

    [ -L "$symlink_path" ] || return 1
    target="$(resolve_symlink_target_path "$symlink_path")" || return 1
    is_path_within_dir "$target" "$package_dir" || return 1
    printf '%s|%s|%s\n' "$symlink_path" "$target" "$package_dir"
}

verify_symlink_snapshot_current() {
    local snapshot="$1"
    local symlink_path=""
    local expected_target=""
    local package_dir=""
    local actual_target=""

    IFS='|' read -r symlink_path expected_target package_dir <<< "$snapshot"
    [ -n "$symlink_path" ] && [ -n "$expected_target" ] && [ -n "$package_dir" ] || return 1
    [ -L "$symlink_path" ] || return 1
    actual_target="$(resolve_symlink_target_path "$symlink_path")" || return 1
    [ "$actual_target" = "$expected_target" ] || return 1
    is_path_within_dir "$actual_target" "$package_dir"
}

capture_directory_snapshot() {
    local dir_path="$1"
    local parent_dir="$2"
    local real_dir=""
    local inode=""
    local mtime=""

    is_safe_removable_child_dir "$dir_path" "$parent_dir" || return 1
    real_dir="$(cd "$dir_path" 2>/dev/null && pwd -P)" || return 1
    inode="$(stat -f '%i' "$real_dir" 2>/dev/null || stat -c '%i' "$real_dir" 2>/dev/null || true)"
    mtime="$(stat -f '%m' "$real_dir" 2>/dev/null || stat -c '%Y' "$real_dir" 2>/dev/null || true)"
    [ -n "$inode" ] || return 1
    printf '%s|%s|%s|%s\n' "$real_dir" "$parent_dir" "$inode" "$mtime"
}

verify_directory_snapshot_current() {
    local snapshot="$1"
    local dir_path=""
    local parent_dir=""
    local expected_inode=""
    local expected_mtime=""
    local actual_inode=""
    local actual_mtime=""

    IFS='|' read -r dir_path parent_dir expected_inode expected_mtime <<< "$snapshot"
    [ -n "$dir_path" ] && [ -n "$parent_dir" ] && [ -n "$expected_inode" ] || return 1
    is_safe_removable_child_dir "$dir_path" "$parent_dir" || return 1
    actual_inode="$(stat -f '%i' "$dir_path" 2>/dev/null || stat -c '%i' "$dir_path" 2>/dev/null || true)"
    actual_mtime="$(stat -f '%m' "$dir_path" 2>/dev/null || stat -c '%Y' "$dir_path" 2>/dev/null || true)"
    [ "$actual_inode" = "$expected_inode" ] || return 1
    [ -z "$expected_mtime" ] || [ "$actual_mtime" = "$expected_mtime" ]
}

remove_owned_symlink_residue() {
    local symlink_path="$1"
    local package_dir="$2"

    is_owned_symlink "$symlink_path" "$package_dir" || return 1
    rm -f "$symlink_path" 2>/dev/null || return 1
    [ ! -e "$symlink_path" ] && [ ! -L "$symlink_path" ]
}

remove_snapshot_symlink_residue() {
    local snapshot="$1"
    local symlink_path=""

    verify_symlink_snapshot_current "$snapshot" || return 1
    symlink_path="${snapshot%%|*}"
    rm -f "$symlink_path" 2>/dev/null || return 1
    [ ! -e "$symlink_path" ] && [ ! -L "$symlink_path" ]
}

nvm_version_user_package_count() {
    local version_dir="$1"
    local npm_path="$version_dir/bin/npm"
    local package_json=""

    [ -x "$npm_path" ] || return 2
    package_json="$("$npm_path" ls -g --depth=0 --json 2>/dev/null)" || return 2
    [ -n "$package_json" ] || return 2
    printf '%s' "$package_json" | count_user_global_packages_from_json
}

nvm_version_package_summary() {
    local version_dir="$1"
    local npm_path="$version_dir/bin/npm"
    local package_json=""

    [ -x "$npm_path" ] || return 2
    package_json="$("$npm_path" ls -g --depth=0 --json 2>/dev/null)" || return 2
    [ -n "$package_json" ] || return 2
    printf '%s' "$package_json" | ruby -rjson -e '
        data = JSON.parse(STDIN.read)
        protected = ["npm", "corepack"]
        deps = data["dependencies"] || {}
        user = deps.keys.reject { |name| protected.include?(name) }
        prot = deps.keys.select { |name| protected.include?(name) }
        puts "user=#{user.length}|protected=#{prot.length}|total=#{deps.length}|packages=#{deps.keys.sort.join(",")}"
    ' 2>/dev/null
}

get_package_directory_size() {
    local package_name="$1"
    local global_root=""
    global_root="$(npm root -g 2>/dev/null || true)"
    local pkg_dir="$global_root/$package_name"

    if [ -d "$pkg_dir" ]; then
        du -sh "$pkg_dir" 2>/dev/null | awk '{print $1}'
    fi
}

get_global_bin_dir() {
    local prefix=""
    prefix="$(npm prefix -g 2>/dev/null || true)"
    if [ -z "$prefix" ]; then
        return 1
    fi
    printf '%s/bin' "$prefix"
}

check_bin_entries() {
    local package_name="$1"
    local global_bin_dir="$2"
    local mode="${3:-list}" # list or residue

    local bin_cmds=""
    bin_cmds="$(get_package_bin_commands "$package_name" 2>/dev/null || true)"
    [ -n "$bin_cmds" ] || return 0
    [ -d "$global_bin_dir" ] || return 0

    # Use here-string to avoid pipe subshell issues and ensure trailing newline
    # read -r handles the last line correctly with <<< even without trailing \n
    while IFS= read -r cmd; do
        [ -n "$cmd" ] || continue
        local bin_path="$global_bin_dir/$cmd"
        if [ -e "$bin_path" ] || [ -L "$bin_path" ]; then
            if [ "$mode" = "residue" ]; then
                printf "%s " "$cmd"
            else
                local bin_type="file"
                [ -L "$bin_path" ] && bin_type="symlink"
                printf "    %s %s\n" "$bin_path" "$bin_type"
            fi
        fi
    done <<< "$bin_cmds"
}

get_installed_global_package_version() {
    local package_name="$1"
    local json=""
    json="$(npm ls -g "$package_name" --depth=0 --json 2>/dev/null || true)"
    if [ -n "$json" ]; then
        printf '%s' "$json" | ruby -rjson -e '
            d = JSON.parse(STDIN.read)
            v = d.dig("dependencies",ARGV[0],"version")
            puts v || ""
        ' "$package_name" 2>/dev/null || true
    fi
}

validate_json_text() {
    command_exists ruby || return 2
    ruby -rjson -e 'JSON.parse(STDIN.read)' >/dev/null 2>&1
}

count_user_global_packages_from_json() {
    command_exists ruby || return 2
    ruby -rjson -e '
        data = JSON.parse(STDIN.read)
        protected = ["npm", "corepack"]
        deps = data["dependencies"] || {}
        puts deps.keys.reject { |name| protected.include?(name) }.length
    ' 2>/dev/null
}

detect_node_gyp_cache_dir() {
    detect_node_gyp_cache_dirs | sed -n '1s/|.*$//p'
}

detect_node_gyp_cache_dirs() {
    local devdir="${npm_config_devdir:-}"
    if [ -n "$devdir" ]; then
        printf '%s|npm_config_devdir\n' "$devdir"
    fi

    if command_exists npm; then
        devdir="$(npm config get devdir 2>/dev/null || true)"
        case "$devdir" in
            ""|"undefined"|"null") ;;
            *) printf '%s|npm-config-devdir\n' "$devdir" ;;
        esac
    fi

    printf '%s|legacy-home\n' "$HOME/.node-gyp"
    printf '%s|macos-cache\n' "$HOME/Library/Caches/node-gyp"
    if command_exists npm; then
        local npm_cache=""
        npm_cache="$(npm config get cache 2>/dev/null || true)"
        case "$npm_cache" in
            ""|"undefined"|"null") ;;
            *) printf '%s|npm-cache-derived\n' "$npm_cache/node-gyp" ;;
        esac
    fi
}

load_batch_package_list() {
    local file_path="${1:-$GLOBAL_PACKAGES_FILE}"
    [ -f "$file_path" ] || return 0

    sed -e 's/#.*$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' "$file_path" \
        | sed '/^$/d'
}

select_pending_indices_from_flags() {
    local flags="$1"
    local index=1
    local flag=""
    local selected=""

    for flag in $flags; do
        if [ "$flag" = "no" ]; then
            selected="${selected:+$selected }$index"
        fi
        index=$((index + 1))
    done

    printf '%s\n' "$selected"
}

validate_package_spec() {
    local spec="${1:-}"

    parse_package_spec "$spec" >/dev/null 2>&1
}

validate_package_name_only() {
    local spec="${1:-}"
    local parsed=""
    local requested=""

    parsed="$(parse_package_spec "$spec")" || return 1
    requested="$(printf '%s' "$parsed" | awk -F'|' '{print $2}')"
    [ -z "$requested" ]
}

parse_package_spec() {
    local spec="${1:-}"
    local package_name=""
    local requested=""
    local scope=""
    local rest=""
    local name_part=""

    case "$spec" in
        ""|*"://"*|npm:*|file:*|git:*|github:*|*".."*|*","*|*" "*|*"|"*)
            return 1
            ;;
    esac
    case "$spec" in
        *"/"*"/"*) return 1 ;;
    esac

    if [[ "$spec" == @* ]]; then
        case "$spec" in
            @*/*) ;;
            *) return 1 ;;
        esac
        scope="${spec%%/*}"
        rest="${spec#*/}"
        if [[ "$rest" == *@* ]]; then
            name_part="${rest%%@*}"
            requested="${rest#*@}"
            [ -n "$requested" ] || return 1
        else
            name_part="$rest"
        fi
        package_name="$scope/$name_part"
        validate_package_name_component "${scope#@}" || return 1
        validate_package_name_component "$name_part" || return 1
    else
        if [[ "$spec" == *@* ]]; then
            package_name="${spec%%@*}"
            requested="${spec#*@}"
            [ -n "$requested" ] || return 1
        else
            package_name="$spec"
        fi
        validate_package_name_component "$package_name" || return 1
    fi

    if [ -n "$requested" ]; then
        [[ "$requested" =~ ^[A-Za-z0-9][A-Za-z0-9._~+-]*$ ]] || return 1
    fi

    printf '%s|%s|%s\n' "$package_name" "$requested" "$spec"
}

validate_package_name_component() {
    local name="${1:-}"

    case "$name" in
        ""|.*|_*|node_modules|favicon.ico)
            return 1
            ;;
    esac

    [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

get_registry_latest_version() {
    local package_name="$1"
    local latest_version=""

    latest_version="$(npm_view_resolved_version "$package_name")" || return 1
    trim_whitespace "$latest_version"
}

extract_version_from_npm_view_text() {
    local view_output="${1:-}"
    local target_version=""

    target_version="$(printf '%s\n' "$view_output" | sed '/^[[:space:]]*$/d' | sed -n '$p')"
    target_version="$(trim_whitespace "$target_version")"
    target_version="${target_version#\'}"
    target_version="${target_version%\'}"
    target_version="${target_version#\"}"
    target_version="${target_version%\"}"
    if ! [[ "$target_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9._-]+)?$ ]]; then
        target_version="$(printf '%s\n' "$target_version" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9._-]+)?' | tail -1 || true)"
    fi
    [ -n "$target_version" ] || return 1
    printf '%s' "$target_version"
}

npm_view_resolved_version() {
    local package_spec="$1"
    local view_output=""
    local target_version=""

    if command_exists ruby; then
        view_output="$(npm view "$package_spec" version --json 2>/dev/null)" || view_output=""
        if [ -n "$view_output" ]; then
            target_version="$(printf '%s' "$view_output" | ruby -rjson -e '
                value = JSON.parse(STDIN.read)
                if value.is_a?(Array)
                  puts(value.compact.last || "")
                elsif value.is_a?(String) || value.is_a?(Numeric)
                  puts(value)
                else
                  puts("")
                end
            ' 2>/dev/null || true)"
            target_version="$(trim_whitespace "$target_version")"
            if [ -n "$target_version" ]; then
                printf '%s' "$target_version"
                return 0
            fi
            if target_version="$(extract_version_from_npm_view_text "$view_output")"; then
                printf '%s' "$target_version"
                return 0
            fi
        fi
    fi

    view_output="$(npm view "$package_spec" version 2>/dev/null)" || return 1
    extract_version_from_npm_view_text "$view_output"
}

requested_package_version_is_exact() {
    local requested="${1:-}"
    [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9._-]*)?(\+[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]
}

resolve_install_target_version() {
    local package_spec="$1"
    local parsed=""
    local package_name=""
    local requested=""
    local target_version=""

    parsed="$(parse_package_spec "$package_spec")" || return 1
    package_name="$(printf '%s' "$parsed" | awk -F'|' '{print $1}')"
    requested="$(printf '%s' "$parsed" | awk -F'|' '{print $2}')"
    if [ -z "$requested" ]; then
        target_version="$(npm_view_resolved_version "$package_name")" || return 1
        [ -n "$target_version" ] || return 1
        printf '%s' "$target_version"
        return 0
    fi

    if requested_package_version_is_exact "$requested"; then
        printf '%s' "$requested"
        return 0
    fi

    target_version="$(npm_view_resolved_version "$package_spec")" || return 1
    [ -n "$target_version" ] || return 1
    printf '%s' "$target_version"
}

verify_install_result_for_spec() {
    local package_spec="$1"
    local installed_version="$2"
    local target_version="${3-}"

    [ -n "$installed_version" ] || {
        printf 'failed|npm 报告成功但无法读取已安装版本|\n'
        return 1
    }

    if [ "$#" -lt 3 ] && ! target_version="$(resolve_install_target_version "$package_spec")"; then
        printf 'failed|无法解析请求的目标版本|\n'
        return 1
    fi

    if [ -n "$target_version" ] && [ "$installed_version" != "$target_version" ]; then
        printf 'failed|安装版本不符合请求|%s\n' "$target_version"
        return 1
    fi

    printf 'ok|安装验证通过|%s\n' "$target_version"
    return 0
}

npm_package_is_installed() {
    local package_name="$1"
    npm ls -g "$package_name" --depth=0 >/dev/null 2>&1
}

is_install_spec_satisfied() {
    local package_spec="$1"
    local installed_version="$2"
    local target_version="${3-}"

    [ -n "$installed_version" ] || return 1
    if [ "$#" -lt 3 ]; then
        target_version="$(resolve_install_target_version "$package_spec")" || return 1
    fi
    [ -z "$target_version" ] && return 0
    [ "$installed_version" = "$target_version" ]
}

extract_package_requested_version_or_tag() {
    local parsed=""
    parsed="$(parse_package_spec "${1:-}")" || return 1
    printf '%s' "$parsed" | awk -F'|' '{print $2}'
}

validate_scope_name() {
    local scope="${1:-}"
    case "$scope" in
        @*) validate_package_name_component "${scope#@}" ;;
        *) return 1 ;;
    esac
}

validate_registry_url() {
    local url="${1:-}"
    [[ "$url" =~ ^https://[^[:space:]]+/$ ]] && return 0
    [[ "$url" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?/$ ]] && return 0
    return 1
}

normalize_package_name_from_spec() {
    extract_package_name "$1"
}

sanitize_filename_component() {
    printf '%s' "${1:-item}" | tr '/:@ ' '____' | sed 's/[^A-Za-z0-9._-]/_/g'
}

create_log_file() {
    local action="$1"
    local subject="${2:-run}"
    local template=""

    ensure_runtime_dirs || return 1
    template="$(printf '%s/%s-%s-%s-%s.log.XXXXXX' \
        "$(manager_log_dir)" \
        "$(sanitize_filename_component "$action")" \
        "$(sanitize_filename_component "$subject")" \
        "$(date +%Y%m%d-%H%M%S)" \
        "$$")"
    mktemp "$template"
}

create_log_file_hint() {
    local action="$1"
    local subject="${2:-run}"

    printf '%s/%s-%s-<timestamp>-<pid>.log.*' \
        "$(manager_log_dir)" \
        "$(sanitize_filename_component "$action")" \
        "$(sanitize_filename_component "$subject")"
}

create_operation_id() {
    printf '%s-%s-%s\n' "$(date +%Y%m%d%H%M%S)" "$$" "$(sanitize_filename_component "${1:-operation}")"
}

run_logged_command() {
    local log_file="$1"
    shift
    local lock_name=""
    local acquired_lock_here="no"

    case "${1:-}" in
        npm)
            case "${2:-}" in
                install|uninstall|update|cache)
                    lock_name="npm-mutation"
                    ;;
            esac
            ;;
        nvm)
            case "${2:-}" in
                install|uninstall|use|alias)
                    lock_name="nvm-mutation"
                    ;;
            esac
            ;;
    esac

    if [ -n "$lock_name" ]; then
        if runtime_lock_owned_by_current_process "$lock_name"; then
            acquired_lock_here="no"
        elif acquire_runtime_lock "$lock_name"; then
            acquired_lock_here="yes"
        else
            printf "LOCKED: %s\n" "$lock_name" >> "$log_file" 2>&1 || true
            return 1
        fi
    fi

    {
        printf "COMMAND:"
        printf " %s" "$@"
        printf "\n"
        "$@"
    } >> "$log_file" 2>&1
    local command_exit=$?
    printf "EXIT_CODE: %s\n" "$command_exit" >> "$log_file" 2>&1 || true
    if [ "$acquired_lock_here" = "yes" ]; then
        release_runtime_lock "$lock_name"
    fi
    return "$command_exit"
}

atomic_write_file() {
    local target="$1"
    local content="$2"
    local dir=""
    local tmp=""

    dir="$(dirname "$target")"
    [ -d "$dir" ] || return 1
    tmp="$(mktemp "$dir/.tmp.$(basename "$target").XXXXXX")" || return 1

    if ! printf '%s\n' "$content" > "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    mv "$tmp" "$target"
}

rollback_nvmrc_file() {
    local nvmrc="$1"
    local had_previous="$2"
    local previous_content="${3:-}"

    if [ "$had_previous" = "yes" ]; then
        atomic_write_file "$nvmrc" "$previous_content"
    else
        rm -f "$nvmrc" 2>/dev/null
    fi
}

# ──────────────────────────────────────────────
# Protected package logic
# ──────────────────────────────────────────────

is_protected_global_package() {
    local package_name="$1"
    local item=""
    for item in "${PROTECTED_GLOBAL_PACKAGES[@]}"; do
        [ "$item" = "$package_name" ] && return 0
    done
    return 1
}

# ──────────────────────────────────────────────
# Registry helpers (read-only)
# ──────────────────────────────────────────────

get_current_registry() {
    npm config get registry 2>/dev/null || true
}

npm_config_get_layer() {
    local key="$1"
    local location="$2"
    if [ "$location" = "effective" ]; then
        npm config get "$key" 2>/dev/null || true
        return 0
    fi
    npm config get "$key" "--location=$location" 2>/dev/null || true
}

normalize_npm_config_value() {
    local value="${1:-}"
    case "$value" in
        ""|"undefined"|"null") printf '<unset>\n' ;;
        *) printf '%s\n' "$value" ;;
    esac
}

print_scope_registry_layers() {
    local scope_name="$1"
    validate_scope_name "$scope_name" || return 1

    printf "%s:registry\n" "$scope_name"
    printf "  effective: %s\n" "$(normalize_npm_config_value "$(npm config get "${scope_name}:registry" 2>/dev/null || true)")"
    printf "  user (--location=user): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "${scope_name}:registry" user)")"
    printf "  project (--location=project): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "${scope_name}:registry" project)")"
    printf "  global (--location=global): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "${scope_name}:registry" global)")"
}

get_npm_cache_path() {
    npm config get cache 2>/dev/null || true
}

# ──────────────────────────────────────────────
# Registry mutation helpers (with verification)
# ──────────────────────────────────────────────

set_registry_value() {
    local registry_url="$1"
    local user_value=""
    local effective_value=""

    validate_registry_url "$registry_url" || return 1
    npm config set registry "$registry_url" --location=user || return 1
    user_value="$(npm config get registry --location=user 2>/dev/null || true)"
    [ "$user_value" = "$registry_url" ] || return 1

    effective_value="$(npm config get registry 2>/dev/null || true)"
    if [ "$effective_value" = "$registry_url" ]; then
        printf 'effective-ok\n'
    else
        printf 'effective-mismatch:%s\n' "${effective_value:-<unavailable>}"
    fi
    return 0
}

delete_registry_value() {
    npm config delete registry --location=user || return 1
    local value=""
    value="$(npm config get registry --location=user 2>/dev/null || true)"
    [ -z "$value" ] || [ "$value" = "undefined" ] || [ "$value" = "null" ]
}

set_scope_registry_value() {
    local scope_name="$1"
    local registry_url="$2"
    local user_value=""
    local effective_value=""

    validate_scope_name "$scope_name" || return 1
    validate_registry_url "$registry_url" || return 1
    npm config set "${scope_name}:registry" "$registry_url" --location=user || return 1
    user_value="$(npm config get "${scope_name}:registry" --location=user 2>/dev/null || true)"
    [ "$user_value" = "$registry_url" ] || return 1

    effective_value="$(npm config get "${scope_name}:registry" 2>/dev/null || true)"
    if [ "$effective_value" = "$registry_url" ]; then
        printf 'effective-ok\n'
    else
        printf 'effective-mismatch:%s\n' "${effective_value:-<unavailable>}"
    fi
    return 0
}

delete_scope_registry_value() {
    local scope_name="$1"
    validate_scope_name "$scope_name" || return 1
    npm config delete "${scope_name}:registry" --location=user || return 1
    local value=""
    value="$(npm config get "${scope_name}:registry" --location=user 2>/dev/null || true)"
    [ -z "$value" ] || [ "$value" = "undefined" ] || [ "$value" = "null" ]
}

verify_scope_registry_deleted_user_layer() {
    local scope_name="$1"
    local user_value=""
    local effective_value=""

    validate_scope_name "$scope_name" || return 1
    user_value="$(npm_config_get_layer "${scope_name}:registry" user)"
    if [ -n "$user_value" ] && [ "$user_value" != "undefined" ] && [ "$user_value" != "null" ]; then
        print_status_message "warn" "用户级 scope registry 删除后仍存在: $user_value"
        return 1
    fi

    effective_value="$(npm_config_get_layer "${scope_name}:registry" effective)"
    if [ -n "$effective_value" ] && [ "$effective_value" != "undefined" ] && [ "$effective_value" != "null" ]; then
        print_status_message "ok" "用户级 scope registry 已删除"
        print_status_message "warn" "project/global/builtin 仍提供 effective scope registry: $effective_value"
        return 0
    fi

    print_status_message "ok" "scope registry 已删除"
    return 0
}

# ──────────────────────────────────────────────
# Install helpers
# ──────────────────────────────────────────────

extract_package_name() {
    local input="$1"
    local parsed=""

    parsed="$(parse_package_spec "$input")" || {
        printf '%s' "$input"
        return 1
    }
    printf '%s' "$parsed" | awk -F'|' '{print $1}'
}

install_global_package() {
    local package_name="$1"
    local log_file="${2:-}"
    [ -n "$log_file" ] || log_file="$(create_log_file install "$package_name")" || return 1
    run_logged_command "$log_file" npm install -g "$package_name"
}

upgrade_global_package_to_latest() {
    local package_name="$1"
    local log_file="${2:-}"
    [ -n "$log_file" ] || log_file="$(create_log_file upgrade-latest "$package_name")" || return 1
    run_logged_command "$log_file" npm install -g "${package_name}@latest"
}

upgrade_global_package() {
    local package_name="$1"
    local log_file="${2:-}"
    [ -n "$log_file" ] || log_file="$(create_log_file upgrade "$package_name")" || return 1
    run_logged_command "$log_file" npm update -g "$package_name"
}

scan_outdated_package_row() {
    local package_name="$1"
    local outdated_json=""
    local stderr_file=""
    local stderr_text=""
    local exit_code=0

    ensure_runtime_dirs || return 2
    stderr_file="$(mktemp "$(manager_tmp_dir)/npm-outdated-package.XXXXXX")" || return 2
    outdated_json="$(npm outdated -g "$package_name" --depth=0 --json 2>"$stderr_file")" || exit_code=$?
    stderr_text="$(sed -n '1,10p' "$stderr_file" 2>/dev/null || true)"
    rm -f "$stderr_file" 2>/dev/null || true

    if [ "$exit_code" -gt 1 ] || { [ "$exit_code" -eq 1 ] && [ -z "$outdated_json" ] && [ -n "$stderr_text" ]; }; then
        return 2
    fi
    [ -n "$outdated_json" ] && [ "$outdated_json" != "{}" ] || return 1
    printf '%s' "$outdated_json" | parse_outdated_package_rows_stdin | awk -F'|' -v pkg="$package_name" '$1 == pkg { print; found=1 } END { exit found ? 0 : 1 }'
}

verify_global_package_update_result() {
    local package_name="$1"
    local old_version="$2"
    local wanted_version="$3"
    local new_version=""
    local row=""

    new_version="$(get_installed_global_package_version "$package_name")"
    if [ -z "$new_version" ]; then
        printf 'failed|升级后无法读取版本|\n'
        return 1
    fi

    if row="$(scan_outdated_package_row "$package_name" 2>/dev/null)"; then
        printf 'failed|升级后仍出现在 outdated 列表: %s|%s\n' "$row" "$new_version"
        return 1
    fi

    local scan_exit=$?
    if [ "$scan_exit" -eq 2 ]; then
        if [ "$new_version" = "$wanted_version" ] || [ "$new_version" != "$old_version" ]; then
            printf 'warn|复扫失败，已用版本变化降级验证|%s\n' "$new_version"
            return 0
        fi
        printf 'failed|复扫失败且版本未达预期|%s\n' "$new_version"
        return 1
    fi

    if [ "$new_version" = "$old_version" ]; then
        printf 'failed|版本未变化|%s\n' "$new_version"
        return 1
    fi

    printf 'ok|不再出现在 outdated 列表|%s\n' "$new_version"
    return 0
}

# ──────────────────────────────────────────────
# Uninstall helpers
# ──────────────────────────────────────────────

uninstall_global_package() {
    local package_name="$1"
    local log_file="${2:-}"
    if is_protected_global_package "$package_name"; then
        return 2
    fi
    [ -n "$log_file" ] || log_file="$(create_log_file uninstall "$package_name")" || return 1
    run_logged_command "$log_file" npm uninstall -g "$package_name"
}

# ──────────────────────────────────────────────
# nvm & Node environment actions
# ──────────────────────────────────────────────

nvm_install_unverified_blocked() {
    [ -z "$NVM_INSTALL_SHA256" ] && [ "$NVM_ALLOW_UNVERIFIED_INSTALL" != "1" ]
}

render_nvm_install_unverified_blocked_json() {
    local subject="${1:-$NVM_INSTALL_VERSION}"
    local log_file="${2:-}"

    printf '{'
    printf '"code":"nvm-install-unverified-blocked",'
    printf '"action":"nvm-install",'
    printf '"subject":"%s",' "$(json_escape "${subject:-$NVM_INSTALL_VERSION}")"
    printf '"version":"%s",' "$(json_escape "$NVM_INSTALL_VERSION")"
    printf '"installUrl":"%s",' "$(json_escape "$NVM_INSTALL_URL")"
    printf '"sha256Configured":false,'
    printf '"allowUnverified":%s' "$([ "$NVM_ALLOW_UNVERIFIED_INSTALL" = "1" ] && printf true || printf false)"
    if [ -n "$log_file" ]; then
        printf ',"logFile":"%s"' "$(json_escape "$log_file")"
    fi
    printf '}\n'
}

install_nvm_official() {
    if nvm_install_unverified_blocked; then
        print_status_message "fail" "默认安装路径需要 NVM_INSTALL_SHA256 校验"
        printf "如需执行未校验下载脚本，请显式设置 NVM_ALLOW_UNVERIFIED_INSTALL=1 后重试。\n"
        return 1
    fi
    command_exists curl || {
        print_status_message "fail" "缺少 curl，无法下载安装脚本"
        return 127
    }
    command_exists bash || {
        print_status_message "fail" "缺少 bash，无法执行安装脚本"
        return 127
    }
    ensure_runtime_dirs || return 1

    local install_script=""
    install_script="$(mktemp "$(manager_tmp_dir)/nvm-install.sh.XXXXXX")" || return 1

    if ! curl -fsSL "$NVM_INSTALL_URL" -o "$install_script"; then
        print_status_message "fail" "nvm 安装脚本下载失败"
        rm -f "$install_script" 2>/dev/null || true
        return 1
    fi

    if [ -n "$NVM_INSTALL_SHA256" ]; then
        command_exists shasum || {
            print_status_message "fail" "配置了 NVM_INSTALL_SHA256 但缺少 shasum"
            rm -f "$install_script" 2>/dev/null || true
            return 127
        }
        local actual_sha=""
        actual_sha="$(shasum -a 256 "$install_script" 2>/dev/null | awk '{print $1}')"
        if [ "$actual_sha" != "$NVM_INSTALL_SHA256" ]; then
            print_status_message "fail" "nvm 安装脚本 SHA256 校验失败"
            printf "  期望: %s\n" "$NVM_INSTALL_SHA256"
            printf "  实际: %s\n" "${actual_sha:-<unknown>}"
            rm -f "$install_script" 2>/dev/null || true
            return 1
        fi
    fi

    if ! bash "$install_script"; then
        print_status_message "fail" "nvm 安装脚本执行失败"
        rm -f "$install_script" 2>/dev/null || true
        return 1
    fi

    rm -f "$install_script" 2>/dev/null || true
    return 0
}

get_installed_node_versions() {
    local dir_versions=""

    dir_versions="$(scan_installed_node_versions_from_dirs)"
    if [ -n "$dir_versions" ]; then
        printf '%s\n' "$dir_versions"
        return 0
    fi

    load_nvm_into_current_shell || return 1
    nvm ls --no-colors 2>/dev/null \
        | grep -E '^[[:space:]]*(->[[:space:]])?[[:space:]]*v[0-9]' \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | sort_node_versions \
        | uniq
}

get_nvm_current_version() {
    load_nvm_into_current_shell || return 1
    nvm current 2>/dev/null
}

get_nvm_default_alias() {
    load_nvm_into_current_shell || return 1
    nvm alias default 2>/dev/null
}

get_nvm_default_version() {
    local info=""
    local resolved=""

    info="$(get_nvm_default_info)"
    resolved="$(printf '%s' "$info" | awk -F'|' '{print $2}')"
    printf '%s' "$resolved"
}

install_node_lts() {
    local lts_target="${1:---lts}"
    load_nvm_into_current_shell || return 1
    acquire_runtime_lock "nvm-mutation" || return 1
    nvm install "$lts_target"
    local install_exit=$?
    if [ "$install_exit" -ne 0 ]; then
        release_runtime_lock "nvm-mutation"
        return 1
    fi
    nvm use "$lts_target"
    local use_exit=$?
    release_runtime_lock "nvm-mutation"
    [ "$use_exit" -eq 0 ] || return 1
    local resolved=""
    resolved="$(nvm current 2>/dev/null || true)"
    [ -n "$resolved" ] && [[ "$resolved" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

install_node_version() {
    local version="$1"
    load_nvm_into_current_shell || return 1
    acquire_runtime_lock "nvm-mutation" || return 1
    nvm install "$version"
    local install_exit=$?
    if [ "$install_exit" -ne 0 ]; then
        release_runtime_lock "nvm-mutation"
        return 1
    fi
    nvm use "$version"
    local use_exit=$?
    release_runtime_lock "nvm-mutation"
    [ "$use_exit" -eq 0 ] || return 1
    local actual=""
    actual="$(node -v 2>/dev/null || true)"
    node_version_satisfies_request "$actual" "$version"
}

switch_node_version() {
    local version="$1"
    load_nvm_into_current_shell || return 1
    acquire_runtime_lock "nvm-mutation" || return 1
    nvm use "$version"
    local use_exit=$?
    release_runtime_lock "nvm-mutation"
    return "$use_exit"
}

set_node_default_alias() {
    local version="$1"
    load_nvm_into_current_shell || return 1
    acquire_runtime_lock "nvm-mutation" || return 1
    nvm alias default "$version"
    local alias_exit=$?
    release_runtime_lock "nvm-mutation"
    return "$alias_exit"
}

set_node_default_alias_verified() {
    local target_version="$1"
    if ! set_node_default_alias "$target_version"; then
        print_status_message "fail" "设置默认版本失败"
        return 1
    fi
    local actual_def=""
    actual_def="$(get_nvm_default_version)"
    if [ "$actual_def" = "$target_version" ]; then
        print_status_message "ok" "默认版本已设置为 $target_version"
        printf "  验证: default = %s\n" "$actual_def"
        return 0
    else
        print_status_message "warn" "设置命令成功但验证不一致"
        printf "  期望: %s\n" "$target_version"
        printf "  实际: %s\n" "${actual_def:-<unknown>}"
        return 1
    fi
}

# ──────────────────────────────────────────────
# Flow: startup page
# ──────────────────────────────────────────────

render_startup_page() {
    print_page_title "npm / Node 全局环境管理"
    printf "当前环境摘要\n"
    print_separator
    collect_startup_summary
    print_separator
    print_blank_line
    render_main_menu
}

# ──────────────────────────────────────────────
# Flow: environment overview
# ──────────────────────────────────────────────

run_environment_overview() {
    print_page_title "环境总览"
    printf "环境总览\n"
    print_separator
    collect_startup_summary
    print_separator

    print_blank_line
    printf "nvm 诊断:\n"
    local detected_nvm_dir=""
    local detected_nvm_script=""
    detected_nvm_dir="$(detect_nvm_dir)"
    detected_nvm_script="$(nvm_script_path)"
    printf "  NVM_DIR: %s\n" "$detected_nvm_dir"
    printf "  nvm_script_path: %s\n" "$detected_nvm_script"
    if [ -s "$detected_nvm_script" ]; then
        printf "  nvm.sh: 存在\n"
    else
        printf "  nvm.sh: 不存在或不可读\n"
    fi
    if is_nvm_loaded; then
        printf "  loaded: yes\n"
    else
        printf "  loaded: no\n"
    fi

    local scanned_versions=""
    scanned_versions="$(scan_installed_node_versions_from_dirs)"
    print_blank_line
    printf "nvm versions 目录扫描:\n"
    if [ -n "$scanned_versions" ]; then
        printf "%s\n" "$scanned_versions"
    else
        printf "  <none>\n"
    fi

    # nvm installed versions detail
    if is_nvm_loaded; then
        print_blank_line
        printf "nvm 已安装的 Node 版本:\n"
        local versions=""
        versions="$(nvm ls --no-colors 2>/dev/null || true)"
        if [ -n "$versions" ]; then
            printf "%s\n" "$versions"
        else
            printf "  <none>\n"
        fi
    fi

    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: single install
# ──────────────────────────────────────────────

run_single_install_flow() {
    local package_name=""
    local node_version=""
    local global_prefix=""
    local attempt=0
    local max_retries="$INSTALL_MAX_RETRIES"
    local log_file=""
    local target_version=""
    local bare_name=""
    local installed_version=""
    local registry=""

    print_page_title "单独安装 global package"

    node_version="$(node -v 2>/dev/null || echo '<unavailable>')"
    global_prefix="$(npm prefix -g 2>/dev/null || echo '<unavailable>')"
    registry="$(npm config get registry 2>/dev/null || echo '<unavailable>')"

    printf "当前 Node 版本: %s\n" "$node_version"
    printf "npm global prefix: %s\n" "$global_prefix"
    print_blank_line

    printf "请输入包名(支持 package、@scope/package、package@version、package@tag): "
    read -r package_name || return 0
    package_name="$(trim_whitespace "$package_name")"
    [ -n "$package_name" ] || return 0
    if ! validate_package_spec "$package_name"; then
        print_status_message "fail" "包名格式不支持: $package_name"
        printf "仅支持安全 registry 子集: package、@scope/package、package@version、package@tag。\n"
        pause_before_return
        return 1
    fi

    bare_name="$(extract_package_name "$package_name")"
    if ! target_version="$(resolve_install_target_version "$package_name")"; then
        print_status_message "fail" "无法解析请求的目标版本: $package_name"
        pause_before_return
        return 1
    fi
    installed_version="$(get_installed_global_package_version "$bare_name")"

    print_blank_line
    printf "准备安装:\n"
    printf "  package spec: %s\n" "$package_name"
    printf "  package name: %s\n" "$bare_name"
    printf "  target version: %s\n" "$target_version"
    printf "  installed version: %s\n" "${installed_version:-<not installed>}"
    printf "  npm global prefix: %s\n" "$global_prefix"
    printf "  registry: %s\n" "$registry"
    printf "  log: 执行开始后创建\n"
    print_separator

    if ! prompt_yes_no "确认安装？" "n"; then
        return 0
    fi

    log_file="$(create_log_file install "$package_name")" || return 1

    attempt=0
    while [ "$attempt" -le "$max_retries" ]; do
        if [ "$attempt" -gt 0 ]; then
            printf "\n重试第 %d 次...\n" "$attempt"
        fi

        if install_global_package "$package_name" "$log_file"; then
            # Verify installation: version must be readable
            installed_version="$(get_installed_global_package_version "$bare_name")"

            local verify_result=""
            local verify_status=""
            local verify_message=""
            local verify_target=""
            verify_result="$(verify_install_result_for_spec "$package_name" "$installed_version" "$target_version" || true)"
            verify_status="$(printf '%s' "$verify_result" | awk -F'|' '{print $1}')"
            verify_message="$(printf '%s' "$verify_result" | awk -F'|' '{print $2}')"
            verify_target="$(printf '%s' "$verify_result" | awk -F'|' '{print $3}')"

            if [ "$verify_status" != "ok" ]; then
                print_blank_line
                print_status_message "warn" "$package_name: ${verify_message:-安装验证失败}"
                if [ -n "$verify_target" ]; then
                    printf "  期望版本: %s\n" "$verify_target"
                    printf "  实际版本: %s\n" "${installed_version:-<unknown>}"
                fi
                attempt=$((attempt + 1))
                if [ "$attempt" -gt "$max_retries" ]; then
                    break
                fi
                if ! prompt_yes_no "验证失败，是否重试？" "y"; then
                    break
                fi
                continue
            fi

            local bin_commands=""
            bin_commands="$(get_package_bin_commands "$bare_name" 2>/dev/null || true)"

            print_blank_line
            print_status_message "ok" "安装成功"
            printf "  包名: %s\n" "$bare_name"
            printf "  版本: %s\n" "$installed_version"
            if [ -n "$bin_commands" ]; then
                printf "  bin 命令:\n"
                while IFS= read -r cmd; do
                    [ -n "$cmd" ] || continue
                    printf "    - %s\n" "$cmd"
                done <<< "$bin_commands"
            fi
            pause_before_return
            return 0
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$max_retries" ]; then
            break
        fi

        if ! prompt_yes_no "安装失败，是否重试？" "y"; then
            break
        fi
    done

    print_blank_line
    print_status_message "fail" "安装失败: $package_name"
    printf "日志文件: %s\n" "$log_file"
    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: batch install
# ──────────────────────────────────────────────

run_batch_install_flow() {
    local package_name=""
    local total=0
    local installed=0
    local skipped=0
    local succeeded=0
    local failed=0
    local warned=0
    local unknown=0
    local already_installed=""
    local -a batch_packages=()
    local -a batch_package_names=()
    local -a batch_target_versions=()
    local -a batch_installed_flags=()

    print_page_title "批量安装内置清单"

    while IFS= read -r package_name; do
        [ -n "$package_name" ] || continue
        batch_packages+=("$package_name")
    done <<< "$(load_batch_package_list)"

    if [ ${#batch_packages[@]} -eq 0 ] && [ ${#INSTALLABLE_GLOBAL_PACKAGES[@]} -gt 0 ]; then
        batch_packages=("${INSTALLABLE_GLOBAL_PACKAGES[@]}")
    fi

    if [ ${#batch_packages[@]} -eq 0 ]; then
        printf "批量安装清单为空，请配置: %s\n" "$GLOBAL_PACKAGES_FILE"
        pause_before_return
        return 0
    fi

    for package_name in "${batch_packages[@]}"; do
        if ! validate_package_spec "$package_name"; then
            print_status_message "fail" "清单包含不支持的包名格式: $package_name"
            printf "请修改: %s\n" "$GLOBAL_PACKAGES_FILE"
            pause_before_return
            return 1
        fi
        batch_package_names+=("$(extract_package_name "$package_name")")
        local target_version=""
        if ! target_version="$(resolve_install_target_version "$package_name")"; then
            print_status_message "fail" "无法解析请求的目标版本: $package_name"
            pause_before_return
            return 1
        fi
        batch_target_versions+=("$target_version")
    done

    total=${#batch_packages[@]}
    printf "内置清单共 %d 个包:\n" "$total"
    print_separator

    local pkg_index=0
    for package_name in "${batch_packages[@]}"; do
        local bare_package_name="${batch_package_names[$pkg_index]}"
        local target_version="${batch_target_versions[$pkg_index]}"
        local installed_version=""
        installed_version="$(get_installed_global_package_version "$bare_package_name")"
        if is_install_spec_satisfied "$package_name" "$installed_version" "$target_version"; then
            already_installed="yes"
        else
            already_installed="no"
        fi
        batch_installed_flags+=("$already_installed")
        if [ "$already_installed" = "yes" ]; then
            printf "  [已安装] %s -> target %s, installed %s\n" "$package_name" "$target_version" "${installed_version:-<unknown>}"
            installed=$((installed + 1))
        else
            printf "  [待安装] %s -> target %s, installed %s\n" "$package_name" "$target_version" "${installed_version:-<not installed>}"
        fi
        pkg_index=$((pkg_index + 1))
    done

    print_separator
    printf "已安装: %d | 待安装: %d\n" "$installed" $((total - installed))
    print_blank_line

    if [ "$installed" -eq "$total" ]; then
        printf "所有包均已安装，无需操作。\n"
        pause_before_return
        return 0
    fi

    printf "选择要安装的包(多个用空格、逗号或范围分隔，all 全部待安装，b 返回): "
    local batch_choice=""
    read -r batch_choice || return 0
    batch_choice="$(trim_whitespace "$batch_choice")"
    [ -n "$batch_choice" ] || batch_choice="all"

    local batch_parsed=""
    batch_parsed="$(parse_multi_numeric_choice "$batch_choice" "$total")"
    if [ "$batch_parsed" = "back" ]; then
        return 0
    fi
    if [ "$batch_parsed" = "invalid" ]; then
        print_status_message "warn" "输入无效。"
        pause_before_return
        return 0
    fi

    local -a selected_indices=()
    if [ "$batch_parsed" = "all" ]; then
        local pending_indices=""
        pending_indices="$(select_pending_indices_from_flags "${batch_installed_flags[*]}")"
        for token in $pending_indices; do
            selected_indices+=("$token")
        done
    else
        for token in $batch_parsed; do
            selected_indices+=("$token")
        done
    fi

    if ! prompt_yes_no "是否开始批量安装？" "y"; then
        return 0
    fi

    # Set up log file
    local log_file=""
    log_file="$(create_log_file batch-install summary)"

    print_blank_line
    printf "开始批量安装...\n"
    printf "日志文件: %s\n" "$log_file"
    print_separator

    # Log header
    {
        printf "=== 批量安装日志 ===\n"
        printf "时间: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "Node: %s\n" "$(node -v 2>/dev/null || echo 'N/A')"
        printf "npm: %s\n" "$(npm -v 2>/dev/null || echo 'N/A')"
        printf "========================\n\n"
    } >> "$log_file" 2>/dev/null || true

    for selected_index in "${selected_indices[@]}"; do
            package_name="${batch_packages[$((selected_index - 1))]}"
            local bare_package_name="${batch_package_names[$((selected_index - 1))]}"
            local target_version="${batch_target_versions[$((selected_index - 1))]}"
            local installed_version=""
            installed_version="$(get_installed_global_package_version "$bare_package_name")"
            if is_install_spec_satisfied "$package_name" "$installed_version" "$target_version"; then
                already_installed="yes"
            else
                already_installed="no"
            fi
            if [ "$already_installed" = "yes" ]; then
                print_status_message "skip" "$package_name 已安装"
                skipped=$((skipped + 1))
                printf "[%s] SKIP 已安装\n" "$package_name" >> "$log_file" 2>/dev/null || true
                continue
            fi

            local package_log_file=""
            package_log_file="$(create_log_file batch-package "$package_name")"
            printf "[%s] LOG %s\n" "$package_name" "$package_log_file" >> "$log_file" 2>/dev/null || true

            local attempt=0
            local installed_ok="no"
            while [ "$attempt" -le "$INSTALL_MAX_RETRIES" ]; do
                if [ "$attempt" -gt 0 ]; then
                    printf "  重试 %s 第 %d 次...\n" "$package_name" "$attempt"
                    printf "[%s] RETRY %d\n" "$package_name" "$attempt" >> "$log_file" 2>/dev/null || true
                else
                    printf "安装 %s ...\n" "$package_name"
                fi

                install_global_package "$package_name" "$package_log_file"
                local install_exit=$?
                printf "[%s] install attempt %d exit %d log %s\n" "$package_name" "$((attempt + 1))" "$install_exit" "$package_log_file" >> "$log_file" 2>/dev/null || true

                if [ "$install_exit" -eq 0 ]; then
                    # Verify installation actually succeeded
                    local new_ver=""
                    local verify_result=""
                    local verify_status=""
                    local verify_message=""
                    local verify_target=""
                    new_ver="$(get_installed_global_package_version "$bare_package_name")"
                    verify_result="$(verify_install_result_for_spec "$package_name" "$new_ver" "$target_version" || true)"
                    verify_status="$(printf '%s' "$verify_result" | awk -F'|' '{print $1}')"
                    verify_message="$(printf '%s' "$verify_result" | awk -F'|' '{print $2}')"
                    verify_target="$(printf '%s' "$verify_result" | awk -F'|' '{print $3}')"
                    if [ "$verify_status" = "ok" ]; then
                        local display_new_ver="${new_ver:-unknown}"
                        if [ -z "$new_ver" ]; then
                            unknown=$((unknown + 1))
                        fi
                        print_status_message "ok" "$package_name $display_new_ver"
                        succeeded=$((succeeded + 1))
                        installed_ok="yes"
                        printf "[%s] OK version: %s\n" "$package_name" "${new_ver:-?}" >> "$log_file" 2>/dev/null || true
                        break
                    else
                        print_status_message "warn" "$package_name ${verify_message:-npm 报告成功但验证失败}"
                        if [ -n "$verify_target" ]; then
                            printf "  期望版本: %s\n" "$verify_target"
                            printf "  实际版本: %s\n" "${new_ver:-<unknown>}"
                        fi
                        printf "[%s] WARN npm ok but verification failed\n" "$package_name" >> "$log_file" 2>/dev/null || true
                    fi
                fi

                attempt=$((attempt + 1))
                if [ "$attempt" -le "$INSTALL_MAX_RETRIES" ]; then
                    printf "  %s 安装失败，自动重试...\n" "$package_name"
                fi
            done

            if [ "$installed_ok" = "no" ]; then
                print_status_message "fail" "$package_name 已重试 $INSTALL_MAX_RETRIES 次"
                failed=$((failed + 1))
                printf "[%s] FAILED after %d retries\n" "$package_name" "$INSTALL_MAX_RETRIES" >> "$log_file" 2>/dev/null || true
            fi
    done

    # Log footer
    {
        printf "\n========================\n"
        printf "=== 安装完成 ===\n"
    } >> "$log_file" 2>/dev/null || true

    print_separator
    print_blank_line
    printf "批量安装结果汇总:\n"
    printf "  清单总计: %d\n" "$total"
    printf "  选中: %d\n" "${#selected_indices[@]}"
    printf "  成功: %d\n" "$succeeded"
    printf "  警告: %d\n" "$warned"
    printf "  未知版本: %d\n" "$unknown"
    printf "  跳过已安装: %d\n" "$skipped"
    printf "  失败: %d\n" "$failed"

    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: install menu
# ──────────────────────────────────────────────

run_install_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "安装项目"
        render_install_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_install_choice "$choice")"
        case "$action" in
            single-install)
                require_capabilities node npm ruby || continue
                run_single_install_flow
                ;;
            batch-install)
                require_capabilities node npm ruby || continue
                run_batch_install_flow
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

# ──────────────────────────────────────────────
# Flow: uninstall
# ──────────────────────────────────────────────

run_uninstall_flow() {
    local packages_json=""
    local package_list=""
    local choice=""
    local index=0
    local package_name=""
    local total=0
    local succeeded=0
    local failed=0
    local warned=0
    local protected=0

    print_page_title "卸载 global package"

    # Scan installed packages
    if ! packages_json="$(load_global_package_inventory_json)"; then
        printf "npm 全局包列表命令执行失败。\n"
        pause_before_return
        return 1
    fi
    if [ -z "$packages_json" ]; then
        printf "npm 全局包列表为空，无法判断当前状态。\n"
        pause_before_return
        return 1
    fi
    if ! printf '%s' "$packages_json" | validate_json_text; then
        printf "npm 全局包列表 JSON 无法解析，已停止卸载流程。\n"
        pause_before_return
        return 1
    fi

    package_list="$(printf '%s' "$packages_json" | parse_global_package_versions_stdin)" || true

    if [ -z "$package_list" ]; then
        printf "当前没有已安装的全局包。\n"
        pause_before_return
        return 0
    fi

    # Display packages
    printf "已安装的全局包:\n"
    print_separator
    local -a pkg_names=()
    local -a pkg_versions=()
    index=0
    while IFS='|' read -r name ver; do
        index=$((index + 1))
        pkg_names+=("$name")
        pkg_versions+=("$ver")

        local size_hint=""
        size_hint="$(get_package_directory_size "$name" 2>/dev/null || true)"

        local protected_mark=""
        if is_protected_global_package "$name"; then
            protected_mark=" 受保护"
        fi

        local size_display=""
        if [ -n "$size_hint" ]; then
            size_display=" $size_hint"
        fi
        printf "  %2d  %-30s %s%s%s\n" "$index" "$name" "$ver" "$size_display" "$protected_mark"
    done <<< "$package_list"
    total=$index

    print_separator
    printf "输入序号选择要卸载的包(多个用空格分隔，输入 all 选择全部，b 返回): "
    read -r choice || return 0

    choice="$(trim_whitespace "$choice")"
    [ -n "$choice" ] || return 0

    local parsed=""
    parsed="$(parse_multi_numeric_choice "$choice" "$total")"

    if [ "$parsed" = "back" ]; then
        return 0
    fi

    if [ "$parsed" = "invalid" ]; then
        print_status_message "warn" "输入无效。"
        pause_before_return
        return 0
    fi

    local -a selected=()
    if [ "$parsed" = "all" ]; then
        local i=1
        while [ "$i" -le "$total" ]; do
            selected+=("$i")
            i=$((i + 1))
        done
    else
        for token in $parsed; do
            selected+=("$token")
        done
    fi

    # Build and show uninstall plan with full metadata
    print_blank_line
    printf "卸载计划 — 影响范围:\n"
    print_separator
    local -a plan_indices=()
    local global_root=""
    global_root="$(npm root -g 2>/dev/null || true)"
    local global_bin_dir=""
    if ! global_bin_dir="$(get_global_bin_dir)"; then
        printf "无法获取全局 bin 目录。\n"
        pause_before_return
        return 1
    fi

    # Pre-capture bin commands for ALL packages before any uninstall
    # (package.json will be gone after uninstall, so we must capture now)
    # Use parallel arrays for Bash 3.2 compatibility (no associative arrays)
    local -a cap_indices=()
    local -a cap_bin_cmds=()
    local -a cap_bin_snapshot_indices=()
    local -a cap_bin_snapshots=()
    local -a cap_dir_indices=()
    local -a cap_dir_snapshots=()

    for idx in "${selected[@]}"; do
        local pkg="${pkg_names[$((idx - 1))]}"
        local ver="${pkg_versions[$((idx - 1))]}"

        if is_protected_global_package "$pkg"; then
            print_status_message "warn" "$pkg 受保护，将跳过"
            protected=$((protected + 1))
            continue
        fi

        plan_indices+=("$idx")

        # Capture bin commands NOW while package.json still exists
        local bin_cmds=""
        bin_cmds="$(get_package_bin_commands "$pkg" 2>/dev/null || true)"
        cap_indices+=("$idx")
        cap_bin_cmds+=("$bin_cmds")

        # Full metadata for each package
        local install_path="$global_root/$pkg"
        local pkg_size=""
        pkg_size="$(get_package_directory_size "$pkg" 2>/dev/null || true)"
        local bin_entries=""
        bin_entries="$(check_bin_entries "$pkg" "$global_bin_dir" list)"
        local metadata_summary=""
        metadata_summary="$(summarize_package_metadata "$install_path/package.json" 2>/dev/null || true)"
        local dir_snapshot=""
        if dir_snapshot="$(capture_directory_snapshot "$install_path" "$global_root" 2>/dev/null)"; then
            cap_dir_indices+=("$idx")
            cap_dir_snapshots+=("$dir_snapshot")
        fi
        if [ -n "$bin_cmds" ] && [ -d "$global_bin_dir" ]; then
            while IFS= read -r cmd; do
                [ -n "$cmd" ] || continue
                local bin_path="$global_bin_dir/$cmd"
                local bin_snapshot=""
                if bin_snapshot="$(capture_symlink_snapshot "$bin_path" "$install_path" 2>/dev/null)"; then
                    cap_bin_snapshot_indices+=("$idx")
                    cap_bin_snapshots+=("$bin_snapshot")
                fi
            done <<< "$bin_cmds"
        fi

        printf "\n  [%d] %s %s\n" "$idx" "$pkg" "$ver"
        printf "      安装路径: %s\n" "${install_path:-<unknown>}"
        printf "      目录体积: %s\n" "${pkg_size:-<unknown>}"
        if [ -n "$metadata_summary" ]; then
            printf "%s\n" "$metadata_summary"
        else
            printf "      package.json 元数据: <unavailable>\n"
        fi
        if [ -n "$bin_cmds" ]; then
            printf "      bin 命令: %s\n" "$(printf '%s' "$bin_cmds" | tr '\n' ', ' | sed 's/,$//')"
        fi
        if [ -n "$bin_entries" ]; then
            printf "      全局 bin 入口:\n%s" "$bin_entries"
        fi
    done

    if [ ${#plan_indices[@]} -eq 0 ]; then
        printf "\n没有可卸载的包(全部受保护)。\n"
        pause_before_return
        return 0
    fi

    print_separator
    printf "\n共 %d 个包将被卸载。\n" "${#plan_indices[@]}"
    if ! prompt_yes_no "确认卸载？" "n"; then
        return 0
    fi

    # Execute uninstall
    print_blank_line
    printf "开始卸载...\n"
    print_separator
    if ! acquire_runtime_lock "npm-mutation"; then
        print_status_message "fail" "另一个 npm 变更操作正在运行，已取消卸载"
        pause_before_return
        return 1
    fi

    # Collect residue candidates for post-uninstall cleanup
    local -a residue_dirs=()
    local -a residue_dir_snapshots=()
    local -a residue_bins=()
    local -a residue_bin_snapshots=()

    for idx in "${plan_indices[@]}"; do
        package_name="${pkg_names[$((idx - 1))]}"
        local pkg_dir="$global_root/$package_name"
        local uninstall_log_file=""
        uninstall_log_file="$(create_log_file uninstall "$package_name")"

        printf "卸载 %s ...\n" "$package_name"
        printf "  日志: %s\n" "$uninstall_log_file"
        if uninstall_global_package "$package_name" "$uninstall_log_file"; then
            # Post-uninstall verification: package list, directory, bin residue
            local still_installed=""
            if npm_package_is_installed "$package_name"; then
                still_installed="yes"
            else
                still_installed="no"
            fi
            local dir_still_exists="no"
            [ -d "$pkg_dir" ] && dir_still_exists="yes"

            # Check bin residue using PRE-CAPTURED bin commands
            local bin_residue=""
            local saved_bin_cmds=""
            local ci=0
            while [ "$ci" -lt "${#cap_indices[@]}" ]; do
                if [ "${cap_indices[$ci]}" = "$idx" ]; then
                    saved_bin_cmds="${cap_bin_cmds[$ci]}"
                    break
                fi
                ci=$((ci + 1))
            done
            if [ -n "$saved_bin_cmds" ] && [ -d "$global_bin_dir" ]; then
                while IFS= read -r cmd; do
                    [ -n "$cmd" ] || continue
                    local bin_path="$global_bin_dir/$cmd"
                    local bs_i=0
                    while [ "$bs_i" -lt "${#cap_bin_snapshot_indices[@]}" ]; do
                        if [ "${cap_bin_snapshot_indices[$bs_i]}" = "$idx" ]; then
                            local snapshot="${cap_bin_snapshots[$bs_i]}"
                            local snapshot_path="${snapshot%%|*}"
                            if [ "$snapshot_path" = "$bin_path" ] && verify_symlink_snapshot_current "$snapshot"; then
                                bin_residue="${bin_residue}${cmd} "
                                residue_bins+=("$bin_path")
                                residue_bin_snapshots+=("$snapshot")
                            fi
                        fi
                        bs_i=$((bs_i + 1))
                    done
                done <<< "$saved_bin_cmds"
            fi

            local status="ok"
            local detail=""
            if [ "$still_installed" = "yes" ]; then
                status="warn"
                detail="npm 报告成功但仍出现在列表中"
            elif [ "$dir_still_exists" = "yes" ]; then
                status="warn"
                detail="包目录仍存在"
                local ds_i=0
                while [ "$ds_i" -lt "${#cap_dir_indices[@]}" ]; do
                    if [ "${cap_dir_indices[$ds_i]}" = "$idx" ] && verify_directory_snapshot_current "${cap_dir_snapshots[$ds_i]}"; then
                        residue_dirs+=("$pkg_dir")
                        residue_dir_snapshots+=("${cap_dir_snapshots[$ds_i]}")
                        break
                    fi
                    ds_i=$((ds_i + 1))
                done
            elif [ -n "$bin_residue" ]; then
                status="warn"
                detail="bin 残留: $(printf '%s' "$bin_residue" | sed 's/ $//')"
            fi

            print_status_message "$status" "$package_name${detail:+ $detail}"
            if [ "$status" = "ok" ]; then
                succeeded=$((succeeded + 1))
            else
                warned=$((warned + 1))
            fi
        else
            print_status_message "fail" "$package_name"
            failed=$((failed + 1))
        fi
    done

    # Post-uninstall residue cleanup
    local total_residue=$((${#residue_dirs[@]} + ${#residue_bins[@]}))
    if [ "$total_residue" -gt 0 ]; then
        print_blank_line
        print_separator
        printf "残留候选项 %d 个:\n" "$total_residue"

        if [ ${#residue_dirs[@]} -gt 0 ]; then
            printf "\n  包目录残留:\n"
            for rd in "${residue_dirs[@]}"; do
                local rd_size=""
                rd_size="$(du -sh "$rd" 2>/dev/null | awk '{print $1}')"
                printf "    %s %s\n" "$rd" "${rd_size:-<unknown>}"
            done
        fi

        if [ ${#residue_bins[@]} -gt 0 ]; then
            printf "\n  bin 入口残留:\n"
            for rb in "${residue_bins[@]}"; do
                local rb_type="file"
                [ -L "$rb" ] && rb_type="symlink"
                printf "    %s %s\n" "$rb" "$rb_type"
            done
        fi

        print_separator
        if prompt_yes_no "是否清理以上残留？" "n"; then
            print_blank_line
            printf "清理残留...\n"
            print_separator
            local cleaned=0
            local clean_failed=0

            local rd_index=0
            for rd in "${residue_dirs[@]}"; do
                local rd_snapshot="${residue_dir_snapshots[$rd_index]:-}"
                rd_index=$((rd_index + 1))
                if ! is_safe_removable_child_dir "$rd" "$global_root"; then
                    print_status_message "fail" "拒绝删除非 global root 子目录: $rd"
                    clean_failed=$((clean_failed + 1))
                    continue
                fi
                if ! verify_directory_snapshot_current "$rd_snapshot"; then
                    print_status_message "fail" "删除前目录快照复验失败，已跳过: $rd"
                    clean_failed=$((clean_failed + 1))
                    continue
                fi

                if rm -rf "$rd" 2>/dev/null; then
                    if [ ! -d "$rd" ]; then
                        print_status_message "ok" "已删除: $rd"
                        cleaned=$((cleaned + 1))
                    else
                        print_status_message "warn" "删除后仍存在: $rd"
                    fi
                else
                    print_status_message "fail" "删除失败: $rd"
                    clean_failed=$((clean_failed + 1))
                fi
            done

            local rb_index=0
            for rb in "${residue_bins[@]}"; do
                local rb_snapshot="${residue_bin_snapshots[$rb_index]:-}"
                rb_index=$((rb_index + 1))
                if remove_snapshot_symlink_residue "$rb_snapshot"; then
                    if [ ! -e "$rb" ] && [ ! -L "$rb" ]; then
                        print_status_message "ok" "已删除: $rb"
                        cleaned=$((cleaned + 1))
                    else
                        print_status_message "warn" "删除后仍存在: $rb"
                    fi
                else
                    print_status_message "fail" "删除前归属复验失败，已跳过: $rb"
                    clean_failed=$((clean_failed + 1))
                fi
            done

            printf "\n残留清理: 成功 %d, 失败 %d\n" "$cleaned" "$clean_failed"
        else
            printf "跳过残留清理。\n"
        fi
    fi

    # Structured summary
    print_separator
    print_blank_line
    printf "卸载结果汇总:\n"
    printf "  选中: %d\n" "${#selected[@]}"
    printf "  成功: %d\n" "$succeeded"
    printf "  警告残留: %d\n" "$warned"
    printf "  失败: %d\n" "$failed"
    printf "  跳过受保护: %d\n" "$protected"
    release_runtime_lock "npm-mutation"

    print_blank_line
    printf "卸载后剩余全局包:\n"
    local remaining_packages_json=""
    local remaining_package_list=""
    if remaining_packages_json="$(load_global_package_inventory_json)" && [ -n "$remaining_packages_json" ] && printf '%s' "$remaining_packages_json" | validate_json_text; then
        remaining_package_list="$(printf '%s' "$remaining_packages_json" | parse_global_package_versions_stdin 2>/dev/null || true)"
        if [ -n "$remaining_package_list" ]; then
            printf "  数量: %s\n" "$(printf '%s\n' "$remaining_package_list" | sed '/^$/d' | wc -l | tr -d ' ')"
        else
            printf "  数量: 0\n"
        fi
    else
        printf "  <无法复扫>\n"
    fi

    pause_before_return
}

run_uninstall_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "卸载项目"
        render_uninstall_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_uninstall_choice "$choice")"
        case "$action" in
            uninstall-package)
                require_capabilities npm ruby || continue
                run_uninstall_flow
                ;;
            back)
                return 0
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1 或 b。"
                pause_before_return
                ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Flow: upgrade scan & execute
# ──────────────────────────────────────────────

run_upgrade_scan_flow() {
    local outdated_json=""
    local outdated_stderr=""
    local outdated_stderr_file=""
    local outdated_exit=0
    local outdated_rows=""
    local choice=""
    local total=0
    local succeeded=0
    local failed=0
    local warned=0

    print_page_title "扫描并升级 global package"

    printf "正在扫描可升级包...\n"
    print_blank_line

    # Capture stdout, stderr, and exit code separately
    # npm outdated returns exit 1 when there ARE outdated packages (not an error)
    # exit 0 means truly nothing outdated
    # Non-empty stderr or exit >1 means a real failure
    outdated_json=""
    outdated_stderr=""
    outdated_exit=0
    ensure_runtime_dirs || return 1
    outdated_stderr_file="$(mktemp "$(manager_tmp_dir)/npm-outdated-stderr.XXXXXX")" || {
        print_status_message "fail" "无法创建临时文件"
        pause_before_return
        return 1
    }
    outdated_json="$(npm outdated -g --depth=0 --json 2>"$outdated_stderr_file")" || outdated_exit=$?
    outdated_stderr="$(cat "$outdated_stderr_file" 2>/dev/null || true)"
    rm -f "$outdated_stderr_file" 2>/dev/null || true

    # Detect real failures vs "has outdated packages" vs "nothing outdated"
    if [ "$outdated_exit" -gt 1 ] || { [ "$outdated_exit" -eq 1 ] && [ -n "$outdated_stderr" ] && [ -z "$outdated_json" ]; }; then
        # Real failure: exit >1, or exit 1 with stderr but no stdout
        print_status_message "fail" "扫描失败"
        if [ -n "$outdated_stderr" ]; then
            printf "错误信息:\n"
            printf "%s\n" "$outdated_stderr"
        fi
        printf "可能原因: 网络问题、registry 异常、认证失败\n"
        pause_before_return
        return 1
    fi

    # exit 1 with empty json object or empty stdout = genuinely no outdated
    if [ -z "$outdated_json" ] || [ "$outdated_json" = "{}" ]; then
        printf "没有可升级的全局包。\n"
        pause_before_return
        return 0
    fi

    # Validate that stdout is actually valid JSON before parsing
    if ! printf '%s' "$outdated_json" | ruby -rjson -e 'JSON.parse(STDIN.read)' 2>/dev/null; then
        # Non-empty but not valid JSON — this is a real error, not "no outdated"
        print_status_message "fail" "扫描返回了无法解析的数据"
        printf "原始输出:\n"
        printf "%s\n" "$outdated_json" | head -10
        printf "可能原因: npm 命令异常、输出格式错误\n"
        pause_before_return
        return 1
    fi

    outdated_rows="$(printf '%s' "$outdated_json" | parse_outdated_package_rows_stdin)" || true

    if [ -z "$outdated_rows" ]; then
        printf "没有可升级的全局包。\n"
        pause_before_return
        return 0
    fi

    # Display outdated packages with row numbers
    printf "  %-4s %-28s %-14s %-14s %-14s\n" "#" "包名" "当前版本" "wanted" "latest"
    print_separator

    local -a out_names=()
    local -a out_current=()
    local -a out_wanted=()
    local -a out_latest=()
    total=0
    while IFS='|' read -r name current wanted latest; do
        total=$((total + 1))
        out_names+=("$name")
        out_current+=("$current")
        out_wanted+=("$wanted")
        out_latest+=("$latest")
        printf "%2d  %-28s %-14s %-14s %-14s\n" "$total" "$name" "$current" "$wanted" "$latest"
    done <<< "$outdated_rows"

    print_separator
    printf "共 %d 个可升级包\n" "$total"
    print_blank_line
    printf "输入序号选择要升级的包(多个用空格分隔，all 全部升级，b 返回): "
    read -r choice || return 0

    choice="$(trim_whitespace "$choice")"
    [ -n "$choice" ] || return 0

    local parsed=""
    parsed="$(parse_multi_numeric_choice "$choice" "$total")"

    if [ "$parsed" = "back" ]; then
        return 0
    fi

    if [ "$parsed" = "invalid" ]; then
        print_status_message "warn" "输入无效。"
        pause_before_return
        return 0
    fi

    local -a selected=()
    if [ "$parsed" = "all" ]; then
        local i=1
        while [ "$i" -le "$total" ]; do
            selected+=("$i")
            i=$((i + 1))
        done
    else
        for token in $parsed; do
            selected+=("$token")
        done
    fi

    # Show upgrade plan (wanted, not latest)
    print_blank_line
    printf "升级计划 wanted:\n"
    print_separator
    for idx in "${selected[@]}"; do
        printf "  %s: %s -> %s\n" \
            "${out_names[$((idx - 1))]}" \
            "${out_current[$((idx - 1))]}" \
            "${out_wanted[$((idx - 1))]}"
    done
    print_separator

    if ! prompt_yes_no "确认升级以上 ${#selected[@]} 个包？" "y"; then
        return 0
    fi

    # Execute upgrade using npm update (wanted semantics, not @latest)
    print_blank_line
    printf "开始升级...\n"
    print_separator

    for idx in "${selected[@]}"; do
        local pkg="${out_names[$((idx - 1))]}"
        local old_ver="${out_current[$((idx - 1))]}"
        local wanted_ver="${out_wanted[$((idx - 1))]}"
        local upgrade_log_file=""
        upgrade_log_file="$(create_log_file upgrade "$pkg")"
        printf "升级 %s ...\n" "$pkg"
        printf "  日志: %s\n" "$upgrade_log_file"
        if upgrade_global_package "$pkg" "$upgrade_log_file"; then
            local verify_result=""
            local verify_status=""
            local verify_detail=""
            local new_version=""
            verify_result="$(verify_global_package_update_result "$pkg" "$old_ver" "$wanted_ver")"
            verify_status="$(printf '%s' "$verify_result" | awk -F'|' '{print $1}')"
            verify_detail="$(printf '%s' "$verify_result" | awk -F'|' '{print $2}')"
            new_version="$(printf '%s' "$verify_result" | awk -F'|' '{print $3}')"
            if [ "$verify_status" = "ok" ]; then
                print_status_message "ok" "$pkg: $old_ver -> $new_version"
                printf "  验证: %s\n" "$verify_detail"
                succeeded=$((succeeded + 1))
            elif [ "$verify_status" = "warn" ]; then
                print_status_message "warn" "$pkg: $old_ver -> ${new_version:-<unknown>}"
                printf "  验证: %s\n" "$verify_detail"
                warned=$((warned + 1))
            else
                print_status_message "fail" "$pkg: $verify_detail"
                printf "  当前版本: %s\n" "${new_version:-<unknown>}"
                failed=$((failed + 1))
            fi
        else
            print_status_message "fail" "$pkg"
            failed=$((failed + 1))
        fi
    done

    # Summary
    print_separator
    print_blank_line
    printf "升级结果汇总:\n"
    printf "  选中: %d\n" "${#selected[@]}"
    printf "  成功: %d\n" "$succeeded"
    printf "  警告: %d\n" "$warned"
    printf "  失败: %d\n" "$failed"

    local remaining_json=""
    local remaining_rows=""
    remaining_json="$(npm outdated -g --depth=0 --json 2>/dev/null || true)"
    if [ -n "$remaining_json" ] && [ "$remaining_json" != "{}" ]; then
        remaining_rows="$(printf '%s' "$remaining_json" | parse_outdated_package_rows_stdin 2>/dev/null || true)"
    fi
    if [ -n "$remaining_rows" ]; then
        printf "  剩余可升级: %s\n" "$(printf '%s\n' "$remaining_rows" | sed '/^$/d' | wc -l | tr -d ' ')"
    else
        printf "  剩余可升级: 0\n"
    fi

    pause_before_return
}

run_upgrade_latest_flow() {
    local package_name=""
    local current_version=""
    local latest_version=""

    print_page_title "指定包升级到 latest"

    printf "请输入包名: "
    read -r package_name || return 0
    package_name="$(trim_whitespace "$package_name")"
    [ -n "$package_name" ] || return 0
    if ! validate_package_name_only "$package_name"; then
        print_status_message "fail" "包名格式不支持: $package_name"
        printf "latest 升级只支持 package 或 @scope/package，不接受 version/tag spec。\n"
        pause_before_return
        return 1
    fi

    # Check if installed
    current_version="$(get_installed_global_package_version "$package_name")"

    if [ -z "$current_version" ]; then
        printf "包 %s 未安装。\n" "$package_name"
        pause_before_return
        return 0
    fi

    # Get latest version from registry
    latest_version="$(get_registry_latest_version "$package_name" || true)"

    print_blank_line
    printf "当前版本: %s\n" "$current_version"
    printf "latest 版本: %s\n" "${latest_version:-<unknown>}"
    print_blank_line

    if [ -z "$latest_version" ]; then
        print_status_message "fail" "无法获取 latest 版本，已取消升级"
        pause_before_return
        return 1
    fi

    if [ "$current_version" = "$latest_version" ]; then
        printf "已经是最新版本，无需升级。\n"
        pause_before_return
        return 0
    fi

    if ! prompt_yes_no "确认升级到 latest？" "y"; then
        return 0
    fi

    print_blank_line
    printf "升级 %s ...\n" "$package_name"
    local upgrade_log_file=""
    upgrade_log_file="$(create_log_file upgrade-latest "$package_name")"
    printf "日志文件: %s\n" "$upgrade_log_file"
    if upgrade_global_package_to_latest "$package_name" "$upgrade_log_file"; then
        local new_version=""
        new_version="$(get_installed_global_package_version "$package_name")"
        print_blank_line
        if [ -z "$new_version" ]; then
            print_status_message "warn" "升级后无法读取版本"
        elif [ "$new_version" != "$latest_version" ]; then
            print_status_message "fail" "升级后版本不是 latest"
            printf "  期望: %s\n" "$latest_version"
            printf "  实际: %s\n" "$new_version"
        elif [ "$new_version" = "$current_version" ]; then
            print_status_message "warn" "版本未变化 $current_version"
        else
            print_status_message "ok" "升级成功"
            printf "  %s: %s -> %s\n" "$package_name" "$current_version" "$new_version"
        fi
    else
        print_status_message "fail" "升级失败: $package_name"
    fi

    pause_before_return
}

run_update_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "更新与升级"
        render_update_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_update_choice "$choice")"
        case "$action" in
            scan-upgrade)
                require_capabilities npm ruby || continue
                run_upgrade_scan_flow
                ;;
            upgrade-latest)
                require_capabilities npm ruby || continue
                run_upgrade_latest_flow
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

# ──────────────────────────────────────────────
# Flow: source management
# ──────────────────────────────────────────────

run_source_overview() {
    local registry=""
    local user_npmrc="$HOME/.npmrc"
    local project_npmrc=""

    print_page_title "查看源配置"

    project_npmrc="$(pwd)/.npmrc"
    registry="$(get_current_registry)"

    printf "当前 registry: %s\n" "${registry:-<unavailable>}"
    print_blank_line

    printf "用户级 .npmrc: %s\n" "$user_npmrc"
    if [ -f "$user_npmrc" ]; then
        printf "  状态: 存在\n"
    else
        printf "  状态: 不存在\n"
    fi
    print_blank_line

    printf "项目级 .npmrc: %s\n" "$project_npmrc"
    if [ -f "$project_npmrc" ]; then
        printf "  状态: 存在\n"
    else
        printf "  状态: 不存在\n"
    fi
    print_blank_line

    # Scope registries
    printf "Scope Registry 配置:\n"
    print_separator
    local scope_lines=""
    if [ -f "$user_npmrc" ]; then
        scope_lines="$(parse_scope_registry_lines "$user_npmrc")"
    fi

    # Also check npm config list for scope registries
    local config_scopes=""
    config_scopes="$(npm config list -l 2>/dev/null | grep -E '^@[^:]+:registry[[:space:]]*=' || true)"
    local combined_scope_lines=""
    combined_scope_lines="$({
        printf '%s\n' "$scope_lines"
        printf '%s\n' "$config_scopes"
    } | sed '/^$/d' | sort -u)"
    if [ -n "$combined_scope_lines" ]; then
        printf "%s\n" "$combined_scope_lines"
    fi

    if [ -z "$combined_scope_lines" ]; then
        printf "  <无>\n"
    else
        print_blank_line
        printf "Scope Registry 分层:\n"
        local scope_key=""
        local scope_name=""
        printf '%s\n' "$combined_scope_lines" | sed 's/:registry[[:space:]]*=.*$//' | sort -u | while IFS= read -r scope_key; do
            scope_name="$(trim_whitespace "$scope_key")"
            [ -n "$scope_name" ] || continue
            print_scope_registry_layers "$scope_name" || true
        done
    fi

    # npm config summary (key config items)
    print_blank_line
    printf "npm config 分层摘要:\n"
    print_separator
    local key=""
    for key in registry cache prefix; do
        printf "%s:\n" "$key"
        printf "  effective: %s\n" "$(normalize_npm_config_value "$(npm config get "$key" 2>/dev/null || true)")"
        printf "  user (--location=user): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "$key" user)")"
        printf "  project (--location=project): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "$key" project)")"
        printf "  global (--location=global): %s\n" "$(normalize_npm_config_value "$(npm_config_get_layer "$key" global)")"
    done

    print_blank_line
    printf "npmrc 文件路径:\n"
    printf "  userconfig: %s\n" "$(npm config get userconfig 2>/dev/null || true)"
    printf "  globalconfig: %s\n" "$(npm config get globalconfig 2>/dev/null || true)"

    pause_before_return
}

run_switch_registry_flow() {
    local choice=""
    local registry_url=""
    local current_registry=""

    current_registry="$(get_current_registry)"

    print_page_title "切换 registry"
    printf "当前 registry: %s\n" "${current_registry:-<unavailable>}"
    print_blank_line

    printf "1) npm 官方源 https://registry.npmjs.org/\n"
    printf "2) npmmirror 源 https://registry.npmmirror.com/\n"
    printf "3) 自定义 registry\n"
    printf "b) 返回\n"
    print_blank_line
    printf "请选择: "
    read -r choice || return 0

    case "$choice" in
        1) registry_url="https://registry.npmjs.org/" ;;
        2) registry_url="https://registry.npmmirror.com/" ;;
        3)
            printf "请输入自定义 registry URL: "
            read -r registry_url || return 0
            registry_url="$(trim_whitespace "$registry_url")"
            [ -n "$registry_url" ] || return 0
            ;;
        b|B) return 0 ;;
        *)
            print_status_message "warn" "输入无效。"
            pause_before_return
            return 0
            ;;
    esac

    if ! validate_registry_url "$registry_url"; then
        print_status_message "fail" "registry URL 格式不支持: $registry_url"
        printf "registry URL 必须使用 https:// 并以 / 结尾；本机调试仅允许 http://localhost:<port>/ 或 http://127.0.0.1:<port>/。\n"
        pause_before_return
        return 1
    fi

    print_blank_line
    printf "准备切换 registry 到: %s\n" "$registry_url"
    if ! prompt_yes_no "确认切换？" "y"; then
        return 0
    fi

    print_blank_line
    printf "执行切换...\n"
    print_separator
    local set_status=""
    if set_status="$(set_registry_value "$registry_url")"; then
        local actual_registry=""
        actual_registry="$(get_current_registry)"
        print_blank_line
        print_status_message "ok" "用户级 registry 写入成功"
        printf "  切换前: %s\n" "$current_registry"
        printf "  切换后: %s\n" "$actual_registry"
        case "$set_status" in
            effective-ok)
                print_status_message "ok" "effective registry 已生效"
                ;;
            effective-mismatch:*)
                print_status_message "warn" "effective registry 被 project/global/builtin 覆盖"
                printf "  期望 effective: %s\n" "$registry_url"
                printf "  实际 effective: %s\n" "${set_status#effective-mismatch:}"
                ;;
            *)
                print_status_message "warn" "effective registry 状态未知"
                ;;
        esac
        if [ "$actual_registry" != "$registry_url" ]; then
            print_status_message "warn" "安装命令当前仍会使用: $actual_registry"
        fi
    else
        print_status_message "fail" "registry 切换失败"
        printf "  当前 registry: %s\n" "$(get_current_registry)"
    fi

    pause_before_return
}

run_reset_registry_flow() {
    local current_registry=""
    local user_registry=""
    local effective_registry=""

    print_page_title "删除用户级 registry"

    current_registry="$(get_current_registry)"
    user_registry="$(npm config get registry --location=user 2>/dev/null || true)"

    printf "当前 effective registry: %s\n" "${current_registry:-<unavailable>}"
    printf "用户级 registry: %s\n" "${user_registry:-<unavailable>}"
    print_blank_line
    printf "将只删除用户级 registry 配置，npm 会回退到项目级/global/builtin/effective 配置。\n"
    if ! prompt_yes_no "确认删除用户级 registry？" "n"; then
        return 0
    fi

    print_blank_line
    if delete_registry_value; then
        effective_registry="$(get_current_registry)"
        print_status_message "ok" "用户级 registry 已删除"
        printf "  当前 effective registry: %s\n" "${effective_registry:-<unavailable>}"
    else
        print_status_message "fail" "用户级 registry 删除失败"
        printf "  当前 user registry: %s\n" "$(npm config get registry --location=user 2>/dev/null || true)"
    fi

    pause_before_return
}

run_scope_registry_flow() {
    local choice=""
    local scope_name=""
    local registry_url=""
    local config_scopes=""

    while true; do
    print_page_title "管理 scope registry"

    printf "1) 添加 scope registry\n"
    printf "2) 删除 scope registry\n"
    printf "3) 查看所有 scope registry\n"
    printf "4) 查看指定 scope registry\n"
    printf "b) 返回\n"
    print_blank_line
    printf "请选择: "
    read -r choice || return 0

    case "$choice" in
        1)
            printf "请输入 scope 名称(例如 @company): "
            read -r scope_name || return 0
            scope_name="$(trim_whitespace "$scope_name")"
            [ -n "$scope_name" ] || return 0
            if ! validate_scope_name "$scope_name"; then
                print_status_message "fail" "scope 名称格式不支持: $scope_name"
                pause_before_return
                return 1
            fi

            printf "请输入 registry URL: "
            read -r registry_url || return 0
            registry_url="$(trim_whitespace "$registry_url")"
            [ -n "$registry_url" ] || return 0
            if ! validate_registry_url "$registry_url"; then
                print_status_message "fail" "registry URL 格式不支持: $registry_url"
                printf "registry URL 必须使用 https:// 并以 / 结尾；本机调试仅允许 http://localhost:<port>/ 或 http://127.0.0.1:<port>/。\n"
                pause_before_return
                return 1
            fi

            print_blank_line
            printf "准备设置 %s:registry = %s\n" "$scope_name" "$registry_url"
            if ! prompt_yes_no "确认添加？" "y"; then
                return 0
            fi

            print_blank_line
            local set_status=""
            if set_status="$(set_scope_registry_value "$scope_name" "$registry_url")"; then
                print_status_message "ok" "scope registry 已添加"
                printf "  %s:registry = %s\n" "$scope_name" "$(npm config get "${scope_name}:registry" 2>/dev/null || true)"
                case "$set_status" in
                    effective-ok)
                        print_status_message "ok" "effective scope registry 已生效"
                        ;;
                    effective-mismatch:*)
                        print_status_message "warn" "effective scope registry 被 project/global/builtin 覆盖"
                        printf "  期望 effective: %s\n" "$registry_url"
                        printf "  实际 effective: %s\n" "${set_status#effective-mismatch:}"
                        ;;
                esac
            else
                print_status_message "fail" "scope registry 添加失败"
            fi
            pause_before_return
            ;;
        2)
            # List existing scope registries
            config_scopes="$(npm config list -l 2>/dev/null | grep -E '^@[^:]+:registry' || true)"
            if [ -z "$config_scopes" ]; then
                printf "当前没有 scope registry 配置。\n"
                pause_before_return
                return 0
            fi

            printf "当前 scope registry:\n"
            printf "%s\n" "$config_scopes"
            print_blank_line

            printf "请输入要删除的 scope 名称(例如 @company): "
            read -r scope_name || return 0
            scope_name="$(trim_whitespace "$scope_name")"
            [ -n "$scope_name" ] || return 0
            if ! validate_scope_name "$scope_name"; then
                print_status_message "fail" "scope 名称格式不支持: $scope_name"
                pause_before_return
                return 1
            fi

            print_blank_line
            printf "准备删除 %s:registry\n" "$scope_name"
            if ! prompt_yes_no "确认删除？" "y"; then
                return 0
            fi

            print_blank_line
            if delete_scope_registry_value "$scope_name"; then
                verify_scope_registry_deleted_user_layer "$scope_name" || true
            else
                print_status_message "fail" "用户级 scope registry 删除失败"
                printf "  user: %s\n" "$(npm_config_get_layer "${scope_name}:registry" user)"
            fi
            pause_before_return
            ;;
        3)
            print_page_title "查看 scope registry"
            config_scopes="$(npm config list -l 2>/dev/null | grep -E '^@[^:]+:registry' || true)"
            if [ -n "$config_scopes" ]; then
                printf "%s\n" "$config_scopes"
            else
                printf "当前没有 scope registry 配置。\n"
            fi
            pause_before_return
            ;;
        4)
            printf "请输入 scope 名称(例如 @company): "
            read -r scope_name || return 0
            scope_name="$(trim_whitespace "$scope_name")"
            [ -n "$scope_name" ] || return 0
            if ! validate_scope_name "$scope_name"; then
                print_status_message "fail" "scope 名称格式不支持: $scope_name"
                pause_before_return
                return 1
            fi

            print_blank_line
            local scope_value=""
            scope_value="$(npm config get "${scope_name}:registry" 2>/dev/null || true)"
            if [ -n "$scope_value" ] && [ "$scope_value" != "undefined" ]; then
                print_scope_registry_layers "$scope_name"
            else
                printf "%s 未配置 registry。\n" "$scope_name"
            fi
            pause_before_return
            ;;
        b|B) return 0 ;;
        *)
            print_status_message "warn" "输入无效。"
            pause_before_return
            ;;
    esac
    done
}

run_source_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "源管理"
        render_source_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_source_choice "$choice")"
        case "$action" in
            view-source)
                require_capabilities npm || continue
                run_source_overview
                ;;
            switch-registry)
                require_capabilities npm || continue
                run_switch_registry_flow
                ;;
            scope-registry)
                require_capabilities npm || continue
                run_scope_registry_flow
                ;;
            reset-registry)
                require_capabilities npm || continue
                run_reset_registry_flow
                ;;
            back)
                return 0
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1、2、3、4 或 b。"
                pause_before_return
                ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Flow: install nvm
# ──────────────────────────────────────────────

run_install_nvm_flow() {
    print_page_title "安装 nvm"

    # Check if nvm is already installed
    export NVM_DIR="${NVM_DIR:-$(detect_nvm_dir)}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        print_status_message "ok" "nvm 已安装"
        printf "  NVM_DIR: %s\n" "$NVM_DIR"

        # Try to load and verify
        load_nvm_into_current_shell || true
        if is_nvm_loaded; then
            printf "  nvm 版本: %s\n" "$(nvm --version 2>/dev/null || true)"
        fi
        print_blank_line
        printf "如需重新安装，请先删除 %s 目录。\n" "$NVM_DIR"
        pause_before_return
        return 0
    fi

    printf "将使用官方安装脚本安装 nvm。\n"
    printf "安装脚本: %s\n" "$NVM_INSTALL_URL"
    printf "目标目录: %s\n" "$NVM_DIR"
    if [ -n "$NVM_INSTALL_SHA256" ]; then
        printf "SHA256 校验: enabled\n"
    else
        print_status_message "warn" "未配置 NVM_INSTALL_SHA256，下载脚本将无法做内容完整性校验"
        printf "版本: %s\n" "$NVM_INSTALL_VERSION"
        printf "URL: %s\n" "$NVM_INSTALL_URL"
    fi
    print_blank_line

    if ! prompt_yes_no "确认安装？" "y"; then
        return 0
    fi
    if [ -z "$NVM_INSTALL_SHA256" ] && [ "$NVM_ALLOW_UNVERIFIED_INSTALL" != "1" ]; then
        print_status_message "fail" "默认安装路径需要 NVM_INSTALL_SHA256 校验"
        printf "如需执行未校验下载脚本，请显式设置 NVM_ALLOW_UNVERIFIED_INSTALL=1 后重试。\n"
        pause_before_return
        return 1
    fi

    # Snapshot profile files BEFORE install so we can detect what changed
    # Use parallel arrays for Bash 3.2 compatibility
    local -a profile_files=("$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile")
    local -a profile_hashes_before=()
    for pf in "${profile_files[@]}"; do
        if [ -f "$pf" ]; then
            profile_hashes_before+=("$(md5 -q "$pf" 2>/dev/null || md5sum "$pf" 2>/dev/null | awk '{print $1}')")
        else
            profile_hashes_before+=("")
        fi
    done

    print_blank_line
    printf "正在安装 nvm...\n"

    if install_nvm_official; then
        print_blank_line
        print_status_message "ok" "nvm 安装完成"
    else
        print_status_message "fail" "nvm 安装失败"
        pause_before_return
        return 1
    fi

    # Load nvm into current script process
    print_blank_line
    printf "正在加载 nvm 到当前会话...\n"
    if load_nvm_into_current_shell; then
        print_status_message "ok" "nvm 已加载到当前脚本进程"
        printf "  nvm 版本: %s\n" "$(nvm --version 2>/dev/null || true)"
    else
        print_status_message "warn" "nvm 安装成功但无法在当前进程加载"
    fi

    # Verify
    if command_exists nvm; then
        print_status_message "ok" "command -v nvm 验证通过"
    else
        print_status_message "warn" "command -v nvm 未通过(需要新开终端)"
    fi

    # Detect which profile file was actually modified by comparing before/after
    local nvm_profile=""
    local pi=0
    for pf in "${profile_files[@]}"; do
        local after_hash=""
        if [ -f "$pf" ]; then
            after_hash="$(md5 -q "$pf" 2>/dev/null || md5sum "$pf" 2>/dev/null | awk '{print $1}')"
        fi
        local before_hash="${profile_hashes_before[$pi]:-}"
        # If file is new or hash changed, and it contains NVM_DIR, it was modified
        if [ -n "$after_hash" ] && [ "$after_hash" != "$before_hash" ] && profile_has_complete_nvm_init "$pf"; then
            nvm_profile="$pf"
            break
        fi
        pi=$((pi + 1))
    done

    print_blank_line
    print_separator
    printf "重要提示:\n"
    printf "  nvm 已安装到 %s\n" "$NVM_DIR"
    if [ -n "$nvm_profile" ]; then
        printf "  初始化配置已写入: %s\n" "$nvm_profile"
        printf "  请执行以下操作之一使其在终端中永久生效:\n"
        printf "    1. 新开一个终端窗口\n"
        printf "    2. 手动执行: source %s\n" "$nvm_profile"
    else
        printf "  未检测到 profile 文件中的 nvm 配置\n"
        printf "  请手动将以下内容添加到你的 shell 配置文件:\n"
        printf "    export NVM_DIR=\"%s\"\n" "$NVM_DIR"
        printf "    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"\n"
    fi
    print_separator

    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: install Node.js version
# ──────────────────────────────────────────────

run_install_node_flow() {
    local choice=""
    local version=""

    print_page_title "安装 Node.js 版本"

    if ! is_nvm_loaded; then
        if ! load_nvm_into_current_shell; then
            printf "nvm 未安装或无法加载。请先安装 nvm。\n"
            pause_before_return
            return 1
        fi
    fi

    # Show current versions
    printf "当前已安装的 Node 版本:\n"
    print_separator
    local installed_list=""
    installed_list="$(nvm ls --no-colors 2>/dev/null || true)"
    if [ -n "$installed_list" ]; then
        printf "%s\n" "$installed_list"
    else
        printf "  <none>\n"
    fi
    print_separator
    print_blank_line

    printf "1) 安装 LTS 版本\n"
    printf "2) 安装指定版本\n"
    printf "b) 返回\n"
    print_blank_line
    printf "请选择: "
    read -r choice || return 0

    case "$choice" in
        1)
            print_blank_line
            printf "正在安装最新 LTS 版本...\n"
            if install_node_lts; then
                local lts_actual=""
                lts_actual="$(node -v 2>/dev/null || true)"
                local lts_verified="no"
                print_blank_line
                if [ -n "$lts_actual" ] && [[ "$lts_actual" == v* ]]; then
                    print_status_message "ok" "LTS 版本安装完成"
                    lts_verified="yes"
                else
                    print_status_message "warn" "安装命令成功但无法读取 node -v"
                fi
                printf "  node 版本: %s\n" "${lts_actual:-<unknown>}"
                printf "  npm 版本: %s\n" "$(npm -v 2>/dev/null || true)"

                # Only offer to set default if verification passed
                if [ "$lts_verified" = "yes" ]; then
                    if prompt_yes_no "是否设置为默认版本？" "y"; then
                        set_node_default_alias_verified "$lts_actual"
                    fi
                else
                    printf "\n"
                    printf "  跳过设置默认版本(安装验证未通过)\n"
                fi
            else
                print_status_message "fail" "LTS 版本安装失败"
            fi
            pause_before_return
            ;;
        2)
            # Show available LTS versions for selection
            printf "\n可安装的 LTS 版本:\n"
            print_separator
            local -a lts_names=()
            local lts_list=""
            lts_list="$(nvm ls-remote --lts --no-colors 2>/dev/null | tail -20)" || true
            if [ -n "$lts_list" ]; then
                local lts_idx=0
                while IFS= read -r line; do
                    [ -n "$line" ] || continue
                    local lts_ver=""
                    lts_ver="$(printf '%s' "$line" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | tail -1)"
                    [ -n "$lts_ver" ] || continue
                    lts_idx=$((lts_idx + 1))
                    lts_names+=("$lts_ver")
                    printf "  %d) %s\n" "$lts_idx" "$lts_ver"
                done <<< "$lts_list"
                print_separator
                printf "输入序号或版本号(例如 20 或 20.11.0)，b 返回\n"
            else
                printf "  <无法获取远程版本列表>\n"
                print_separator
                printf "输入版本号(例如 20 或 20.11.0)，b 返回\n"
            fi
            print_blank_line
            printf "请选择: "
            read -r version || return 0
            version="$(trim_whitespace "$version")"
            [ -n "$version" ] || return 0

            # Handle "b" for back
            if [ "$version" = "b" ] || [ "$version" = "B" ]; then
                return 0
            fi

            if [ ${#lts_names[@]} -gt 0 ]; then
                version="$(select_version_from_number_or_literal "$version" "${lts_names[@]}")"
            fi

            print_blank_line
            printf "正在安装 Node.js %s ...\n" "$version"
            if install_node_version "$version"; then
                local actual_ver=""
                actual_ver="$(node -v 2>/dev/null || true)"
                local install_verified="no"
                print_blank_line
                if ! normalize_node_version "$version" >/dev/null 2>&1; then
                    print_status_message "warn" "版本号无效: $version"
                elif [ -n "$actual_ver" ] && node_version_satisfies_request "$actual_ver" "$version"; then
                    print_status_message "ok" "Node.js $version 安装完成"
                    install_verified="yes"
                elif [ -n "$actual_ver" ]; then
                    print_status_message "warn" "安装命令成功但 node -v 不匹配"
                    printf "  期望: %s\n" "$version"
                    printf "  实际: %s\n" "$actual_ver"
                else
                    print_status_message "warn" "安装命令成功但无法读取 node -v"
                fi
                printf "  node 版本: %s\n" "${actual_ver:-<unknown>}"
                printf "  npm 版本: %s\n" "$(npm -v 2>/dev/null || true)"

                # Only offer to set default if verification passed
                if [ "$install_verified" = "yes" ]; then
                    if prompt_yes_no "是否设置为默认版本？" "n"; then
                        set_node_default_alias_verified "$actual_ver"
                    fi
                else
                    printf "\n"
                    printf "  跳过设置默认版本(安装验证未通过)\n"
                fi
            else
                print_status_message "fail" "Node.js $version 安装失败"
            fi
            pause_before_return
            ;;
        b|B) return 0 ;;
        *)
            print_status_message "warn" "输入无效。"
            pause_before_return
            ;;
    esac
}

# ──────────────────────────────────────────────
# Flow: switch Node version
# ──────────────────────────────────────────────

run_switch_node_flow() {
    local choice=""
    local version=""
    local current_version=""
    local default_alias=""

    print_page_title "更改全局 Node 版本"

    if ! is_nvm_loaded; then
        if ! load_nvm_into_current_shell; then
            printf "nvm 未安装或无法加载。请先安装 nvm。\n"
            pause_before_return
            return 1
        fi
    fi

    current_version="$(nvm current 2>/dev/null || true)"
    default_alias="$(get_nvm_default_version)"

    printf "当前 Node 版本: %s\n" "${current_version:-<unknown>}"
    printf "默认 Node 版本: %s\n" "${default_alias:-<unknown>}"
    print_blank_line

    # List installed versions (reuse helper)
    printf "已安装的 Node 版本:\n"
    print_separator
    local -a versions=()
    local v_index=0
    while IFS= read -r ver; do
        [ -n "$ver" ] || continue
        v_index=$((v_index + 1))
        versions+=("$ver")
        local marker=""
        if [ "$ver" = "$current_version" ]; then
            marker=" (当前)"
        fi
        if [ "$ver" = "$default_alias" ]; then
            marker="${marker} (默认)"
        fi
        printf "  %d) %s%s\n" "$v_index" "$ver" "$marker"
    done <<< "$(get_installed_node_versions)"

    if [ "$v_index" -eq 0 ]; then
        printf "  <none>\n"
        pause_before_return
        return 0
    fi

    print_separator
    printf "输入序号选择版本(b 返回): "
    read -r choice || return 0

    local parsed=""
    parsed="$(parse_numeric_choice "$choice" "$v_index")"

    if [ "$parsed" = "back" ]; then
        return 0
    fi

    if [ "$parsed" = "invalid" ]; then
        print_status_message "warn" "输入无效。"
        pause_before_return
        return 0
    fi

    version="${versions[$((parsed - 1))]}"

    print_blank_line
    printf "切换计划:\n"
    print_separator
    printf "  当前版本: %s\n" "$current_version"
    printf "  目标版本: %s\n" "$version"
    print_separator
    if ! prompt_yes_no "确认切换？" "y"; then
        return 0
    fi

    print_blank_line
    printf "执行切换...\n"
    print_separator
    if switch_node_version "$version"; then
        local actual_version=""
        actual_version="$(node -v 2>/dev/null || true)"
        local switch_verified="no"
        print_blank_line
        if node_version_satisfies_request "$actual_version" "$version"; then
            print_status_message "ok" "版本切换成功"
            printf "  切换前: %s\n" "$current_version"
            printf "  切换后: %s\n" "$actual_version"
            switch_verified="yes"
        else
            print_status_message "warn" "nvm use 成功但 node -v 不匹配"
            printf "  期望: %s\n" "$version"
            printf "  实际: %s\n" "${actual_version:-<unknown>}"
        fi

        # Only offer to set default if verification passed
        if [ "$switch_verified" = "yes" ]; then
            if prompt_yes_no "是否同时设置为默认版本？" "n"; then
                set_node_default_alias_verified "$version"
            fi
        else
            printf "\n"
            printf "  跳过设置默认版本(切换验证未通过)\n"
        fi
    else
        print_status_message "fail" "版本切换失败"
        printf "  当前版本: %s\n" "$(node -v 2>/dev/null || true)"
    fi

    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: cleanup
# ──────────────────────────────────────────────

run_cleanup_menu() {
    printf "1) npm cache verify\n"
    printf "2) npm cache clean --force\n"
    printf "3) 清理 npm 用户缓存目录\n"
    printf "4) 清理 node-gyp 缓存\n"
    printf "5) 清理全局 bin 孤儿软链接\n"
    printf "6) 清理 nvm 旧版本残留\n"
    printf "b) 返回\n"
}

run_npm_cache_verify_cleanup() {
    local verify_output=""
    local verify_exit=0

    print_blank_line
    printf "执行 npm cache verify...\n"
    print_separator
    verify_output="$(npm cache verify 2>&1)" || verify_exit=$?
    printf "%s\n" "$verify_output"
    print_separator
    if [ "$verify_exit" -eq 0 ]; then
        print_status_message "ok" "缓存验证完成"
    else
        print_status_message "fail" "缓存验证失败 exit $verify_exit"
    fi
    pause_before_return
}

run_npm_cache_clean_cleanup() {
    print_blank_line
    printf "将执行 npm cache clean --force\n"
    printf "这会清理 npm 缓存目录中的所有内容。\n"
    print_blank_line
    if ! prompt_yes_no "确认清理？" "n"; then
        return 0
    fi

    print_blank_line
    printf "执行清理...\n"
    print_separator
    if ! acquire_runtime_lock "npm-mutation"; then
        print_status_message "fail" "已有 npm cache 操作在运行"
        pause_before_return
        return 1
    fi
    npm cache clean --force 2>&1
    local clean_exit=$?
    release_runtime_lock "npm-mutation"
    if [ "$clean_exit" -eq 0 ]; then
        local cache_status=""
        local cache_verify_exit=0
        cache_status="$(npm cache verify 2>&1)" || cache_verify_exit=$?
        if [ "$cache_verify_exit" -eq 0 ]; then
            print_status_message "ok" "缓存清理完成"
        else
            print_status_message "warn" "缓存清理执行成功但验证失败 exit $cache_verify_exit"
        fi
        printf "  清理后状态:\n"
        printf "%s\n" "$cache_status" | head -3
    else
        print_status_message "fail" "缓存清理失败"
    fi
    pause_before_return
}

remove_confirmed_cache_directory() {
    local label="$1"
    local original_path="$2"
    local resolved_path=""
    local dir_size=""
    local confirm_path=""

    if [ ! -d "$original_path" ]; then
        printf "%s目录不存在，无需清理: %s\n" "$label" "$original_path"
        pause_before_return
        return 0
    fi

    if ! resolved_path="$(resolve_safe_user_cache_delete_path "$original_path")"; then
        print_status_message "fail" "$label路径不在安全范围内，拒绝操作: $original_path"
        printf "  允许范围: HOME 子目录或 /tmp 子目录；拒绝 HOME、/tmp、/private/tmp 根目录\n"
        pause_before_return
        return 1
    fi

    dir_size="$(du -sh "$resolved_path" 2>/dev/null | awk '{print $1}')"
    printf "%s路径: %s\n" "$label" "$resolved_path"
    printf "目录体积: %s\n" "${dir_size:-<unknown>}"
    print_blank_line
    printf "请输入完整路径确认删除: %s\n" "$resolved_path"
    printf "确认路径: "
    read -r confirm_path || return 0
    confirm_path="$(trim_whitespace "$confirm_path")"
    if [ "$confirm_path" != "$resolved_path" ]; then
        printf "确认路径不匹配，取消删除。\n"
        return 0
    fi

    print_blank_line
    printf "执行删除...\n"
    print_separator
    if ! acquire_runtime_lock "npm-mutation"; then
        print_status_message "fail" "已有 npm 变更操作在运行，已取消目录删除"
        pause_before_return
        return 1
    fi
    if rm -rf "$resolved_path"; then
        release_runtime_lock "npm-mutation"
        if [ -d "$resolved_path" ]; then
            print_status_message "warn" "删除命令执行成功但目录仍存在"
        else
            print_status_message "ok" "$label已删除"
            printf "  路径: %s\n" "$resolved_path"
            printf "  释放空间: %s\n" "${dir_size:-<unknown>}"
        fi
    else
        release_runtime_lock "npm-mutation"
        print_status_message "fail" "$label删除失败"
        printf "  路径: %s\n" "$resolved_path"
    fi
    pause_before_return
}

run_npm_cache_dir_cleanup() {
    local cache_path=""

    print_page_title "清理 npm 用户缓存目录"
    cache_path="$(get_npm_cache_path)"
    if [ -z "$cache_path" ]; then
        printf "无法获取 npm cache 路径。\n"
        pause_before_return
        return 0
    fi
    print_status_message "warn" "高级修复入口: 优先使用 npm cache verify / npm cache clean --force"
    printf "直接删除 cache 目录可能影响正在运行的 npm 进程。继续前请确认没有 npm install/update/cache 操作正在运行。\n"
    print_blank_line
    if ! prompt_yes_no "确认进入直接目录删除流程？" "n"; then
        return 0
    fi
    printf "npm cache 路径: %s\n" "$cache_path"
    remove_confirmed_cache_directory "npm cache 目录" "$cache_path"
}

run_node_gyp_cache_cleanup() {
    local candidates=""
    local nodegyp_path=""
    local source=""
    local resolved_path=""
    local dir_size=""
    local choice=""
    local parsed_choice=""
    local selected_index=""
    local cleaned=0
    local clean_failed=0
    local -a existing_paths=()
    local -a existing_sources=()

    print_page_title "清理 node-gyp 缓存"
    candidates="$(detect_node_gyp_cache_dirs)"
    if [ -z "$candidates" ]; then
        printf "没有可检测的 node-gyp 缓存路径。\n"
        pause_before_return
        return 0
    fi

    while IFS='|' read -r nodegyp_path source; do
        [ -n "$nodegyp_path" ] || continue
        [ -d "$nodegyp_path" ] || continue
        existing_paths+=("$nodegyp_path")
        existing_sources+=("${source:-unknown}")
    done <<< "$candidates"

    if [ "${#existing_paths[@]}" -eq 0 ]; then
        printf "检测到候选路径，但当前都不存在，无需清理。\n"
        pause_before_return
        return 0
    fi

    printf "检测到的 node-gyp 缓存目录:\n"
    print_separator
    local i=0
    while [ "$i" -lt "${#existing_paths[@]}" ]; do
        nodegyp_path="${existing_paths[$i]}"
        source="${existing_sources[$i]}"
        resolved_path="$(resolve_safe_user_cache_delete_path "$nodegyp_path" 2>/dev/null || true)"
        if [ -n "$resolved_path" ]; then
            dir_size="$(du -sh "$resolved_path" 2>/dev/null | awk '{print $1}')"
        else
            dir_size="<unsafe>"
        fi
        printf "  %d) %s\n" "$((i + 1))" "$nodegyp_path"
        printf "     来源: %s  体积: %s\n" "$source" "${dir_size:-<unknown>}"
        i=$((i + 1))
    done
    print_separator
    printf "输入序号、范围或 all 全选；输入 b 返回。\n"
    printf "请选择要清理的目录: "
    read -r choice || return 0
    if ! parsed_choice="$(parse_multi_numeric_choice "$choice" "${#existing_paths[@]}")"; then
        printf "输入无效，已取消。\n"
        pause_before_return
        return 1
    fi
    [ "$parsed_choice" != "back" ] || return 0
    if [ "$parsed_choice" = "all" ]; then
        parsed_choice=""
        local all_index=1
        while [ "$all_index" -le "${#existing_paths[@]}" ]; do
            parsed_choice="${parsed_choice:+$parsed_choice }$all_index"
            all_index=$((all_index + 1))
        done
    fi

    for selected_index in $parsed_choice; do
        i=$((selected_index - 1))
        if remove_confirmed_cache_directory "node-gyp 缓存(${existing_sources[$i]})" "${existing_paths[$i]}"; then
            cleaned=$((cleaned + 1))
        else
            clean_failed=$((clean_failed + 1))
        fi
    done

    print_blank_line
    printf "清理完成: 成功 %d，失败 %d\n" "$cleaned" "$clean_failed"
    pause_before_return
}

run_orphan_bin_cleanup() {
    local global_bin=""
    local orphan=""
    local orphan_choice=""
    local orphan_parsed=""
    local cleaned=0
    local clean_failed=0
    local -a orphans=()
    local -a selected_orphans=()

    print_page_title "清理全局 bin 孤儿软链接"
    if ! global_bin="$(get_global_bin_dir)"; then
        printf "无法获取全局 bin 目录。\n"
        pause_before_return
        return 1
    fi
    if [ ! -d "$global_bin" ]; then
        printf "全局 bin 目录不存在: %s\n" "$global_bin"
        pause_before_return
        return 0
    fi

    while IFS= read -r orphan; do
        [ -n "$orphan" ] || continue
        [ -L "$orphan" ] && [ ! -e "$orphan" ] && orphans+=("$orphan")
    done < <(find "$global_bin" -maxdepth 1 -type l 2>/dev/null)

    if [ ${#orphans[@]} -eq 0 ]; then
        printf "没有发现孤儿软链接。\n"
        pause_before_return
        return 0
    fi

    printf "发现 %d 个孤儿软链接:\n" "${#orphans[@]}"
    print_separator
    local oi=1
    for orphan in "${orphans[@]}"; do
        printf "  %d) %s -> %s\n" "$oi" "$orphan" "$(readlink "$orphan" 2>/dev/null || true)"
        oi=$((oi + 1))
    done
    print_separator

    printf "输入序号选择要删除的孤儿软链接(多个用空格、逗号或范围分隔，all 全部，b 返回): "
    read -r orphan_choice || return 0
    orphan_parsed="$(parse_multi_numeric_choice "$orphan_choice" "${#orphans[@]}")"
    case "$orphan_parsed" in
        back) return 0 ;;
        invalid)
            print_status_message "warn" "输入无效。"
            pause_before_return
            return 0
            ;;
        all)
            local soi=1
            while [ "$soi" -le "${#orphans[@]}" ]; do
                selected_orphans+=("$soi")
                soi=$((soi + 1))
            done
            ;;
        *)
            local token=""
            for token in $orphan_parsed; do
                selected_orphans+=("$token")
            done
            ;;
    esac

    if ! prompt_yes_no "确认删除选中的 ${#selected_orphans[@]} 个孤儿软链接？" "n"; then
        return 0
    fi

    print_blank_line
    printf "清理孤儿软链接...\n"
    print_separator
    local selected_idx=""
    for selected_idx in "${selected_orphans[@]}"; do
        orphan="${orphans[$((selected_idx - 1))]}"
        if [ ! -L "$orphan" ] || [ -e "$orphan" ]; then
            print_status_message "warn" "跳过非孤儿软链接: $orphan"
            continue
        fi
        if rm -f "$orphan" 2>/dev/null && [ ! -L "$orphan" ] && [ ! -e "$orphan" ]; then
            print_status_message "ok" "已删除: $orphan"
            cleaned=$((cleaned + 1))
        else
            print_status_message "fail" "删除失败: $orphan"
            clean_failed=$((clean_failed + 1))
        fi
    done
    printf "\n清理结果: 成功 %d, 失败 %d\n" "$cleaned" "$clean_failed"
    pause_before_return
}

run_nvm_old_versions_cleanup() {
    print_page_title "清理 nvm 旧版本残留"
    if ! is_nvm_loaded && ! load_nvm_into_current_shell; then
        printf "nvm 未安装或无法加载。\n"
        pause_before_return
        return 1
    fi

    local current_ver=""
    local default_ver=""
    local default_info=""
    local default_status=""
    local ver=""
    local choice=""
    local parsed=""
    local cv_index=0
    local -a cleanup_versions=()
    local -a cleanup_dirs=()
    local -a cleanup_sizes=()

    current_ver="$(nvm current 2>/dev/null || true)"
    default_info="$(get_nvm_default_info)"
    default_ver="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"
    printf "当前版本: %s\n" "${current_ver:-<unknown>}"
    printf "默认版本: %s\n" "${default_ver:-<unknown>}"
    if [ "$default_status" != "resolved" ]; then
        print_status_message "warn" "default alias 无法解析为具体版本，旧版本清理将禁止执行"
    fi
    print_blank_line
    printf "已安装的 Node 版本:\n"
    print_separator

    while IFS= read -r ver; do
        [ -n "$ver" ] || continue
        local vdir=""
        local vsize=""
        local skip_reason=""
        local pkg_summary=""
        vdir="$(nvm_version_dir "$ver")"
        vsize="$(du -sh "$vdir" 2>/dev/null | awk '{print $1}')"
        pkg_summary="$(nvm_version_package_summary "$vdir" 2>/dev/null || true)"
        if [ "$ver" = "$current_ver" ]; then
            skip_reason=" (当前版本，不可清理)"
        elif [ "$default_status" != "resolved" ]; then
            skip_reason=" (default alias 未解析，不可清理)"
        elif [ "$ver" = "$default_ver" ]; then
            skip_reason=" (默认版本，不可清理)"
        else
            local v_pkg_count=""
            if ! v_pkg_count="$(nvm_version_user_package_count "$vdir" 2>/dev/null)"; then
                skip_reason=" (npm 不可用或全局包不可验证，不可清理)"
            elif [ "$v_pkg_count" -gt 0 ] 2>/dev/null; then
                skip_reason=" (${v_pkg_count} 个用户全局包，不可清理)"
            fi
        fi
        cv_index=$((cv_index + 1))
        cleanup_versions+=("$ver")
        cleanup_dirs+=("$vdir")
        cleanup_sizes+=("$vsize")
        printf "  %d) %-15s %s%s\n" "$cv_index" "$ver" "${vsize:-<unknown>}" "$skip_reason"
        if [ -n "$pkg_summary" ]; then
            printf "      package summary: %s\n" "$pkg_summary"
        fi
    done <<< "$(get_installed_node_versions)"

    if [ "$cv_index" -eq 0 ]; then
        printf "  <none>\n"
        pause_before_return
        return 0
    fi

    print_separator
    printf "输入序号选择要清理的版本(多个用空格分隔，b 返回):\n"
    printf "注意: 当前版本和默认版本不可清理。\n\n请选择: "
    read -r choice || return 0
    parsed="$(parse_multi_numeric_choice "$choice" "$cv_index")"
    case "$parsed" in
        back) return 0 ;;
        invalid)
            print_status_message "warn" "输入无效。"
            pause_before_return
            return 0
            ;;
    esac

    local token=""
    local idx=""
    local -a selected=()
    local -a valid_indices=()
    if [ "$parsed" = "all" ]; then
        idx=1
        while [ "$idx" -le "$cv_index" ]; do
            selected+=("$idx")
            idx=$((idx + 1))
        done
    else
        for token in $parsed; do
            selected+=("$token")
        done
    fi

    print_blank_line
    printf "清理计划:\n"
    print_separator
    for idx in "${selected[@]}"; do
        ver="${cleanup_versions[$((idx - 1))]}"
        local vdir="${cleanup_dirs[$((idx - 1))]}"
        local v_pkg_count=""
        if [ "$ver" = "$current_ver" ]; then
            print_status_message "warn" "$ver 当前版本，跳过"
        elif [ "$default_status" != "resolved" ]; then
            print_status_message "warn" "$ver default alias 未解析，跳过"
        elif [ "$ver" = "$default_ver" ]; then
            print_status_message "warn" "$ver 默认版本，跳过"
        elif ! v_pkg_count="$(nvm_version_user_package_count "$vdir" 2>/dev/null)"; then
            print_status_message "warn" "$ver npm 不可用或全局包不可验证，跳过"
        elif [ "$v_pkg_count" -gt 0 ] 2>/dev/null; then
            print_status_message "warn" "$ver 仍有用户全局包，跳过"
        else
            local summary=""
            summary="$(nvm_version_package_summary "$vdir" 2>/dev/null || true)"
            printf "  将卸载: %s %s\n" "$ver" "${cleanup_sizes[$((idx - 1))]:-<unknown>}"
            if [ -n "$summary" ]; then
                printf "    package summary: %s\n" "$summary"
            fi
            valid_indices+=("$idx")
        fi
    done

    if [ ${#valid_indices[@]} -eq 0 ]; then
        printf "\n没有可清理的版本。\n"
        pause_before_return
        return 0
    fi

    print_separator
    if ! prompt_yes_no "确认卸载以上 ${#valid_indices[@]} 个版本？" "n"; then
        return 0
    fi

    local expected_versions=""
    for idx in "${valid_indices[@]}"; do
        ver="${cleanup_versions[$((idx - 1))]}"
        expected_versions="${expected_versions}${expected_versions:+ }${ver}"
    done
    printf "请输入完整版本号确认: %s\n确认版本: " "$expected_versions"
    local confirmed_versions=""
    read -r confirmed_versions || return 0
    confirmed_versions="$(trim_whitespace "$confirmed_versions")"
    if [ "$confirmed_versions" != "$expected_versions" ]; then
        printf "确认版本不匹配，取消卸载。\n"
        return 0
    fi

    print_blank_line
    printf "开始清理...\n"
    print_separator
    local cleaned=0
    local clean_warned=0
    local clean_failed=0
    for idx in "${valid_indices[@]}"; do
        ver="${cleanup_versions[$((idx - 1))]}"
        local vdir="${cleanup_dirs[$((idx - 1))]}"
        printf "卸载 %s ...\n" "$ver"
        if ! acquire_runtime_lock "nvm-mutation"; then
            print_status_message "fail" "$ver 已有 nvm uninstall 操作在运行"
            clean_failed=$((clean_failed + 1))
            continue
        fi
        nvm uninstall "$ver"
        local uninstall_exit=$?
        release_runtime_lock "nvm-mutation"
        if [ "$uninstall_exit" -eq 0 ]; then
            if [ -d "$vdir" ]; then
                print_status_message "warn" "$ver: nvm uninstall 成功但目录仍存在"
                clean_warned=$((clean_warned + 1))
            else
                print_status_message "ok" "$ver 已卸载"
                cleaned=$((cleaned + 1))
            fi
        else
            print_status_message "fail" "$ver 卸载失败"
            clean_failed=$((clean_failed + 1))
        fi
    done
    printf "\n清理结果: 成功 %d, 警告 %d, 失败 %d\n" "$cleaned" "$clean_warned" "$clean_failed"
    pause_before_return
}

run_cleanup_flow() {
    local choice=""

    while true; do
        print_page_title "清理 npm 环境"
        run_cleanup_menu
        print_blank_line
        printf "请选择: "
        read -r choice || return 0

        case "$choice" in
            1) run_npm_cache_verify_cleanup ;;
            2) run_npm_cache_clean_cleanup ;;
            3) run_npm_cache_dir_cleanup ;;
            4) run_node_gyp_cache_cleanup ;;
            5) run_orphan_bin_cleanup ;;
            6) run_nvm_old_versions_cleanup ;;
            b|B) return 0 ;;
            *)
                print_status_message "warn" "输入无效。"
                pause_before_return
                ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Flow: uninstall Node.js version
# ──────────────────────────────────────────────

run_uninstall_node_flow() {
    local choice=""
    local version=""
    local current_version=""
    local default_alias=""
    local default_info=""
    local default_status=""
    local v_index=0
    local -a versions=()

    print_page_title "卸载 Node.js 版本"

    if ! is_nvm_loaded; then
        if ! load_nvm_into_current_shell; then
            printf "nvm 未安装或无法加载。\n"
            pause_before_return
            return 1
        fi
    fi

    current_version="$(nvm current 2>/dev/null || true)"
    default_info="$(get_nvm_default_info)"
    default_alias="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"

    printf "当前版本: %s\n" "${current_version:-<unknown>}"
    printf "默认版本: %s\n" "${default_alias:-<unknown>}"
    if [ "$default_status" != "resolved" ]; then
        print_status_message "warn" "default alias 无法解析为具体版本，卸载操作将被阻断"
    fi
    print_blank_line
    printf "已安装的 Node 版本:\n"
    print_separator

    while IFS= read -r version; do
        [ -n "$version" ] || continue
        v_index=$((v_index + 1))
        versions+=("$version")
        printf "  %d) %s\n" "$v_index" "$version"
    done <<< "$(get_installed_node_versions)"

    if [ "$v_index" -eq 0 ]; then
        printf "  <none>\n"
        pause_before_return
        return 0
    fi

    print_separator
    printf "输入序号选择要卸载的版本，b 返回: "
    read -r choice || return 0

    local parsed=""
    parsed="$(parse_numeric_choice "$choice" "$v_index")"

    if [ "$parsed" = "back" ]; then
        return 0
    fi

    if [ "$parsed" = "invalid" ]; then
        print_status_message "warn" "输入无效。"
        pause_before_return
        return 0
    fi

    version="${versions[$((parsed - 1))]}"

    # Safety checks
    if [ "$default_status" != "resolved" ]; then
        print_blank_line
        print_status_message "fail" "default alias 未解析，无法安全判断默认版本"
        printf "  请先用 nvm alias default <version> 绑定具体已安装版本。\n"
        pause_before_return
        return 1
    fi

    if [ "$version" = "$current_version" ]; then
        print_blank_line
        print_status_message "fail" "不能卸载当前正在使用的版本 $version"
        printf "  请先切换到其他版本后再卸载。\n"
        pause_before_return
        return 1
    fi

    if [ "$version" = "$default_alias" ]; then
        print_blank_line
        print_status_message "fail" "不能直接卸载默认版本 $version"
        printf "  请先使用「更改全局 Node 版本」将默认版本切换到其他版本。\n"
        printf "  切换后再次执行卸载。\n"
        pause_before_return
        return 1
    fi

    # Show version details
    local version_dir=""
    version_dir="$(nvm_version_dir "$version")"
    print_blank_line
    printf "卸载计划:\n"
    print_separator
    printf "  版本: %s\n" "$version"
    printf "  目录: %s\n" "$version_dir"

    if [ -d "$version_dir" ]; then
        local dir_size=""
        dir_size="$(du -sh "$version_dir" 2>/dev/null | awk '{print $1}')"
        printf "  目录体积: %s\n" "${dir_size:-<unknown>}"
    fi

    # Show global packages under this version
    local version_npm="$version_dir/bin/npm"
    if [ -x "$version_npm" ]; then
        local version_packages=""
        local version_json=""
        version_json="$("$version_npm" ls -g --depth=0 --json 2>/dev/null || true)"
        version_packages="$(printf '%s' "$version_json" \
            | ruby -rjson -e '
                d = JSON.parse(STDIN.read)
                deps = d["dependencies"] || {}
                deps.keys.sort.each do |n|
                  v = deps[n]["version"] rescue "?"
                  puts "#{n} #{v}"
                end
            ' 2>/dev/null || true)"
        if [ -z "$version_packages" ] && ! printf '%s' "$version_json" | validate_json_text; then
            print_blank_line
            print_status_message "fail" "无法解析该版本的全局包列表，取消卸载"
            pause_before_return
            return 1
        fi
        if [ -n "$version_packages" ]; then
            printf "\n  该版本下的全局包:\n"
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                printf "    %s\n" "$line"
            done <<< "$version_packages"
            print_blank_line
            print_status_message "warn" "卸载此版本将同时删除以上全局包"
        fi
    fi

    print_separator
    printf "\n"
    printf "此操作不可逆。请输入版本号确认卸载: "
    read -r choice || return 0
    choice="$(trim_whitespace "$choice")"
    if [ "$choice" != "$version" ]; then
        printf "确认不匹配，取消卸载。\n"
        pause_before_return
        return 0
    fi

    # Execute uninstall
    print_blank_line
    printf "卸载 %s ...\n" "$version"
    print_separator
    if ! acquire_runtime_lock "nvm-mutation"; then
        print_status_message "fail" "已有 nvm uninstall 操作在运行"
        pause_before_return
        return 1
    fi
    nvm uninstall "$version"
    local uninstall_exit=$?
    release_runtime_lock "nvm-mutation"
    if [ "$uninstall_exit" -eq 0 ]; then
        # Verify
        if [ -d "$version_dir" ]; then
            print_status_message "warn" "nvm uninstall 成功但目录仍存在"
        else
            print_status_message "ok" "版本 $version 已卸载"
        fi
    else
        print_status_message "fail" "卸载失败"
    fi

    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: project Node version (.nvmrc)
# ──────────────────────────────────────────────

run_project_node_flow() {
    local project_path=""
    local version=""

    print_page_title "指定项目 Node 版本"
    if [ "${NODE_MANAGER_ALLOW_PROJECT_WRITE:-0}" != "1" ]; then
        print_status_message "warn" "该功能会写入所选项目目录，默认已禁用以保持 scripts/node 输出边界"
        printf "如需启用，请在明确授权后设置 NODE_MANAGER_ALLOW_PROJECT_WRITE=1。\n"
        pause_before_return
        return 0
    fi

    if ! is_nvm_loaded; then
        if ! load_nvm_into_current_shell; then
            printf "nvm 未安装或无法加载。请先安装 nvm。\n"
            pause_before_return
            return 1
        fi
    fi

    printf "请输入项目路径(或拖拽文件夹到终端): "
    read -r project_path || return 0
    project_path="$(normalize_dragged_path "$project_path")"
    [ -n "$project_path" ] || return 0

    # Validate path
    if [ ! -e "$project_path" ]; then
        print_status_message "fail" "路径不存在: $project_path"
        pause_before_return
        return 1
    fi

    if [ ! -d "$project_path" ]; then
        print_status_message "fail" "不是目录: $project_path"
        pause_before_return
        return 1
    fi

    # Check for package.json
    local pkg_json="$project_path/package.json"
    local nvmrc="$project_path/.nvmrc"
    local engines_node=""

    print_blank_line
    printf "项目路径: %s\n" "$project_path"

    if [ -f "$pkg_json" ]; then
        printf "package.json: 存在\n"
        engines_node="$(ruby -rjson -e '
            d = JSON.parse(File.read(ARGV[0]))
            puts d.dig("engines","node") || ""
        ' "$pkg_json" 2>/dev/null || true)"
        if [ -n "$engines_node" ]; then
            printf "  engines.node: %s\n" "$engines_node"
        fi
    else
        printf "package.json: 不存在\n"
    fi

    if [ -f "$nvmrc" ]; then
        local current_nvmrc=""
        current_nvmrc="$(cat "$nvmrc" 2>/dev/null)"
        printf ".nvmrc: 存在 %s\n" "$current_nvmrc"
    else
        printf ".nvmrc: 不存在\n"
    fi

    print_blank_line

    # List installed versions for selection
    printf "已安装的 Node 版本:\n"
    print_separator
    local -a versions=()
    local v_index=0
    while IFS= read -r ver; do
        [ -n "$ver" ] || continue
        v_index=$((v_index + 1))
        versions+=("$ver")
        printf "  %d) %s\n" "$v_index" "$ver"
    done <<< "$(get_installed_node_versions)"

    if [ "$v_index" -eq 0 ]; then
        printf "  <none>\n"
    fi

    print_separator
    printf "输入序号或具体版本号(例如 20.11.0)。20 / 20.11 仅在唯一匹配已安装版本时可用，b 返回\n"
    print_blank_line
    printf "请选择: "
    read -r choice || return 0
    choice="$(trim_whitespace "$choice")"

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        return 0
    fi

    version="$(select_version_from_number_or_literal "$choice" "${versions[@]}")"
    local requested_version="$version"

    [ -n "$version" ] || return 0
    if ! version="$(resolve_project_nvmrc_concrete_version "$version" "${versions[@]}" 2>/dev/null)"; then
        print_status_message "fail" "版本号格式不支持或无法唯一解析: $requested_version"
        printf "请使用具体版本号 X.Y.Z；major/minor 简写必须唯一匹配已安装版本。\n"
        pause_before_return
        return 1
    fi

    local had_nvmrc="no"
    local previous_nvmrc=""
    print_blank_line
    printf "准备写入 .nvmrc: %s\n" "$version"
    printf "注意: 该功能会写入所选项目目录，不属于 scripts/node 运行产物边界。\n"
    printf "请输入完整项目路径确认: %s\n" "$project_path"
    printf "确认路径: "
    local confirmed_project_path=""
    read -r confirmed_project_path || return 0
    confirmed_project_path="$(trim_whitespace "$confirmed_project_path")"
    if [ "$confirmed_project_path" != "$project_path" ]; then
        printf "确认路径不匹配，取消写入。\n"
        return 0
    fi

    if [ -f "$nvmrc" ]; then
        had_nvmrc="yes"
        local existing=""
        existing="$(cat "$nvmrc" 2>/dev/null)"
        previous_nvmrc="$existing"
        printf "  现有内容: %s\n" "$existing"
        if ! prompt_yes_no "是否覆盖？" "y"; then
            return 0
        fi
    fi

    local installed_versions=""
    installed_versions="$(get_installed_node_versions)"
    if ! installed_node_versions_satisfy_request "$version" "$installed_versions"; then
        print_blank_line
        if prompt_yes_no "版本 $version 未安装，是否现在安装？" "y"; then
            if install_node_version "$version"; then
                local installed_actual=""
                installed_actual="$(node -v 2>/dev/null || true)"
                if [ -n "$installed_actual" ] && node_version_satisfies_request "$installed_actual" "$version"; then
                    print_status_message "ok" "Node.js $version 安装完成"
                else
                    print_status_message "fail" "安装后版本验证失败"
                    printf "  请求: %s\n" "$version"
                    printf "  实际: %s\n" "${installed_actual:-<unknown>}"
                    pause_before_return
                    return 1
                fi
            else
                print_status_message "fail" "安装失败"
                pause_before_return
                return 1
            fi
        else
            printf "版本未安装，已取消写入 .nvmrc。\n"
            pause_before_return
            return 0
        fi
    fi

    if atomic_write_file "$nvmrc" "$version"; then
        print_status_message "ok" ".nvmrc 已写入"
        printf "  路径: %s\n" "$nvmrc"
        printf "  内容: %s\n" "$version"
    else
        print_status_message "fail" ".nvmrc 写入失败"
        pause_before_return
        return 1
    fi

    # Optional: use now
    print_blank_line
    if prompt_yes_no "是否在当前 shell 切换到 ${version}？" "y"; then
        if switch_node_version "$version"; then
            local actual_ver=""
            actual_ver="$(node -v 2>/dev/null || true)"
            if [ -n "$actual_ver" ] && node_version_satisfies_request "$actual_ver" "$version"; then
                print_status_message "ok" "已切换到 $actual_ver"
            elif [ -n "$actual_ver" ]; then
                print_status_message "warn" "nvm use 成功但 node -v 不匹配"
                printf "  期望: %s\n" "$version"
                printf "  实际: %s\n" "$actual_ver"
            else
                print_status_message "warn" "nvm use 成功但无法读取 node -v"
            fi
        else
            print_status_message "fail" "切换失败"
            rollback_nvmrc_file "$nvmrc" "$had_nvmrc" "$previous_nvmrc" || true
            print_status_message "warn" ".nvmrc 已回滚"
            pause_before_return
            return 1
        fi
    fi

    pause_before_return
}

# ──────────────────────────────────────────────
# Flow: environment menu
# ──────────────────────────────────────────────

run_environment_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "环境与依赖"
        render_environment_menu
        print_blank_line
        printf "请输入序号: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_environment_choice "$choice")"
        case "$action" in
            overview)
                run_environment_overview
                ;;
            install-nvm)
                run_install_nvm_flow
                ;;
            install-node)
                run_install_node_flow
                ;;
            switch-node)
                run_switch_node_flow
                ;;
            uninstall-node)
                run_uninstall_node_flow
                ;;
            project-node)
                run_project_node_flow
                ;;
            cleanup)
                run_cleanup_flow
                ;;
            back)
                return 0
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1-7 或 b。"
                pause_before_return
                ;;
        esac
    done
}

# ──────────────────────────────────────────────
# CLI helpers for future app wrappers
# ──────────────────────────────────────────────

manager_version() {
    printf "npm-global-manager 0.3.0\n"
}

render_help() {
    cat <<'EOF'
npm-global-manager

Usage:
  npm-global-manager.sh
  npm-global-manager.sh --help
  npm-global-manager.sh --version
  npm-global-manager.sh --info
  npm-global-manager.sh --json summary
  npm-global-manager.sh --json packages
  npm-global-manager.sh --json outdated
  npm-global-manager.sh --json config
  npm-global-manager.sh --json package-plan <safe-package>
  npm-global-manager.sh --json plan <install|uninstall|update-latest> <package-spec-or-name>
  npm-global-manager.sh --json execute <install|uninstall|update-latest> <package-spec-or-name>
  npm-global-manager.sh --json plan registry-set <url>
  npm-global-manager.sh --json execute registry-set <url>
  npm-global-manager.sh --json plan registry-delete
  npm-global-manager.sh --json execute registry-delete
  npm-global-manager.sh --json plan scope-registry-set <scope> <url>
  npm-global-manager.sh --json execute scope-registry-set <scope> <url>
  npm-global-manager.sh --json plan scope-registry-delete <scope>
  npm-global-manager.sh --json execute scope-registry-delete <scope>
  npm-global-manager.sh --json plan nvm-install
  npm-global-manager.sh --json execute nvm-install
  npm-global-manager.sh --json plan node-install <version|lts>
  npm-global-manager.sh --json execute node-install <version|lts>
  npm-global-manager.sh --json plan node-use <version>
  npm-global-manager.sh --json execute node-use <version>
  npm-global-manager.sh --json plan node-uninstall <version>
  npm-global-manager.sh --json execute node-uninstall <version>
  npm-global-manager.sh --json plan cleanup <target>
  npm-global-manager.sh --json execute cleanup <target>
  npm-global-manager.sh --json plan project-nvmrc <project-path> <version>
  npm-global-manager.sh --json execute project-nvmrc <project-path> <version>
  npm-global-manager.sh --json status
  npm-global-manager.sh --json logs [limit]
  npm-global-manager.sh --json logs-cleanup [keep-count]
  npm-global-manager.sh --json operation-result <operation-id> <action> <subject> <exit-code> <status> <log-file>

Options:
  --help       Show this help.
  --version    Show script version.
  --info       Print runtime directories and supported machine commands.
  --dry-run    Compatibility alias for --info; does not simulate arbitrary mutations.
  --test-mode  Enable test-friendly behavior for wrappers.
  --json       Output machine-readable data for supported commands.

Notes:
  JSON execute requires NODE_MANAGER_ALLOW_JSON_EXECUTE=1 after app-side confirmation.
  execute cleanup logs proxies to logs-cleanup and does not require NODE_MANAGER_ALLOW_JSON_EXECUTE.
  node-install also accepts --lts, --lts=<line>, lts/*, and lts/<line>.
  project-nvmrc execute also requires NODE_MANAGER_ALLOW_PROJECT_WRITE=1 because it writes outside scripts/node.
  cleanup targets: npm-cache-verify, npm-cache-clean, node-gyp-cache, orphan-bins, nvm-old-versions, logs.
EOF
}

json_escape() {
    local value="${1:-}"

    if command_exists ruby; then
        ruby -rjson -e 'print ARGV[0].to_json[1..-2]' "$value" 2>/dev/null && return 0
    fi

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

json_print_string_array() {
    local first="yes"
    local item=""

    printf '['
    for item in "$@"; do
        [ "$first" = "yes" ] || printf ','
        first="no"
        printf '"%s"' "$(json_escape "$item")"
    done
    printf ']'
}

json_print_business_error_with_operation() {
    local error_json="$1"
    local action="$2"
    local subject="$3"
    local log_file="$4"
    local exit_code="${5:-1}"
    local code=""
    local operation_id=""

    operation_id="$(create_operation_id "$action-${subject:-default}")"

    if command_exists ruby; then
        ruby -rjson -e '
          raw, action, subject, log_file, exit_code, operation_id = ARGV
          begin
            error = JSON.parse(raw)
            error = {"code" => "action-failed", "rawError" => raw} unless error.is_a?(Hash)
          rescue JSON::ParserError
            error = {"code" => "action-failed", "rawError" => raw}
          end
          code = error["code"].to_s
          code = "action-failed" if code.empty?
          error["code"] = code
          error["operationId"] = operation_id
          error["action"] = action
          error["subject"] = subject
          error["exitCode"] = exit_code.to_i
          error["status"] = "failed"
          error["logFile"] = log_file
          error["causeCode"] = code
          print JSON.generate(error)
        ' "$error_json" "$action" "$subject" "$log_file" "$exit_code" "$operation_id" 2>/dev/null && {
            printf '\n'
            return 0
        }
    fi

    code="$(printf '%s' "$error_json" | sed -n 's/.*"code":"\([^"]*\)".*/\1/p' | sed -n '1p')"
    [ -n "$code" ] || code="action-failed"
    printf '{'
    printf '"code":"%s",' "$(json_escape "$code")"
    printf '"operationId":"%s",' "$(json_escape "$operation_id")"
    printf '"action":"%s",' "$(json_escape "$action")"
    printf '"subject":"%s",' "$(json_escape "$subject")"
    printf '"exitCode":%s,' "$exit_code"
    printf '"status":"failed",'
    printf '"logFile":"%s",' "$(json_escape "$log_file")"
    printf '"causeCode":"%s",' "$(json_escape "$code")"
    printf '"rawError":"%s"' "$(json_escape "$error_json")"
    printf '}\n'
}

render_summary_json() {
    local node_path=""
    local npm_path=""
    local node_version=""
    local npm_version=""
    local nvm_loaded="false"
    local global_prefix=""
    local global_root=""
    local registry=""

    node_path="$(command -v node 2>/dev/null || true)"
    npm_path="$(command -v npm 2>/dev/null || true)"
    node_version="$(node -v 2>/dev/null || true)"
    npm_version="$(npm -v 2>/dev/null || true)"
    if is_nvm_loaded; then
        nvm_loaded="true"
    fi
    global_prefix="$(npm prefix -g 2>/dev/null || true)"
    global_root="$(npm root -g 2>/dev/null || true)"
    registry="$(npm config get registry 2>/dev/null || true)"

    printf '{'
    printf '"nodePath":"%s",' "$(json_escape "$node_path")"
    printf '"npmPath":"%s",' "$(json_escape "$npm_path")"
    printf '"nodeVersion":"%s",' "$(json_escape "$node_version")"
    printf '"npmVersion":"%s",' "$(json_escape "$npm_version")"
    printf '"nvmLoaded":%s,' "$nvm_loaded"
    printf '"globalPrefix":"%s",' "$(json_escape "$global_prefix")"
    printf '"globalRoot":"%s",' "$(json_escape "$global_root")"
    printf '"registry":"%s"' "$(json_escape "$registry")"
    printf '}\n'
}

render_packages_json() {
    local packages_json=""
    if ! packages_json="$(load_global_package_inventory_json)"; then
        printf '{"code":"npm-list-failed"}\n'
        return 1
    fi
    if [ -z "$packages_json" ] || ! printf '%s' "$packages_json" | validate_json_text; then
        printf '{"code":"invalid-package-json"}\n'
        return 1
    fi
    printf '%s\n' "$packages_json"
}

render_outdated_json() {
    local outdated_json=""
    local outdated_exit=0
    local stderr_file=""
    local stderr_text=""

    ensure_runtime_dirs || {
        printf '{"code":"runtime-dir-failed"}\n'
        return 1
    }

    stderr_file="$(mktemp "$(manager_tmp_dir)/npm-outdated-stderr.XXXXXX")" || {
        printf '{"code":"tmp-file-failed"}\n'
        return 1
    }

    outdated_json="$(npm outdated -g --depth=0 --json 2>"$stderr_file")" || outdated_exit=$?
    stderr_text="$(sed -n '1,20p' "$stderr_file" 2>/dev/null || true)"
    rm -f "$stderr_file"

    if [ "$outdated_exit" -gt 1 ]; then
        printf '{"code":"npm-outdated-failed","exitCode":%d,"stderr":"%s"}\n' \
            "$outdated_exit" "$(json_escape "$stderr_text")"
        return 1
    fi
    if [ "$outdated_exit" -eq 1 ] && [ -z "$outdated_json" ] && [ -n "$stderr_text" ]; then
        printf '{"code":"npm-outdated-failed","exitCode":%d,"stderr":"%s"}\n' \
            "$outdated_exit" "$(json_escape "$stderr_text")"
        return 1
    fi
    if [ -z "$outdated_json" ]; then
        printf '{}\n'
        return 0
    fi
    if ! printf '%s' "$outdated_json" | validate_json_text; then
        printf '{"code":"invalid-outdated-json"}\n'
        return 1
    fi
    printf '%s\n' "$outdated_json"
}

run_json_preflight() {
    local command_name="${1:-}"
    local action_name="${2:-}"
    local cmd=""
    local required_commands="sed mktemp"
    local missing_dependencies=""

    case "$command_name" in
        summary|status|logs|logs-cleanup)
            required_commands="sed mktemp"
            ;;
        packages|outdated|config|package-plan)
            required_commands="ruby npm sed mktemp"
            ;;
        plan)
            case "$action_name" in
                nvm-install|node-install|node-use|node-uninstall|project-nvmrc)
                    required_commands="sed mktemp"
                    ;;
                cleanup)
                    case "${3:-}" in
                        logs) required_commands="sed mktemp" ;;
                        npm-cache-verify|npm-cache-clean|node-gyp-cache|orphan-bins) required_commands="npm sed mktemp" ;;
                        nvm-old-versions) required_commands="ruby sed mktemp" ;;
                        *) required_commands="sed mktemp" ;;
                    esac
                    ;;
                registry-set|registry-delete|scope-registry-set|scope-registry-delete)
                    required_commands="npm sed mktemp"
                    ;;
                install|uninstall|update-latest|"")
                    required_commands="ruby npm sed mktemp"
                    ;;
                *)
                    required_commands="sed mktemp"
                    ;;
            esac
            ;;
        execute)
            case "$action_name" in
                nvm-install)
                    required_commands="curl bash sed mktemp"
                    [ -n "$NVM_INSTALL_SHA256" ] && required_commands="$required_commands shasum"
                    ;;
                node-install|node-use|node-uninstall|project-nvmrc)
                    required_commands="sed mktemp"
                    ;;
                cleanup)
                    case "${3:-}" in
                        logs) required_commands="sed mktemp" ;;
                        npm-cache-verify|npm-cache-clean|node-gyp-cache|orphan-bins) required_commands="npm sed mktemp" ;;
                        nvm-old-versions) required_commands="ruby sed mktemp" ;;
                        *) required_commands="sed mktemp" ;;
                    esac
                    ;;
                registry-set|registry-delete|scope-registry-set|scope-registry-delete)
                    required_commands="npm sed mktemp"
                    ;;
                install|uninstall|update-latest|"")
                    required_commands="ruby npm sed mktemp"
                    ;;
                *)
                    required_commands="sed mktemp"
                    ;;
            esac
            ;;
        *)
            required_commands="ruby npm sed mktemp"
            ;;
    esac

    for cmd in $required_commands; do
        if ! command_exists "$cmd"; then
            missing_dependencies="${missing_dependencies:+$missing_dependencies }$cmd"
        fi
    done

    if [ -n "$missing_dependencies" ]; then
        printf '{"code":"missing-dependency","dependencies":['
        local first="yes"
        for cmd in $missing_dependencies; do
            [ "$first" = "yes" ] || printf ','
            first="no"
            printf '"%s"' "$(json_escape "$cmd")"
        done
        printf ']}\n'
        return 1
    fi

    return 0
}

run_json_command() {
    local command_name="${1:-}"
    local output=""
    local command_exit=0
    local preflight_error=""
    local fallback_preflight_error='{"code":"preflight-failed"}'
    local fallback_command_error='{"code":"command-failed"}'
    shift || true

    if ! preflight_error="$(run_json_preflight "$command_name" "$@")"; then
        printf '{"ok":false,"schemaVersion":1,"command":"%s","error":%s}\n' "$(json_escape "$command_name")" "${preflight_error:-$fallback_preflight_error}"
        return 1
    fi

    case "$command_name" in
        summary)
            output="$(render_summary_json)" || command_exit=$?
            ;;
        packages)
            output="$(render_packages_json)" || command_exit=$?
            ;;
        outdated)
            output="$(render_outdated_json)" || command_exit=$?
            ;;
        config)
            output="$(render_config_json)" || command_exit=$?
            ;;
        package-plan)
            output="$(render_package_plan_json "${1:-}")" || command_exit=$?
            ;;
        plan)
            output="$(render_action_plan_json "${1:-}" "${2:-}" "${3:-}")" || command_exit=$?
            ;;
        execute)
            if [ "${1:-}" = "cleanup" ] && [ "${2:-}" = "logs" ]; then
                output="$(render_logs_cleanup_json "${3:-100}")" || command_exit=$?
            else
                output="$(render_execute_json "${1:-}" "${2:-}" "${3:-}")" || command_exit=$?
            fi
            ;;
        status)
            output="$(render_status_json)" || command_exit=$?
            ;;
        logs)
            output="$(render_logs_json "${1:-20}")" || command_exit=$?
            ;;
        logs-cleanup)
            output="$(render_logs_cleanup_json "${1:-100}")" || command_exit=$?
            ;;
        operation-result)
            output="$(render_operation_result_json "${1:-}" "${2:-}" "${3:-}" "${4:-0}" "${5:-unknown}" "${6:-}")" || command_exit=$?
            ;;
        *)
            printf '{"ok":false,"schemaVersion":1,"command":"%s","error":{"code":"unsupported-json-command"}}\n' "$(json_escape "$command_name")"
            return 1
            ;;
    esac

    if [ "$command_exit" -eq 0 ]; then
        printf '{"ok":true,"schemaVersion":1,"command":"%s","data":%s}\n' "$(json_escape "$command_name")" "${output:-null}"
        return 0
    fi

    printf '{"ok":false,"schemaVersion":1,"command":"%s","error":%s}\n' "$(json_escape "$command_name")" "${output:-$fallback_command_error}"
    return "$command_exit"
}

render_operation_result_json() {
    local operation_id="$1"
    local action="$2"
    local subject="$3"
    local exit_code="$4"
    local status="$5"
    local log_file="$6"

    if ! is_nonnegative_integer "$exit_code"; then
        printf '{"code":"invalid-exit-code","exitCode":"%s"}\n' "$(json_escape "$exit_code")"
        return 1
    fi

    printf '{'
    printf '"operationId":"%s",' "$(json_escape "$operation_id")"
    printf '"action":"%s",' "$(json_escape "$action")"
    printf '"subject":"%s",' "$(json_escape "$subject")"
    printf '"exitCode":%s,' "${exit_code:-0}"
    printf '"status":"%s",' "$(json_escape "$status")"
    printf '"logFile":"%s"' "$(json_escape "$log_file")"
    printf '}\n'
}

render_config_json() {
    local registry=""
    local cache_path=""
    local prefix=""
    registry="$(npm config get registry 2>/dev/null || true)"
    cache_path="$(npm config get cache 2>/dev/null || true)"
    prefix="$(npm prefix -g 2>/dev/null || true)"
    printf '{'
    printf '"registry":"%s",' "$(json_escape "$registry")"
    printf '"cache":"%s",' "$(json_escape "$cache_path")"
    printf '"prefix":"%s",' "$(json_escape "$prefix")"
    printf '"userRegistry":"%s",' "$(json_escape "$(npm_config_get_layer registry user)")"
    printf '"projectRegistry":"%s",' "$(json_escape "$(npm_config_get_layer registry project)")"
    printf '"globalRegistry":"%s"' "$(json_escape "$(npm_config_get_layer registry global)")"
    printf '}\n'
}

resolve_nvm_install_request_json() {
    local requested="${1:-}"
    requested="${requested:-$NVM_INSTALL_VERSION}"

    if [ "$requested" != "$NVM_INSTALL_VERSION" ]; then
        printf '{"code":"unsupported-nvm-install-version","action":"nvm-install","requestedVersion":"%s","configuredVersion":"%s"}\n' \
            "$(json_escape "$requested")" "$(json_escape "$NVM_INSTALL_VERSION")"
        return 1
    fi

    printf '{'
    printf '"requestedVersion":"%s",' "$(json_escape "$requested")"
    printf '"resolvedVersion":"%s",' "$(json_escape "$NVM_INSTALL_VERSION")"
    printf '"installUrl":"%s",' "$(json_escape "$NVM_INSTALL_URL")"
    printf '"sha256":"%s",' "$(json_escape "$NVM_INSTALL_SHA256")"
    printf '"sha256Configured":%s' "$([ -n "$NVM_INSTALL_SHA256" ] && printf true || printf false)"
    printf '}\n'
}

normalize_node_install_target() {
    local target="${1:-}"

    case "$target" in
        lts|--lts|lts/\*)
            printf '%s\n' "--lts"
            return 0
            ;;
        --lts=*)
            [ -n "${target#--lts=}" ] || return 1
            printf '%s\n' "$target"
            return 0
            ;;
        lts/*)
            [ -n "${target#lts/}" ] || return 1
            printf '%s\n' "--lts=${target#lts/}"
            return 0
            ;;
        *)
            normalize_node_version "$target"
            ;;
    esac
}

validate_node_install_target() {
    normalize_node_install_target "$1" >/dev/null 2>&1
}

validate_node_concrete_action_version() {
    normalize_node_concrete_version "$1" >/dev/null 2>&1
}

print_invalid_node_version_for_action_json() {
    local action="$1"
    local version="${2:-}"

    printf '{"code":"invalid-node-version-for-action","action":"%s","version":"%s"}\n' \
        "$(json_escape "$action")" "$(json_escape "$version")"
}

collect_node_plan_state() {
    local nvm_available="false"
    local current_version=""
    local default_info=""
    local default_version=""
    local default_status=""

    if load_nvm_into_current_shell >/dev/null 2>&1; then
        nvm_available="true"
        current_version="$(nvm current 2>/dev/null || true)"
        default_info="$(parse_nvm_default_alias_output "$(nvm alias default 2>/dev/null || true)")"
    else
        default_info="$(read_nvm_default_alias_file_info)"
    fi
    default_version="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"

    printf '%s|%s|%s|%s\n' "$nvm_available" "$current_version" "$default_version" "$default_status"
}

validate_cleanup_target() {
    case "${1:-}" in
        npm-cache-verify|npm-cache-clean|node-gyp-cache|orphan-bins|nvm-old-versions|logs)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

render_non_package_action_plan_json() {
    local action="$1"
    local subject="${2:-}"
    local extra="${3:-}"
    local target_type=""
    local requires_confirmation="true"
    local execute_supported="true"
    local external_write="false"

    case "$action" in
        registry-set)
            validate_registry_url "$subject" || {
                printf '{"code":"invalid-registry-url","action":"registry-set","registry":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            target_type="npm-registry"
            ;;
        registry-delete)
            target_type="npm-registry"
            subject="registry"
            ;;
        scope-registry-set)
            validate_scope_name "$subject" || {
                printf '{"code":"invalid-scope-name","action":"scope-registry-set","scope":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            validate_registry_url "$extra" || {
                printf '{"code":"invalid-registry-url","action":"scope-registry-set","scope":"%s","registry":"%s"}\n' "$(json_escape "$subject")" "$(json_escape "$extra")"
                return 1
            }
            target_type="npm-scope-registry"
            ;;
        scope-registry-delete)
            validate_scope_name "$subject" || {
                printf '{"code":"invalid-scope-name","action":"scope-registry-delete","scope":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            target_type="npm-scope-registry"
            ;;
        nvm-install)
            local nvm_install_request_json=""
            nvm_install_request_json="$(resolve_nvm_install_request_json "$subject")" || {
                printf '%s\n' "$nvm_install_request_json"
                return 1
            }
            target_type="nvm"
            subject="${subject:-$NVM_INSTALL_VERSION}"
            ;;
        node-install)
            validate_node_install_target "$subject" || {
                print_invalid_node_version_for_action_json "$action" "$subject"
                return 1
            }
            target_type="node-version"
            ;;
        node-use|node-uninstall)
            validate_node_concrete_action_version "$subject" || {
                print_invalid_node_version_for_action_json "$action" "$subject"
                return 1
            }
            target_type="node-version"
            ;;
        cleanup)
            validate_cleanup_target "$subject" || {
                printf '{"code":"invalid-cleanup-target","action":"cleanup","target":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            target_type="cleanup"
            [ "$subject" = "npm-cache-verify" ] && requires_confirmation="false"
            ;;
        project-nvmrc)
            [ -n "$subject" ] && [ -n "$extra" ] || {
                printf '{"code":"project-nvmrc-requires-path-and-version","action":"project-nvmrc"}\n'
                return 1
            }
            validate_node_concrete_action_version "$extra" || {
                print_invalid_node_version_for_action_json "project-nvmrc" "$extra"
                return 1
            }
            target_type="project-nvmrc"
            external_write="true"
            ;;
        *)
            printf '{"code":"unsupported-plan-action","action":"%s"}\n' "$(json_escape "$action")"
            return 1
            ;;
    esac

    printf '{'
    printf '"ok":true,'
    printf '"schemaVersion":1,'
    printf '"action":"%s",' "$(json_escape "$action")"
    printf '"targetType":"%s",' "$(json_escape "$target_type")"
    printf '"subject":"%s",' "$(json_escape "$subject")"
    printf '"value":"%s",' "$(json_escape "$extra")"
    printf '"requiresConfirmation":%s,' "$requires_confirmation"
    printf '"executeSupported":%s,' "$execute_supported"
    printf '"logFileHint":"%s",' "$(json_escape "$(create_log_file_hint "$action" "${subject:-default}")")"
    printf '"externalWrite":%s' "$external_write"

    case "$action" in
        registry-set)
            printf ',"effectiveRegistry":"%s"' "$(json_escape "$(npm config get registry 2>/dev/null || true)")"
            printf ',"targetRegistry":"%s"' "$(json_escape "$subject")"
            ;;
        registry-delete)
            printf ',"effectiveRegistry":"%s"' "$(json_escape "$(npm config get registry 2>/dev/null || true)")"
            printf ',"userRegistry":"%s"' "$(json_escape "$(npm_config_get_layer registry user)")"
            printf ',"projectRegistry":"%s"' "$(json_escape "$(npm_config_get_layer registry project)")"
            printf ',"globalRegistry":"%s"' "$(json_escape "$(npm_config_get_layer registry global)")"
            ;;
        scope-registry-set)
            printf ',"effectiveRegistry":"%s"' "$(json_escape "$(npm config get "${subject}:registry" 2>/dev/null || true)")"
            printf ',"targetRegistry":"%s"' "$(json_escape "$extra")"
            ;;
        scope-registry-delete)
            printf ',"effectiveRegistry":"%s"' "$(json_escape "$(npm config get "${subject}:registry" 2>/dev/null || true)")"
            printf ',"userRegistry":"%s"' "$(json_escape "$(npm_config_get_layer "${subject}:registry" user)")"
            printf ',"projectRegistry":"%s"' "$(json_escape "$(npm_config_get_layer "${subject}:registry" project)")"
            printf ',"globalRegistry":"%s"' "$(json_escape "$(npm_config_get_layer "${subject}:registry" global)")"
            ;;
        nvm-install)
            printf ',"requestedVersion":"%s"' "$(json_escape "$subject")"
            printf ',"resolvedVersion":"%s"' "$(json_escape "$NVM_INSTALL_VERSION")"
            printf ',"version":"%s"' "$(json_escape "$NVM_INSTALL_VERSION")"
            printf ',"installUrl":"%s"' "$(json_escape "$NVM_INSTALL_URL")"
            printf ',"sha256":"%s"' "$(json_escape "$NVM_INSTALL_SHA256")"
            printf ',"sha256Configured":%s' "$([ -n "$NVM_INSTALL_SHA256" ] && printf true || printf false)"
            printf ',"allowUnverified":%s' "$([ "$NVM_ALLOW_UNVERIFIED_INSTALL" = "1" ] && printf true || printf false)"
            printf ',"targetDir":"%s"' "$(json_escape "$(detect_nvm_dir)")"
            ;;
        node-install|node-use|node-uninstall)
            local normalized_subject=""
            local current_version=""
            local node_plan_state=""
            local nvm_available="false"
            local default_version=""
            local default_status=""
            local version_dir=""
            if [ "$action" = "node-install" ]; then
                normalized_subject="$(normalize_node_install_target "$subject" 2>/dev/null || printf '%s' "$subject")"
            else
                normalized_subject="$(normalize_node_concrete_version "$subject" 2>/dev/null || printf '%s' "$subject")"
            fi
            node_plan_state="$(collect_node_plan_state)"
            nvm_available="$(printf '%s' "$node_plan_state" | awk -F'|' '{print $1}')"
            current_version="$(printf '%s' "$node_plan_state" | awk -F'|' '{print $2}')"
            default_version="$(printf '%s' "$node_plan_state" | awk -F'|' '{print $3}')"
            default_status="$(printf '%s' "$node_plan_state" | awk -F'|' '{print $4}')"
            case "$normalized_subject" in
                v[0-9]*.[0-9]*.[0-9]*) version_dir="$(nvm_version_dir "$normalized_subject")" ;;
                *) version_dir="" ;;
            esac
            printf ',"nvmAvailable":%s' "$nvm_available"
            printf ',"normalizedVersion":"%s"' "$(json_escape "$normalized_subject")"
            printf ',"currentVersion":"%s"' "$(json_escape "$current_version")"
            printf ',"defaultVersion":"%s"' "$(json_escape "$default_version")"
            printf ',"defaultStatus":"%s"' "$(json_escape "$default_status")"
            printf ',"versionDir":"%s"' "$(json_escape "$version_dir")"
            if [ -n "$version_dir" ] && [ -d "$version_dir" ]; then
                printf ',"versionDirExists":true'
                printf ',"versionDirSize":"%s"' "$(json_escape "$(du -sh "$version_dir" 2>/dev/null | awk '{print $1}')")"
                printf ',"globalPackageSummary":"%s"' "$(json_escape "$(nvm_version_package_summary "$version_dir" 2>/dev/null || true)")"
            else
                printf ',"versionDirExists":false'
            fi
            if [ "$action" = "node-uninstall" ]; then
                printf ',"protectedByCurrent":%s' "$([ "$normalized_subject" = "$current_version" ] && printf true || printf false)"
                printf ',"protectedByDefault":%s' "$([ "$normalized_subject" = "$default_version" ] && printf true || printf false)"
            fi
            ;;
        cleanup)
            printf ',"paths":'
            case "$subject" in
                npm-cache-verify|npm-cache-clean)
                    json_print_string_array "$(npm config get cache 2>/dev/null || true)"
                    ;;
                node-gyp-cache)
                    local node_gyp_paths=()
                    local node_gyp_path=""
                    while IFS='|' read -r node_gyp_path _; do
                        [ -n "$node_gyp_path" ] || continue
                        node_gyp_paths+=("$node_gyp_path")
                    done <<< "$(detect_node_gyp_cache_dirs)"
                    json_print_string_array "${node_gyp_paths[@]}"
                    ;;
                orphan-bins)
                    json_print_string_array "$(get_global_bin_dir 2>/dev/null || true)"
                    ;;
                nvm-old-versions)
                    local nvm_old_paths=()
                    local old_ver=""
                    while IFS= read -r old_ver; do
                        [ -n "$old_ver" ] || continue
                        nvm_old_paths+=("$(nvm_version_dir "$old_ver")")
                    done <<< "$(get_installed_node_versions 2>/dev/null || true)"
                    json_print_string_array "${nvm_old_paths[@]}"
                    ;;
                logs)
                    json_print_string_array "$(manager_log_dir)"
                    ;;
                *)
                    json_print_string_array
                    ;;
            esac
            ;;
        project-nvmrc)
            local current_nvmrc=""
            local engines_node=""
            [ -f "$subject/.nvmrc" ] && current_nvmrc="$(sed -n '1p' "$subject/.nvmrc" 2>/dev/null || true)"
            if [ -f "$subject/package.json" ] && command_exists ruby; then
                engines_node="$(ruby -rjson -e 'data = JSON.parse(File.read(ARGV[0])); puts data.dig("engines", "node") || ""' "$subject/package.json" 2>/dev/null || true)"
            fi
            printf ',"pathExists":%s' "$([ -e "$subject" ] && printf true || printf false)"
            printf ',"pathIsDirectory":%s' "$([ -d "$subject" ] && printf true || printf false)"
            printf ',"nvmrcPath":"%s"' "$(json_escape "$subject/.nvmrc")"
            printf ',"currentNvmrc":"%s"' "$(json_escape "$current_nvmrc")"
            printf ',"packageJsonExists":%s' "$([ -f "$subject/package.json" ] && printf true || printf false)"
            printf ',"enginesNode":"%s"' "$(json_escape "$engines_node")"
            ;;
    esac
    printf '}\n'
}

render_action_plan_json() {
    local action="${1:-}"
    local subject="${2:-}"
    local extra="${3:-}"
    local package_name=""
    local package_spec="$subject"
    local installed_version=""
    local target_version=""
    local log_file_hint=""

    [ -n "$action" ] || {
        printf '{"code":"missing-argument","argument":"action"}\n'
        return 1
    }

    case "$action" in
        install)
            validate_package_spec "$package_spec" || {
                printf '{"code":"invalid-package-spec","action":"install","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
                return 1
            }
            package_name="$(extract_package_name "$package_spec")"
            if ! target_version="$(resolve_install_target_version "$package_spec")"; then
                printf '{"code":"target-version-unavailable","action":"install","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
                return 1
            fi
            ;;
        uninstall|update-latest)
            validate_package_name_only "$subject" || {
                printf '{"code":"invalid-package-name","action":"%s","packageName":"%s"}\n' "$(json_escape "$action")" "$(json_escape "$subject")"
                return 1
            }
            package_name="$subject"
            if [ "$action" = "uninstall" ] && is_protected_global_package "$package_name"; then
                printf '{"code":"protected-package","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
                return 1
            fi
            ;;
        *)
            render_non_package_action_plan_json "$action" "$subject" "$extra"
            return $?
            ;;
    esac

    installed_version="$(get_installed_global_package_version "$package_name")"
    if [ "$action" = "uninstall" ] && [ -z "$installed_version" ]; then
        printf '{"code":"package-not-installed","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
        return 1
    fi
    log_file_hint="$(create_log_file_hint "$action" "$package_name")"

    printf '{'
    printf '"ok":true,'
    printf '"schemaVersion":1,'
    printf '"action":"%s",' "$(json_escape "$action")"
    printf '"packageSpec":"%s",' "$(json_escape "$package_spec")"
    printf '"packageName":"%s",' "$(json_escape "$package_name")"
    printf '"installedVersion":"%s",' "$(json_escape "$installed_version")"
    printf '"targetVersion":"%s",' "$(json_escape "$target_version")"
    printf '"alreadyInstalled":%s,' "$(is_install_spec_satisfied "$package_spec" "$installed_version" "$target_version" && printf true || printf false)"
    printf '"logFileHint":"%s",' "$(json_escape "$log_file_hint")"
    printf '"requiresConfirmation":true,'
    printf '"executeSupported":true'
    printf '}\n'
}

render_uninstall_execute_json() {
    local package_name="$1"
    local installed_version=""
    local global_root=""
    local global_bin_dir=""
    local install_path=""
    local bin_cmds=""
    local dir_snapshot=""
    local operation_id=""
    local log_file=""
    local exit_code=0
    local still_installed="no"
    local status="ok"
    local detail=""
    local cleanup_residue="${NODE_MANAGER_JSON_UNINSTALL_CLEAN_RESIDUE:-0}"
    local cleaned_residues=0
    local failed_residue_cleanups=0
    local cmd=""
    local bin_snapshot=""
    local snapshot=""
    local bin_path=""
    local residue_path=""
    local residue_snapshot=""
    local -a bin_snapshots=()
    local -a residue_dirs=()
    local -a residue_dir_snapshots=()
    local -a residue_bins=()
    local -a residue_bin_snapshots=()

    validate_package_name_only "$package_name" || {
        printf '{"code":"invalid-package-name","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
        return 1
    }
    if is_protected_global_package "$package_name"; then
        printf '{"code":"protected-package","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
        return 1
    fi

    installed_version="$(get_installed_global_package_version "$package_name")"
    if [ -z "$installed_version" ]; then
        printf '{"code":"package-not-installed","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
        return 1
    fi

    global_root="$(npm root -g 2>/dev/null || true)"
    [ -n "$global_root" ] || {
        printf '{"code":"global-root-unavailable","packageName":"%s"}\n' "$(json_escape "$package_name")"
        return 1
    }
    if ! global_bin_dir="$(get_global_bin_dir)"; then
        printf '{"code":"global-bin-dir-unavailable","packageName":"%s"}\n' "$(json_escape "$package_name")"
        return 1
    fi

    install_path="$global_root/$package_name"
    bin_cmds="$(get_package_bin_commands "$package_name" 2>/dev/null || true)"
    dir_snapshot="$(capture_directory_snapshot "$install_path" "$global_root" 2>/dev/null || true)"

    if [ -n "$bin_cmds" ] && [ -d "$global_bin_dir" ]; then
        while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            bin_path="$global_bin_dir/$cmd"
            bin_snapshot="$(capture_symlink_snapshot "$bin_path" "$install_path" 2>/dev/null || true)"
            [ -n "$bin_snapshot" ] && bin_snapshots+=("$bin_snapshot")
        done <<< "$bin_cmds"
    fi

    operation_id="$(create_operation_id "uninstall-$package_name")"
    log_file="$(create_log_file uninstall "$package_name")" || return 1
    uninstall_global_package "$package_name" "$log_file" || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        if npm_package_is_installed "$package_name"; then
            still_installed="yes"
            status="failed"
            detail="still-installed"
        fi

        if [ "$still_installed" = "no" ]; then
            if [ -d "$install_path" ] && [ -n "$dir_snapshot" ] && verify_directory_snapshot_current "$dir_snapshot"; then
                residue_dirs+=("$install_path")
                residue_dir_snapshots+=("$dir_snapshot")
            fi
            if [ "${#bin_snapshots[@]}" -gt 0 ]; then
                local snapshot_index=0
                while [ "$snapshot_index" -lt "${#bin_snapshots[@]}" ]; do
                    snapshot="${bin_snapshots[$snapshot_index]}"
                    if verify_symlink_snapshot_current "$snapshot"; then
                        residue_bins+=("${snapshot%%|*}")
                        residue_bin_snapshots+=("$snapshot")
                    fi
                    snapshot_index=$((snapshot_index + 1))
                done
            fi
            if [ "${#residue_dirs[@]}" -gt 0 ] || [ "${#residue_bins[@]}" -gt 0 ]; then
                status="warn"
                detail="residue-detected"
            fi
        fi
    else
        status="failed"
        detail="npm-uninstall-failed"
    fi

    if [ "$cleanup_residue" = "1" ] && { [ "${#residue_dirs[@]}" -gt 0 ] || [ "${#residue_bins[@]}" -gt 0 ]; }; then
        local residue_index=0
        while [ "$residue_index" -lt "${#residue_dirs[@]}" ]; do
            residue_path="${residue_dirs[$residue_index]}"
            residue_snapshot="${residue_dir_snapshots[$residue_index]:-}"
            if verify_directory_snapshot_current "$residue_snapshot" && rm -rf "$residue_path" 2>/dev/null && [ ! -d "$residue_path" ]; then
                cleaned_residues=$((cleaned_residues + 1))
            else
                failed_residue_cleanups=$((failed_residue_cleanups + 1))
            fi
            residue_index=$((residue_index + 1))
        done

        residue_index=0
        while [ "$residue_index" -lt "${#residue_bins[@]}" ]; do
            residue_path="${residue_bins[$residue_index]}"
            residue_snapshot="${residue_bin_snapshots[$residue_index]:-}"
            if remove_snapshot_symlink_residue "$residue_snapshot" && [ ! -e "$residue_path" ] && [ ! -L "$residue_path" ]; then
                cleaned_residues=$((cleaned_residues + 1))
            else
                failed_residue_cleanups=$((failed_residue_cleanups + 1))
            fi
            residue_index=$((residue_index + 1))
        done
    fi

    printf '{'
    printf '"operationId":"%s",' "$(json_escape "$operation_id")"
    printf '"action":"uninstall",'
    printf '"subject":"%s",' "$(json_escape "$package_name")"
    printf '"packageName":"%s",' "$(json_escape "$package_name")"
    printf '"installedVersion":"%s",' "$(json_escape "$installed_version")"
    printf '"exitCode":%s,' "$exit_code"
    printf '"status":"%s",' "$(json_escape "$status")"
    printf '"detail":"%s",' "$(json_escape "$detail")"
    printf '"logFile":"%s",' "$(json_escape "$log_file")"
    printf '"residueCleanupPerformed":%s,' "$([ "$cleanup_residue" = "1" ] && printf true || printf false)"
    printf '"cleanedResidues":%s,' "$cleaned_residues"
    printf '"failedResidueCleanups":%s,' "$failed_residue_cleanups"
    printf '"residues":{"directories":'
    if [ "${#residue_dirs[@]}" -gt 0 ]; then
        json_print_string_array "${residue_dirs[@]}"
    else
        json_print_string_array
    fi
    printf ',"bins":'
    if [ "${#residue_bins[@]}" -gt 0 ]; then
        json_print_string_array "${residue_bins[@]}"
    else
        json_print_string_array
    fi
    printf '}}'
    printf '\n'

    [ "$status" != "failed" ]
}

execute_node_uninstall_json_action() {
    local version="$1"
    local current_version=""
    local default_info=""
    local default_version=""
    local default_status=""
    local version_dir=""

    version="$(normalize_node_concrete_version "$version")" || {
        print_invalid_node_version_for_action_json "node-uninstall" "$1"
        return 1
    }
    load_nvm_into_current_shell || {
        printf '{"code":"nvm-unavailable","action":"node-uninstall"}\n'
        return 1
    }
    current_version="$(nvm current 2>/dev/null || true)"
    default_info="$(get_nvm_default_info)"
    default_version="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"
    version_dir="$(nvm_version_dir "$version")"

    if [ ! -d "$version_dir" ]; then
        printf '{"code":"node-version-not-installed","action":"node-uninstall","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    fi
    if [ "$default_status" != "resolved" ]; then
        printf '{"code":"default-node-unresolved","action":"node-uninstall","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    fi
    if [ "$version" = "$current_version" ]; then
        printf '{"code":"cannot-uninstall-current-node","action":"node-uninstall","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    fi
    if [ "$version" = "$default_version" ]; then
        printf '{"code":"cannot-uninstall-default-node","action":"node-uninstall","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    fi
    if ! acquire_runtime_lock "nvm-mutation"; then
        printf '{"code":"mutation-locked","action":"node-uninstall","lock":"nvm-mutation"}\n'
        return 1
    fi
    nvm uninstall "$version"
    local uninstall_exit=$?
    release_runtime_lock "nvm-mutation"
    [ "$uninstall_exit" -eq 0 ] && [ ! -d "$version_dir" ]
}

execute_node_use_json_action() {
    local version="$1"
    local installed_versions=""

    version="$(normalize_node_concrete_version "$version")" || {
        print_invalid_node_version_for_action_json "node-use" "$1"
        return 1
    }
    load_nvm_into_current_shell || {
        printf '{"code":"nvm-unavailable","action":"node-use","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    }
    installed_versions="$(get_installed_node_versions 2>/dev/null || true)"
    if ! installed_node_versions_satisfy_request "$version" "$installed_versions"; then
        printf '{"code":"node-version-not-installed","action":"node-use","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    fi
    switch_node_version "$version"
}

execute_node_install_json_action() {
    local requested="$1"
    local log_file="$2"
    local install_target=""
    local actual_version=""
    local install_exit=0
    local use_exit=0

    install_target="$(normalize_node_install_target "$requested")" || {
        print_invalid_node_version_for_action_json "node-install" "$requested"
        return 1
    }
    if ! load_nvm_into_current_shell >> "$log_file" 2>&1; then
        printf '{"code":"nvm-unavailable","action":"node-install","version":"%s"}\n' "$(json_escape "$install_target")"
        return 1
    fi
    if ! acquire_runtime_lock "nvm-mutation"; then
        printf '{"code":"mutation-locked","action":"node-install","lock":"nvm-mutation"}\n'
        return 1
    fi

    nvm install "$install_target" >> "$log_file" 2>&1
    install_exit=$?
    if [ "$install_exit" -ne 0 ]; then
        release_runtime_lock "nvm-mutation"
        printf '{"code":"node-install-failed","action":"node-install","version":"%s","exitCode":%s}\n' "$(json_escape "$install_target")" "$install_exit"
        return 1
    fi

    nvm use "$install_target" >> "$log_file" 2>&1
    use_exit=$?
    release_runtime_lock "nvm-mutation"
    if [ "$use_exit" -ne 0 ]; then
        printf '{"code":"node-use-after-install-failed","action":"node-install","version":"%s","exitCode":%s}\n' "$(json_escape "$install_target")" "$use_exit"
        return 1
    fi

    actual_version="$(node -v 2>>"$log_file" || nvm current 2>>"$log_file" || true)"
    case "$install_target" in
        --lts*)
            if [ -n "$actual_version" ] && [[ "$actual_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                return 0
            fi
            ;;
        *)
            if node_version_satisfies_request "$actual_version" "$install_target"; then
                return 0
            fi
            ;;
    esac

    printf '{"code":"node-install-verification-failed","action":"node-install","version":"%s","actualVersion":"%s"}\n' \
        "$(json_escape "$install_target")" "$(json_escape "$actual_version")"
    return 1
}

execute_cleanup_json_action() {
    local target="$1"
    local log_file="$2"
    local path=""
    local resolved_path=""
    local global_bin=""
    local orphan=""
    local removed=0

    validate_cleanup_target "$target" || return 2
    case "$target" in
        npm-cache-verify)
            npm cache verify >> "$log_file" 2>&1
            ;;
        npm-cache-clean)
            run_logged_command "$log_file" npm cache clean --force || return 1
            npm cache verify >> "$log_file" 2>&1
            ;;
        logs)
            cleanup_runtime_logs_keep_recent 100 >> "$log_file" 2>&1
            ;;
        node-gyp-cache)
            while IFS='|' read -r path _; do
                [ -n "$path" ] || continue
                [ -d "$path" ] || continue
                resolved_path="$(resolve_safe_user_cache_delete_path "$path" 2>/dev/null || true)"
                [ -n "$resolved_path" ] || return 1
                rm -rf "$resolved_path" >> "$log_file" 2>&1 || return 1
                removed=$((removed + 1))
            done <<< "$(detect_node_gyp_cache_dirs)"
            printf 'removed=%s\n' "$removed" >> "$log_file" 2>&1
            ;;
        orphan-bins)
            global_bin="$(get_global_bin_dir)" || return 1
            [ -d "$global_bin" ] || return 0
            while IFS= read -r orphan; do
                [ -n "$orphan" ] || continue
                if [ -L "$orphan" ] && [ ! -e "$orphan" ]; then
                    rm -f "$orphan" >> "$log_file" 2>&1 || return 1
                    removed=$((removed + 1))
                fi
            done < <(find "$global_bin" -maxdepth 1 -type l 2>/dev/null)
            printf 'removed=%s\n' "$removed" >> "$log_file" 2>&1
            ;;
        nvm-old-versions)
            run_nvm_old_versions_cleanup_json "$log_file"
            ;;
    esac
}

run_nvm_old_versions_cleanup_json() {
    local log_file="$1"
    local current_ver=""
    local default_info=""
    local default_ver=""
    local default_status=""
    local ver=""
    local vdir=""
    local pkg_count=""
    local removed=0

    load_nvm_into_current_shell || return 1
    current_ver="$(nvm current 2>/dev/null || true)"
    default_info="$(get_nvm_default_info)"
    default_ver="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"
    [ "$default_status" = "resolved" ] || return 1

    while IFS= read -r ver; do
        [ -n "$ver" ] || continue
        [ "$ver" != "$current_ver" ] || continue
        [ "$ver" != "$default_ver" ] || continue
        vdir="$(nvm_version_dir "$ver")"
        pkg_count="$(nvm_version_user_package_count "$vdir" 2>/dev/null)" || continue
        [ "$pkg_count" -eq 0 ] 2>/dev/null || continue
        if ! acquire_runtime_lock "nvm-mutation"; then
            return 1
        fi
        nvm uninstall "$ver" >> "$log_file" 2>&1
        local uninstall_exit=$?
        release_runtime_lock "nvm-mutation"
        [ "$uninstall_exit" -eq 0 ] || return 1
        [ ! -d "$vdir" ] || return 1
        removed=$((removed + 1))
    done <<< "$(get_installed_node_versions)"
    printf 'removed=%s\n' "$removed" >> "$log_file" 2>&1
}

write_project_nvmrc_json_action() {
    local project_path="$1"
    local version="$2"
    local nvmrc=""

    [ "${NODE_MANAGER_ALLOW_PROJECT_WRITE:-0}" = "1" ] || {
        printf '{"code":"project-write-disabled","action":"project-nvmrc"}\n'
        return 1
    }
    [ -d "$project_path" ] || {
        printf '{"code":"project-path-not-directory","action":"project-nvmrc","path":"%s"}\n' "$(json_escape "$project_path")"
        return 1
    }
    validate_node_concrete_action_version "$version" || {
        print_invalid_node_version_for_action_json "project-nvmrc" "$version"
        return 1
    }
    nvmrc="$project_path/.nvmrc"
    atomic_write_file "$nvmrc" "$version"
}

render_simple_execute_result_json() {
    local action="$1"
    local subject="$2"
    local log_file="$3"
    local status="$4"
    local exit_code="$5"

    render_operation_result_json "$(create_operation_id "$action-${subject:-default}")" "$action" "$subject" "$exit_code" "$status" "$log_file"
}

render_execute_json() {
    local action="${1:-}"
    local subject="${2:-}"
    local extra="${3:-}"
    local package_name=""
    local package_spec="$subject"
    local operation_id=""
    local log_file=""
    local exit_code=0
    local installed_version=""
    local latest_version=""
    local target_version=""

    [ -n "$action" ] || {
        printf '{"code":"missing-argument","argument":"action"}\n'
        return 1
    }

    if [ "${NODE_MANAGER_ALLOW_JSON_EXECUTE:-0}" != "1" ]; then
        printf '{"code":"json-execute-disabled","hint":"set NODE_MANAGER_ALLOW_JSON_EXECUTE=1 after app-side confirmation"}\n'
        return 1
    fi

    case "$action" in
        install)
            validate_package_spec "$package_spec" || {
                printf '{"code":"invalid-package-spec","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
                return 1
            }
            package_name="$(extract_package_name "$package_spec")"
            if ! target_version="$(resolve_install_target_version "$package_spec")"; then
                printf '{"code":"target-version-unavailable","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
                return 1
            fi
            operation_id="$(create_operation_id "install-$package_name")"
            log_file="$(create_log_file install "$package_name")" || return 1
            install_global_package "$package_spec" "$log_file" || exit_code=$?
            installed_version="$(get_installed_global_package_version "$package_name")"
            local verify_result=""
            local verify_status=""
            verify_result="$(verify_install_result_for_spec "$package_spec" "$installed_version" "$target_version" || true)"
            verify_status="$(printf '%s' "$verify_result" | awk -F'|' '{print $1}')"
            if [ "$exit_code" -eq 0 ] && [ "$verify_status" = "ok" ]; then
                render_operation_result_json "$operation_id" "$action" "$package_name" "$exit_code" "ok" "$log_file"
                return 0
            fi
            render_operation_result_json "$operation_id" "$action" "$package_name" "${exit_code:-1}" "failed" "$log_file"
            return 1
            ;;
        uninstall)
            render_uninstall_execute_json "$subject"
            ;;
        update-latest)
            validate_package_name_only "$subject" || {
                printf '{"code":"invalid-package-name","packageName":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            latest_version="$(get_registry_latest_version "$subject" || true)"
            if [ -z "$latest_version" ]; then
                printf '{"code":"latest-version-unavailable","packageName":"%s"}\n' "$(json_escape "$subject")"
                return 1
            fi
            operation_id="$(create_operation_id "update-latest-$subject")"
            log_file="$(create_log_file update-latest "$subject")" || return 1
            upgrade_global_package_to_latest "$subject" "$log_file" || exit_code=$?
            installed_version="$(get_installed_global_package_version "$subject")"
            if [ "$exit_code" -eq 0 ] && [ "$installed_version" = "$latest_version" ]; then
                render_operation_result_json "$operation_id" "$action" "$subject" "$exit_code" "ok" "$log_file"
                return 0
            fi
            render_operation_result_json "$operation_id" "$action" "$subject" "${exit_code:-1}" "failed" "$log_file"
            return 1
            ;;
        registry-set)
            validate_registry_url "$subject" || {
                printf '{"code":"invalid-registry-url","action":"registry-set","registry":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            log_file="$(create_log_file "$action" registry)" || return 1
            if set_registry_value "$subject" >> "$log_file" 2>&1; then
                render_simple_execute_result_json "$action" "$subject" "$log_file" "ok" 0
                return 0
            fi
            render_simple_execute_result_json "$action" "$subject" "$log_file" "failed" 1
            return 1
            ;;
        registry-delete)
            log_file="$(create_log_file "$action" registry)" || return 1
            if delete_registry_value >> "$log_file" 2>&1; then
                render_simple_execute_result_json "$action" registry "$log_file" "ok" 0
                return 0
            fi
            render_simple_execute_result_json "$action" registry "$log_file" "failed" 1
            return 1
            ;;
        scope-registry-set)
            validate_scope_name "$subject" || {
                printf '{"code":"invalid-scope-name","action":"scope-registry-set","scope":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            validate_registry_url "$extra" || {
                printf '{"code":"invalid-registry-url","action":"scope-registry-set","scope":"%s","registry":"%s"}\n' "$(json_escape "$subject")" "$(json_escape "$extra")"
                return 1
            }
            log_file="$(create_log_file "$action" "$subject")" || return 1
            if set_scope_registry_value "$subject" "$extra" >> "$log_file" 2>&1; then
                render_simple_execute_result_json "$action" "$subject" "$log_file" "ok" 0
                return 0
            fi
            render_simple_execute_result_json "$action" "$subject" "$log_file" "failed" 1
            return 1
            ;;
        scope-registry-delete)
            validate_scope_name "$subject" || {
                printf '{"code":"invalid-scope-name","action":"scope-registry-delete","scope":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            log_file="$(create_log_file "$action" "$subject")" || return 1
            if delete_scope_registry_value "$subject" >> "$log_file" 2>&1; then
                render_simple_execute_result_json "$action" "$subject" "$log_file" "ok" 0
                return 0
            fi
            render_simple_execute_result_json "$action" "$subject" "$log_file" "failed" 1
            return 1
            ;;
        nvm-install|node-install|node-use|node-uninstall|cleanup|project-nvmrc)
            local action_output=""
            local normalized_subject="$subject"
            local nvm_install_request_json=""
            [ "$action" = "nvm-install" ] && normalized_subject="${subject:-$NVM_INSTALL_VERSION}"
            if [ "$action" = "nvm-install" ]; then
                nvm_install_request_json="$(resolve_nvm_install_request_json "$subject")" || {
                    printf '%s\n' "$nvm_install_request_json"
                    return 1
                }
            fi
            log_file="$(create_log_file "$action" "${normalized_subject:-default}")" || return 1
            case "$action" in
                nvm-install)
                    if nvm_install_unverified_blocked; then
                        render_nvm_install_unverified_blocked_json "$normalized_subject" "$log_file"
                        return 1
                    fi
                    install_nvm_official >> "$log_file" 2>&1
                    exit_code=$?
                    ;;
                node-install)
                    action_output="$(execute_node_install_json_action "$subject" "$log_file")" || exit_code=$?
                    if [ "$exit_code" -ne 0 ] && printf '%s' "$action_output" | grep -F '"code":"' >/dev/null 2>&1; then
                        json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" "$exit_code"
                        return 1
                    fi
                    [ -n "$action_output" ] && printf '%s\n' "$action_output" >> "$log_file" 2>&1
                    ;;
                node-use)
                    action_output="$(execute_node_use_json_action "$subject" 2>>"$log_file")" || exit_code=$?
                    if [ "$exit_code" -ne 0 ] && printf '%s' "$action_output" | grep -F '"code":"' >/dev/null 2>&1; then
                        json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" "$exit_code"
                        return 1
                    fi
                    [ -n "$action_output" ] && printf '%s\n' "$action_output" >> "$log_file" 2>&1
                    ;;
                node-uninstall)
                    action_output="$(execute_node_uninstall_json_action "$subject" 2>>"$log_file")" || exit_code=$?
                    if [ "$exit_code" -ne 0 ] && printf '%s' "$action_output" | grep -F '"code":"' >/dev/null 2>&1; then
                        json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" "$exit_code"
                        return 1
                    fi
                    [ -n "$action_output" ] && printf '%s\n' "$action_output" >> "$log_file" 2>&1
                    ;;
                cleanup)
                    validate_cleanup_target "$subject" || {
                        printf '{"code":"invalid-cleanup-target","action":"cleanup","target":"%s","logFile":"%s"}\n' "$(json_escape "$subject")" "$(json_escape "$log_file")"
                        return 1
                    }
                    execute_cleanup_json_action "$subject" "$log_file"
                    exit_code=$?
                    ;;
                project-nvmrc)
                    action_output="$(write_project_nvmrc_json_action "$subject" "$extra" 2>>"$log_file")" || exit_code=$?
                    if [ "$exit_code" -ne 0 ] && printf '%s' "$action_output" | grep -F '"code":"' >/dev/null 2>&1; then
                        json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" "$exit_code"
                        return 1
                    fi
                    [ -n "$action_output" ] && printf '%s\n' "$action_output" >> "$log_file" 2>&1
                    ;;
            esac
            if [ "$exit_code" -eq 0 ]; then
                render_simple_execute_result_json "$action" "$normalized_subject" "$log_file" "ok" 0
                return 0
            fi
            render_simple_execute_result_json "$action" "$normalized_subject" "$log_file" "failed" "$exit_code"
            return 1
            ;;
        *)
            printf '{"code":"unsupported-execute-action","action":"%s"}\n' "$(json_escape "$action")"
            return 1
            ;;
    esac
}

render_status_json() {
    printf '{'
    printf '"ok":true,'
    printf '"runtimeDir":"%s",' "$(json_escape "$(manager_runtime_dir)")"
    printf '"logDir":"%s",' "$(json_escape "$(manager_log_dir)")"
    printf '"tmpDir":"%s",' "$(json_escape "$(manager_tmp_dir)")"
    printf '"jsonExecuteEnabled":%s' "$([ "${NODE_MANAGER_ALLOW_JSON_EXECUTE:-0}" = "1" ] && printf true || printf false)"
    printf '}\n'
}

render_logs_json() {
    local limit="${1:-20}"

    is_nonnegative_integer "$limit" || limit=20
    ensure_runtime_dirs || return 1
    printf '['
    find "$(manager_log_dir)" -maxdepth 1 -type f -name '*.log*' 2>/dev/null \
        | sort -r \
        | head -n "$limit" \
        | awk -v first=1 '
            {
              gsub(/\\/,"\\\\",$0); gsub(/"/,"\\\"",$0)
              if (!first) printf ","
              printf "\"%s\"", $0
              first=0
            }
        '
    printf ']\n'
}

cleanup_runtime_logs_keep_recent() {
    local keep_count="${1:-100}"
    local log_dir=""
    local log_file=""
    local index=0

    is_nonnegative_integer "$keep_count" || keep_count=100
    ensure_runtime_dirs || return 1
    log_dir="$(manager_log_dir)"
    [ -d "$log_dir" ] || return 0

    while IFS= read -r log_file; do
        [ -n "$log_file" ] || continue
        case "$log_file" in
            "$log_dir"/*.log.*) ;;
            *) continue ;;
        esac
        index=$((index + 1))
        if [ "$index" -gt "$keep_count" ]; then
            rm -f "$log_file" 2>/dev/null || return 1
        fi
    done <<EOF
$(find "$log_dir" -maxdepth 1 -type f -name '*.log.*' -exec ls -t {} + 2>/dev/null || true)
EOF
}

render_logs_cleanup_json() {
    local keep_count="${1:-100}"

    is_nonnegative_integer "$keep_count" || keep_count=100
    if cleanup_runtime_logs_keep_recent "$keep_count"; then
        printf '{"ok":true,"action":"logs-cleanup","kept":%s,"logDir":"%s"}\n' "$keep_count" "$(json_escape "$(manager_log_dir)")"
        return 0
    fi
    printf '{"code":"logs-cleanup-failed"}\n'
    return 1
}

render_package_plan_json() {
    local package_spec="${1:-}"
    local package_name=""
    local installed_version=""
    local target_version=""
    local log_file=""

    if ! validate_package_spec "$package_spec"; then
        printf '{"code":"invalid-package-spec","packageSpec":"%s","allowed":"registry package safe subset: package, @scope/package, package@version, @scope/package@tag"}\n' "$(json_escape "$package_spec")"
        return 1
    fi

    package_name="$(extract_package_name "$package_spec")"
    if ! target_version="$(resolve_install_target_version "$package_spec")"; then
        printf '{"code":"target-version-unavailable","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
        return 1
    fi
    installed_version="$(get_installed_global_package_version "$package_name")"
    log_file_hint="$(create_log_file_hint install "$package_name")"
    local already_installed="false"
    if is_install_spec_satisfied "$package_spec" "$installed_version" "$target_version"; then
        already_installed="true"
    fi

    printf '{'
    printf '"ok":true,'
    printf '"action":"install-global-package",'
    printf '"packageSpec":"%s",' "$(json_escape "$package_spec")"
    printf '"packageName":"%s",' "$(json_escape "$package_name")"
    printf '"targetVersion":"%s",' "$(json_escape "$target_version")"
    printf '"alreadyInstalled":%s,' "$already_installed"
    printf '"installedVersion":"%s",' "$(json_escape "$installed_version")"
    printf '"logFileHint":"%s"' "$(json_escape "$log_file_hint")"
    printf '}\n'
}

render_dry_run_plan() {
    ensure_runtime_dirs || return 1

    cat <<EOF
INFO
runtimeDir=$(manager_runtime_dir)
logDir=$(manager_log_dir)
tmpDir=$(manager_tmp_dir)
configDir=$CONFIG_DIR
behavior=Informational only; use JSON plan/execute/status/logs contracts for app wrappers.
supportedJsonCommands=summary,packages,outdated,config,package-plan,plan,execute,status,logs,logs-cleanup,operation-result
EOF
}

render_test_mode_status() {
    ensure_runtime_dirs || return 1

    cat <<EOF
TEST MODE
runtimeDir=$(manager_runtime_dir)
logDir=$(manager_log_dir)
tmpDir=$(manager_tmp_dir)
platform=$(platform_uname)
EOF
}

# ──────────────────────────────────────────────
# Main entrypoint
# ──────────────────────────────────────────────

main() {
    local choice=""
    local action=""
    local arg="${1:-}"

    case "$arg" in
        --help|-h)
            render_help
            return 0
            ;;
        --version|-v)
            manager_version
            return 0
            ;;
    esac

    ensure_macos || return 1
    if ! ensure_runtime_dirs; then
        print_status_message "fail" "无法创建运行目录: $(manager_runtime_dir)"
        return 1
    fi

    case "$arg" in
        --info|--dry-run)
            DRY_RUN=1 render_dry_run_plan
            return $?
            ;;
        --test-mode)
            TEST_MODE=1 render_test_mode_status
            return $?
            ;;
        --json)
            run_json_command "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}"
            return $?
            ;;
    esac

    if ! run_dependency_preflight; then
        print_status_message "fail" "依赖预检失败，已停止。"
        return 1
    fi

    while true; do
        render_startup_page
        printf "请输入序号(q 退出): "
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
                run_install_menu
                ;;
            uninstall)
                run_uninstall_menu
                ;;
            update)
                run_update_menu
                ;;
            source-management)
                run_source_menu
                ;;
            environment)
                run_environment_menu
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1、2、3、4、5 或 q。"
                pause_before_return
                ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
