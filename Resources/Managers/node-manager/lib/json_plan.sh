# shellcheck shell=bash

cleanup_plan_fingerprint_material() {
    local target="$1"
    local cache_path=""
    local candidate_path=""
    local candidate_snapshot=""
    local global_bin=""
    local current_version=""
    local default_info=""
    local installed_versions=""
    local node_path=""
    local version=""
    local version_dir=""
    local package_summary=""

    case "$target" in
        npm-cache-clean)
            cache_path="$(npm config get cache 2>/dev/null)" || return 1
            case "$cache_path" in
                ""|undefined|null) return 1 ;;
            esac
            printf 'cache|%s\n' "$cache_path"
            ;;
        node-gyp-cache)
            while IFS='|' read -r candidate_path _; do
                [ -d "$candidate_path" ] || continue
                candidate_path="$(resolve_safe_user_cache_delete_path "$candidate_path" 2>/dev/null)" || return 1
                candidate_snapshot="$(capture_directory_snapshot "$candidate_path" "$(dirname "$candidate_path")" 2>/dev/null)" || return 1
                printf 'node-gyp|%s\n' "$candidate_snapshot"
            done <<< "$(detect_node_gyp_cache_dirs)"
            ;;
        orphan-bins)
            global_bin="$(get_global_bin_dir 2>/dev/null)" || return 1
            [ -n "$global_bin" ] || return 1
            printf 'global-bin|%s\n' "$global_bin"
            if [ -d "$global_bin" ]; then
                [ -r "$global_bin" ] && [ -x "$global_bin" ] || return 1
                while IFS= read -r candidate_path; do
                    [ -n "$candidate_path" ] || continue
                    [ ! -e "$candidate_path" ] || continue
                    candidate_snapshot="$(capture_orphan_symlink_snapshot "$candidate_path" 2>/dev/null)" || return 1
                    printf 'orphan|%s\n' "$candidate_snapshot"
                done < <(find "$global_bin" -maxdepth 1 -type l 2>/dev/null)
            fi
            ;;
        nvm-old-versions)
            node_path="$(command -v node 2>/dev/null || true)"
            if [ -n "$node_path" ] && is_node_path_nvm_managed "$node_path"; then
                current_version="$(node -v 2>/dev/null)" || return 1
                current_version="$(normalize_node_concrete_version "$current_version")" || return 1
            elif [ -n "$node_path" ]; then
                current_version="system"
            else
                current_version="none"
            fi
            default_info="$(read_nvm_default_alias_file_info)" || return 1
            installed_versions="$(scan_installed_node_versions_from_dirs)" || return 1
            printf 'current|%s\n' "$current_version"
            printf 'default|%s\n' "$default_info"
            while IFS= read -r version; do
                [ -n "$version" ] || continue
                version_dir="$(nvm_version_dir "$version")"
                package_summary="$(nvm_version_package_summary "$version_dir" 2>/dev/null)" || return 1
                printf 'version|%s|%s|%s\n' "$version" "$version_dir" "$package_summary"
            done <<< "$installed_versions"
            ;;
        *)
            return 1
            ;;
    esac
}

cleanup_plan_token_from_material() {
    local material="$1"

    command_exists shasum || return 1
    printf '%s\n' "$material" | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}

cleanup_plan_paths_from_material() {
    local target="$1"
    local material="$2"
    local record=""
    local snapshot=""
    local current_version=""
    local default_version=""
    local version=""
    local version_dir=""
    local user_field=""
    local user_count=""

    case "$target" in
        npm-cache-clean)
            printf '%s\n' "${material#cache|}"
            ;;
        node-gyp-cache)
            while IFS= read -r record; do
                case "$record" in
                    node-gyp\|*)
                        snapshot="${record#node-gyp|}"
                        printf '%s\n' "${snapshot%%|*}"
                        ;;
                esac
            done <<< "$material"
            ;;
        orphan-bins)
            while IFS= read -r record; do
                case "$record" in
                    orphan\|*)
                        snapshot="${record#orphan|}"
                        printf '%s\n' "${snapshot%%|*}"
                        ;;
                esac
            done <<< "$material"
            ;;
        nvm-old-versions)
            current_version="$(printf '%s\n' "$material" | sed -n 's/^current|//p' | head -1)"
            default_version="$(printf '%s\n' "$material" | sed -n 's/^default|[^|]*|\([^|]*\)|.*$/\1/p' | head -1)"
            while IFS= read -r record; do
                case "$record" in
                    version\|*)
                        IFS='|' read -r _ version version_dir user_field _ <<< "$record"
                        user_count="${user_field#user=}"
                        if [ "$user_count" = "0" ] && [ "$version" != "$current_version" ] && [ "$version" != "$default_version" ]; then
                            printf '%s\n' "$version_dir"
                        fi
                        ;;
                esac
            done <<< "$material"
            ;;
        *) return 1 ;;
    esac
}

render_non_package_action_plan_json() {
    local action="$1"
    local subject="${2:-}"
    local extra="${3:-}"
    local target_type=""
    local requires_confirmation="true"
    local execute_supported="true"
    local external_write="false"
    local plan_token=""
    local cleanup_plan_material=""

    case "$action" in
        registry-set)
            validate_registry_url "$subject" || {
                printf '{"code":"invalid-registry-url","action":"registry-set","registry":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            target_type="npm-registry"
            ;;
        registry-delete)
            target_type="npm-registry"
            subject="registry"
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
            target_type="npm-scope-registry"
            ;;
        scope-registry-delete)
            validate_scope_name "$subject" || {
                printf '{"code":"invalid-scope-name","action":"scope-registry-delete","scope":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            target_type="npm-scope-registry"
            ;;
        nvm-install)
            local nvm_install_request_json=""
            local safe_nvm_dir=""
            nvm_install_request_json="$(resolve_nvm_install_request_json "$subject")" || {
                printf '%s\n' "$nvm_install_request_json"
                return 1
            }
            safe_nvm_dir="$(resolve_safe_nvm_install_dir "$(detect_nvm_dir)")" || {
                printf '{"code":"unsafe-nvm-install-dir","action":"nvm-install","path":"%s"}\n' "$(json_escape "$(detect_nvm_dir)")"
                return 1
            }
            target_type="nvm"
            subject="${subject:-$NVM_INSTALL_VERSION}"
            ;;
        node-install)
            validate_node_install_target "$subject" || {
                print_invalid_node_version_for_action_json "$action" "$subject"
                return 1
            }
            target_type="node-version"
            ;;
        node-use|node-default|node-uninstall)
            validate_node_concrete_action_version "$subject" || {
                print_invalid_node_version_for_action_json "$action" "$subject"
                return 1
            }
            target_type="node-version"
            ;;
        cleanup)
            validate_cleanup_target "$subject" || {
                printf '{"code":"invalid-cleanup-target","action":"cleanup","target":"%s"}\n' "$(json_escape "$subject")"
                return 1
            }
            target_type="cleanup"
            [ "$subject" = "npm-cache-verify" ] && requires_confirmation="false"
            case "$subject" in
                npm-cache-clean|node-gyp-cache|orphan-bins|nvm-old-versions)
                    cleanup_plan_material="$(cleanup_plan_fingerprint_material "$subject" 2>/dev/null)" || {
                        printf '{"code":"cleanup-plan-unavailable","action":"cleanup","target":"%s"}\n' "$(json_escape "$subject")"
                        return 1
                    }
                    plan_token="$(cleanup_plan_token_from_material "$cleanup_plan_material" 2>/dev/null)" || {
                        printf '{"code":"cleanup-plan-unavailable","action":"cleanup","target":"%s"}\n' "$(json_escape "$subject")"
                        return 1
                    }
                    ;;
            esac
            ;;
        project-nvmrc)
            [ -n "$subject" ] && [ -n "$extra" ] || {
                printf '{"code":"project-nvmrc-requires-path-and-version","action":"project-nvmrc"}\n'
                return 1
            }
            validate_node_concrete_action_version "$extra" || {
                print_invalid_node_version_for_action_json "project-nvmrc" "$extra"
                return 1
            }
            target_type="project-nvmrc"
            external_write="true"
            ;;
        *)
            printf '{"code":"unsupported-plan-action","action":"%s"}\n' "$(json_escape "$action")"
            return 1
            ;;
    esac

    printf '{'
    printf '"ok":true,'
    printf '"schemaVersion":1,'
    printf '"action":"%s",' "$(json_escape "$action")"
    printf '"targetType":"%s",' "$(json_escape "$target_type")"
    printf '"subject":"%s",' "$(json_escape "$subject")"
    printf '"value":"%s",' "$(json_escape "$extra")"
    printf '"requiresConfirmation":%s,' "$requires_confirmation"
    printf '"executeSupported":%s,' "$execute_supported"
    printf '"logFileHint":"%s",' "$(json_escape "$(create_log_file_hint "$action" "${subject:-default}")")"
    printf '"externalWrite":%s' "$external_write"

    case "$action" in
        registry-set)
            printf ',"effectiveRegistry":"%s"' "$(json_escape "$(npm config get registry 2>/dev/null || true)")"
            printf ',"targetRegistry":"%s"' "$(json_escape "$subject")"
            ;;
        registry-delete)
            printf ',"effectiveRegistry":"%s"' "$(json_escape "$(npm config get registry 2>/dev/null || true)")"
            printf ',"userRegistry":"%s"' "$(json_escape "$(npm_config_get_layer registry user)")"
            printf ',"projectRegistry":"%s"' "$(json_escape "$(npm_config_get_layer registry project)")"
            printf ',"globalRegistry":"%s"' "$(json_escape "$(npm_config_get_layer registry global)")"
            ;;
        scope-registry-set)
            printf ',"effectiveRegistry":"%s"' "$(json_escape "$(npm config get "${subject}:registry" 2>/dev/null || true)")"
            printf ',"targetRegistry":"%s"' "$(json_escape "$extra")"
            ;;
        scope-registry-delete)
            printf ',"effectiveRegistry":"%s"' "$(json_escape "$(npm config get "${subject}:registry" 2>/dev/null || true)")"
            printf ',"userRegistry":"%s"' "$(json_escape "$(npm_config_get_layer "${subject}:registry" user)")"
            printf ',"projectRegistry":"%s"' "$(json_escape "$(npm_config_get_layer "${subject}:registry" project)")"
            printf ',"globalRegistry":"%s"' "$(json_escape "$(npm_config_get_layer "${subject}:registry" global)")"
            ;;
        nvm-install)
            printf ',"requestedVersion":"%s"' "$(json_escape "$subject")"
            printf ',"resolvedVersion":"%s"' "$(json_escape "$NVM_INSTALL_VERSION")"
            printf ',"version":"%s"' "$(json_escape "$NVM_INSTALL_VERSION")"
            printf ',"installUrl":"%s"' "$(json_escape "$NVM_INSTALL_URL")"
            printf ',"sha256":"%s"' "$(json_escape "$NVM_INSTALL_SHA256")"
            printf ',"sha256Configured":%s' "$([ -n "$NVM_INSTALL_SHA256" ] && printf true || printf false)"
            printf ',"allowUnverified":%s' "$([ "$NVM_ALLOW_UNVERIFIED_INSTALL" = "1" ] && printf true || printf false)"
            printf ',"targetDir":"%s"' "$(json_escape "$safe_nvm_dir")"
            ;;
        node-install|node-use|node-default|node-uninstall)
            local normalized_subject=""
            local current_version=""
            local node_plan_state=""
            local nvm_available="false"
            local default_version=""
            local default_status=""
            local version_dir=""
            local global_package_summary=""
            local node_executable="true"
            local node_blocked_reason=""
            if [ "$action" = "node-install" ]; then
                normalized_subject="$(normalize_node_install_target "$subject" 2>/dev/null || printf '%s' "$subject")"
            else
                normalized_subject="$(normalize_node_concrete_version "$subject" 2>/dev/null || printf '%s' "$subject")"
            fi
            node_plan_state="$(collect_node_plan_state)"
            nvm_available="$(printf '%s' "$node_plan_state" | awk -F'|' '{print $1}')"
            current_version="$(printf '%s' "$node_plan_state" | awk -F'|' '{print $2}')"
            default_version="$(printf '%s' "$node_plan_state" | awk -F'|' '{print $3}')"
            default_status="$(printf '%s' "$node_plan_state" | awk -F'|' '{print $4}')"
            case "$normalized_subject" in
                v[0-9]*.[0-9]*.[0-9]*) version_dir="$(nvm_version_dir "$normalized_subject")" ;;
                *) version_dir="" ;;
            esac
            printf ',"nvmAvailable":%s' "$nvm_available"
            printf ',"normalizedVersion":"%s"' "$(json_escape "$normalized_subject")"
            printf ',"currentVersion":"%s"' "$(json_escape "$current_version")"
            printf ',"defaultVersion":"%s"' "$(json_escape "$default_version")"
            printf ',"defaultStatus":"%s"' "$(json_escape "$default_status")"
            printf ',"versionDir":"%s"' "$(json_escape "$version_dir")"
            if [ -n "$version_dir" ] && [ -d "$version_dir" ]; then
                global_package_summary="$(nvm_version_package_summary "$version_dir" 2>/dev/null || true)"
                printf ',"versionDirExists":true'
                printf ',"versionDirSize":"%s"' "$(json_escape "$(du -sh "$version_dir" 2>/dev/null | awk '{print $1}')")"
                printf ',"globalPackageSummary":"%s"' "$(json_escape "$global_package_summary")"
            else
                printf ',"versionDirExists":false'
            fi
            if [ "$nvm_available" != "true" ]; then
                node_executable="false"
                node_blocked_reason="nvm-unavailable"
            elif [ "$action" != "node-install" ] && [ ! -d "$version_dir" ]; then
                node_executable="false"
                node_blocked_reason="node-version-not-installed"
            fi
            if [ "$action" = "node-uninstall" ]; then
                printf ',"protectedByCurrent":%s' "$([ "$normalized_subject" = "$current_version" ] && printf true || printf false)"
                printf ',"protectedByDefault":%s' "$([ "$normalized_subject" = "$default_version" ] && printf true || printf false)"
                if [ "$default_status" != "resolved" ]; then
                    node_executable="false"
                    node_blocked_reason="default-node-unresolved"
                elif [ "$normalized_subject" = "$current_version" ]; then
                    node_executable="false"
                    node_blocked_reason="cannot-uninstall-current-node"
                elif [ "$normalized_subject" = "$default_version" ]; then
                    node_executable="false"
                    node_blocked_reason="cannot-uninstall-default-node"
                elif [ -d "$version_dir" ] && [ -z "$global_package_summary" ]; then
                    node_executable="false"
                    node_blocked_reason="node-package-inventory-unavailable"
                fi
            fi
            printf ',"executable":%s' "$node_executable"
            printf ',"blockedReason":"%s"' "$(json_escape "$node_blocked_reason")"
            if [ "$action" = "node-use" ]; then
                printf ',"processOnly":true,"persistent":false'
            elif [ "$action" = "node-default" ]; then
                printf ',"processOnly":false,"persistent":true'
            fi
            ;;
        cleanup)
            printf ',"paths":'
            case "$subject" in
                npm-cache-verify|npm-cache-clean)
                    if [ "$subject" = "npm-cache-clean" ]; then
                        json_print_string_array "$(cleanup_plan_paths_from_material "$subject" "$cleanup_plan_material")"
                    else
                        json_print_string_array "$(npm config get cache 2>/dev/null || true)"
                    fi
                    ;;
                node-gyp-cache)
                    local node_gyp_paths=()
                    local node_gyp_path=""
                    while IFS= read -r node_gyp_path; do
                        [ -n "$node_gyp_path" ] || continue
                        node_gyp_paths+=("$node_gyp_path")
                    done <<< "$(cleanup_plan_paths_from_material "$subject" "$cleanup_plan_material")"
                    if [ "${#node_gyp_paths[@]}" -gt 0 ]; then
                        json_print_string_array "${node_gyp_paths[@]}"
                    else
                        json_print_string_array
                    fi
                    ;;
                orphan-bins)
                    local orphan_paths=()
                    local orphan_path=""
                    while IFS= read -r orphan_path; do
                        [ -n "$orphan_path" ] || continue
                        orphan_paths+=("$orphan_path")
                    done <<< "$(cleanup_plan_paths_from_material "$subject" "$cleanup_plan_material")"
                    if [ "${#orphan_paths[@]}" -gt 0 ]; then
                        json_print_string_array "${orphan_paths[@]}"
                    else
                        json_print_string_array
                    fi
                    ;;
                nvm-old-versions)
                    local nvm_old_paths=()
                    local old_path=""
                    while IFS= read -r old_path; do
                        [ -n "$old_path" ] || continue
                        nvm_old_paths+=("$old_path")
                    done <<< "$(cleanup_plan_paths_from_material "$subject" "$cleanup_plan_material")"
                    if [ "${#nvm_old_paths[@]}" -gt 0 ]; then
                        json_print_string_array "${nvm_old_paths[@]}"
                    else
                        json_print_string_array
                    fi
                    ;;
                logs)
                    json_print_string_array "$(manager_log_dir)"
                    ;;
                *)
                    json_print_string_array
                    ;;
            esac
            case "$subject" in
                npm-cache-clean|node-gyp-cache|orphan-bins|nvm-old-versions)
                    printf ',"planToken":"%s"' "$(json_escape "$plan_token")"
                    ;;
            esac
            ;;
        project-nvmrc)
            local current_nvmrc=""
            local engines_node=""
            [ -f "$subject/.nvmrc" ] && current_nvmrc="$(sed -n '1p' "$subject/.nvmrc" 2>/dev/null || true)"
            if [ -f "$subject/package.json" ] && command_exists ruby; then
                engines_node="$(ruby -rjson -e 'data = JSON.parse(File.read(ARGV[0])); puts data.dig("engines", "node") || ""' "$subject/package.json" 2>/dev/null || true)"
            fi
            printf ',"pathExists":%s' "$([ -e "$subject" ] && printf true || printf false)"
            printf ',"pathIsDirectory":%s' "$([ -d "$subject" ] && printf true || printf false)"
            printf ',"nvmrcPath":"%s"' "$(json_escape "$subject/.nvmrc")"
            printf ',"currentNvmrc":"%s"' "$(json_escape "$current_nvmrc")"
            printf ',"packageJsonExists":%s' "$([ -f "$subject/package.json" ] && printf true || printf false)"
            printf ',"enginesNode":"%s"' "$(json_escape "$engines_node")"
            printf ',"nvmrcIsSymlink":%s' "$([ -L "$subject/.nvmrc" ] && printf true || printf false)"
            if [ ! -d "$subject" ]; then
                printf ',"executable":false,"blockedReason":"project-path-not-directory"'
            elif ! capture_project_nvmrc_snapshot "$subject/.nvmrc" >/dev/null 2>&1; then
                printf ',"executable":false,"blockedReason":"project-nvmrc-not-regular-file"'
            else
                printf ',"executable":true,"blockedReason":""'
            fi
            ;;
    esac
    printf '}\n'
}

render_action_plan_json() {
    local action="${1:-}"
    local subject="${2:-}"
    local extra="${3:-}"
    local package_name=""
    local package_spec="$subject"
    local installed_version=""
    local target_version=""
    local log_file_hint=""
    local install_state=""
    local install_state_exit=0

    [ -n "$action" ] || {
        printf '{"code":"missing-argument","argument":"action"}\n'
        return 1
    }

    case "$action" in
        install)
            validate_package_spec "$package_spec" || {
                printf '{"code":"invalid-package-spec","action":"install","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
                return 1
            }
            package_name="$(extract_package_name "$package_spec")"
            if ! target_version="$(resolve_install_target_version "$package_spec")"; then
                printf '{"code":"target-version-unavailable","action":"install","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
                return 1
            fi
            ;;
        uninstall|update-latest)
            validate_package_name_only "$subject" || {
                printf '{"code":"invalid-package-name","action":"%s","packageName":"%s"}\n' "$(json_escape "$action")" "$(json_escape "$subject")"
                return 1
            }
            package_name="$subject"
            if [ "$action" = "uninstall" ] && is_protected_global_package "$package_name"; then
                printf '{"code":"protected-package","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
                return 1
            fi
            ;;
        *)
            render_non_package_action_plan_json "$action" "$subject" "$extra"
            return $?
            ;;
    esac

    install_state="$(query_global_package_install_state "$package_name")" || install_state_exit=$?
    case "$install_state_exit" in
        0) installed_version="${install_state#*|}" ;;
        1)
            installed_version=""
            if [ "$action" != "install" ]; then
                printf '{"code":"package-not-installed","action":"%s","packageName":"%s"}\n' "$(json_escape "$action")" "$(json_escape "$package_name")"
                return 1
            fi
            ;;
        *)
            printf '{"code":"package-state-unavailable","action":"%s","packageName":"%s"}\n' "$(json_escape "$action")" "$(json_escape "$package_name")"
            return 1
            ;;
    esac
    if [ "$action" = "update-latest" ]; then
        target_version="$(get_registry_latest_version "$package_name")" || {
            printf '{"code":"latest-version-unavailable","action":"update-latest","packageName":"%s"}\n' "$(json_escape "$package_name")"
            return 1
        }
    fi
    log_file_hint="$(create_log_file_hint "$action" "$package_name")"

    printf '{'
    printf '"ok":true,'
    printf '"schemaVersion":1,'
    printf '"action":"%s",' "$(json_escape "$action")"
    printf '"packageSpec":"%s",' "$(json_escape "$package_spec")"
    printf '"packageName":"%s",' "$(json_escape "$package_name")"
    printf '"installedVersion":"%s",' "$(json_escape "$installed_version")"
    printf '"targetVersion":"%s",' "$(json_escape "$target_version")"
    printf '"alreadyInstalled":%s,' "$(is_install_spec_satisfied "$package_spec" "$installed_version" "$target_version" && printf true || printf false)"
    printf '"logFileHint":"%s",' "$(json_escape "$log_file_hint")"
    printf '"requiresConfirmation":true,'
    printf '"executeSupported":true'
    printf '}\n'
}
