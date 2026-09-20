# shellcheck shell=bash

render_shell_plan_json() {
    local action="${1:-}"
    local subject="${2:-}"
    local executable=true
    local blocked_reason=""
    local target_path=""
    local token=""

    case "$action" in
        install-omz)
            target_path="$OMZ_DIR"
            if [ -d "$OMZ_DIR" ]; then executable=false; blocked_reason="already-installed"
            elif [ -e "$OMZ_DIR" ]; then executable=false; blocked_reason="target-path-exists"; fi
            ;;
        install-plugin)
            validate_plugin_url "$subject" || {
                printf '{"code":"invalid-plugin-url"}'
                return 1
            }
            local plugin_name=""
            plugin_name="$(derive_plugin_name_from_url "$subject")"
            target_path="$CUSTOM_PLUGINS_DIR/$plugin_name"
            if [ ! -d "$OMZ_DIR" ]; then executable=false; blocked_reason="oh-my-zsh-not-installed"
            elif [ -e "$target_path" ]; then executable=false; blocked_reason="plugin-destination-exists"; fi
            ;;
        set-plugins)
            validate_plugin_list "$subject" || {
                printf '{"code":"invalid-plugin-selection"}'
                return 1
            }
            target_path="$ZSHRC_PATH"
            ;;
        switch-theme)
            validate_simple_name "$subject" || {
                printf '{"code":"invalid-theme-name"}'
                return 1
            }
            target_path="$OMZ_DIR/themes/$subject.zsh-theme"
            if [ ! -f "$target_path" ]; then executable=false; blocked_reason="theme-not-installed"; fi
            ;;
        tidy)
            subject="zsh-files"
            target_path="$ZSH_TIDY_DIR"
            ;;
        *)
            printf '{"code":"unsupported-action"}'
            return 1
            ;;
    esac

    case "$action" in
        install-plugin|set-plugins|switch-theme|tidy)
            if [ -L "$ZSHRC_PATH" ]; then
                executable=false
                blocked_reason="zshrc-is-symlink"
            elif [ -e "$ZSHRC_PATH" ] && [ ! -f "$ZSHRC_PATH" ]; then
                executable=false
                blocked_reason="zshrc-not-regular-file"
            fi
            ;;
    esac

    token="$(config_fingerprint "$action" "$subject")" || {
        printf '{"code":"plan-fingerprint-unavailable"}'
        return 1
    }
    printf '{"action":"%s","subject":"%s","targetPath":"%s","requiresConfirmation":true,"executable":%s,"blockedReason":"%s","planToken":"%s","generatedAt":%s}' \
        "$(json_escape "$action")" "$(json_escape "$subject")" "$(json_escape "$target_path")" \
        "$executable" "$(json_escape "$blocked_reason")" "$(json_escape "$token")" "$(date '+%s')"
}
