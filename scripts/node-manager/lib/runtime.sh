# shellcheck shell=bash

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

runtime_lock_owner_pid_start_signature() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 1
    ps -o lstart= -p "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

runtime_lock_owner_pid() {
    local lock_dir="$1"
    local pid=""
    # `sed ... || sed ...` only falls back on a hard failure of the first
    # command; an existing-but-empty pid file exits 0 with no output, which
    # would short-circuit past the metadata fallback. Check the output
    # itself, not just the exit code.
    pid="$(sed -n '1p' "$lock_dir/pid" 2>/dev/null)"
    if [ -z "$pid" ]; then
        pid="$(sed -n 's/^pid=//p' "$lock_dir/metadata" 2>/dev/null | head -1)"
    fi
    printf '%s\n' "$pid"
}

runtime_lock_recorded_pid_start() {
    local lock_dir="$1"
    sed -n 's/^pidStart=//p' "$lock_dir/metadata" 2>/dev/null | head -1
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
            printf 'pidStart=%s\n' "$(runtime_lock_owner_pid_start_signature "$$")"
            printf 'created=%s\n' "$(date +%s)"
            printf 'action=%s\n' "$lock_name"
        } > "$lock_dir/metadata" 2>/dev/null || true
        printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
        add_held_runtime_lock "$lock_name"
        return 0
    fi

    lock_pid="$(runtime_lock_owner_pid "$lock_dir")"
    local lock_is_stale="no"
    if [ -n "$lock_pid" ]; then
        if ! kill -0 "$lock_pid" 2>/dev/null; then
            lock_is_stale="yes"
        else
            # The PID is alive, but PIDs get recycled: if the process
            # currently holding this PID started at a different time than
            # the one recorded when the lock was acquired, the original
            # lock holder is gone and an unrelated process just happens to
            # reuse its PID. Only treat this as positive proof of staleness
            # when both signatures are actually available — an unreadable
            # signature must never be treated as a mismatch, or a live,
            # legitimate lock holder could get its lock yanked out from
            # under it.
            local recorded_start=""
            local current_start=""
            recorded_start="$(runtime_lock_recorded_pid_start "$lock_dir")"
            current_start="$(runtime_lock_owner_pid_start_signature "$lock_pid")"
            if [ -n "$recorded_start" ] && [ -n "$current_start" ] && [ "$recorded_start" != "$current_start" ]; then
                lock_is_stale="yes"
            fi
        fi
    fi

    if [ "$lock_is_stale" = "yes" ]; then
        rm -rf "$lock_dir" 2>/dev/null || return 1
        if mkdir "$lock_dir" 2>/dev/null; then
            {
                printf 'pid=%s\n' "$$"
                printf 'pidStart=%s\n' "$(runtime_lock_owner_pid_start_signature "$$")"
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
