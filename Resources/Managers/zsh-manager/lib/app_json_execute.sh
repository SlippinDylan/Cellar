# shellcheck shell=bash

install_omz_once() {
    local installer=""
    installer="$(mktemp "${TMPDIR:-/tmp}/cellar-omz-install.XXXXXX")" || return 1
    if ! /usr/bin/curl -fsSL "$OMZ_INSTALL_URL" -o "$installer"; then
        rm -f "$installer"
        return 1
    fi
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes /bin/sh "$installer"
    local result=$?
    rm -f "$installer"
    return "$result"
}

install_plugin_once() {
    local url="$1"
    # The App owns staging and publishes with renameatx_np(RENAME_EXCL). Pin this
    # process's cwd before cloning; never write or remove the final destination.
    [ -n "${SHELL_MANAGER_PLUGIN_STAGING:-}" ] && [ -n "${SHELL_MANAGER_PLUGIN_OWNER:-}" ] || return 1
    (
        cd -P "$SHELL_MANAGER_PLUGIN_STAGING" || exit 1
        [ "$(/usr/bin/stat -f '%d:%i' .)" = "${SHELL_MANAGER_PLUGIN_IDENTITY:-}" ] || exit 1
        [ -f .cellar-owner ] && [ ! -L .cellar-owner ] || exit 1
        [ "$(/bin/cat .cellar-owner)" = "$SHELL_MANAGER_PLUGIN_OWNER" ] || exit 1
        /usr/bin/git clone --depth=1 "$url" repository
    )
}

set_plugin_selection() {
    local csv="$1"
    local raw_names=()
    local names=()
    local name=""
    local plugin_line=""
    IFS=',' read -r -a raw_names <<< "$csv"
    for name in "${raw_names[@]+"${raw_names[@]}"}"; do
        if ! array_contains_exact "$name" "${names[@]+"${names[@]}"}"; then
            append_to_array names "$name"
        fi
    done
    if ! array_contains_exact git "${names[@]+"${names[@]}"}"; then
        append_to_array names git
    fi
    plugin_line="plugins=($(join_array_with_separator " " "${names[@]+"${names[@]}"}"))"
    write_managed_block plugins "$plugin_line" || return 1
    reload_zshrc
}

validate_shell_execute_request() {
    local action="$1"
    local subject="$2"
    case "$action" in
        install-omz)
            [ -n "$OMZ_INSTALL_URL" ] && [ ! -e "$OMZ_DIR" ]
            ;;
        install-plugin)
            validate_plugin_url "$subject" || return 1
            local plugin_name=""
            plugin_name="$(derive_plugin_name_from_url "$subject")" || return 1
            [ -d "$OMZ_DIR" ] && [ ! -e "$CUSTOM_PLUGINS_DIR/$plugin_name" ]
            ;;
        set-plugins)
            validate_plugin_list "$subject"
            ;;
        switch-theme)
            theme_file_path "$subject" >/dev/null
            ;;
        tidy)
            [ "$subject" = "zsh-files" ]
            ;;
        *) return 1 ;;
    esac
}

execute_shell_action_json() {
    local action="${1:-}"
    local subject="${2:-}"
    local token="${3:-}"
    local log_file=""
    local exit_code=0

    [ "${SHELL_MANAGER_ALLOW_JSON_EXECUTE:-0}" = "1" ] || {
        printf '{"code":"json-execute-disabled"}'
        return 1
    }
    validate_shell_execute_request "$action" "$subject" || {
        printf '{"code":"execute-preflight-failed"}'
        return 1
    }
    require_fresh_plan "$token" "$action" "$subject" || {
        printf '{"code":"plan-stale"}'
        return 1
    }
    log_file="$(create_shell_log "$action")" || {
        printf '{"code":"log-create-failed"}'
        return 1
    }

    case "$action" in
        install-omz) install_omz_once >>"$log_file" 2>&1 || exit_code=$? ;;
        install-plugin) install_plugin_once "$subject" >>"$log_file" 2>&1 || exit_code=$? ;;
        set-plugins) set_plugin_selection "$subject" >>"$log_file" 2>&1 || exit_code=$? ;;
        switch-theme) switch_theme "$subject" >>"$log_file" 2>&1 || exit_code=$? ;;
        tidy) run_zsh_tidy_flow >>"$log_file" 2>&1 || exit_code=$? ;;
        *)
            printf '{"code":"unsupported-action"}'
            return 1
            ;;
    esac

    if [ "$exit_code" -eq 0 ]; then
        operation_result_json "$action" "$subject" ok 0 "$log_file"
        return 0
    fi
    operation_error_json "$action" "$subject" "$exit_code" "$log_file"
    return 1
}
