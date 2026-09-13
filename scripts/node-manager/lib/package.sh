# shellcheck shell=bash

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

package_spec_is_pinned_version() {
    local package_spec="${1:-}"
    local parsed=""
    local requested=""

    parsed="$(parse_package_spec "$package_spec")" || return 1
    requested="$(printf '%s' "$parsed" | awk -F'|' '{print $2}')"
    [ -n "$requested" ] && requested_package_version_is_exact "$requested"
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

# npm resolves package URLs by joining the registry base against the
# trailing slash, so a missing slash is a real correctness footgun, not
# just a style nit -- but rejecting the extremely common "no trailing
# slash" typed form outright is bad UX. Add it back for otherwise
# http(s)-shaped input before validation, at interactive entry points only.
normalize_registry_url_trailing_slash() {
    local url="${1:-}"
    case "$url" in
        */) printf '%s\n' "$url" ;;
        http://*|https://*) printf '%s/\n' "$url" ;;
        *) printf '%s\n' "$url" ;;
    esac
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

    local scan_exit=0
    row="$(scan_outdated_package_row "$package_name" 2>/dev/null)" || scan_exit=$?
    if [ "$scan_exit" -eq 0 ]; then
        printf 'failed|升级后仍出现在 outdated 列表: %s|%s\n' "$row" "$new_version"
        return 1
    fi

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
