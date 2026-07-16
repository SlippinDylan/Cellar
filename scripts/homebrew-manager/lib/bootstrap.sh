# bootstrap.sh
# Sourced by main.sh; not meant to be executed directly.

resolve_homebrew_binary_path() {
    local candidate=""

    if command_exists brew; then
        command -v brew
        return 0
    fi

    for candidate in \
        /opt/homebrew/bin/brew \
        /usr/local/bin/brew
    do
        if [ -x "$candidate" ]; then
            printf "%s" "$candidate"
            return 0
        fi
    done

    return 1
}


is_homebrew_installed() {
    resolve_homebrew_binary_path >/dev/null 2>&1
}


initialize_homebrew_shellenv() {
    local brew_bin=""
    local shellenv_output=""

    if ! brew_bin="$(resolve_homebrew_binary_path 2>/dev/null)"; then
        return 1
    fi

    shellenv_output="$(env SHELL=/bin/bash "$brew_bin" shellenv 2>/dev/null)" || return 1

    if [ -n "$shellenv_output" ]; then
        eval "$shellenv_output" || return 1
    fi

    command_exists brew || return 1
    return 0
}


current_login_shell_name() {
    local shell_path="${SHELL:-}"

    shell_path="${shell_path##*/}"
    printf "%s" "$shell_path"
}


homebrew_shellenv_line() {
    local brew_bin=""

    if ! brew_bin="$(resolve_homebrew_binary_path 2>/dev/null)"; then
        return 1
    fi
    [ -n "$brew_bin" ] || return 1

    printf 'eval "$(%s shellenv)"' "$brew_bin"
}


file_contains_exact_line() {
    local file_path="$1"
    local expected_line="$2"

    [ -f "$file_path" ] || return 1
    grep -Fqx "$expected_line" "$file_path" 2>/dev/null
}


ensure_file_ends_with_newline() {
    local file_path="$1"
    local last_byte_hex=""

    [ -f "$file_path" ] || return 1
    [ -s "$file_path" ] || return 0

    last_byte_hex="$(tail -c 1 "$file_path" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')"
    [ -n "$last_byte_hex" ] || return 1

    if [ "$last_byte_hex" != "0a" ]; then
        printf "\n" >>"$file_path" || return 1
    fi

    return 0
}


persist_homebrew_shellenv_to_zprofile() {
    local profile_path="$HOME/.zprofile"
    local shellenv_line=""

    if ! shellenv_line="$(homebrew_shellenv_line 2>/dev/null)"; then
        return 1
    fi

    if file_contains_exact_line "$profile_path" "$shellenv_line"; then
        return 2
    fi

    if ! prompt_yes_no "是否将 Homebrew 环境写入 ~/.zprofile，以便以后打开终端即可直接使用 brew？" "y"; then
        return 10
    fi

    if [ ! -e "$profile_path" ] && ! : >"$profile_path"; then
        return 1
    fi

    ensure_file_ends_with_newline "$profile_path" || return 1

    if ! printf "%s\n" "$shellenv_line" >>"$profile_path"; then
        return 1
    fi

    initialize_homebrew_shellenv || return 1
    return 0
}


configure_homebrew_shellenv_persistence() {
    if [ "$(current_login_shell_name)" != "zsh" ]; then
        return 11
    fi

    persist_homebrew_shellenv_to_zprofile
}


ensure_homebrew_available() {
    if ! is_homebrew_installed; then
        print_message "未检测到 Homebrew，或 PATH 中找不到 brew。"
        return 1
    fi

    if initialize_homebrew_shellenv; then
        return 0
    fi

    print_message "已检测到 Homebrew 二进制，但当前 shell 无法初始化 Homebrew 环境。"
    print_message "请检查 brew shellenv 是否可正常执行。"
    return 1
}


require_homebrew_for_feature() {
    local feature_name="$1"

    if ensure_homebrew_available; then
        return 0
    fi

    print_status_message "warn" "当前 Homebrew 不可用，无法执行「${feature_name}」。"
    print_message "请先进入「环境与依赖」检查或安装 Homebrew。"
    return 1
}


is_xcode_command_line_tools_installed() {
    xcode-select -p >/dev/null 2>&1
}


run_install_xcode_command_line_tools_flow() {
    print_page_title "安装 Xcode Command Line Tools"

    if is_xcode_command_line_tools_installed; then
        print_status_message "ok" "已检测到 Xcode Command Line Tools。"
        return 0
    fi

    print_status_message "info" "当前未检测到 Xcode Command Line Tools。"
    print_message "将调用系统安装器：xcode-select --install"

    if ! prompt_yes_no "是否继续唤起系统安装器？" "n"; then
        print_status_message "skip" "已取消安装 Xcode Command Line Tools。"
        return 1
    fi

    if ! xcode-select --install >/dev/null 2>&1; then
        print_status_message "err" "未能成功发起 Xcode Command Line Tools 系统安装器。"
        print_message "请手动执行 xcode-select --install，或检查当前系统是否禁止重复发起安装。"
        return 1
    fi
    print_status_message "info" "系统安装器已发起，请在弹出的窗口中完成安装。"

    while ! is_xcode_command_line_tools_installed; do
        if ! prompt_yes_no "安装完成后是否立即重新检测？选择 n 返回。" "y"; then
            print_status_message "skip" "尚未完成 Xcode Command Line Tools 安装。"
            return 1
        fi

        if ! is_xcode_command_line_tools_installed; then
            print_status_message "warn" "尚未检测到 Xcode Command Line Tools，请先完成系统安装。"
        fi
    done

    print_status_message "ok" "已检测到 Xcode Command Line Tools。"
    return 0
}


run_install_homebrew_flow() {
    local install_status="failed"
    local install_script_path=""
    local version_line=""
    local shellenv_line=""
    local shell_name=""
    local shellenv_config_status=1

    print_page_title "安装 Homebrew"

    if is_homebrew_installed; then
        if initialize_homebrew_shellenv; then
            print_status_message "ok" "已检测到 Homebrew。"
            if command_exists brew; then
                print_message "$(brew --version | head -n 1)"
            fi
        else
            print_status_message "warn" "已检测到 Homebrew 二进制，但当前 shell 无法初始化 Homebrew 环境。"
            print_message "请先确认 brew shellenv 可正常执行，再决定是否重新安装。"
        fi
        return 0
    fi

    print_status_message "info" "当前未检测到 Homebrew。"

    if ! is_xcode_command_line_tools_installed; then
        print_status_message "warn" "安装 Homebrew 前需要先安装 Xcode Command Line Tools。"
        if ! prompt_yes_no "是否先安装 Xcode Command Line Tools？" "y"; then
            print_status_message "skip" "已取消安装 Homebrew。"
            return 0
        fi

        if ! run_install_xcode_command_line_tools_flow; then
            print_status_message "warn" "尚未完成 Xcode Command Line Tools 安装，暂不继续安装 Homebrew。"
            return 0
        fi

        if ! prompt_yes_no "Xcode Command Line Tools 已就绪，是否继续安装 Homebrew？" "n"; then
            print_status_message "skip" "已取消安装 Homebrew。"
            return 0
        fi
    else
        if ! prompt_yes_no "是否继续安装 Homebrew？" "n"; then
            print_status_message "skip" "已取消安装 Homebrew。"
            return 0
        fi
    fi

    if ! install_script_path="$(mktemp "${TMPDIR:-/tmp}/brew-install-script.XXXXXX")"; then
        print_status_message "err" "未能创建 Homebrew 安装脚本临时文件，已取消安装。"
        return 1
    fi
    print_message "安装脚本来源：$HOMEBREW_INSTALL_SCRIPT_URL"
    print_message "已钉住 Homebrew/install 提交：$HOMEBREW_INSTALL_SCRIPT_REF"
    print_output_boundary "开始执行 Homebrew 官方安装脚本"
    if curl -fsSL "$HOMEBREW_INSTALL_SCRIPT_URL" -o "$install_script_path" && /bin/bash "$install_script_path"; then
        install_status="success"
        initialize_homebrew_shellenv || true
    fi
    print_output_boundary "Homebrew 官方安装脚本执行结束"
    rm -f "$install_script_path"

    print_page_title "安装 Homebrew 总结"
    if [ "$install_status" = "success" ] && ensure_homebrew_available; then
        version_line="$(brew --version | head -n 1 2>/dev/null || true)"
        shell_name="$(current_login_shell_name)"
        shellenv_line="$(homebrew_shellenv_line 2>/dev/null || true)"
        configure_homebrew_shellenv_persistence
        shellenv_config_status="$?"

        print_status_message "ok" "Homebrew 安装完成。"
        if [ -n "$version_line" ]; then
            print_message "版本：$version_line"
        fi

        case "$shellenv_config_status" in
            0)
                print_status_message "ok" "Homebrew 环境已配置完成。以后重新打开终端即可直接使用 brew。"
                ;;
            2)
                print_status_message "ok" "Homebrew 环境已配置完成。当前 ~/.zprofile 已包含 shellenv 设置。"
                ;;
            10)
                print_status_message "warn" "Homebrew 已安装完成，但你选择了不写入 ~/.zprofile。当前仅保证本次脚本会话可用。"
                ;;
            11)
                print_status_message "info" "Homebrew 已安装完成。当前默认 shell 不是 zsh，脚本未自动修改 shell 配置。"
                if [ -n "$shellenv_line" ]; then
                    print_message "如需持久化 Homebrew 环境，请将下面这行加入你的 ${shell_name:-当前} 登录配置文件："
                    print_message "$shellenv_line"
                fi
                ;;
            *)
                print_status_message "warn" "Homebrew 已安装完成，但未能完成 shell 环境持久化配置。"
                if [ -n "$shellenv_line" ]; then
                    print_message "你可以手动将下面这行加入 ~/.zprofile："
                    print_message "$shellenv_line"
                fi
                ;;
        esac

        if [ "$shellenv_config_status" -eq 0 ] || [ "$shellenv_config_status" -eq 2 ]; then
            print_message "当前会话与后续新的 zsh 终端都可以直接使用 brew。"
        fi
    else
        print_status_message "err" "Homebrew 安装失败，或当前 shell 尚未加载 Homebrew 环境。"
        print_message "如安装已成功，请重新打开终端后再执行脚本。"
    fi
}


run_environment_menu() {
    local choice=""
    local action=""

    while true; do
        print_page_title "环境与依赖"
        printf "%s\n" "$(render_environment_menu)"
        printf "请输入序号（b 返回）: "
        if ! read -r choice; then
            return 0
        fi

        action="$(dispatch_environment_choice "$choice")"
        case "$action" in
            cleanup)
                run_cleanup_flow
                pause_before_return
                ;;
            install-clt)
                run_install_xcode_command_line_tools_flow
                pause_before_return
                ;;
            install-homebrew)
                run_install_homebrew_flow
                pause_before_return
                ;;
            back)
                return 0
                ;;
            *)
                print_status_message "warn" "输入无效，请输入 1、2、3 或 b。"
                pause_before_return
                ;;
        esac
    done
}

