# shellcheck shell=bash

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

    if is_arithmetic_safe_digit_string "$choice" && [ "$choice" -ge 1 ] && [ "$choice" -le "$max_index" ]; then
        strip_leading_zeros "$choice"
        printf '\n'
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
            if ! is_arithmetic_safe_digit_string "$range_start" || ! is_arithmetic_safe_digit_string "$range_end"; then
                if [ "$noglob_was_set" != "1" ]; then
                    set +f
                fi
                echo "invalid"
                return 0
            fi
            range_start="$(strip_leading_zeros "$range_start")"
            range_end="$(strip_leading_zeros "$range_end")"
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

        if ! is_arithmetic_safe_digit_string "$token" || [ "$token" -lt 1 ] || [ "$token" -gt "$max_index" ]; then
            if [ "$noglob_was_set" != "1" ]; then
                set +f
            fi
            echo "invalid"
            return 0
        fi

        token="$(strip_leading_zeros "$token")"
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
