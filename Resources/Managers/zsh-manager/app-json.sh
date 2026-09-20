#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep the frozen interactive manager unchanged and layer the App protocol on its
# tested file and configuration helpers.
source "$SCRIPT_DIR/omz-manager.sh"
source "$SCRIPT_DIR/lib/app_json_common.sh"
source "$SCRIPT_DIR/lib/app_json_query.sh"
source "$SCRIPT_DIR/lib/app_json_plan.sh"
source "$SCRIPT_DIR/lib/app_json_execute.sh"

run_app_json_command() {
    local command_name="${1:-}"
    shift || true

    case "$command_name" in
        snapshot) json_success "$command_name" "$(render_shell_snapshot_json)" ;;
        plan)
            local output=""
            if output="$(render_shell_plan_json "${1:-}" "${2:-}")"; then
                json_success "$command_name" "$output"
            else
                [ -n "$output" ] || output='{"code":"plan-failed"}'
                json_failure "$command_name" "$output"
                return 1
            fi
            ;;
        execute)
            local output=""
            if output="$(execute_shell_action_json "${1:-}" "${2:-}" "${3:-}")"; then
                json_success "$command_name" "$output"
            else
                [ -n "$output" ] || output='{"code":"execute-failed"}'
                json_failure "$command_name" "$output"
                return 1
            fi
            ;;
        *)
            json_failure "$command_name" '{"code":"unsupported-json-command"}'
            return 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    [ "${1:-}" = "--json" ] || {
        printf 'Usage: app-json.sh --json <snapshot|plan|execute>\n' >&2
        exit 64
    }
    shift
    run_app_json_command "$@"
fi
