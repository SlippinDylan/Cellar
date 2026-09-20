# disk_usage.sh
# Sourced by main.sh; not meant to be executed directly.

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


measure_cleanup_paths_footprint_kib() {
    local summary=""

    summary="$(collect_disk_usage_summary "$@")"
    extract_key_value "$summary" "total_kib"
}

