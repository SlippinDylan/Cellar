# plist.sh
# Sourced by main.sh; not meant to be executed directly.

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

