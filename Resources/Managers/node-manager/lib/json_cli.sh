# shellcheck shell=bash

run_json_command() {
    local command_name="${1:-}"
    local output=""
    local command_exit=0
    local preflight_error=""
    local fallback_preflight_error='{"code":"preflight-failed"}'
    local fallback_command_error='{"code":"command-failed"}'
    shift || true

    if ! preflight_error="$(run_json_preflight "$command_name" "$@")"; then
        printf '{"ok":false,"schemaVersion":1,"command":"%s","error":%s}\n' "$(json_escape "$command_name")" "${preflight_error:-$fallback_preflight_error}"
        return 1
    fi

    case "$command_name" in
        summary)
            output="$(render_summary_json)" || command_exit=$?
            ;;
        packages)
            output="$(render_packages_json)" || command_exit=$?
            ;;
        outdated)
            output="$(render_outdated_json)" || command_exit=$?
            ;;
        config)
            output="$(render_config_json)" || command_exit=$?
            ;;
        package-plan)
            output="$(render_package_plan_json "${1:-}")" || command_exit=$?
            ;;
        plan)
            output="$(render_action_plan_json "${1:-}" "${2:-}" "${3:-}")" || command_exit=$?
            ;;
        execute)
            if [ "${1:-}" = "cleanup" ] && [ "${2:-}" = "logs" ]; then
                output="$(render_logs_cleanup_json "${3:-100}")" || command_exit=$?
            else
                output="$(render_execute_json "${1:-}" "${2:-}" "${3:-}")" || command_exit=$?
            fi
            ;;
        status)
            output="$(render_status_json)" || command_exit=$?
            ;;
        logs)
            output="$(render_logs_json "${1:-20}")" || command_exit=$?
            ;;
        logs-cleanup)
            output="$(render_logs_cleanup_json "${1:-100}")" || command_exit=$?
            ;;
        operation-result)
            output="$(render_operation_result_json "${1:-}" "${2:-}" "${3:-}" "${4:-0}" "${5:-unknown}" "${6:-}")" || command_exit=$?
            ;;
        *)
            printf '{"ok":false,"schemaVersion":1,"command":"%s","error":{"code":"unsupported-json-command"}}\n' "$(json_escape "$command_name")"
            return 1
            ;;
    esac

    if [ "$command_exit" -eq 0 ]; then
        printf '{"ok":true,"schemaVersion":1,"command":"%s","data":%s}\n' "$(json_escape "$command_name")" "${output:-null}"
        return 0
    fi

    printf '{"ok":false,"schemaVersion":1,"command":"%s","error":%s}\n' "$(json_escape "$command_name")" "${output:-$fallback_command_error}"
    return "$command_exit"
}
