# shellcheck shell=bash

# ──────────────────────────────────────────────
# CLI helpers for future app wrappers
# ──────────────────────────────────────────────

manager_version() {
    printf "npm-global-manager 0.3.0\n"
}

render_help() {
    cat <<'EOF'
npm-global-manager

Usage:
  npm-global-manager.sh
  npm-global-manager.sh --help
  npm-global-manager.sh --version
  npm-global-manager.sh --info
  npm-global-manager.sh --json summary
  npm-global-manager.sh --json packages
  npm-global-manager.sh --json outdated
  npm-global-manager.sh --json config
  npm-global-manager.sh --json package-plan <safe-package>
  npm-global-manager.sh --json plan <install|uninstall|update-latest> <package-spec-or-name>
  npm-global-manager.sh --json execute <install|uninstall|update-latest> <package-spec-or-name>
  npm-global-manager.sh --json plan registry-set <url>
  npm-global-manager.sh --json execute registry-set <url>
  npm-global-manager.sh --json plan registry-delete
  npm-global-manager.sh --json execute registry-delete
  npm-global-manager.sh --json plan scope-registry-set <scope> <url>
  npm-global-manager.sh --json execute scope-registry-set <scope> <url>
  npm-global-manager.sh --json plan scope-registry-delete <scope>
  npm-global-manager.sh --json execute scope-registry-delete <scope>
  npm-global-manager.sh --json plan nvm-install
  npm-global-manager.sh --json execute nvm-install
  npm-global-manager.sh --json plan node-install <version|lts>
  npm-global-manager.sh --json execute node-install <version|lts>
  npm-global-manager.sh --json plan node-use <version>
  npm-global-manager.sh --json execute node-use <version>
  npm-global-manager.sh --json plan node-uninstall <version>
  npm-global-manager.sh --json execute node-uninstall <version>
  npm-global-manager.sh --json plan cleanup <target>
  npm-global-manager.sh --json execute cleanup <target>
  npm-global-manager.sh --json plan project-nvmrc <project-path> <version>
  npm-global-manager.sh --json execute project-nvmrc <project-path> <version>
  npm-global-manager.sh --json status
  npm-global-manager.sh --json logs [limit]
  npm-global-manager.sh --json logs-cleanup [keep-count]
  npm-global-manager.sh --json operation-result <operation-id> <action> <subject> <exit-code> <status> <log-file>

Options:
  --help       Show this help.
  --version    Show script version.
  --info       Print runtime directories and supported machine commands.
  --dry-run    Compatibility alias for --info; does not simulate arbitrary mutations.
  --test-mode  Enable test-friendly behavior for wrappers.
  --json       Output machine-readable data for supported commands.

Notes:
  JSON execute requires NODE_MANAGER_ALLOW_JSON_EXECUTE=1 after app-side confirmation.
  execute cleanup logs proxies to logs-cleanup and does not require NODE_MANAGER_ALLOW_JSON_EXECUTE.
  node-install also accepts --lts, --lts=<line>, lts/*, and lts/<line>.
  project-nvmrc execute also requires NODE_MANAGER_ALLOW_PROJECT_WRITE=1 because it writes outside scripts/node-manager.
  cleanup targets: npm-cache-verify, npm-cache-clean, node-gyp-cache, orphan-bins, nvm-old-versions, logs.
EOF
}

json_escape() {
    local value="${1:-}"

    if command_exists ruby; then
        ruby -rjson -e 'print ARGV[0].to_json[1..-2]' "$value" 2>/dev/null && return 0
    fi

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    json_escape_remaining_control_bytes "$value"
}

# Fallback-only helper (ruby unavailable): \n \r \t are already escaped by
# the caller above, but valid JSON also requires escaping every other byte
# in 0x00-0x1F (e.g. a raw ESC byte inside an npm/curl error message), or
# the output isn't parseable JSON. Skips the byte walk entirely unless a
# control byte is actually present. Walks byte-by-byte in the C locale so
# UTF-8 multibyte sequences (whose bytes are always >= 0x80) pass through
# untouched; only ASCII control bytes ever hit the \u00XX branch.
json_escape_remaining_control_bytes() {
    local value="${1:-}"

    LC_ALL=C printf '%s' "$value" 2>/dev/null | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null || {
        printf '%s' "$value"
        return 0
    }

    local -x LC_ALL=C
    local len="${#value}"
    local i=0
    local ch=""
    local code=0
    local out=""
    while [ "$i" -lt "$len" ]; do
        ch="${value:i:1}"
        code="$(printf '%d' "'$ch" 2>/dev/null || printf '32')"
        if [ "$code" -ge 0 ] && [ "$code" -lt 32 ]; then
            out="${out}$(printf '\\u%04x' "$code")"
        else
            out="${out}${ch}"
        fi
        i=$((i + 1))
    done
    printf '%s' "$out"
}

json_print_string_array() {
    local first="yes"
    local item=""

    printf '['
    for item in "$@"; do
        [ "$first" = "yes" ] || printf ','
        first="no"
        printf '"%s"' "$(json_escape "$item")"
    done
    printf ']'
}

json_print_business_error_with_operation() {
    local error_json="$1"
    local action="$2"
    local subject="$3"
    local log_file="$4"
    local exit_code="${5:-1}"
    local code=""
    local operation_id=""

    operation_id="$(create_operation_id "$action-${subject:-default}")"

    if command_exists ruby; then
        ruby -rjson -e '
          raw, action, subject, log_file, exit_code, operation_id = ARGV
          begin
            error = JSON.parse(raw)
            error = {"code" => "action-failed", "rawError" => raw} unless error.is_a?(Hash)
          rescue JSON::ParserError
            error = {"code" => "action-failed", "rawError" => raw}
          end
          code = error["code"].to_s
          code = "action-failed" if code.empty?
          error["code"] = code
          error["operationId"] = operation_id
          error["action"] = action
          error["subject"] = subject
          error["exitCode"] = exit_code.to_i
          error["status"] = "failed"
          error["logFile"] = log_file
          error["causeCode"] = code
          print JSON.generate(error)
        ' "$error_json" "$action" "$subject" "$log_file" "$exit_code" "$operation_id" 2>/dev/null && {
            printf '\n'
            return 0
        }
    fi

    code="$(printf '%s' "$error_json" | sed -n 's/.*"code":"\([^"]*\)".*/\1/p' | sed -n '1p')"
    [ -n "$code" ] || code="action-failed"

    # error_json here is always one of this script's own flat, single-level
    # JSON objects -- every caller only reaches this fallback after already
    # confirming the payload looks like one of our own `{"code":"...",...}`
    # errors. That guarantee lets the no-ruby path splice the enrichment
    # fields into the existing object instead of discarding every field but
    # "code" into an opaque rawError string. Malformed input still falls
    # through to the safe rawError-wrapping form below.
    case "$error_json" in
        '{'*'}')
            local error_body="${error_json#\{}"
            error_body="${error_body%\}}"
            printf '{%s,"operationId":"%s","action":"%s","subject":"%s","exitCode":%s,"status":"failed","logFile":"%s","causeCode":"%s"}\n' \
                "$error_body" "$(json_escape "$operation_id")" "$(json_escape "$action")" "$(json_escape "$subject")" "$exit_code" "$(json_escape "$log_file")" "$(json_escape "$code")"
            return 0
            ;;
    esac

    printf '{'
    printf '"code":"%s",' "$(json_escape "$code")"
    printf '"operationId":"%s",' "$(json_escape "$operation_id")"
    printf '"action":"%s",' "$(json_escape "$action")"
    printf '"subject":"%s",' "$(json_escape "$subject")"
    printf '"exitCode":%s,' "$exit_code"
    printf '"status":"failed",'
    printf '"logFile":"%s",' "$(json_escape "$log_file")"
    printf '"causeCode":"%s",' "$(json_escape "$code")"
    printf '"rawError":"%s"' "$(json_escape "$error_json")"
    printf '}\n'
}

render_operation_result_json() {
    local operation_id="$1"
    local action="$2"
    local subject="$3"
    local exit_code="$4"
    local status="$5"
    local log_file="$6"

    if ! is_nonnegative_integer "$exit_code"; then
        printf '{"code":"invalid-exit-code","exitCode":"%s"}\n' "$(json_escape "$exit_code")"
        return 1
    fi

    printf '{'
    printf '"operationId":"%s",' "$(json_escape "$operation_id")"
    printf '"action":"%s",' "$(json_escape "$action")"
    printf '"subject":"%s",' "$(json_escape "$subject")"
    printf '"exitCode":%s,' "${exit_code:-0}"
    printf '"status":"%s",' "$(json_escape "$status")"
    printf '"logFile":"%s"' "$(json_escape "$log_file")"
    printf '}\n'
}

render_config_json() {
    local registry=""
    local cache_path=""
    local prefix=""
    registry="$(npm config get registry 2>/dev/null || true)"
    cache_path="$(npm config get cache 2>/dev/null || true)"
    prefix="$(npm prefix -g 2>/dev/null || true)"
    printf '{'
    printf '"registry":"%s",' "$(json_escape "$registry")"
    printf '"cache":"%s",' "$(json_escape "$cache_path")"
    printf '"prefix":"%s",' "$(json_escape "$prefix")"
    printf '"userRegistry":"%s",' "$(json_escape "$(npm_config_get_layer registry user)")"
    printf '"projectRegistry":"%s",' "$(json_escape "$(npm_config_get_layer registry project)")"
    printf '"globalRegistry":"%s"' "$(json_escape "$(npm_config_get_layer registry global)")"
    printf '}\n'
}

resolve_nvm_install_request_json() {
    local requested="${1:-}"
    requested="${requested:-$NVM_INSTALL_VERSION}"

    if [ "$requested" != "$NVM_INSTALL_VERSION" ]; then
        printf '{"code":"unsupported-nvm-install-version","action":"nvm-install","requestedVersion":"%s","configuredVersion":"%s"}\n' \
            "$(json_escape "$requested")" "$(json_escape "$NVM_INSTALL_VERSION")"
        return 1
    fi

    printf '{'
    printf '"requestedVersion":"%s",' "$(json_escape "$requested")"
    printf '"resolvedVersion":"%s",' "$(json_escape "$NVM_INSTALL_VERSION")"
    printf '"installUrl":"%s",' "$(json_escape "$NVM_INSTALL_URL")"
    printf '"sha256":"%s",' "$(json_escape "$NVM_INSTALL_SHA256")"
    printf '"sha256Configured":%s' "$([ -n "$NVM_INSTALL_SHA256" ] && printf true || printf false)"
    printf '}\n'
}

normalize_node_install_target() {
    local target="${1:-}"

    case "$target" in
        lts|--lts|lts/\*)
            printf '%s\n' "--lts"
            return 0
            ;;
        --lts=*)
            [ -n "${target#--lts=}" ] || return 1
            printf '%s\n' "$target"
            return 0
            ;;
        lts/*)
            [ -n "${target#lts/}" ] || return 1
            printf '%s\n' "--lts=${target#lts/}"
            return 0
            ;;
        *)
            normalize_node_version "$target"
            ;;
    esac
}

validate_node_install_target() {
    normalize_node_install_target "$1" >/dev/null 2>&1
}

validate_node_concrete_action_version() {
    normalize_node_concrete_version "$1" >/dev/null 2>&1
}

print_invalid_node_version_for_action_json() {
    local action="$1"
    local version="${2:-}"

    printf '{"code":"invalid-node-version-for-action","action":"%s","version":"%s"}\n' \
        "$(json_escape "$action")" "$(json_escape "$version")"
}

collect_node_plan_state() {
    local nvm_available="false"
    local current_version=""
    local default_info=""
    local default_version=""
    local default_status=""

    if load_nvm_into_current_shell >/dev/null 2>&1; then
        nvm_available="true"
        current_version="$(nvm current 2>/dev/null || true)"
        default_info="$(parse_nvm_default_alias_output "$(nvm alias default 2>/dev/null || true)")"
    else
        default_info="$(read_nvm_default_alias_file_info)"
    fi
    default_version="$(printf '%s' "$default_info" | awk -F'|' '{print $2}')"
    default_status="$(printf '%s' "$default_info" | awk -F'|' '{print $3}')"

    printf '%s|%s|%s|%s\n' "$nvm_available" "$current_version" "$default_version" "$default_status"
}

validate_cleanup_target() {
    case "${1:-}" in
        npm-cache-verify|npm-cache-clean|node-gyp-cache|orphan-bins|nvm-old-versions|logs)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
