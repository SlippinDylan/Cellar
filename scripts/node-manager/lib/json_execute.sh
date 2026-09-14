# shellcheck shell=bash

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
    local install_state=""
    local install_state_exit=0
    local cmd=""
    local bin_snapshot=""
    local snapshot=""
    local bin_path=""
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

    install_state="$(query_global_package_install_state "$package_name")" || install_state_exit=$?
    case "$install_state_exit" in
        0) installed_version="${install_state#*|}" ;;
        1)
            printf '{"code":"package-not-installed","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
            return 1
            ;;
        *)
            printf '{"code":"package-state-unavailable","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
            return 1
            ;;
    esac

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
    if ! acquire_runtime_lock "npm-mutation"; then
        printf '{"code":"mutation-locked","action":"uninstall","lock":"npm-mutation"}\n'
        return 1
    fi
    uninstall_global_package "$package_name" "$log_file" || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        install_state_exit=0
        install_state="$(query_global_package_install_state "$package_name")" || install_state_exit=$?
        case "$install_state_exit" in
            0)
                still_installed="yes"
                status="failed"
                detail="still-installed"
                ;;
            1)
                still_installed="no"
                ;;
            *)
                still_installed="unknown"
                status="failed"
                detail="post-uninstall-state-unavailable"
                ;;
        esac

        if [ "$still_installed" = "no" ]; then
            if [ -d "$install_path" ] && [ -n "$dir_snapshot" ]; then
                local refreshed_dir_snapshot=""
                refreshed_dir_snapshot="$(refresh_directory_snapshot_if_same_inode "$dir_snapshot" 2>/dev/null || true)"
                if [ -n "$refreshed_dir_snapshot" ]; then
                    residue_dirs+=("$install_path")
                    residue_dir_snapshots+=("$refreshed_dir_snapshot")
                fi
            fi
            if [ "${#bin_snapshots[@]}" -gt 0 ]; then
                local snapshot_index=0
                while [ "$snapshot_index" -lt "${#bin_snapshots[@]}" ]; do
                    snapshot="${bin_snapshots[$snapshot_index]}"
                    if verify_broken_symlink_snapshot_current "$snapshot"; then
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

    release_runtime_lock "npm-mutation"

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
    printf '"residueCleanupPerformed":false,'
    printf '"cleanedResidues":0,'
    printf '"failedResidueCleanups":0,'
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
    local package_snapshot=""

    version="$(normalize_node_concrete_version "$version")" || {
        print_invalid_node_version_for_action_json "node-uninstall" "$1"
        return 1
    }
    load_nvm_into_current_shell || {
        printf '{"code":"nvm-unavailable","action":"node-uninstall"}\n'
        return 1
    }
    current_version="$(read_nvm_current_state)" || {
        printf '{"code":"current-node-unavailable","action":"node-uninstall","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    }
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
    package_snapshot="$(nvm_version_package_summary "$version_dir" 2>/dev/null)" || {
        printf '{"code":"node-package-inventory-unavailable","action":"node-uninstall","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    }
    if ! acquire_runtime_lock "nvm-mutation"; then
        printf '{"code":"mutation-locked","action":"node-uninstall","lock":"nvm-mutation"}\n'
        return 1
    fi
    current_version="$(read_nvm_current_state 2>/dev/null || true)"
    default_info="$(get_nvm_default_info)"
    default_version="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"
    local locked_package_snapshot=""
    locked_package_snapshot="$(nvm_version_package_summary "$version_dir" 2>/dev/null || true)"
    if [ -z "$current_version" ] || [ ! -d "$version_dir" ] || [ "$default_status" != "resolved" ] || \
        [ "$version" = "$current_version" ] || [ "$version" = "$default_version" ] || \
        [ -z "$locked_package_snapshot" ] || [ "$locked_package_snapshot" != "$package_snapshot" ]; then
        release_runtime_lock "nvm-mutation"
        printf '{"code":"node-uninstall-state-changed","action":"node-uninstall","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    fi
    nvm uninstall "$version"
    local uninstall_exit=$?
    release_runtime_lock "nvm-mutation"
    [ "$uninstall_exit" -eq 0 ] && [ ! -d "$version_dir" ]
}

execute_node_use_json_action() {
    local version="$1"
    local log_file="${2:-}"
    local installed_versions=""
    local actual_version=""

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
    switch_node_version "$version" "$log_file" || return 1
    actual_version="$(node -v 2>/dev/null || true)"
    if ! node_version_matches "$actual_version" "$version"; then
        printf '{"code":"node-use-verification-failed","action":"node-use","version":"%s","actualVersion":"%s"}\n' \
            "$(json_escape "$version")" "$(json_escape "$actual_version")"
        return 1
    fi
}

execute_node_default_json_action() {
    local version="$1"
    local log_file="${2:-}"
    local installed_versions=""
    local default_info=""
    local default_version=""
    local default_status=""

    version="$(normalize_node_concrete_version "$version")" || {
        print_invalid_node_version_for_action_json "node-default" "$1"
        return 1
    }
    load_nvm_into_current_shell || {
        printf '{"code":"nvm-unavailable","action":"node-default","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    }
    installed_versions="$(get_installed_node_versions 2>/dev/null || true)"
    if ! installed_node_versions_satisfy_request "$version" "$installed_versions"; then
        printf '{"code":"node-version-not-installed","action":"node-default","version":"%s"}\n' "$(json_escape "$version")"
        return 1
    fi
    set_node_default_alias "$version" "$log_file" || return 1
    default_info="$(get_nvm_default_info)"
    default_version="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"
    if [ "$default_status" != "resolved" ] || [ "$default_version" != "$version" ]; then
        printf '{"code":"node-default-verification-failed","action":"node-default","version":"%s","actualVersion":"%s"}\n' \
            "$(json_escape "$version")" "$(json_escape "$default_version")"
        return 1
    fi
}

execute_node_install_json_action() {
    local requested="$1"
    local log_file="$2"
    local install_target=""
    local actual_version=""
    local expected_lts_version=""
    local install_exit=0
    local use_exit=0
    local verified="no"

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
    if [ "$use_exit" -ne 0 ]; then
        release_runtime_lock "nvm-mutation"
        printf '{"code":"node-use-after-install-failed","action":"node-install","version":"%s","exitCode":%s}\n' "$(json_escape "$install_target")" "$use_exit"
        return 1
    fi

    actual_version="$(node -v 2>>"$log_file" || nvm current 2>>"$log_file" || true)"
    case "$install_target" in
        --lts*)
            expected_lts_version="$(resolve_installed_lts_target_version "$install_target" 2>>"$log_file" || true)"
            if [ -n "$expected_lts_version" ] && node_version_matches "$actual_version" "$expected_lts_version"; then
                verified="yes"
            fi
            ;;
        *)
            if node_version_satisfies_request "$actual_version" "$install_target"; then
                verified="yes"
            fi
            ;;
    esac
    release_runtime_lock "nvm-mutation"
    [ "$verified" = "yes" ] && return 0

    printf '{"code":"node-install-verification-failed","action":"node-install","version":"%s","actualVersion":"%s"}\n' \
        "$(json_escape "$install_target")" "$(json_escape "$actual_version")"
    return 1
}

execute_cleanup_json_action() {
    local target="$1"
    local log_file="$2"
    local expected_plan_token="${3:-}"
    local lock_name=""
    local plan_material=""
    local current_plan_token=""
    local record=""
    local snapshot=""
    local path=""
    local removed=0
    local action_exit=0

    validate_cleanup_target "$target" || return 2
    case "$target" in
        npm-cache-verify)
            npm cache verify >> "$log_file" 2>&1
            return $?
            ;;
        logs)
            cleanup_runtime_logs_keep_recent 100 >> "$log_file" 2>&1
            return $?
            ;;
        npm-cache-clean|node-gyp-cache|orphan-bins) lock_name="npm-mutation" ;;
        nvm-old-versions)
            load_nvm_into_current_shell >/dev/null 2>&1 || return 4
            lock_name="nvm-mutation"
            ;;
    esac

    acquire_runtime_lock "$lock_name" || return 1
    plan_material="$(cleanup_plan_fingerprint_material "$target" 2>/dev/null)" || {
        release_runtime_lock "$lock_name"
        return 4
    }
    if [ -n "$expected_plan_token" ]; then
        current_plan_token="$(cleanup_plan_token_from_material "$plan_material" 2>/dev/null)" || {
            release_runtime_lock "$lock_name"
            return 4
        }
        if [ "$current_plan_token" != "$expected_plan_token" ]; then
            release_runtime_lock "$lock_name"
            return 3
        fi
    fi

    case "$target" in
        npm-cache-clean)
            run_logged_command "$log_file" npm cache clean --force || action_exit=$?
            if [ "$action_exit" -eq 0 ]; then
                npm cache verify >> "$log_file" 2>&1 || action_exit=$?
            fi
            ;;
        node-gyp-cache)
            while IFS= read -r record; do
                case "$record" in
                    node-gyp\|*) ;;
                    *) continue ;;
                esac
                snapshot="${record#node-gyp|}"
                path="${snapshot%%|*}"
                if ! verify_directory_snapshot_current "$snapshot" || \
                    ! rm -rf "$path" >> "$log_file" 2>&1 || [ -d "$path" ]; then
                    action_exit=1
                    break
                fi
                removed=$((removed + 1))
            done <<< "$plan_material"
            ;;
        orphan-bins)
            while IFS= read -r record; do
                case "$record" in
                    orphan\|*) ;;
                    *) continue ;;
                esac
                snapshot="${record#orphan|}"
                if ! remove_orphan_symlink_snapshot "$snapshot" >> "$log_file" 2>&1; then
                    action_exit=1
                    break
                fi
                removed=$((removed + 1))
            done <<< "$plan_material"
            ;;
        nvm-old-versions)
            run_nvm_old_versions_cleanup_json "$log_file" "$plan_material" || action_exit=$?
            ;;
    esac

    release_runtime_lock "$lock_name"
    if [ "$target" != "npm-cache-clean" ] && [ "$target" != "nvm-old-versions" ]; then
        printf 'removed=%s\n' "$removed" >> "$log_file" 2>&1
    fi
    return "$action_exit"
}

run_nvm_old_versions_cleanup_json() {
    local log_file="$1"
    local plan_material="$2"
    local planned_paths=""
    local path=""
    local ver=""
    local vdir=""
    local removed=0

    planned_paths="$(cleanup_plan_paths_from_material nvm-old-versions "$plan_material")" || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        ver="${path##*/}"
        vdir="$(nvm_version_dir "$ver")"
        [ "$vdir" = "$path" ] || return 1
        nvm_version_is_safe_cleanup_candidate "$ver" || continue
        nvm uninstall "$ver" >> "$log_file" 2>&1
        local uninstall_exit=$?
        if [ "$uninstall_exit" -ne 0 ] || [ -d "$vdir" ]; then
            return 1
        fi
        removed=$((removed + 1))
    done <<< "$planned_paths"
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
    capture_project_nvmrc_snapshot "$nvmrc" >/dev/null 2>&1 || {
        printf '{"code":"project-nvmrc-not-regular-file","action":"project-nvmrc","path":"%s"}\n' "$(json_escape "$nvmrc")"
        return 1
    }
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
    local install_state=""
    local install_state_exit=0

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
            install_state="$(query_global_package_install_state "$package_name")" || install_state_exit=$?
            if [ "$install_state_exit" -eq 2 ]; then
                printf '{"code":"package-state-unavailable","action":"install","packageName":"%s"}\n' "$(json_escape "$package_name")"
                return 1
            fi
            if ! target_version="$(resolve_install_target_version "$package_spec")"; then
                printf '{"code":"target-version-unavailable","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
                return 1
            fi
            operation_id="$(create_operation_id "install-$package_name")"
            log_file="$(create_log_file install "$package_name")" || return 1
            install_global_package "$package_spec" "$log_file" || exit_code=$?
            install_state_exit=0
            install_state="$(query_global_package_install_state "$package_name")" || install_state_exit=$?
            if [ "$exit_code" -eq 0 ] && [ "$install_state_exit" -eq 2 ]; then
                json_print_business_error_with_operation \
                    "$(printf '{\"code\":\"post-install-state-unavailable\",\"packageName\":\"%s\"}' "$(json_escape "$package_name")")" \
                    "$action" "$package_name" "$log_file" 1
                return 1
            fi
            if [ "$install_state_exit" -eq 0 ]; then
                installed_version="${install_state#*|}"
            else
                installed_version=""
            fi
            local verify_result=""
            local verify_status=""
            if package_spec_is_pinned_version "$package_spec"; then
                verify_result="$(verify_install_result_for_spec "$package_spec" "$installed_version" "$target_version" || true)"
            else
                verify_result="$(verify_install_result_for_spec "$package_spec" "$installed_version" || true)"
            fi
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
            install_state_exit=0
            install_state="$(query_global_package_install_state "$subject")" || install_state_exit=$?
            case "$install_state_exit" in
                0) installed_version="${install_state#*|}" ;;
                1)
                    printf '{"code":"package-not-installed","action":"update-latest","packageName":"%s"}\n' "$(json_escape "$subject")"
                    return 1
                    ;;
                *)
                    printf '{"code":"package-state-unavailable","action":"update-latest","packageName":"%s"}\n' "$(json_escape "$subject")"
                    return 1
                    ;;
            esac
            latest_version="$(get_registry_latest_version "$subject" || true)"
            if [ -z "$latest_version" ]; then
                printf '{"code":"latest-version-unavailable","packageName":"%s"}\n' "$(json_escape "$subject")"
                return 1
            fi
            operation_id="$(create_operation_id "update-latest-$subject")"
            log_file="$(create_log_file update-latest "$subject")" || return 1
            local upgrade_result=""
            local upgrade_status=""
            local upgrade_detail=""
            upgrade_result="$(upgrade_global_package_to_latest_verified "$subject" "$installed_version" "$log_file")" || exit_code=$?
            IFS='|' read -r upgrade_status upgrade_detail installed_version latest_version <<< "$upgrade_result"
            printf 'verification=%s detail=%s installed=%s latest=%s\n' "$upgrade_status" "$upgrade_detail" "$installed_version" "$latest_version" >> "$log_file"
            if [ "$exit_code" -eq 0 ] && { [ "$upgrade_status" = "ok" ] || [ "$upgrade_status" = "warn" ]; }; then
                render_operation_result_json "$operation_id" "$action" "$subject" "$exit_code" "$upgrade_status" "$log_file"
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
        nvm-install|node-install|node-use|node-default|node-uninstall|cleanup|project-nvmrc)
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
                    local safe_nvm_dir=""
                    safe_nvm_dir="$(resolve_safe_nvm_install_dir "${NVM_DIR:-$(detect_nvm_dir)}")" || {
                        action_output="$(printf '{"code":"unsafe-nvm-install-dir","action":"nvm-install","path":"%s"}' "$(json_escape "${NVM_DIR:-$(detect_nvm_dir)}")")"
                        json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" 1
                        return 1
                    }
                    export NVM_DIR="$safe_nvm_dir"
                    if [ -s "$NVM_DIR/nvm.sh" ]; then
                        local installed_nvm_version=""
                        installed_nvm_version="$(nvm_installation_version 2>>"$log_file" || true)"
                        if [ "$installed_nvm_version" = "${NVM_INSTALL_VERSION#v}" ]; then
                            exit_code=0
                        elif [ -n "$installed_nvm_version" ]; then
                            action_output="$(printf '{"code":"nvm-version-mismatch","action":"nvm-install","requestedVersion":"%s","installedVersion":"%s"}' "$(json_escape "$NVM_INSTALL_VERSION")" "$(json_escape "$installed_nvm_version")")"
                            json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" 1
                            return 1
                        else
                            printf 'existing nvm installation is not usable\n' >> "$log_file"
                            exit_code=1
                        fi
                    else
                        if nvm_install_unverified_blocked; then
                            action_output="$(render_nvm_install_unverified_blocked_json "$normalized_subject")"
                            json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" 1
                            return 1
                        fi
                        install_nvm_official >> "$log_file" 2>&1
                        exit_code=$?
                        if [ "$exit_code" -eq 0 ]; then
                            installed_nvm_version="$(nvm_installation_version 2>>"$log_file" || true)"
                            [ "$installed_nvm_version" = "${NVM_INSTALL_VERSION#v}" ] || exit_code=1
                        fi
                    fi
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
                    # shellcheck disable=SC2094 # both writers append-only (O_APPEND); no read/write race
                    action_output="$(execute_node_use_json_action "$subject" "$log_file" 2>>"$log_file")" || exit_code=$?
                    if [ "$exit_code" -ne 0 ] && printf '%s' "$action_output" | grep -F '"code":"' >/dev/null 2>&1; then
                        json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" "$exit_code"
                        return 1
                    fi
                    [ -n "$action_output" ] && printf '%s\n' "$action_output" >> "$log_file" 2>&1
                    ;;
                node-default)
                    # shellcheck disable=SC2094 # both writers append-only (O_APPEND); no read/write race
                    action_output="$(execute_node_default_json_action "$subject" "$log_file" 2>>"$log_file")" || exit_code=$?
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
                        action_output="$(printf '{"code":"invalid-cleanup-target","action":"cleanup","target":"%s"}' "$(json_escape "$subject")")"
                        json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" 1
                        return 1
                    }
                    execute_cleanup_json_action "$subject" "$log_file" "$extra" || exit_code=$?
                    if [ "$exit_code" -eq 3 ] || [ "$exit_code" -eq 4 ]; then
                        local cleanup_error_code="plan-stale"
                        [ "$exit_code" -eq 4 ] && cleanup_error_code="cleanup-plan-unavailable"
                        action_output="$(printf '{"code":"%s","action":"cleanup","target":"%s"}' "$cleanup_error_code" "$(json_escape "$subject")")"
                        json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" 1
                        return 1
                    fi
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
