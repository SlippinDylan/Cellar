# install.sh
# Sourced by main.sh; not meant to be executed directly.

install_package_with_retries() {
    local package="$1"
    local logs_dir="$2"
    local status_dir="$3"
    local retry_count=0
    local success="0"
    local log_file="$logs_dir/${package}.log"
    local status_file="$status_dir/${package}.status"

    if brew list --cask "$package" >/dev/null 2>&1; then
        print_status_message "ok" "$package 已安装，跳过"
        printf "already-installed\n" >"$status_file"
        return 0
    fi

    while [ "$retry_count" -le "$INSTALL_MAX_RETRIES" ] && [ "$success" != "1" ]; do
        if [ "$retry_count" -gt 0 ]; then
            print_status_message "warn" "重试安装 ${package}（第 $retry_count 次）"
            sleep 3
        else
            print_status_message "info" "开始安装 $package"
        fi

        if brew install --cask "$package" >"$log_file" 2>&1; then
            print_status_message "ok" "$package 安装成功"
            success="1"
            break
        fi

        if brew list --cask "$package" >/dev/null 2>&1; then
            print_status_message "ok" "$package 已处于安装状态"
            success="1"
            break
        fi

        retry_count=$((retry_count + 1))
    done

    if [ "$success" = "1" ]; then
        if grep -qi "already installed" "$log_file" 2>/dev/null; then
            printf "already-installed\n" >"$status_file"
        else
            printf "installed\n" >"$status_file"
        fi
        return 0
    fi

    print_status_message "err" "$package 安装失败（已重试 $INSTALL_MAX_RETRIES 次）"
    printf "failed\n" >"$status_file"
    return 1
}


install_packages_serially() {
    local logs_dir="$1"
    local status_dir="$2"
    local package=""

    for package in "${INSTALLABLE_CASKS[@]+"${INSTALLABLE_CASKS[@]}"}"; do
        [ -n "$package" ] || continue
        install_package_with_retries "$package" "$logs_dir" "$status_dir"
    done
}


build_install_parallel_command() {
    local logs_dir="$1"
    local status_dir="$2"
    local package=""
    local command_script=""
    local escaped_script_path=""
    local escaped_package=""
    local escaped_logs_dir=""
    local escaped_status_dir=""

    printf -v escaped_script_path '%q' "$MANAGER_SCRIPT_PATH"
    printf -v escaped_logs_dir '%q' "$logs_dir"
    printf -v escaped_status_dir '%q' "$status_dir"

    for package in "${INSTALLABLE_CASKS[@]+"${INSTALLABLE_CASKS[@]}"}"; do
        [ -n "$package" ] || continue
        printf -v escaped_package '%q' "$package"
        command_script="${command_script}bash -c 'source $escaped_script_path && install_package_with_retries $escaped_package $escaped_logs_dir $escaped_status_dir'"$'\n'
    done

    printf "%s" "$command_script"
}


install_packages_with_parallel() {
    local logs_dir="$1"
    local status_dir="$2"
    local command_script=""

    command_script="$(build_install_parallel_command "$logs_dir" "$status_dir")"
    if [ -z "$command_script" ]; then
        return 0
    fi

    printf "%s" "$command_script" | parallel -j "$INSTALL_PARALLEL_JOBS"
}


print_installation_summary() {
    local logs_dir="$1"
    local status_dir="$2"
    local executor_status="${3:-0}"
    local total="${#INSTALLABLE_CASKS[@]}"
    local installed_count=0
    local already_installed_count=0
    local failed_count=0
    local unknown_count=0
    local package=""
    local package_status=""
    local status_file=""
    local failed_packages=()
    local unknown_packages=()

    for package in "${INSTALLABLE_CASKS[@]+"${INSTALLABLE_CASKS[@]}"}"; do
        [ -n "$package" ] || continue
        status_file="$status_dir/${package}.status"
        if [ ! -f "$status_file" ]; then
            unknown_count=$((unknown_count + 1))
            unknown_packages+=("$package")
            continue
        fi

        package_status="$(head -n 1 "$status_file" 2>/dev/null || true)"
        case "$package_status" in
            installed)
                installed_count=$((installed_count + 1))
                ;;
            already-installed)
                already_installed_count=$((already_installed_count + 1))
                ;;
            failed)
                failed_count=$((failed_count + 1))
                failed_packages+=("$package")
                ;;
            *)
                unknown_count=$((unknown_count + 1))
                unknown_packages+=("$package")
                ;;
        esac
    done

    print_page_title "安装项目总结"
    print_message "计划安装数量：$total"
    print_message "新安装数量：$installed_count"
    print_message "已满足数量：$already_installed_count"
    print_message "安装失败数量：$failed_count"
    print_message "结果未知数量：$unknown_count"
    print_message "日志目录：$logs_dir"

    if [ "$executor_status" -ne 0 ]; then
        print_status_message "warn" "安装执行器返回非零状态，部分 worker 可能在写入结果前异常退出。"
    fi

    if [ "$failed_count" -gt 0 ]; then
        print_message "安装失败项目："
        for package in "${failed_packages[@]+"${failed_packages[@]}"}"; do
            print_message "- ${package}（日志：$logs_dir/$package.log）"
        done
    fi

    if [ "$unknown_count" -gt 0 ]; then
        print_message "结果未知项目："
        for package in "${unknown_packages[@]+"${unknown_packages[@]}"}"; do
            print_message "- ${package}（日志：$logs_dir/$package.log）"
        done
    fi
}


run_install_flow() {
    if ! require_homebrew_for_feature "安装项目"; then
        return 0
    fi

    local logs_dir=""
    local status_dir=""
    local total="${#INSTALLABLE_CASKS[@]}"
    local executor_status=0

    print_page_title "安装项目"
    print_message "将按内置清单安装以下 Homebrew cask 项目："
    print_compact_value_list "待安装项目：" "${INSTALLABLE_CASKS[@]+"${INSTALLABLE_CASKS[@]}"}"
    print_message "计划安装数量：$total"
    if command_exists parallel; then
        print_message "执行模式：并行安装（$INSTALL_PARALLEL_JOBS 个任务）"
    else
        print_message "执行模式：串行安装（未检测到 parallel）"
    fi
    print_message "失败重试次数：$INSTALL_MAX_RETRIES"

    if ! prompt_yes_no "是否继续安装这些项目？" "n"; then
        print_message "已取消安装。"
        return 0
    fi

    if ! logs_dir="$(mktemp -d "${TMPDIR:-/tmp}/brew-app-manager-install.XXXXXX")"; then
        print_status_message "err" "未能创建安装日志目录，已取消安装。"
        return 1
    fi
    status_dir="$logs_dir/status"
    if ! mkdir -p "$status_dir"; then
        print_status_message "err" "未能创建安装状态目录，已取消安装。"
        rmdir "$logs_dir" >/dev/null 2>&1 || true
        return 1
    fi

    print_output_boundary "开始执行安装"
    if command_exists parallel; then
        install_packages_with_parallel "$logs_dir" "$status_dir"
        executor_status="$?"
    else
        install_packages_serially "$logs_dir" "$status_dir"
        executor_status="$?"
    fi
    print_output_boundary "安装执行结束"

    print_installation_summary "$logs_dir" "$status_dir" "$executor_status"
}

