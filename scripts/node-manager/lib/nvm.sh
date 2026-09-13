# shellcheck shell=bash

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
        # Genuinely ambiguous only in this range: the number is both a valid
        # 1-based list index AND could be a short version literal ("20"
        # meaning any installed 20.x). Prefer the literal interpretation
        # whenever it uniquely resolves against the provided version list —
        # this is what callers advertise to the user ("20 / 20.11 仅在唯一
        # 匹配已安装版本时可用"). Without this check, once enough versions
        # happen to be installed that the typed major version also falls
        # inside the valid index range, it would silently resolve to "list
        # item N" instead of "version N.x" with no warning.
        if normalize_node_version "$choice" >/dev/null 2>&1; then
            local -a literal_matches=()
            local candidate=""
            for candidate in "$@"; do
                node_version_satisfies_request "$candidate" "$choice" && literal_matches+=("$candidate")
            done
            if [ "${#literal_matches[@]}" -eq 1 ]; then
                printf '%s\n' "${literal_matches[0]}"
                return 0
            fi
        fi

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
