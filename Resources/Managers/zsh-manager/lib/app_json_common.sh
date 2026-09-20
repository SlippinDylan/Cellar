# shellcheck shell=bash

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    json_escape_control_bytes "$value"
}

json_escape_control_bytes() {
    local value="$1"
    LC_ALL=C printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null || {
        printf '%s' "$value"
        return 0
    }
    local -x LC_ALL=C
    local index=0
    local character=""
    local code=0
    while [ "$index" -lt "${#value}" ]; do
        character="${value:index:1}"
        code="$(printf '%d' "'$character" 2>/dev/null || printf 32)"
        if [ "$code" -ge 0 ] && [ "$code" -lt 32 ]; then
            printf '\\u%04x' "$code"
        else
            printf '%s' "$character"
        fi
        index=$((index + 1))
    done
}

json_string_array_from_lines() {
    local value=""
    local first=1
    printf '['
    while IFS= read -r value; do
        [ -n "$value" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '"%s"' "$(json_escape "$value")"
    done
    printf ']'
}

json_success() {
    printf '{"ok":true,"schemaVersion":1,"command":"%s","data":%s}\n' \
        "$(json_escape "$1")" "${2:-null}"
}

json_failure() {
    local payload="${2:-}"
    [ -n "$payload" ] || payload='{"code":"unknown-error"}'
    printf '{"ok":false,"schemaVersion":1,"command":"%s","error":%s}\n' \
        "$(json_escape "$1")" "$payload"
}

shell_manager_runtime_dir() {
    printf '%s/.runtime' "$SCRIPT_DIR"
}

shell_manager_log_dir() {
    printf '%s/logs' "$(shell_manager_runtime_dir)"
}

create_shell_log() {
    local action="$1"
    local log_dir=""
    log_dir="$(shell_manager_log_dir)"
    mkdir -p "$log_dir" || return 1
    printf '%s/%s-%s-%s.log' "$log_dir" "$action" "$(date '+%Y%m%d%H%M%S')" "$$"
}

validate_simple_name() {
    case "${1:-}" in
        ''|.|..|*/*|*' '*|*$'\t'*|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_plugin_url() {
    [[ "${1:-}" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$ ]] || return 1
    validate_simple_name "$(derive_plugin_name_from_url "$1")"
}

validate_plugin_list() {
    local csv="${1:-}"
    local item=""
    local old_ifs="$IFS"
    IFS=','
    for item in $csv; do
        IFS="$old_ifs"
        validate_simple_name "$item" || return 1
        should_keep_plugin_enabled "$item" || return 1
        IFS=','
    done
    IFS="$old_ifs"
}

config_fingerprint() {
    local action="$1"
    local subject="${2:-}"
    local zshrc_digest="missing"
    local state=""

    if [ -f "$ZSHRC_PATH" ]; then
        zshrc_digest="$(/sbin/md5 -q "$ZSHRC_PATH" 2>/dev/null || printf unreadable)"
    elif [ -e "$ZSHRC_PATH" ]; then
        zshrc_digest="unsupported"
    fi

    case "$action" in
        install-omz) state="$([ -d "$OMZ_DIR" ] && printf installed || printf missing)" ;;
        install-plugin)
            local plugin_name=""
            plugin_name="$(derive_plugin_name_from_url "$subject" 2>/dev/null || true)"
            state="$([ -d "$CUSTOM_PLUGINS_DIR/$plugin_name" ] && printf installed || printf missing)"
            ;;
        set-plugins|switch-theme) state="$zshrc_digest" ;;
        tidy)
            state="$zshrc_digest|$(find "$HOME" -maxdepth 1 -type f \
                \( -name '.zcompdump*' -o -name '.zshrc.backup-*' -o -name '.zshrc.backup.*' -o -name '.zshrc.bak.*' -o -name '.zprofile.bak' \) \
                -print 2>/dev/null | LC_ALL=C sort | /sbin/md5 2>/dev/null || true)"
            ;;
        *) return 1 ;;
    esac
    printf '%s|%s|%s' "$action" "$subject" "$state" | /sbin/md5 -q
}

require_fresh_plan() {
    local expected="$1"
    local actual=""
    actual="$(config_fingerprint "$2" "${3:-}")" || return 1
    [ -n "$expected" ] && [ "$expected" = "$actual" ]
}

operation_result_json() {
    local action="$1"
    local subject="$2"
    local status="$3"
    local exit_code="$4"
    local log_file="$5"
    printf '{"operationId":"%s-%s","action":"%s","subject":"%s","status":"%s","exitCode":%s,"logFile":"%s","backupPath":"%s"}' \
        "$(date '+%Y%m%d%H%M%S')" "$$" "$(json_escape "$action")" "$(json_escape "$subject")" \
        "$(json_escape "$status")" "$exit_code" "$(json_escape "$log_file")" "$(json_escape "${LAST_ZSHRC_BACKUP_PATH:-}")"
}

operation_error_json() {
    local action="$1"
    local subject="$2"
    local exit_code="$3"
    local log_file="$4"
    printf '{"code":"action-failed","operationId":"%s-%s","action":"%s","subject":"%s","status":"failed","exitCode":%s,"logFile":"%s","backupPath":"%s"}' \
        "$(date '+%Y%m%d%H%M%S')" "$$" "$(json_escape "$action")" "$(json_escape "$subject")" \
        "$exit_code" "$(json_escape "$log_file")" "$(json_escape "${LAST_ZSHRC_BACKUP_PATH:-}")"
}
