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
    local cleanup_residue="${NODE_MANAGER_JSON_UNINSTALL_CLEAN_RESIDUE:-0}"
    local cleaned_residues=0
    local failed_residue_cleanups=0
    local cmd=""
    local bin_snapshot=""
    local snapshot=""
    local bin_path=""
    local residue_path=""
    local residue_snapshot=""
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

    installed_version="$(get_installed_global_package_version "$package_name")"
    if [ -z "$installed_version" ]; then
        printf '{"code":"package-not-installed","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
        return 1
    fi

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
    uninstall_global_package "$package_name" "$log_file" || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        if npm_package_is_installed "$package_name"; then
            still_installed="yes"
            status="failed"
            detail="still-installed"
        fi

        if [ "$still_installed" = "no" ]; then
            if [ -d "$install_path" ] && [ -n "$dir_snapshot" ] && directory_snapshot_inode_matches "$dir_snapshot"; then
                residue_dirs+=("$install_path")
                residue_dir_snapshots+=("$dir_snapshot")
            fi
            if [ "${#bin_snapshots[@]}" -gt 0 ]; then
                local snapshot_index=0
                while [ "$snapshot_index" -lt "${#bin_snapshots[@]}" ]; do
                    snapshot="${bin_snapshots[$snapshot_index]}"
                    if verify_symlink_snapshot_current "$snapshot"; then
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

    if [ "$cleanup_residue" = "1" ] && { [ "${#residue_dirs[@]}" -gt 0 ] || [ "${#residue_bins[@]}" -gt 0 ]; }; then
        local residue_index=0
        while [ "$residue_index" -lt "${#residue_dirs[@]}" ]; do
            residue_path="${residue_dirs[$residue_index]}"
            residue_snapshot="${residue_dir_snapshots[$residue_index]:-}"
            if verify_directory_snapshot_current "$residue_snapshot" && rm -rf "$residue_path" 2>/dev/null && [ ! -d "$residue_path" ]; then
                cleaned_residues=$((cleaned_residues + 1))
            else
                failed_residue_cleanups=$((failed_residue_cleanups + 1))
            fi
            residue_index=$((residue_index + 1))
        done

        residue_index=0
        while [ "$residue_index" -lt "${#residue_bins[@]}" ]; do
            residue_path="${residue_bins[$residue_index]}"
            residue_snapshot="${residue_bin_snapshots[$residue_index]:-}"
            if remove_snapshot_symlink_residue "$residue_snapshot" && [ ! -e "$residue_path" ] && [ ! -L "$residue_path" ]; then
                cleaned_residues=$((cleaned_residues + 1))
            else
                failed_residue_cleanups=$((failed_residue_cleanups + 1))
            fi
            residue_index=$((residue_index + 1))
        done
    fi

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
    printf '"residueCleanupPerformed":%s,' "$([ "$cleanup_residue" = "1" ] && printf true || printf false)"
    printf '"cleanedResidues":%s,' "$cleaned_residues"
    printf '"failedResidueCleanups":%s,' "$failed_residue_cleanups"
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

    version="$(normalize_node_concrete_version "$version")" || {
        print_invalid_node_version_for_action_json "node-uninstall" "$1"
        return 1
    }
    load_nvm_into_current_shell || {
        printf '{"code":"nvm-unavailable","action":"node-uninstall"}\n'
        return 1
    }
    current_version="$(nvm current 2>/dev/null || true)"
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
    if ! acquire_runtime_lock "nvm-mutation"; then
        printf '{"code":"mutation-locked","action":"node-uninstall","lock":"nvm-mutation"}\n'
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
    switch_node_version "$version" "$log_file"
}

execute_node_install_json_action() {
    local requested="$1"
    local log_file="$2"
    local install_target=""
    local actual_version=""
    local install_exit=0
    local use_exit=0

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
    release_runtime_lock "nvm-mutation"
    if [ "$use_exit" -ne 0 ]; then
        printf '{"code":"node-use-after-install-failed","action":"node-install","version":"%s","exitCode":%s}\n' "$(json_escape "$install_target")" "$use_exit"
        return 1
    fi

    actual_version="$(node -v 2>>"$log_file" || nvm current 2>>"$log_file" || true)"
    case "$install_target" in
        --lts*)
            if [ -n "$actual_version" ] && [[ "$actual_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                return 0
            fi
            ;;
        *)
            if node_version_satisfies_request "$actual_version" "$install_target"; then
                return 0
            fi
            ;;
    esac

    printf '{"code":"node-install-verification-failed","action":"node-install","version":"%s","actualVersion":"%s"}\n' \
        "$(json_escape "$install_target")" "$(json_escape "$actual_version")"
    return 1
}

execute_cleanup_json_action() {
    local target="$1"
    local log_file="$2"
    local path=""
    local resolved_path=""
    local global_bin=""
    local orphan=""
    local removed=0

    validate_cleanup_target "$target" || return 2
    case "$target" in
        npm-cache-verify)
            npm cache verify >> "$log_file" 2>&1
            ;;
        npm-cache-clean)
            run_logged_command "$log_file" npm cache clean --force || return 1
            npm cache verify >> "$log_file" 2>&1
            ;;
        logs)
            cleanup_runtime_logs_keep_recent 100 >> "$log_file" 2>&1
            ;;
        node-gyp-cache)
            while IFS='|' read -r path _; do
                [ -n "$path" ] || continue
                [ -d "$path" ] || continue
                resolved_path="$(resolve_safe_user_cache_delete_path "$path" 2>/dev/null || true)"
                [ -n "$resolved_path" ] || return 1
                rm -rf "$resolved_path" >> "$log_file" 2>&1 || return 1
                removed=$((removed + 1))
            done <<< "$(detect_node_gyp_cache_dirs)"
            printf 'removed=%s\n' "$removed" >> "$log_file" 2>&1
            ;;
        orphan-bins)
            global_bin="$(get_global_bin_dir)" || return 1
            [ -d "$global_bin" ] || return 0
            while IFS= read -r orphan; do
                [ -n "$orphan" ] || continue
                if [ -L "$orphan" ] && [ ! -e "$orphan" ]; then
                    rm -f "$orphan" >> "$log_file" 2>&1 || return 1
                    removed=$((removed + 1))
                fi
            done < <(find "$global_bin" -maxdepth 1 -type l 2>/dev/null)
            printf 'removed=%s\n' "$removed" >> "$log_file" 2>&1
            ;;
        nvm-old-versions)
            run_nvm_old_versions_cleanup_json "$log_file"
            ;;
    esac
}

run_nvm_old_versions_cleanup_json() {
    local log_file="$1"
    local current_ver=""
    local default_info=""
    local default_ver=""
    local default_status=""
    local ver=""
    local vdir=""
    local pkg_count=""
    local removed=0

    load_nvm_into_current_shell || return 1
    current_ver="$(nvm current 2>/dev/null || true)"
    default_info="$(get_nvm_default_info)"
    default_ver="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"
    [ "$default_status" = "resolved" ] || return 1

    while IFS= read -r ver; do
        [ -n "$ver" ] || continue
        [ "$ver" != "$current_ver" ] || continue
        [ "$ver" != "$default_ver" ] || continue
        vdir="$(nvm_version_dir "$ver")"
        pkg_count="$(nvm_version_user_package_count "$vdir" 2>/dev/null)" || continue
        [ "$pkg_count" -eq 0 ] 2>/dev/null || continue
        if ! acquire_runtime_lock "nvm-mutation"; then
            return 1
        fi
        nvm uninstall "$ver" >> "$log_file" 2>&1
        local uninstall_exit=$?
        release_runtime_lock "nvm-mutation"
        [ "$uninstall_exit" -eq 0 ] || return 1
        [ ! -d "$vdir" ] || return 1
        removed=$((removed + 1))
    done <<< "$(get_installed_node_versions)"
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
            if ! target_version="$(resolve_install_target_version "$package_spec")"; then
                printf '{"code":"target-version-unavailable","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
                return 1
            fi
            operation_id="$(create_operation_id "install-$package_name")"
            log_file="$(create_log_file install "$package_name")" || return 1
            install_global_package "$package_spec" "$log_file" || exit_code=$?
            installed_version="$(get_installed_global_package_version "$package_name")"
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
            latest_version="$(get_registry_latest_version "$subject" || true)"
            if [ -z "$latest_version" ]; then
                printf '{"code":"latest-version-unavailable","packageName":"%s"}\n' "$(json_escape "$subject")"
                return 1
            fi
            operation_id="$(create_operation_id "update-latest-$subject")"
            log_file="$(create_log_file update-latest "$subject")" || return 1
            upgrade_global_package_to_latest "$subject" "$log_file" || exit_code=$?
            installed_version="$(get_installed_global_package_version "$subject")"
            if [ "$exit_code" -eq 0 ] && [ "$installed_version" = "$latest_version" ]; then
                render_operation_result_json "$operation_id" "$action" "$subject" "$exit_code" "ok" "$log_file"
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
        nvm-install|node-install|node-use|node-uninstall|cleanup|project-nvmrc)
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
                    if nvm_install_unverified_blocked; then
                        action_output="$(render_nvm_install_unverified_blocked_json "$normalized_subject")"
                        json_print_business_error_with_operation "$action_output" "$action" "$normalized_subject" "$log_file" 1
                        return 1
                    fi
                    install_nvm_official >> "$log_file" 2>&1
                    exit_code=$?
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
                    execute_cleanup_json_action "$subject" "$log_file"
                    exit_code=$?
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
