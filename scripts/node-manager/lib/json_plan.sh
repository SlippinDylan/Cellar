# shellcheck shell=bash

render_non_package_action_plan_json() {
    local action="$1"
    local subject="${2:-}"
    local extra="${3:-}"
    local target_type=""
    local requires_confirmation="true"
    local execute_supported="true"
    local external_write="false"

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
            nvm_install_request_json="$(resolve_nvm_install_request_json "$subject")" || {
                printf '%s\n' "$nvm_install_request_json"
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
        node-use|node-uninstall)
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
            printf ',"targetDir":"%s"' "$(json_escape "$(detect_nvm_dir)")"
            ;;
        node-install|node-use|node-uninstall)
            local normalized_subject=""
            local current_version=""
            local node_plan_state=""
            local nvm_available="false"
            local default_version=""
            local default_status=""
            local version_dir=""
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
                printf ',"versionDirExists":true'
                printf ',"versionDirSize":"%s"' "$(json_escape "$(du -sh "$version_dir" 2>/dev/null | awk '{print $1}')")"
                printf ',"globalPackageSummary":"%s"' "$(json_escape "$(nvm_version_package_summary "$version_dir" 2>/dev/null || true)")"
            else
                printf ',"versionDirExists":false'
            fi
            if [ "$action" = "node-uninstall" ]; then
                printf ',"protectedByCurrent":%s' "$([ "$normalized_subject" = "$current_version" ] && printf true || printf false)"
                printf ',"protectedByDefault":%s' "$([ "$normalized_subject" = "$default_version" ] && printf true || printf false)"
            fi
            ;;
        cleanup)
            printf ',"paths":'
            case "$subject" in
                npm-cache-verify|npm-cache-clean)
                    json_print_string_array "$(npm config get cache 2>/dev/null || true)"
                    ;;
                node-gyp-cache)
                    local node_gyp_paths=()
                    local node_gyp_path=""
                    while IFS='|' read -r node_gyp_path _; do
                        [ -n "$node_gyp_path" ] || continue
                        node_gyp_paths+=("$node_gyp_path")
                    done <<< "$(detect_node_gyp_cache_dirs)"
                    if [ "${#node_gyp_paths[@]}" -gt 0 ]; then
                        json_print_string_array "${node_gyp_paths[@]}"
                    else
                        json_print_string_array
                    fi
                    ;;
                orphan-bins)
                    json_print_string_array "$(get_global_bin_dir 2>/dev/null || true)"
                    ;;
                nvm-old-versions)
                    local nvm_old_paths=()
                    local old_ver=""
                    while IFS= read -r old_ver; do
                        [ -n "$old_ver" ] || continue
                        nvm_old_paths+=("$(nvm_version_dir "$old_ver")")
                    done <<< "$(get_installed_node_versions 2>/dev/null || true)"
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

    installed_version="$(get_installed_global_package_version "$package_name")"
    if [ "$action" = "uninstall" ] && [ -z "$installed_version" ]; then
        printf '{"code":"package-not-installed","action":"uninstall","packageName":"%s"}\n' "$(json_escape "$package_name")"
        return 1
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
