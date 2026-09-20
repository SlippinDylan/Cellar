# uninstall_cask_metadata.sh
# Sourced by main.sh; not meant to be executed directly.

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

