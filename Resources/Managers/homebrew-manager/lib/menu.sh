# menu.sh
# Sourced by main.sh; not meant to be executed directly.

render_main_menu() {
    cat <<'EOF'
1) 安装项目
2) 卸载项目
3) 更新与升级
4) Tap 管理
5) 环境与依赖
q) 退出
EOF
}


render_uninstall_menu() {
    cat <<'EOF'
1) Formula
2) Cask
b) 返回上一级
EOF
}


render_cleanup_plan() {
    cat <<'EOF'
brew cleanup --prune=all
brew cleanup
brew autoremove
brew services cleanup
EOF
}


render_tap_menu() {
    cat <<'EOF'
1) 添加 Tap
2) 删除 Tap
b) 返回上一级
EOF
}


render_update_menu() {
    cat <<'EOF'
1) 更新 Homebrew
2) 更新已安装项目
b) 返回上一级
EOF
}


render_environment_menu() {
    cat <<'EOF'
1) 清理 Homebrew 环境
2) 安装 Xcode Command Line Tools
3) 安装 Homebrew
b) 返回上一级
EOF
}


should_exit_menu() {
    local menu_name="$1"
    local choice="$2"

    if [ "$menu_name" = "main" ] && { [ "$choice" = "q" ] || [ "$choice" = "Q" ]; }; then
        echo "1"
        return 0
    fi

    echo "0"
}


dispatch_main_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "install" ;;
        2) echo "uninstall" ;;
        3) echo "update" ;;
        4) echo "tap-management" ;;
        5) echo "environment" ;;
        *) echo "back" ;;
    esac
}


dispatch_uninstall_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "formula" ;;
        2) echo "cask" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}


dispatch_tap_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "add" ;;
        2) echo "remove" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}


dispatch_update_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "update-homebrew" ;;
        2) echo "update-projects" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}


dispatch_environment_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "cleanup" ;;
        2) echo "install-clt" ;;
        3) echo "install-homebrew" ;;
        b|B) echo "back" ;;
        *) echo "invalid" ;;
    esac
}


parse_numeric_choice() {
    local choice="$1"
    local max_index="$2"

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        echo "back"
        return 0
    fi

    case "$choice" in
        ''|*[!0-9]*)
            echo "invalid"
            return 0
            ;;
    esac

    if [ "$choice" -ge 1 ] && [ "$choice" -le "$max_index" ]; then
        echo "$choice"
        return 0
    fi

    echo "invalid"
}


parse_multi_numeric_choice() {
    local choice="$1"
    local max_index="$2"
    local token=""
    local normalized=""
    local noglob_was_set="0"

    choice="$(trim_whitespace "$choice")"

    if [ "$choice" = "b" ] || [ "$choice" = "B" ]; then
        echo "back"
        return 0
    fi

    if [ "$choice" = "all" ] || [ "$choice" = "ALL" ]; then
        echo "all"
        return 0
    fi

    case "$-" in
        *f*) noglob_was_set="1" ;;
    esac
    set -f
    for token in $choice; do
        case "$token" in
            ''|*[!0-9]*)
                if [ "$noglob_was_set" != "1" ]; then
                    set +f
                fi
                echo "invalid"
                return 0
                ;;
        esac

        if [ "$token" -lt 1 ] || [ "$token" -gt "$max_index" ]; then
            if [ "$noglob_was_set" != "1" ]; then
                set +f
            fi
            echo "invalid"
            return 0
        fi

        case " $normalized " in
            *" $token "*) ;;
            *)
                normalized="${normalized:+$normalized }$token"
                ;;
        esac
    done
    if [ "$noglob_was_set" != "1" ]; then
        set +f
    fi

    if [ -z "$normalized" ]; then
        echo "invalid"
        return 0
    fi

    echo "$normalized"
}


prompt_for_multi_selection() {
    local title="$1"
    local prompt="$2"
    shift 2
    local items=("$@")
    local choice=""
    local parsed_choice=""

    PROMPT_MULTI_SELECT_RESULT=""

    while true; do
        print_page_title "$title"
        print_multi_select_hint
        render_numbered_list "selection" "${items[@]+"${items[@]}"}"
        print_blank_line
        printf "%s" "$prompt"
        if ! read -r choice; then
            PROMPT_MULTI_SELECT_RESULT="back"
            return 0
        fi

        parsed_choice="$(parse_multi_numeric_choice "$choice" "${#items[@]}")"
        case "$parsed_choice" in
            invalid)
                print_status_message "warn" "输入无效，请输入 all、空格分隔序号或 b。"
                pause_before_return
                ;;
            *)
                PROMPT_MULTI_SELECT_RESULT="$parsed_choice"
                return 0
                ;;
        esac
    done
}


populate_array_from_selection() {
    local array_name="$1"
    local parsed_choice="$2"
    shift 2
    local items=("$@")
    local token=""
    local index=0
    local item=""

    if ! reset_named_array "$array_name"; then
        return 1
    fi

    if [ "$parsed_choice" = "all" ]; then
        for item in "${items[@]+"${items[@]}"}"; do
            append_to_array "$array_name" "$item"
        done
        return 0
    fi

    for token in $parsed_choice; do
        index=$((token - 1))
        append_to_array "$array_name" "${items[$index]}"
    done
}

