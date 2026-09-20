# shellcheck shell=bash

render_summary_json() {
    local node_path=""
    local npm_path=""
    local node_version=""
    local npm_version=""
    local nvm_loaded="false"
    local global_prefix=""
    local global_root=""
    local registry=""

    node_path="$(command -v node 2>/dev/null || true)"
    npm_path="$(command -v npm 2>/dev/null || true)"
    node_version="$(node -v 2>/dev/null || true)"
    npm_version="$(npm -v 2>/dev/null || true)"
    if is_nvm_loaded; then
        nvm_loaded="true"
    fi
    global_prefix="$(npm prefix -g 2>/dev/null || true)"
    global_root="$(npm root -g 2>/dev/null || true)"
    registry="$(npm config get registry 2>/dev/null || true)"

    printf '{'
    printf '"nodePath":"%s",' "$(json_escape "$node_path")"
    printf '"npmPath":"%s",' "$(json_escape "$npm_path")"
    printf '"nodeVersion":"%s",' "$(json_escape "$node_version")"
    printf '"npmVersion":"%s",' "$(json_escape "$npm_version")"
    printf '"nvmLoaded":%s,' "$nvm_loaded"
    printf '"globalPrefix":"%s",' "$(json_escape "$global_prefix")"
    printf '"globalRoot":"%s",' "$(json_escape "$global_root")"
    printf '"registry":"%s"' "$(json_escape "$registry")"
    printf '}\n'
}

render_packages_json() {
    local packages_json=""
    if ! packages_json="$(load_global_package_inventory_json)"; then
        printf '{"code":"npm-list-failed"}\n'
        return 1
    fi
    if [ -z "$packages_json" ] || ! printf '%s' "$packages_json" | validate_global_package_inventory_json; then
        printf '{"code":"invalid-package-json"}\n'
        return 1
    fi
    printf '%s\n' "$packages_json"
}

render_outdated_json() {
    local outdated_json=""
    local outdated_exit=0
    local stderr_file=""
    local stderr_text=""

    stderr_file="$(mktemp "${TMPDIR:-/tmp}/node-manager-outdated-stderr.XXXXXX")" || {
        printf '{"code":"tmp-file-failed"}\n'
        return 1
    }

    outdated_json="$(npm outdated -g --depth=0 --json 2>"$stderr_file")" || outdated_exit=$?
    stderr_text="$(sed -n '1,20p' "$stderr_file" 2>/dev/null || true)"
    rm -f "$stderr_file"

    if [ "$outdated_exit" -gt 1 ]; then
        printf '{"code":"npm-outdated-failed","exitCode":%d,"stderr":"%s"}\n' \
            "$outdated_exit" "$(json_escape "$stderr_text")"
        return 1
    fi
    if [ "$outdated_exit" -eq 1 ] && [ -z "$outdated_json" ] && [ -n "$stderr_text" ]; then
        printf '{"code":"npm-outdated-failed","exitCode":%d,"stderr":"%s"}\n' \
            "$outdated_exit" "$(json_escape "$stderr_text")"
        return 1
    fi
    if [ -z "$outdated_json" ]; then
        printf '{}\n'
        return 0
    fi
    if ! printf '%s' "$outdated_json" | validate_json_text; then
        printf '{"code":"invalid-outdated-json"}\n'
        return 1
    fi
    if [ "$outdated_json" != "{}" ] && ! printf '%s' "$outdated_json" | parse_outdated_package_rows_stdin >/dev/null 2>&1; then
        printf '{"code":"invalid-outdated-schema"}\n'
        return 1
    fi
    printf '%s\n' "$outdated_json"
}

run_json_preflight() {
    local command_name="${1:-}"
    local action_name="${2:-}"
    local cmd=""
    local required_commands="sed mktemp"
    local missing_dependencies=""

    case "$command_name" in
        summary|status|logs|logs-cleanup)
            required_commands="sed mktemp"
            ;;
        packages|outdated|config|package-plan)
            required_commands="ruby npm sed mktemp"
            ;;
        plan)
            case "$action_name" in
                nvm-install|node-install|node-use|node-default)
                    required_commands="sed mktemp"
                    ;;
                project-nvmrc)
                    required_commands="md5 sed mktemp"
                    ;;
                node-uninstall)
                    required_commands="ruby sed mktemp"
                    ;;
                cleanup)
                    case "${3:-}" in
                        logs) required_commands="sed mktemp" ;;
                        npm-cache-verify) required_commands="npm sed mktemp" ;;
                        npm-cache-clean|node-gyp-cache|orphan-bins) required_commands="shasum npm sed mktemp" ;;
                        nvm-old-versions) required_commands="shasum ruby sed mktemp" ;;
                        *) required_commands="sed mktemp" ;;
                    esac
                    ;;
                registry-set|registry-delete|scope-registry-set|scope-registry-delete)
                    required_commands="ruby npm sed mktemp"
                    ;;
                install|uninstall|update-latest|"")
                    required_commands="ruby npm sed mktemp"
                    ;;
                *)
                    required_commands="sed mktemp"
                    ;;
            esac
            ;;
        execute)
            case "$action_name" in
                nvm-install)
                    required_commands="curl bash env sed mktemp"
                    [ -n "$NVM_INSTALL_SHA256" ] && required_commands="$required_commands shasum"
                    ;;
                node-install|node-use|node-default)
                    required_commands="sed mktemp"
                    ;;
                project-nvmrc)
                    required_commands="md5 sed mktemp"
                    ;;
                node-uninstall)
                    required_commands="ruby sed mktemp"
                    ;;
                cleanup)
                    case "${3:-}" in
                        logs) required_commands="sed mktemp" ;;
                        npm-cache-verify|npm-cache-clean|node-gyp-cache|orphan-bins) required_commands="npm sed mktemp" ;;
                        nvm-old-versions) required_commands="ruby sed mktemp" ;;
                        *) required_commands="sed mktemp" ;;
                    esac
                    [ "${3:-}" = "logs" ] || {
                        [ -n "${4:-}" ] && required_commands="$required_commands shasum"
                    }
                    ;;
                registry-set|registry-delete|scope-registry-set|scope-registry-delete)
                    required_commands="ruby npm sed mktemp"
                    ;;
                install|uninstall|update-latest|"")
                    required_commands="ruby npm sed mktemp"
                    ;;
                *)
                    required_commands="sed mktemp"
                    ;;
            esac
            ;;
        *)
            required_commands="ruby npm sed mktemp"
            ;;
    esac

    for cmd in $required_commands; do
        if ! command_exists "$cmd"; then
            missing_dependencies="${missing_dependencies:+$missing_dependencies }$cmd"
        fi
    done

    if [ -n "$missing_dependencies" ]; then
        printf '{"code":"missing-dependency","dependencies":['
        local first="yes"
        for cmd in $missing_dependencies; do
            [ "$first" = "yes" ] || printf ','
            first="no"
            printf '"%s"' "$(json_escape "$cmd")"
        done
        printf ']}\n'
        return 1
    fi

    return 0
}

render_status_json() {
    printf '{'
    printf '"ok":true,'
    printf '"runtimeDir":"%s",' "$(json_escape "$(manager_runtime_dir)")"
    printf '"logDir":"%s",' "$(json_escape "$(manager_log_dir)")"
    printf '"tmpDir":"%s",' "$(json_escape "$(manager_tmp_dir)")"
    printf '"jsonExecuteEnabled":%s' "$([ "${NODE_MANAGER_ALLOW_JSON_EXECUTE:-0}" = "1" ] && printf true || printf false)"
    printf '}\n'
}

render_logs_json() {
    local limit="${1:-20}"

    is_nonnegative_integer "$limit" || limit=20
    if [ ! -d "$(manager_log_dir)" ]; then
        printf '[]\n'
        return 0
    fi
    printf '['
    find "$(manager_log_dir)" -maxdepth 1 -type f -name '*.log*' 2>/dev/null \
        | sort -r \
        | head -n "$limit" \
        | awk -v first=1 '
            {
              gsub(/\\/,"\\\\",$0); gsub(/"/,"\\\"",$0)
              if (!first) printf ","
              printf "\"%s\"", $0
              first=0
            }
        '
    printf ']\n'
}

cleanup_runtime_logs_keep_recent() {
    local keep_count="${1:-100}"
    local log_dir=""
    local log_file=""
    local index=0

    is_nonnegative_integer "$keep_count" || keep_count=100
    log_dir="$(manager_log_dir)"
    [ -d "$log_dir" ] || return 0

    while IFS= read -r log_file; do
        [ -n "$log_file" ] || continue
        case "$log_file" in
            "$log_dir"/*.log.*) ;;
            *) continue ;;
        esac
        index=$((index + 1))
        if [ "$index" -gt "$keep_count" ]; then
            rm -f "$log_file" 2>/dev/null || return 1
        fi
    done <<EOF
$(find "$log_dir" -maxdepth 1 -type f -name '*.log.*' -exec ls -t {} + 2>/dev/null || true)
EOF
}

render_logs_cleanup_json() {
    local keep_count="${1:-100}"

    is_nonnegative_integer "$keep_count" || keep_count=100
    if cleanup_runtime_logs_keep_recent "$keep_count"; then
        printf '{"ok":true,"action":"logs-cleanup","kept":%s,"logDir":"%s"}\n' "$keep_count" "$(json_escape "$(manager_log_dir)")"
        return 0
    fi
    printf '{"code":"logs-cleanup-failed"}\n'
    return 1
}

render_package_plan_json() {
    local package_spec="${1:-}"
    local package_name=""
    local installed_version=""
    local target_version=""
    local log_file=""
    local install_state=""
    local install_state_exit=0

    if ! validate_package_spec "$package_spec"; then
        printf '{"code":"invalid-package-spec","packageSpec":"%s","allowed":"registry package safe subset: package, @scope/package, package@version, @scope/package@tag"}\n' "$(json_escape "$package_spec")"
        return 1
    fi

    package_name="$(extract_package_name "$package_spec")"
    if ! target_version="$(resolve_install_target_version "$package_spec")"; then
        printf '{"code":"target-version-unavailable","packageSpec":"%s"}\n' "$(json_escape "$package_spec")"
        return 1
    fi
    install_state="$(query_global_package_install_state "$package_name")" || install_state_exit=$?
    case "$install_state_exit" in
        0) installed_version="${install_state#*|}" ;;
        1) installed_version="" ;;
        *)
            printf '{"code":"package-state-unavailable","action":"install","packageName":"%s"}\n' "$(json_escape "$package_name")"
            return 1
            ;;
    esac
    log_file_hint="$(create_log_file_hint install "$package_name")"
    local already_installed="false"
    if is_install_spec_satisfied "$package_spec" "$installed_version" "$target_version"; then
        already_installed="true"
    fi

    printf '{'
    printf '"ok":true,'
    printf '"action":"install-global-package",'
    printf '"packageSpec":"%s",' "$(json_escape "$package_spec")"
    printf '"packageName":"%s",' "$(json_escape "$package_name")"
    printf '"targetVersion":"%s",' "$(json_escape "$target_version")"
    printf '"alreadyInstalled":%s,' "$already_installed"
    printf '"installedVersion":"%s",' "$(json_escape "$installed_version")"
    printf '"logFileHint":"%s"' "$(json_escape "$log_file_hint")"
    printf '}\n'
}
