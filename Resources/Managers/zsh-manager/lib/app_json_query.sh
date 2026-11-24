# shellcheck shell=bash

render_shell_snapshot_json() {
    local installed_plugins=""
    local active_plugins=""
    local themes=""

    collect_installed_custom_plugins >/dev/null 2>&1 || INSTALLED_CUSTOM_PLUGINS=()
    installed_plugins="$(printf '%s\n' "${INSTALLED_CUSTOM_PLUGINS[@]+"${INSTALLED_CUSTOM_PLUGINS[@]}"}" | json_string_array_from_lines)"
    active_plugins="$(get_active_plugins_string | tr ' ' '\n' | json_string_array_from_lines)"
    themes="$({
        for dir in "$OMZ_DIR/themes" "$OMZ_DIR/custom/themes"; do
            [ -d "$dir" ] || continue
            find "$dir" -maxdepth 1 \( -type f -o -type l \) -name '*.zsh-theme' -print 2>/dev/null \
                | while IFS= read -r file; do
                    [ -f "$file" ] || continue
                    basename "$file" .zsh-theme
                done
        done
    } | LC_ALL=C sort -u | json_string_array_from_lines)"

    printf '{'
    printf '"zshVersion":"%s",' "$(json_escape "$(/bin/zsh --version 2>/dev/null || true)")"
    printf '"ohMyZshInstalled":%s,' "$([ -d "$OMZ_DIR" ] && printf true || printf false)"
    printf '"ohMyZshPath":"%s",' "$(json_escape "$OMZ_DIR")"
    printf '"zshrcPath":"%s",' "$(json_escape "$ZSHRC_PATH")"
    printf '"zshrcExists":%s,' "$([ -f "$ZSHRC_PATH" ] && printf true || printf false)"
    printf '"currentTheme":"%s",' "$(json_escape "$(get_current_theme)")"
    printf '"activePlugins":%s,' "$active_plugins"
    printf '"installedCustomPlugins":%s,' "$installed_plugins"
    printf '"availableThemes":%s,' "$themes"
    printf '"defaultPluginNames":[],'
    printf '"runtimeDirectory":"%s"' "$(json_escape "$(shell_manager_runtime_dir)")"
    printf '}'
}
