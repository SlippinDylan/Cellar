# uninstall_cask_receipt.sh
# Sourced by main.sh; not meant to be executed directly.

load_cask_app_name_from_receipt() {
    local receipt_path="$1"

    if ! load_cask_receipt_artifacts "$receipt_path"; then
        return 1
    fi

    if [ "${#CASK_RECEIPT_APP_ARTIFACTS[@]}" -eq 0 ]; then
        return 1
    fi

    strip_app_bundle_suffix "${CASK_RECEIPT_APP_ARTIFACTS[0]}"
    return 0
}


reset_cask_receipt_artifact_state() {
    CASK_RECEIPT_APP_ARTIFACTS=()
    CASK_RECEIPT_BINARY_ARTIFACTS=()
    CASK_RECEIPT_MANPAGE_ARTIFACTS=()
    CASK_RECEIPT_PKGUTIL_ARTIFACTS=()
    CASK_RECEIPT_LAUNCHCTL_ARTIFACTS=()
    CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS=()
}


load_cask_receipt_artifacts() {
    local receipt_path="$1"
    local artifact_count="0"
    local artifact_index=0
    local uninstall_count="0"
    local uninstall_index=0
    local value=""

    reset_cask_receipt_artifact_state

    if [ ! -f "$receipt_path" ]; then
        return 1
    fi

    artifact_count="$(plutil_extract_array_count "$receipt_path" "uninstall_artifacts" 2>/dev/null || true)"
    if ! is_nonnegative_integer "$artifact_count"; then
        return 1
    fi

    while [ "$artifact_index" -lt "$artifact_count" ]; do
        while IFS= read -r value; do
            [ -n "$value" ] || continue
            append_unique_to_array CASK_RECEIPT_APP_ARTIFACTS "$value"
        done < <(plutil_extract_string_array_values "$receipt_path" "uninstall_artifacts.$artifact_index.app")

        while IFS= read -r value; do
            [ -n "$value" ] || continue
            append_unique_to_array CASK_RECEIPT_BINARY_ARTIFACTS "$value"
        done < <(plutil_extract_string_array_values "$receipt_path" "uninstall_artifacts.$artifact_index.binary")

        while IFS= read -r value; do
            [ -n "$value" ] || continue
            append_unique_to_array CASK_RECEIPT_MANPAGE_ARTIFACTS "$value"
        done < <(plutil_extract_string_array_values "$receipt_path" "uninstall_artifacts.$artifact_index.manpage")

        uninstall_count="$(plutil_extract_array_count "$receipt_path" "uninstall_artifacts.$artifact_index.uninstall" 2>/dev/null || true)"
        if is_nonnegative_integer "$uninstall_count"; then
            uninstall_index=0
            while [ "$uninstall_index" -lt "$uninstall_count" ]; do
                value="$(plutil_extract_raw_value "$receipt_path" "uninstall_artifacts.$artifact_index.uninstall.$uninstall_index.pkgutil" 2>/dev/null || true)"
                if [ -n "$value" ]; then
                    append_unique_to_array CASK_RECEIPT_PKGUTIL_ARTIFACTS "$value"
                fi

                value="$(plutil_extract_raw_value "$receipt_path" "uninstall_artifacts.$artifact_index.uninstall.$uninstall_index.launchctl" 2>/dev/null || true)"
                if [ -n "$value" ]; then
                    append_unique_to_array CASK_RECEIPT_LAUNCHCTL_ARTIFACTS "$value"
                fi

                value="$(plutil_extract_raw_value "$receipt_path" "uninstall_artifacts.$artifact_index.uninstall.$uninstall_index.early_script.executable" 2>/dev/null || true)"
                if [ -n "$value" ]; then
                    append_unique_to_array CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS "$value"
                fi

                uninstall_index=$((uninstall_index + 1))
            done
        fi

        artifact_index=$((artifact_index + 1))
    done

    return 0
}


serialize_cask_receipt_artifact_state() {
    printf "apps=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_APP_ARTIFACTS[@]+"${CASK_RECEIPT_APP_ARTIFACTS[@]}"}" | join_lines)"
    printf "binaries=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_BINARY_ARTIFACTS[@]+"${CASK_RECEIPT_BINARY_ARTIFACTS[@]}"}" | join_lines)"
    printf "manpages=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]+"${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]}"}" | join_lines)"
    printf "pkgutil=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]+"${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]}"}" | join_lines)"
    printf "launchctl=%s\n" "$(printf "%s\n" "${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]+"${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]}"}" | join_lines)"
    printf "early_scripts=%s" "$(printf "%s\n" "${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]+"${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]}"}" | join_lines)"
}


reset_cask_postcheck_state() {
    CASK_POSTCHECK_RESIDUAL_DELETE_PATHS=()
    CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS=()
    CASK_POSTCHECK_CLEARED_ITEMS=()
    CASK_POSTCHECK_DELEGATED_ITEMS=()
}


reset_cask_uninstall_last_report_state() {
    CASK_UNINSTALL_LAST_CLEARED_ARTIFACTS=()
    CASK_UNINSTALL_LAST_DELETED_PATHS=()
    CASK_UNINSTALL_LAST_ELEVATED_DELETED_PATHS=()
    CASK_UNINSTALL_LAST_PERMISSION_SKIPPED_PATHS=()
    CASK_UNINSTALL_LAST_FAILED_PATHS=()
    CASK_UNINSTALL_LAST_MANUAL_ATTENTION_ITEMS=()
    CASK_UNINSTALL_LAST_DELEGATED_ITEMS=()
}


append_prefixed_items_to_array() {
    local array_name="$1"
    local prefix="$2"
    shift 2
    local item=""

    for item in "$@"; do
        [ -n "$item" ] || continue
        append_to_array "$array_name" "[$prefix] $item"
    done
}


derive_cask_binary_link_path() {
    local homebrew_prefix="$1"
    local source_path="$2"
    local binary_name=""

    [ -n "$homebrew_prefix" ] || return 1
    binary_name="$(basename "$source_path")"
    [ -n "$binary_name" ] || return 1
    printf "%s/bin/%s" "$homebrew_prefix" "$binary_name"
}


derive_cask_manpage_link_path() {
    local homebrew_prefix="$1"
    local source_path="$2"
    local section_dir=""
    local manpage_name=""

    [ -n "$homebrew_prefix" ] || return 1
    section_dir="$(basename "$(dirname "$source_path")")"
    manpage_name="$(basename "$source_path")"
    [ -n "$section_dir" ] || return 1
    [ -n "$manpage_name" ] || return 1
    printf "%s/share/man/%s/%s" "$homebrew_prefix" "$section_dir" "$manpage_name"
}


symlink_points_to_exact_path() {
    local link_path="$1"
    local expected_target="$2"
    local actual_target=""

    [ -L "$link_path" ] || return 1
    actual_target="$(readlink "$link_path" 2>/dev/null || true)"
    [ "$actual_target" = "$expected_target" ]
}


find_launchctl_plist_paths_for_label() {
    local label="$1"
    local candidate=""

    for candidate in \
        "/Library/LaunchDaemons/$label.plist" \
        "/Library/LaunchAgents/$label.plist" \
        "$HOME/Library/LaunchAgents/$label.plist"
    do
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            printf "%s\n" "$candidate"
        fi
    done
}


launchctl_label_exists() {
    local label="$1"
    local current_uid=""

    if ! command_exists launchctl; then
        return 1
    fi

    if launchctl print "system/$label" >/dev/null 2>&1; then
        return 0
    fi

    current_uid="$(id -u 2>/dev/null || true)"
    if is_nonnegative_integer "$current_uid" && launchctl print "gui/$current_uid/$label" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}


pkgutil_receipts_matching_pattern() {
    local pattern="$1"
    local receipt=""

    if ! command_exists pkgutil; then
        return 0
    fi

    while IFS= read -r receipt; do
        [ -n "$receipt" ] || continue
        case "$receipt" in
            $pattern)
                printf "%s\n" "$receipt"
                ;;
        esac
    done < <(pkgutil --pkgs 2>/dev/null || true)
}


build_cask_managed_path_candidates() {
    local homebrew_prefix="$1"
    local app_path="$2"
    local source_path=""
    local derived_path=""

    [ -n "$app_path" ] && printf "%s\n" "$app_path"

    for source_path in "${CASK_RECEIPT_BINARY_ARTIFACTS[@]+"${CASK_RECEIPT_BINARY_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_binary_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        [ -n "$derived_path" ] && printf "%s\n" "$derived_path"
    done

    for source_path in "${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]+"${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_manpage_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        [ -n "$derived_path" ] && printf "%s\n" "$derived_path"
    done
}


build_cask_release_size_preview_paths() {
    local homebrew_prefix="$1"
    local cask="$2"
    local app_path="$3"
    shift 3
    local local_cleanup_candidates=("$@")
    local candidate=""
    local caskroom_entry=""

    {
        if [ -n "$app_path" ] && { [ -e "$app_path" ] || [ -L "$app_path" ]; }; then
            printf "%s\n" "$app_path"
        fi

        if [ -n "$homebrew_prefix" ]; then
            caskroom_entry="$homebrew_prefix/Caskroom/$cask"
            if [ -e "$caskroom_entry" ] || [ -L "$caskroom_entry" ]; then
                printf "%s\n" "$caskroom_entry"
            fi
        fi

        for candidate in "${local_cleanup_candidates[@]+"${local_cleanup_candidates[@]}"}"; do
            [ -n "$candidate" ] || continue
            printf "%s\n" "$candidate"
        done
    } | unique_lines | prune_nested_cask_candidates
}


build_cask_homebrew_managed_artifact_labels() {
    local homebrew_prefix="$1"
    local app_path="$2"
    local app_name="$3"
    local source_path=""
    local derived_path=""
    local label=""

    if [ -n "$app_path" ]; then
        printf "app: %s\n" "$app_path"
    elif [ -n "$app_name" ]; then
        printf "app: %s.app\n" "$app_name"
    fi

    for source_path in "${CASK_RECEIPT_BINARY_ARTIFACTS[@]+"${CASK_RECEIPT_BINARY_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_binary_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        if [ -n "$derived_path" ]; then
            printf "binary: %s\n" "$derived_path"
        fi
    done

    for source_path in "${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]+"${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_manpage_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        if [ -n "$derived_path" ]; then
            printf "manpage: %s\n" "$derived_path"
        fi
    done

    for label in "${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]+"${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]}"}"; do
        printf "launchctl: %s\n" "$label"
    done

    for label in "${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]+"${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]}"}"; do
        printf "pkgutil: %s\n" "$label"
    done

    for label in "${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]+"${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]}"}"; do
        printf "uninstall-script: %s\n" "$label"
    done
}


collect_cask_post_uninstall_artifact_state() {
    local homebrew_prefix="$1"
    local app_path="$2"
    local source_path=""
    local derived_path=""
    local label=""
    local pkg_receipts=""
    local plist_paths=""

    reset_cask_postcheck_state

    if [ -n "$app_path" ]; then
        if [ -e "$app_path" ] || [ -L "$app_path" ]; then
            append_unique_to_array CASK_POSTCHECK_RESIDUAL_DELETE_PATHS "$app_path"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "app: $app_path"
        fi
    fi

    for source_path in "${CASK_RECEIPT_BINARY_ARTIFACTS[@]+"${CASK_RECEIPT_BINARY_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_binary_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        [ -n "$derived_path" ] || continue
        if symlink_points_to_exact_path "$derived_path" "$source_path"; then
            append_unique_to_array CASK_POSTCHECK_RESIDUAL_DELETE_PATHS "$derived_path"
        elif [ -e "$derived_path" ] || [ -L "$derived_path" ]; then
            append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "binary: $derived_path"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "binary: $derived_path"
        fi
    done

    for source_path in "${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]+"${CASK_RECEIPT_MANPAGE_ARTIFACTS[@]}"}"; do
        derived_path="$(derive_cask_manpage_link_path "$homebrew_prefix" "$source_path" 2>/dev/null || true)"
        [ -n "$derived_path" ] || continue
        if symlink_points_to_exact_path "$derived_path" "$source_path"; then
            append_unique_to_array CASK_POSTCHECK_RESIDUAL_DELETE_PATHS "$derived_path"
        elif [ -e "$derived_path" ] || [ -L "$derived_path" ]; then
            append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "manpage: $derived_path"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "manpage: $derived_path"
        fi
    done

    for label in "${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]+"${CASK_RECEIPT_LAUNCHCTL_ARTIFACTS[@]}"}"; do
        plist_paths="$(find_launchctl_plist_paths_for_label "$label" 2>/dev/null || true)"
        if [ -n "$plist_paths" ]; then
            append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "launchctl: $label"
            while IFS= read -r derived_path; do
                [ -n "$derived_path" ] || continue
                append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "launchctl-plist: $derived_path"
            done <<< "$plist_paths"
        elif launchctl_label_exists "$label"; then
            append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "launchctl: $label"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "launchctl: $label"
        fi
    done

    for label in "${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]+"${CASK_RECEIPT_PKGUTIL_ARTIFACTS[@]}"}"; do
        pkg_receipts="$(pkgutil_receipts_matching_pattern "$label" 2>/dev/null || true)"
        if [ -n "$pkg_receipts" ]; then
            while IFS= read -r derived_path; do
                [ -n "$derived_path" ] || continue
                append_unique_to_array CASK_POSTCHECK_MANUAL_ATTENTION_ITEMS "pkgutil: $derived_path"
            done <<< "$pkg_receipts"
        else
            append_unique_to_array CASK_POSTCHECK_CLEARED_ITEMS "pkgutil: $label"
        fi
    done

    for label in "${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]+"${CASK_RECEIPT_EARLY_SCRIPT_ARTIFACTS[@]}"}"; do
        append_unique_to_array CASK_POSTCHECK_DELEGATED_ITEMS "uninstall-script: $label"
    done
}


caskroom_entry_exists() {
    local cask="$1"
    local homebrew_prefix=""
    local caskroom_path=""

    homebrew_prefix="$(brew --prefix 2>/dev/null)" || return 2
    [ -n "$homebrew_prefix" ] || return 2
    caskroom_path="$homebrew_prefix/Caskroom/$cask"

    [ -d "$caskroom_path" ]
}

