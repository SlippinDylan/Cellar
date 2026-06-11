#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")/../.." && pwd)"
source "$script_dir/brew-app-manager.sh"

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $message"
        echo "expected: $expected"
        echo "actual:   $actual"
        exit 1
    fi
}

run_test_case() {
    local test_name="$1"

    if ! ("$test_name"); then
        echo "FAIL: $test_name"
        exit 1
    fi
}

test_main_menu_labels() {
    local output
    output="$(render_main_menu)"

    assert_equal "1) 安装项目
2) 卸载项目
3) 更新与升级
4) Tap 管理
5) 环境与依赖
q) 退出" "$output" "main menu should expose the top-level actions"
}

test_uninstall_menu_labels() {
    local output
    output="$(render_uninstall_menu)"

    assert_equal "1) Formula
2) Cask
b) 返回上一级" "$output" "uninstall menu should expose formula, cask, and back"
}

test_tap_menu_labels() {
    local output
    output="$(render_tap_menu)"

    assert_equal "1) 添加 Tap
2) 删除 Tap
b) 返回上一级" "$output" "tap menu should expose add, remove, and back"
}

test_update_menu_labels() {
    local output
    output="$(render_update_menu)"

    assert_equal "1) 更新 Homebrew
2) 更新已安装项目
b) 返回上一级" "$output" "update menu should expose update-homebrew, update-projects, and back"
}

test_environment_menu_labels() {
    local output
    output="$(render_environment_menu)"

    assert_equal "1) 清理 Homebrew 环境
2) 安装 Xcode Command Line Tools
3) 安装 Homebrew
b) 返回上一级" "$output" "environment menu should expose cleanup and bootstrap actions"
}

test_should_exit_only_at_top_level() {
    assert_equal "1" "$(should_exit_menu main q)" "top-level q should exit"
    assert_equal "0" "$(should_exit_menu uninstall b)" "submenu b should return, not exit"
}

test_dispatch_main_action() {
    assert_equal "install" "$(dispatch_main_choice 1)" "choice 1 should dispatch install"
    assert_equal "uninstall" "$(dispatch_main_choice 2)" "choice 2 should dispatch uninstall"
    assert_equal "update" "$(dispatch_main_choice 3)" "choice 3 should dispatch the update submenu"
    assert_equal "tap-management" "$(dispatch_main_choice 4)" "choice 4 should dispatch tap management"
    assert_equal "environment" "$(dispatch_main_choice 5)" "choice 5 should dispatch environment utilities"
    assert_equal "back" "$(dispatch_main_choice 9)" "unknown choice should not exit"
}

test_dispatch_tap_action() {
    assert_equal "add" "$(dispatch_tap_choice 1)" "choice 1 should dispatch tap add"
    assert_equal "remove" "$(dispatch_tap_choice 2)" "choice 2 should dispatch tap removal"
    assert_equal "back" "$(dispatch_tap_choice b)" "b should return to the parent menu"
    assert_equal "invalid" "$(dispatch_tap_choice 9)" "unknown choice should be rejected"
}

test_dispatch_update_action() {
    assert_equal "update-homebrew" "$(dispatch_update_choice 1)" "choice 1 should dispatch Homebrew self-update"
    assert_equal "update-projects" "$(dispatch_update_choice 2)" "choice 2 should dispatch installed-project upgrades"
    assert_equal "back" "$(dispatch_update_choice b)" "b should return to the parent menu"
    assert_equal "invalid" "$(dispatch_update_choice 9)" "unknown choice should be rejected"
}

test_dispatch_environment_action() {
    assert_equal "cleanup" "$(dispatch_environment_choice 1)" "choice 1 should dispatch Homebrew cleanup"
    assert_equal "install-clt" "$(dispatch_environment_choice 2)" "choice 2 should dispatch Xcode Command Line Tools install"
    assert_equal "install-homebrew" "$(dispatch_environment_choice 3)" "choice 3 should dispatch Homebrew install"
    assert_equal "back" "$(dispatch_environment_choice b)" "b should return to the parent menu"
    assert_equal "invalid" "$(dispatch_environment_choice 9)" "unknown choice should be rejected"
}

test_render_inventory_lines() {
    local rendered
    rendered="$(render_numbered_list "formula" "wget" "htop" "jq")"

    assert_equal "1) wget
2) htop
3) jq
b) 返回上一级" "$rendered" "inventory renderer should print all items and the back option"
}

test_parse_numeric_choice() {
    assert_equal "2" "$(parse_numeric_choice 2 3)" "valid choice should be returned"
    assert_equal "invalid" "$(parse_numeric_choice 4 3)" "out-of-range choice should be rejected"
    assert_equal "back" "$(parse_numeric_choice b 3)" "b should return to the parent menu"
}

test_parse_multi_numeric_choice() {
    assert_equal "all" "$(parse_multi_numeric_choice all 5)" "all should select every updatable item"
    assert_equal "1 3 5" "$(parse_multi_numeric_choice '1 3 5' 5)" "space-separated indexes should be normalized"
    assert_equal "1 3" "$(parse_multi_numeric_choice '1 3 1' 5)" "duplicate indexes should be collapsed"
    assert_equal "back" "$(parse_multi_numeric_choice b 5)" "b should return to the previous menu"
    assert_equal "invalid" "$(parse_multi_numeric_choice '1 x' 5)" "mixed invalid tokens should be rejected"
    assert_equal "invalid" "$(parse_multi_numeric_choice '1 *' 5)" "glob characters should not expand into filesystem entries"
}

test_populate_array_from_selection() {
    local selected=()

    populate_array_from_selection selected "2 3" "alpha" "beta" "gamma"
    assert_equal "beta
gamma" "$(printf "%s\n" "${selected[@]}")" "selection helper should resolve explicit indexes"

    populate_array_from_selection selected "all" "alpha" "beta"
    assert_equal "alpha
beta" "$(printf "%s\n" "${selected[@]}")" "selection helper should expand all entries"
}

test_build_typed_display_items() {
    local display_items=()

    build_typed_display_items display_items "formula:llmfit" "cask:cc-switch"

    assert_equal "llmfit [formula]
cc-switch [cask]" "$(printf "%s\n" "${display_items[@]}")" "typed display helper should annotate visible labels"
}

test_describe_tap_associated_cask_state() {
    find_cask_install_receipts() {
        printf "/tmp/vibebar-receipt.json\n"
    }

    load_cask_app_name_from_receipt() {
        printf "VibeBar"
    }

    find_app_bundle_path() {
        return 1
    }

    brew() {
        return 1
    }

    caskroom_entry_exists() {
        return 0
    }

    assert_equal "仅 Homebrew 记录 / Caskroom 残留" "$(describe_tap_associated_cask_state "vibebar")" "tap cask state should explain when only Homebrew record and Caskroom residue remain"

    source "$script_dir/brew-app-manager.sh"
}

test_describe_tap_associated_cask_state_reports_scan_failure_when_receipt_discovery_fails() {
    find_cask_install_receipts() {
        return 1
    }

    assert_equal "1" "$(describe_tap_associated_cask_state "vibebar" >/dev/null; printf "%s" "$?")" "tap cask state should fail closed when receipt discovery fails"
    assert_equal "扫描失败" "$(describe_tap_associated_cask_state "vibebar" 2>/dev/null || true)" "tap cask state should surface scan failure instead of pretending only Homebrew records remain"

    source "$script_dir/brew-app-manager.sh"
}

test_load_cask_app_name_from_receipt_uses_structured_parser() {
    local receipt_path=""

    receipt_path="$(mktemp "/tmp/brew-app-manager-receipt.XXXXXX")"
    printf '{"uninstall_artifacts":[{"dummy":["ignored"]},{"app":["ChatGPT Atlas.app"]}]}\n' >"$receipt_path"

    assert_equal "ChatGPT Atlas" "$(load_cask_app_name_from_receipt "$receipt_path")" "receipt app name loader should parse uninstall_artifacts structurally"

    rm -f "$receipt_path"
}

test_extract_tap_from_install_receipt_uses_structured_parser() {
    local receipt_path=""

    receipt_path="$(mktemp "/tmp/brew-app-manager-receipt.XXXXXX")"
    printf '{"installed_on_request":true,"tap":"farion1231/ccswitch","version":"1.0"}\n' >"$receipt_path"

    assert_equal "farion1231/ccswitch" "$(extract_tap_from_install_receipt "$receipt_path")" "tap extraction should read the structured receipt field instead of relying on line-oriented regex parsing"

    rm -f "$receipt_path"
}

test_build_tap_association_display_items() {
    describe_tap_associated_cask_state() {
        printf "仅 Homebrew 记录 / Caskroom 残留"
    }

    local display_items=()
    build_tap_association_display_items display_items "formula:llmfit" "cask:vibebar"

    assert_equal "llmfit [formula]
vibebar [cask, 仅 Homebrew 记录 / Caskroom 残留]" "$(printf "%s\n" "${display_items[@]}")" "tap association display items should include cask state annotations"

    source "$script_dir/brew-app-manager.sh"
}

test_run_install_flow_prints_installable_catalog_before_confirmation() {
    local output=""

    require_homebrew_for_feature() {
        return 0
    }

    print_section_title() {
        output="${output}TITLE:$1\n"
    }

    print_message() {
        output="${output}$1\n"
    }

    print_compact_value_list() {
        output="${output}$1\n$2\n"
    }

    command_exists() {
        [ "$1" = "parallel" ] && return 1
        return 0
    }

    prompt_yes_no() {
        return 1
    }

    run_install_flow

    printf "%b" "$output" | grep -F "待安装项目：" >/dev/null
    printf "%b" "$output" | grep -F "1password" >/dev/null

    source "$script_dir/brew-app-manager.sh"
}

test_run_install_flow_aborts_when_log_directory_creation_fails() {
    local output=""

    require_homebrew_for_feature() {
        return 0
    }

    prompt_yes_no() {
        return 0
    }

    mktemp() {
        return 1
    }

    print_section_title() {
        true
    }

    print_message() {
        true
    }

    print_compact_value_list() {
        true
    }

    print_output_boundary() {
        true
    }

    print_status_message() {
        output="${output}$2\n"
    }

    run_install_flow || true

    printf "%b" "$output" | grep -F "未能创建安装日志目录，已取消安装。" >/dev/null

    source "$script_dir/brew-app-manager.sh"
}

test_prompt_for_multi_selection_sets_result() {

    print_section_title() {
        printf "TITLE:%s\n" "$1"
    }

    print_multi_select_hint() {
        printf "HINT\n"
    }

    render_numbered_list() {
        printf "1) alpha\nb) 返回上一级"
    }

    print_blank_line() {
        printf "\n"
    }

    prompt_for_multi_selection "选择项目" "请输入选择: " "alpha" <<'EOF'
b
EOF

    assert_equal "back" "$PROMPT_MULTI_SELECT_RESULT" "multi-select prompt should persist the parsed choice in the shared result variable"

    source "$script_dir/brew-app-manager.sh"
}

test_is_valid_tap_name() {
    assert_equal "0" "$(is_valid_tap_name "owner/repo"; printf "%s" "$?")" "tap names with owner/repo format should be accepted"
    assert_equal "1" "$(is_valid_tap_name "repo-only"; printf "%s" "$?")" "tap names without a slash should be rejected"
    assert_equal "1" "$(is_valid_tap_name "/"; printf "%s" "$?")" "bare slash should be rejected"
    assert_equal "1" "$(is_valid_tap_name "owner/repo/extra"; printf "%s" "$?")" "tap names with more than one slash should be rejected"
    assert_equal "1" "$(is_valid_tap_name "owner/"; printf "%s" "$?")" "tap names without a repo segment should be rejected"
    assert_equal "1" "$(is_valid_tap_name "owner//repo"; printf "%s" "$?")" "tap names with empty segments should be rejected"
}

test_collect_installed_items_for_tap() {
    load_formula_inventory() {
        printf "llmfit\nwget\n"
    }

    load_cask_inventory() {
        printf "cc-switch\nchatgpt\n"
    }

    formula_belongs_to_tap() {
        [ "$1" = "llmfit" ] && [ "$2" = "alexsjones/llmfit" ]
    }

    cask_belongs_to_tap() {
        [ "$1" = "cc-switch" ] && [ "$2" = "alexsjones/llmfit" ]
    }

    assert_equal "formula:llmfit
cask:cc-switch" "$(collect_installed_items_for_tap "alexsjones/llmfit")" "tap scan should combine matching formulas and casks"
}

test_collect_installed_items_for_tap_fails_closed_when_receipt_parse_fails() {
    load_formula_inventory() {
        printf "llmfit\n"
    }

    load_cask_inventory() {
        printf "cc-switch\n"
    }

    formula_belongs_to_tap() {
        return 2
    }

    cask_belongs_to_tap() {
        return 2
    }

    assert_equal "1" "$(collect_installed_items_for_tap "alexsjones/llmfit" >/dev/null; printf "%s" "$?")" "tap scan should fail closed when receipt parsing cannot determine tap ownership"
}

test_collect_installed_items_for_tap_fails_closed_when_formula_receipt_discovery_fails() {
    load_formula_inventory() {
        printf "llmfit\n"
    }

    load_cask_inventory() {
        true
    }

    brew() {
        case "$1 $2" in
            "--cellar llmfit")
                return 1
                ;;
        esac
        return 0
    }

    assert_equal "1" "$(collect_installed_items_for_tap "alexsjones/llmfit" >/dev/null; printf "%s" "$?")" "tap scan should fail closed when formula receipt discovery cannot query Homebrew"

    source "$script_dir/brew-app-manager.sh"
}

test_collect_installed_items_for_tap_fails_closed_when_cask_receipt_discovery_fails() {
    load_formula_inventory() {
        true
    }

    load_cask_inventory() {
        printf "cc-switch\n"
    }

    brew() {
        case "$1" in
            --prefix)
                return 1
                ;;
        esac
        return 0
    }

    assert_equal "1" "$(collect_installed_items_for_tap "alexsjones/llmfit" >/dev/null; printf "%s" "$?")" "tap scan should fail closed when cask receipt discovery cannot query Homebrew"

    source "$script_dir/brew-app-manager.sh"
}

test_read_command_output_into_array() {
    local items=()

    emit_sample_lines() {
        printf "alpha value\nbeta value\n"
    }

    read_command_output_into_array items emit_sample_lines

    assert_equal "2" "${#items[@]}" "read_command_output_into_array should preserve line count"
    assert_equal "alpha value
beta value" "$(printf "%s\n" "${items[@]}")" "read_command_output_into_array should preserve spaces in each line"
}

test_read_command_output_into_array_propagates_command_failure() {
    local items=()
    local status=0

    emit_failed_lines() {
        printf "partial value\n"
        return 23
    }

    if read_command_output_into_array items emit_failed_lines; then
        status=0
    else
        status="$?"
    fi

    assert_equal "23" "$status" "read_command_output_into_array should propagate producer exit status"
    assert_equal "1" "${#items[@]}" "read_command_output_into_array should still preserve captured lines on failure"
    assert_equal "partial value" "${items[0]}" "read_command_output_into_array should retain partial output for diagnostics"
}

test_render_entries_in_columns_column_major() {
    local rendered
    rendered="$(render_entries_in_columns 2 "1) a" "2) b" "3) c" "4) d" "5) e" "6) f")"

    assert_equal "1) a  4) d
2) b  5) e
3) c  6) f" "$rendered" "entries should render in column-major order from left to right, top to bottom"
}

test_calculate_column_count_caps_at_six() {
    assert_equal "6" "$(calculate_column_count 400 1 6 \
        "1) a" "2) b" "3) c" "4) d" "5) e" "6) f" "7) g" "8) h" "9) i")" \
        "adaptive column count should never exceed the configured maximum"
}

test_calculate_column_count_uses_two_columns_when_terminal_is_too_narrow_for_three() {
    assert_equal "2" "$(calculate_column_count 80 8 6 \
        "31) monitorcontrol" \
        "37) progressive-downloader" \
        "42) spotify" \
        "45) switchhosts" \
        "46) tailscale-app" \
        "55) visual-studio-code" \
        "58) wechatwebdevtools" \
        "61) zed")" \
        "inventory lists should drop to two columns when the longest entry prevents a third column from fitting"
}

test_get_terminal_width_prefers_live_terminal_measurement() {
    get_terminal_width_from_stty() {
        printf "120"
    }

    get_terminal_width_from_tput() {
        printf "90"
    }

    COLUMNS=80

    assert_equal "120" "$(get_terminal_width)" "live terminal width should win over stale inherited COLUMNS"
}

test_get_terminal_width_falls_back_cleanly() {
    get_terminal_width_from_stty() {
        return 1
    }

    get_terminal_width_from_tput() {
        return 1
    }

    unset COLUMNS

    assert_equal "80" "$(get_terminal_width)" "terminal width detection should fall back to 80 when no probe succeeds"
}

test_collect_disk_usage_summary() {
    disk_usage_kib_for_path() {
        case "$1" in
            /tmp/a) printf "1024" ;;
            /tmp/b) printf "2048" ;;
            /tmp/c) return 1 ;;
        esac
    }

    local summary
    summary="$(collect_disk_usage_summary /tmp/a /tmp/b /tmp/c)"

    assert_equal "count=3
total_kib=3072
unreadable=1" "$summary" "disk usage summary should accumulate total size and unreadable count"
}

test_print_candidate_list_with_no_items() {
    local output=""

    print_blank_line() {
        true
    }

    print_message() {
        output="${output}${1}
"
    }

    print_candidate_list "待清理候选项"

    assert_equal "待清理候选项
<none>
" "$output" "empty candidate lists should print only the title and <none>"
}

test_create_temp_cask_metadata_file() {
    mktemp() {
        printf "%s" "$1"
    }

    assert_equal "${TMPDIR:-/tmp}/brew-app-manager-cask.XXXXXX" "$(create_temp_cask_metadata_file)" "temporary cask metadata path should use a macOS-compatible mktemp template without a suffix after XXXXXX"

    unset -f mktemp
}

test_fetch_cask_metadata_json_fails_cleanly_when_temp_file_creation_fails() {
    local brew_info_called="0"

    create_temp_cask_metadata_file() {
        return 1
    }

    brew() {
        if [ "$1" = "info" ]; then
            brew_info_called="1"
        fi
        return 0
    }

    assert_equal "2" "$(fetch_cask_metadata_json "spotify" >/dev/null 2>&1; printf "%s" "$?")" "metadata fetch should expose temp-file creation failure distinctly"
    assert_equal "0" "$brew_info_called" "metadata fetch should stop before calling brew info when temp file creation fails"

    source "$script_dir/brew-app-manager.sh"
}

test_require_homebrew_for_feature_fails_when_shellenv_initialization_fails() {
    is_homebrew_installed() {
        return 0
    }

    ensure_homebrew_available() {
        return 1
    }

    print_status_message() {
        true
    }

    print_message() {
        true
    }

    assert_equal "1" "$(require_homebrew_for_feature "feature-test" >/dev/null; printf "%s" "$?")" "feature gate should fail closed when Homebrew shellenv cannot be initialized"
}

test_persist_homebrew_shellenv_to_zprofile_is_idempotent() {
    local temp_home=""
    local profile_path=""
    local line_count=""

    source "$script_dir/brew-app-manager.sh"
    temp_home="$(mktemp -d "/tmp/brew-app-manager-home.XXXXXX")"
    profile_path="$temp_home/.zprofile"
    HOME="$temp_home"
    SHELL="/bin/zsh"

    resolve_homebrew_binary_path() {
        printf "/opt/homebrew/bin/brew"
    }

    initialize_homebrew_shellenv() {
        return 0
    }

    prompt_yes_no() {
        return 0
    }

    assert_equal "0" "$(persist_homebrew_shellenv_to_zprofile >/dev/null; printf "%s" "$?")" "shellenv persistence should append the Homebrew loader line when ~/.zprofile is missing"
    assert_equal 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$(cat "$profile_path")" "shellenv persistence should write the expected loader line"
    assert_equal "2" "$(persist_homebrew_shellenv_to_zprofile >/dev/null; printf "%s" "$?")" "shellenv persistence should detect an existing loader line and avoid appending it twice"

    line_count="$(grep -Fxc 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$profile_path")"
    assert_equal "1" "$line_count" "shellenv persistence should keep ~/.zprofile idempotent"

    rm -rf "$temp_home"
    source "$script_dir/brew-app-manager.sh"
}

test_persist_homebrew_shellenv_to_zprofile_preserves_existing_line_without_trailing_newline() {
    local temp_home=""
    local profile_path=""

    source "$script_dir/brew-app-manager.sh"
    temp_home="$(mktemp -d "/tmp/brew-app-manager-home.XXXXXX")"
    profile_path="$temp_home/.zprofile"
    HOME="$temp_home"
    SHELL="/bin/zsh"

    resolve_homebrew_binary_path() {
        printf "/opt/homebrew/bin/brew"
    }

    initialize_homebrew_shellenv() {
        return 0
    }

    prompt_yes_no() {
        return 0
    }

    printf "export FOO=bar" >"$profile_path"

    assert_equal "0" "$(persist_homebrew_shellenv_to_zprofile >/dev/null; printf "%s" "$?")" "shellenv persistence should succeed when ~/.zprofile exists without a trailing newline"
    assert_equal "export FOO=bar
eval \"\$(/opt/homebrew/bin/brew shellenv)\"" "$(cat "$profile_path")" "shellenv persistence should append on a new line instead of joining the existing last line"

    rm -rf "$temp_home"
    source "$script_dir/brew-app-manager.sh"
}

test_configure_homebrew_shellenv_persistence_skips_non_zsh_shells() {
    local temp_home=""
    local prompt_seen="0"

    source "$script_dir/brew-app-manager.sh"
    temp_home="$(mktemp -d "/tmp/brew-app-manager-home.XXXXXX")"
    HOME="$temp_home"
    SHELL="/bin/bash"

    resolve_homebrew_binary_path() {
        printf "/opt/homebrew/bin/brew"
    }

    prompt_yes_no() {
        prompt_seen="1"
        return 0
    }

    assert_equal "11" "$(configure_homebrew_shellenv_persistence >/dev/null; printf "%s" "$?")" "shellenv persistence should not modify non-zsh shell profiles automatically"
    assert_equal "0" "$prompt_seen" "non-zsh shell profiles should not trigger the zprofile write confirmation"
    assert_equal "1" "$([ -e "$temp_home/.zprofile" ]; printf "%s" "$?")" "non-zsh shell profiles should not create ~/.zprofile automatically"

    rm -rf "$temp_home"
    source "$script_dir/brew-app-manager.sh"
}

test_is_valid_bundle_identifier() {
    assert_equal "0" "$(is_valid_bundle_identifier "com.openai.atlas"; printf "%s" "$?")" "valid bundle identifiers should pass validation"
    assert_equal "1" "$(is_valid_bundle_identifier "/Applications/ChatGPT Atlas.app: could not find"; printf "%s" "$?")" "diagnostic text should not be treated as a bundle identifier"
}

test_print_formula_plan_uses_multicolumn_lists() {
    collect_formula_managed_paths() {
        true
    }

    print_blank_line() {
        printf "\n"
    }

    print_message() {
        printf "%s\n" "$1"
    }

    local output=""
    COLUMNS=120
    FORMULA_PLAN_TARGET="python@3.12"
    FORMULA_PLAN_DEPENDENCIES=("dep-one" "dep-two" "dep-three" "dep-four" "dep-five" "dep-six" "dep-seven" "dep-eight")
    FORMULA_PLAN_ORPHANS=("orphan-one" "orphan-two" "orphan-three" "orphan-four" "orphan-five" "orphan-six" "orphan-seven" "orphan-eight")

    output="$(print_formula_plan "python@3.12")"

    printf "%s" "$output" | grep -F "直接依赖：" >/dev/null
    printf "%s" "$output" | grep -F "dep-one" | grep -F "dep-three" >/dev/null
    printf "%s" "$output" | grep -F "可一并移除的孤儿依赖：" >/dev/null
    printf "%s" "$output" | grep -F "orphan-one" | grep -F "orphan-three" >/dev/null
}

test_print_formula_plan_reports_managed_path_scan_failure() {
    local output=""

    collect_formula_managed_paths() {
        return 1
    }

    print_blank_line() {
        true
    }

    print_section_title() {
        true
    }

    print_message() {
        output="${output}$1\n"
    }

    print_status_message() {
        output="${output}$2\n"
    }

    FORMULA_PLAN_TARGET="python@3.12"
    FORMULA_PLAN_DEPENDENCIES=()
    FORMULA_PLAN_ORPHANS=()

    print_formula_plan "python@3.12" >/dev/null

    printf "%b" "$output" | grep -F "相关 Homebrew 管理路径：<scan-failed>" >/dev/null
    printf "%b" "$output" | grep -F "未能扫描这个 formula 的 Homebrew 管理路径。" >/dev/null
}

test_print_formula_plan_reports_managed_path_scan_failure_when_homebrew_query_fails() {
    local output=""

    brew() {
        case "$1" in
            --prefix|--cellar)
                return 1
                ;;
        esac
        return 0
    }

    print_blank_line() {
        true
    }

    print_section_title() {
        true
    }

    print_message() {
        output="${output}$1\n"
    }

    print_status_message() {
        output="${output}$2\n"
    }

    FORMULA_PLAN_TARGET="python@3.12"
    FORMULA_PLAN_DEPENDENCIES=()
    FORMULA_PLAN_ORPHANS=()

    print_formula_plan "python@3.12" >/dev/null

    printf "%b" "$output" | grep -F "相关 Homebrew 管理路径：<scan-failed>" >/dev/null
    printf "%b" "$output" | grep -F "未能扫描这个 formula 的 Homebrew 管理路径。" >/dev/null

    source "$script_dir/brew-app-manager.sh"
}

test_collect_formula_plan() {
    brew_dependencies_for_formula() {
        cat <<'EOF'
openssl@3
readline
EOF
    }

    brew_installed_users_for_formula() {
        local dependency="$1"

        case "$dependency" in
            openssl@3)
                cat <<'EOF'
python@3.12
git
EOF
                ;;
            readline)
                cat <<'EOF'
python@3.12
EOF
                ;;
        esac
    }

    local plan
    plan="$(collect_formula_uninstall_plan "python@3.12")"

    assert_equal "target=python@3.12
dependencies=openssl@3 readline
orphans=readline" "$plan" "formula plan should separate shared dependencies from orphan candidates"
}

test_collect_formula_plan_finds_transitive_orphans() {
    brew_dependencies_for_formula() {
        local formula="$1"

        case "$formula" in
            python@3.12)
                printf "readline\n"
                ;;
            readline)
                printf "ncurses\n"
                ;;
        esac
    }

    brew_installed_users_for_formula() {
        local dependency="$1"

        case "$dependency" in
            readline)
                printf "python@3.12\n"
                ;;
            ncurses)
                printf "readline\n"
                ;;
        esac
    }

    local plan
    plan="$(collect_formula_uninstall_plan "python@3.12")"

    assert_equal "target=python@3.12
dependencies=readline
orphans=readline ncurses" "$plan" "formula plan should keep walking the dependency graph to find transitive orphan candidates"

    source "$script_dir/brew-app-manager.sh"
}

test_parse_cask_metadata() {
    local fixture_path
    fixture_path="$(cd "$(dirname "$0")" && pwd)/fixtures/brew-info-sample.json"

    local metadata
    metadata="$(parse_cask_metadata_from_json "$fixture_path")"

    assert_equal "token=spotify
app_name=Spotify
zap_paths=$HOME/Library/Application Support/Spotify $HOME/Library/Caches/com.spotify.client" "$metadata" "cask metadata parser should extract token, app name, and zap paths"
}

test_collect_formula_plan_with_no_dependencies() {
    brew_dependencies_for_formula() {
        true
    }

    brew_installed_users_for_formula() {
        true
    }

    local plan
    plan="$(collect_formula_uninstall_plan "jq")"

    assert_equal "target=jq
dependencies=
orphans=" "$plan" "formula plan should handle formulas without dependencies"
}

test_load_formula_uninstall_plan_aborts_when_dependency_user_query_fails() {
    local status=0

    brew_dependencies_for_formula() {
        if [ "$1" = "python@3.14" ]; then
            printf "readline\n"
            return 0
        fi
        return 0
    }

    brew_installed_users_for_formula() {
        return 1
    }

    if load_formula_uninstall_plan "python@3.14"; then
        status=0
    else
        status="$?"
    fi

    assert_equal "1" "$status" "formula uninstall planning should fail closed when brew uses cannot determine dependency users"
    assert_equal "0" "${#FORMULA_PLAN_ORPHANS[@]}" "failed dependency-user queries must not fabricate orphan candidates"
}

test_run_formula_uninstall_flow_stops_after_main_failure() {
    local call_log=()

    brew() {
        local command_name="${1:-}"
        local arg_one="${2:-}"
        local arg_two="${3:-}"

        case "$command_name:$arg_one:$arg_two" in
            uninstall:python@3.12:)
                call_log+=("uninstall-formula:$arg_one")
                return 1
                ;;
            list:--formula:ncurses)
                call_log+=("list-orphan:$arg_two")
                return 0
                ;;
            autoremove::)
                call_log+=("autoremove")
                return 0
                ;;
        esac
        return 1
    }

    stop_formula_service_if_needed() {
        call_log+=("stop-service:$1")
    }

    print_section_title() {
        true
    }

    print_message() {
        true
    }

    FORMULA_PLAN_ORPHANS=("ncurses")
    run_formula_uninstall_flow "python@3.12" || true

    assert_equal "stop-service:python@3.12
uninstall-formula:python@3.12" "$(printf "%s\n" "${call_log[@]}")" "formula uninstall should stop after the main formula removal fails"

    source "$script_dir/brew-app-manager.sh"
}

test_run_formula_uninstall_batch_respects_post_scan_confirmation() {
    local uninstall_called="0"
    local prompt_seen="0"
    local event_log=()

    brew() {
        if [ "$1" = "list" ] && [ "$2" = "--formula" ] && [ "$3" = "python@3.12" ]; then
            return 0
        fi
        return 1
    }

    load_formula_uninstall_plan() {
        FORMULA_PLAN_TARGET="python@3.12"
        FORMULA_PLAN_DEPENDENCIES=("readline")
        FORMULA_PLAN_ORPHANS=("ncurses")
        event_log+=("load-plan")
        return 0
    }

    print_formula_plan() {
        event_log+=("print-plan:${FORMULA_PLAN_DEPENDENCIES[*]}:${FORMULA_PLAN_ORPHANS[*]}")
        true
    }

    prompt_yes_no() {
        prompt_seen="1"
        event_log+=("confirm")
        return 1
    }

    print_section_title() {
        true
    }

    print_message() {
        true
    }

    print_status_message() {
        true
    }

    print_compact_value_list() {
        true
    }

    run_formula_uninstall_flow() {
        uninstall_called="1"
        return 0
    }

    run_formula_uninstall_batch "python@3.12"

    assert_equal "1" "$prompt_seen" "formula batch uninstall should ask again after the real dependency scan is printed"
    assert_equal "0" "$uninstall_called" "formula batch uninstall should skip execution when post-scan confirmation is declined"
    assert_equal "load-plan
print-plan:readline:ncurses
confirm" "$(printf "%s\n" "${event_log[@]}")" "formula batch uninstall should confirm only after loading and printing the real plan state"

    source "$script_dir/brew-app-manager.sh"
}

test_build_cask_candidate_patterns() {
    local patterns
    patterns="$(build_cask_candidate_patterns "Spotify" "com.spotify.client")"

    printf "%s\n" "$patterns" | grep -Fqx "$HOME/Library/Application Support/com.spotify.client"
    printf "%s\n" "$patterns" | grep -Fqx "/Library/Application Support/com.spotify.client"
    printf "%s\n" "$patterns" | grep -Fqx "$HOME/Library/Application Scripts/com.spotify.client"
    printf "%s\n" "$patterns" | grep -Fqx "$HOME/Library/HTTPStorages/com.spotify.client"
    printf "%s\n" "$patterns" | grep -Fqx "$HOME/Library/Cookies/com.spotify.client.binarycookies"
    printf "%s\n" "$patterns" | grep -Fqx "$HOME/Library/WebKit/com.spotify.client"
    printf "%s\n" "$patterns" | grep -Fqx "$HOME/Library/Logs/DiagnosticReports/*com.spotify.client*"
    printf "%s\n" "$patterns" | grep -Fqx "/Library/LaunchDaemons/*com.spotify.client*.plist"
    printf "%s\n" "$patterns" | grep -Fqx "/Library/PrivilegedHelperTools/*com.spotify.client*"
    assert_equal "" "$(printf "%s\n" "$patterns" | grep -F "Caskroom/*" || true)" "candidate patterns should not include a wildcard for every Caskroom entry"
}

test_build_cask_temp_candidate_patterns() {
    local patterns
    TMPDIR="/private/var/folders/ab/cd123/T/"
    patterns="$(build_cask_temp_candidate_patterns "ChatGPT Atlas" "com.openai.atlas")"

    printf "%s\n" "$patterns" | grep -Fqx "/private/var/folders/ab/cd123/C/*com.openai.atlas*"
    assert_equal "" "$(printf "%s\n" "$patterns" | grep -F "ChatGPT Atlas" || true)" "temp candidate patterns should not add app-name fuzzy globs when a bundle identifier is available"
}

test_build_cask_candidate_patterns_without_bundle_id_stays_exact() {
    local patterns
    patterns="$(build_cask_candidate_patterns "Very Long Generic App" "")"

    printf "%s\n" "$patterns" | grep -Fqx "/Applications/Very Long Generic App.app"
    assert_equal "" "$(printf "%s\n" "$patterns" | grep -F "DiagnosticReports/*Very Long Generic App*" || true)" "fallback candidate patterns should not add app-name fuzzy globs without a bundle identifier"
    assert_equal "" "$(printf "%s\n" "$patterns" | grep -F "/private/var/db/receipts/*Very Long Generic App*" || true)" "fallback candidate patterns should not glob system receipts by app name"
}

test_build_cask_temp_candidate_patterns_without_bundle_id_stay_empty() {
    local patterns
    TMPDIR="/private/var/folders/ab/cd123/T/"
    patterns="$(build_cask_temp_candidate_patterns "Very Long Generic App" "")"

    assert_equal "" "$patterns" "temp candidate patterns should not fall back to app-name globs when bundle identifiers are unavailable"
}

test_filter_cask_candidates_excludes_app_cleaner_metadata() {
    local filtered
    filtered="$(printf "%s\n%s\n" \
        "/Users/test/Library/Application Support/com.nektony.App-Cleaner-S/SubdomainAppsSearcher/com.openai.atlas.plist" \
        "/Users/test/Library/Caches/com.openai.atlas" | filter_cask_candidates)"

    assert_equal "/Users/test/Library/Caches/com.openai.atlas" "$filtered" "candidate filter should exclude App Cleaner bookkeeping files"
}

test_build_cask_scan_roots_includes_application_scripts_and_http_storages() {
    local roots
    roots="$(build_cask_scan_roots)"

    printf "%s\n" "$roots" | grep -Fqx "$HOME/Library/Application Scripts"
    printf "%s\n" "$roots" | grep -Fqx "$HOME/Library/Cookies"
    printf "%s\n" "$roots" | grep -Fqx "$HOME/Library/HTTPStorages"
}

test_collect_cask_cleanup_candidates_expands_zap_patterns() {
    local mock_json
    mock_json="/tmp/brew-app-manager-test-zap.json"
    : >"$mock_json"

    build_cask_candidate_patterns() {
        printf "%s\n" "/Applications/Test.app"
    }

    build_cask_temp_candidate_patterns() {
        true
    }

    load_cask_zap_paths_from_json() {
        printf "%s\n" "/tmp/Test Dir/*.plist"
        printf "%s\n" "/tmp/Exact Path"
    }

    scan_cask_roots_for_terms() {
        true
    }

    emit_existing_path_matches() {
        case "$1" in
            "/Applications/Test.app")
                printf "%s\n" "/Applications/Test.app"
                ;;
            "/tmp/Test Dir/*.plist")
                printf "%s\n" "/tmp/Test Dir/one.plist"
                printf "%s\n" "/tmp/Test Dir/two.plist"
                ;;
            "/tmp/Exact Path")
                printf "%s\n" "/tmp/Exact Path"
                ;;
        esac
    }

    local candidates
    candidates="$(collect_cask_cleanup_candidates "Test" "com.example.test" "$mock_json")"

    rm -f "$mock_json"

    assert_equal "/tmp/Exact Path
/Applications/Test.app
/tmp/Test Dir/one.plist
/tmp/Test Dir/two.plist" "$candidates" "cask cleanup candidates should expand zap patterns before size calculation"
}

test_prune_nested_cask_candidates_removes_descendants() {
    local pruned
    pruned="$(printf "%s\n%s\n%s\n" \
        "/tmp/parent" \
        "/tmp/parent/child" \
        "/tmp/parent/child/grandchild" | prune_nested_cask_candidates)"

    assert_equal "/tmp/parent" "$pruned" "nested candidate pruning should keep only the top-level parent path"
}

test_build_cask_scan_terms_filters_short_final_component() {
    local terms
    terms="$(build_cask_scan_terms "Cool App" "com.vendor.app")"

    assert_equal "" "$(printf "%s\n" "$terms" | grep -Fx "app" || true)" "short final bundle components should not be used as fuzzy scan terms"
    assert_equal "0" "$(build_cask_scan_terms "QQ" "com.tencent.qq" >/dev/null; printf "%s" "$?")" "cask scan term builder should return success when it emits valid terms"
}

test_build_cask_scan_terms_falls_back_to_specific_app_name() {
    local terms
    terms="$(build_cask_scan_terms "ChatGPT Atlas" "")"

    assert_equal "ChatGPT Atlas" "$terms" "cask scan term builder should fall back to the full app name when no bundle identifier is available"
    assert_equal "IINA" "$(build_cask_scan_terms "IINA" "")" "cask scan term builder should allow four-character app names as safe fallback scan terms"
    assert_equal "" "$(build_cask_scan_terms "QQ" "")" "cask scan term builder should avoid broad scans for very short app names when bundle identifiers are unavailable"
}

test_find_app_bundle_path_uses_spotlight_when_default_locations_miss() {
    local app_dir=""
    local app_name="BrewAppManagerNondefaultTestApp"

    app_dir="$(mktemp -d "/tmp/brew-app-manager-app.XXXXXX")/${app_name}.app"
    mkdir -p "$app_dir"

    command_exists() {
        [ "$1" = "mdfind" ]
    }

    mdfind() {
        printf "%s\n" "$app_dir"
    }

    [ "$(find_app_bundle_path "$app_name")" = "$app_dir" ] || {
        echo "FAIL: find_app_bundle_path should fall back to Spotlight search for exact app bundle names"
        exit 1
    }

    rm -rf "${app_dir%/${app_name}.app}"
    source "$script_dir/brew-app-manager.sh"
}

test_install_package_with_retries_treats_installed_cask_as_success() {
    local logs_dir=""
    local status_dir=""

    logs_dir="$(mktemp -d "/tmp/brew-app-manager-install.XXXXXX")"
    status_dir="$logs_dir/status"
    mkdir -p "$status_dir"

    brew() {
        [ "$1" = "list" ] && [ "$2" = "--cask" ] && [ "$3" = "warp" ]
    }

    print_status_message() {
        true
    }

    install_package_with_retries "warp" "$logs_dir" "$status_dir"

    assert_equal "already-installed" "$(cat "$status_dir/warp.status")" "install retries should treat already-installed casks as a successful no-op"

    rm -rf "$logs_dir"
}

test_print_installation_summary_marks_missing_worker_results_as_unknown() {
    local logs_dir=""
    local status_dir=""
    local output=""

    logs_dir="$(mktemp -d "/tmp/brew-app-manager-install.XXXXXX")"
    status_dir="$logs_dir/status"
    mkdir -p "$status_dir"
    INSTALLABLE_CASKS=("chatgpt" "warp")
    printf "installed\n" >"$status_dir/chatgpt.status"

    print_section_title() {
        output="${output}TITLE:$1\n"
    }

    print_message() {
        output="${output}$1\n"
    }

    print_status_message() {
        output="${output}$2\n"
    }

    print_installation_summary "$logs_dir" "$status_dir" "1"

    printf "%b" "$output" | grep -F "结果未知数量：1" >/dev/null
    printf "%b" "$output" | grep -F "warp（日志：" >/dev/null
    printf "%b" "$output" | grep -F "安装执行器返回非零状态" >/dev/null

    rm -rf "$logs_dir"
    source "$script_dir/brew-app-manager.sh"
}

test_scan_cask_roots_for_terms_skips_when_no_safe_terms_exist() {
    local find_called="0"

    find() {
        find_called="1"
        printf "%s\n" "/tmp/unexpected"
    }

    assert_equal "" "$(scan_cask_roots_for_terms "QQ" "")" "cask root term scanning should stay disabled when neither bundle identifier nor a sufficiently specific app name is available"
    assert_equal "0" "$find_called" "cask root term scanning should not run broad fuzzy find calls without safe scan terms"

    unset -f find
}

test_scan_cask_roots_for_terms_uses_app_name_fallback_when_bundle_identifier_missing() {
    local temp_root=""
    local roots_log=""
    local output=""

    temp_root="$(mktemp -d "/tmp/brew-app-manager-cask-root.XXXXXX")"
    roots_log="$(mktemp "/tmp/brew-app-manager-cask-root-log.XXXXXX")"

    build_cask_scan_roots() {
        printf "%s\n" "$temp_root"
    }

    find() {
        printf "%s\n" "$1" >>"$roots_log"
        printf "%s\n" "$1/$4"
    }

    output="$(scan_cask_roots_for_terms "IINA" "")"

    assert_equal "$temp_root" "$(cat "$roots_log")" "cask root term scanning should still walk configured roots when a safe app-name fallback term exists"
    printf "%s\n" "$output" | grep -Fq "$temp_root/-iname"

    rm -rf "$temp_root"
    rm -f "$roots_log"
    source "$script_dir/brew-app-manager.sh"
}

test_run_cask_uninstall_flow_order() {
    local call_log=()

    brew() {
        if [ "$1" = "services" ] && [ "$2" = "stop" ]; then
            call_log+=("service-stop:$3")
            return 0
        fi

        if [ "$1" = "uninstall" ] && [ "$2" = "--zap" ]; then
            call_log+=("brew-uninstall:$3")
            return 0
        fi

        if [ "$1" = "--prefix" ]; then
            printf "/tmp/homebrew"
            return 0
        fi

        return 1
    }

    delete_paths_with_optional_elevation() {
        local prompt_label="$1"
        shift
        local path=""

        call_log+=("delete-prompt:$prompt_label")
        for path in "${@:-}"; do
            call_log+=("delete:$path")
        done
        DELETE_REPORT_DELETED=("${@:-}")
        DELETE_REPORT_ELEVATED=()
        DELETE_REPORT_PERMISSION_SKIPPED=()
        DELETE_REPORT_FAILED=()
        return 0
    }

    print_blank_line() {
        true
    }

    print_message() {
        true
    }

    run_cask_uninstall_flow "spotify" "Spotify" "2048" "2" "/Applications/Spotify.app" "$HOME/Library/Caches/com.spotify.client"

    assert_equal "service-stop:spotify
brew-uninstall:spotify
delete-prompt:检测到权限问题，是否使用 sudo 删除这些 cask 残留路径？
delete:/Applications/Spotify.app
delete:$HOME/Library/Caches/com.spotify.client" "$(printf "%s\n" "${call_log[@]}")" "cask uninstall should run brew uninstall before deleting residue paths"

    source "$script_dir/brew-app-manager.sh"
}

test_run_cask_uninstall_flow_skips_residue_deletion_when_homebrew_uninstall_fails() {
    local deletion_called="0"

    brew() {
        if [ "$1" = "services" ] && [ "$2" = "stop" ]; then
            return 0
        fi

        if [ "$1" = "uninstall" ] && [ "$2" = "--zap" ]; then
            return 1
        fi

        return 1
    }

    delete_paths_with_optional_elevation() {
        deletion_called="1"
        return 0
    }

    print_section_title() {
        true
    }

    print_message() {
        true
    }

    run_cask_uninstall_flow "spotify" "Spotify" "2048" "2" "/Applications/Spotify.app" "$HOME/Library/Caches/com.spotify.client" || true

    assert_equal "0" "$deletion_called" "cask residue deletion should not run after Homebrew uninstall fails"

    source "$script_dir/brew-app-manager.sh"
}

test_run_cask_uninstall_flow_with_no_candidates() {
    local deletion_called="0"
    local output=""

    brew() {
        if [ "$1" = "services" ] && [ "$2" = "stop" ]; then
            return 0
        fi

        if [ "$1" = "uninstall" ] && [ "$2" = "--zap" ]; then
            return 0
        fi

        if [ "$1" = "--prefix" ]; then
            printf "/tmp/homebrew"
            return 0
        fi

        return 1
    }

    delete_paths_with_optional_elevation() {
        deletion_called="1"
        return 0
    }

    print_message() {
        output="${output}$1\n"
    }

    print_blank_line() {
        true
    }

    run_cask_uninstall_flow "spotify" "Spotify" "0" "0"

    assert_equal "1" "$deletion_called" "cask uninstall should still run the deletion helper even when no residue paths are found"
    printf "%b" "$output" | grep -F "普通删除成功路径数：0" >/dev/null
    printf "%b" "$output" | grep -F "提权删除成功路径数：0" >/dev/null
    printf "%b" "$output" | grep -F "因权限跳过路径数：0" >/dev/null
    printf "%b" "$output" | grep -F "其他失败路径数：0" >/dev/null

    source "$script_dir/brew-app-manager.sh"
}

test_remove_path_without_elevation_aborts_when_temp_error_file_creation_fails() {
    local status=0

    mktemp() {
        return 1
    }

    if remove_path_without_elevation "/tmp/does-not-matter"; then
        status=0
    else
        status="$?"
    fi

    assert_equal "1" "$status" "delete helper should fail closed when it cannot create its error capture file"
    assert_equal "未能创建删除错误日志临时文件。" "$DELETE_LAST_ERROR_MESSAGE" "delete helper should preserve the real failure cause when temp file creation fails"

    source "$script_dir/brew-app-manager.sh"
}

test_remove_path_with_elevation_aborts_when_temp_error_file_creation_fails() {
    local status=0

    mktemp() {
        return 1
    }

    if remove_path_with_elevation "/tmp/does-not-matter"; then
        status=0
    else
        status="$?"
    fi

    assert_equal "1" "$status" "sudo delete helper should fail closed when it cannot create its error capture file"
    assert_equal "未能创建提权删除错误日志临时文件。" "$DELETE_LAST_ERROR_MESSAGE" "sudo delete helper should preserve the temp-file creation failure"

    source "$script_dir/brew-app-manager.sh"
}

test_run_cask_uninstall_batch_respects_per_item_confirmation() {
    local uninstall_called="0"
    local metadata_json=""

    metadata_json="$(mktemp "/tmp/brew-app-manager-cask.XXXXXX")"
    printf '{"casks":[{"token":"test-cask","artifacts":[{"app":["Test App.app"]}]}]}\n' >"$metadata_json"

    extract_key_value() {
        case "$2" in
            count) printf "1" ;;
            total_kib) printf "2048" ;;
            unreadable) printf "0" ;;
        esac
    }

    fetch_cask_metadata_json() {
        printf "%s" "$metadata_json"
    }

    load_cask_metadata_from_json() {
        CASK_METADATA_TOKEN="test-cask"
        CASK_METADATA_APP_NAME="Test App"
        CASK_METADATA_ZAP_PATHS=()
        return 0
    }

    find_app_bundle_path() {
        printf "/Applications/Test App.app"
    }

    get_bundle_identifier_for_app_path() {
        printf "com.example.test"
    }

    read_command_output_into_array() {
        local array_name="$1"
        shift

        case "$1" in
            collect_cask_cleanup_candidates)
                eval "$array_name=()"
                append_to_array "$array_name" "/Applications/Test App.app"
                ;;
        esac
    }

    collect_disk_usage_summary() {
        printf "count=1\ntotal_kib=2048\nunreadable=0"
    }

    prompt_yes_no() {
        return 1
    }

    run_cask_uninstall_flow() {
        uninstall_called="1"
        return 0
    }

    print_blank_line() {
        true
    }

    print_message() {
        true
    }

    print_section_title() {
        true
    }

    print_status_message() {
        true
    }

    print_candidate_list() {
        true
    }

    print_compact_value_list() {
        true
    }

    run_cask_uninstall_batch "test-cask"
    assert_equal "0" "$uninstall_called" "batch cask uninstall should skip execution when per-item confirmation is declined"

    rm -f "$metadata_json"
    source "$script_dir/brew-app-manager.sh"
}

test_run_cask_uninstall_batch_skips_target_when_candidate_scan_fails() {
    local output=""
    local uninstall_called="0"

    fetch_cask_metadata_json() {
        return 1
    }

    find_cask_install_receipts() {
        true
    }

    find_app_bundle_path() {
        return 1
    }

    get_bundle_identifier_for_app_path() {
        return 1
    }

    read_command_output_into_array() {
        local array_name="$1"
        shift

        case "$1" in
            collect_cask_cleanup_candidates)
                reset_named_array "$array_name"
                return 1
                ;;
            *)
                reset_named_array "$array_name"
                return 0
                ;;
        esac
    }

    run_cask_uninstall_flow() {
        uninstall_called="1"
        return 0
    }

    print_blank_line() {
        true
    }

    print_section_title() {
        true
    }

    print_message() {
        output="${output}$1\n"
    }

    print_status_message() {
        output="${output}$2\n"
    }

    run_cask_uninstall_batch "test-cask"

    assert_equal "0" "$uninstall_called" "batch cask uninstall should not continue when candidate scan fails"
    printf "%b" "$output" | grep -F "未能扫描这个 cask 的清理候选项，已跳过：test-cask" >/dev/null

    source "$script_dir/brew-app-manager.sh"
}

test_run_cask_uninstall_batch_falls_back_when_metadata_unavailable() {
    local uninstall_called="0"

    fetch_cask_metadata_json() {
        return 1
    }

    find_cask_install_receipts() {
        printf "/tmp/test-cask-receipt.json\n"
    }

    load_cask_app_name_from_receipt() {
        printf "Fallback App"
    }

    find_app_bundle_path() {
        return 1
    }

    get_bundle_identifier_for_app_path() {
        return 1
    }

    read_command_output_into_array() {
        local array_name="$1"
        shift

        case "$1" in
            collect_cask_cleanup_candidates)
                reset_named_array "$array_name"
                return 0
                ;;
            *)
                reset_named_array "$array_name"
                return 0
                ;;
        esac
    }

    collect_disk_usage_summary() {
        printf "count=0\ntotal_kib=0\nunreadable=0"
    }

    prompt_yes_no() {
        return 0
    }

    run_cask_uninstall_flow() {
        uninstall_called="1"
        return 0
    }

    print_blank_line() {
        true
    }

    print_message() {
        true
    }

    print_section_title() {
        true
    }

    print_status_message() {
        true
    }

    print_candidate_list() {
        true
    }

    run_cask_uninstall_batch "test-cask"
    assert_equal "1" "$uninstall_called" "cask batch uninstall should fall back to Homebrew uninstall even when cask metadata cannot be loaded"

    source "$script_dir/brew-app-manager.sh"
}

test_run_cask_uninstall_batch_resets_metadata_status_per_item() {
    local output=""
    local uninstall_called="0"

    fetch_cask_metadata_json() {
        case "$1" in
            c1) return 2 ;;
            c2) return 1 ;;
        esac
        return 1
    }

    find_cask_install_receipts() {
        return 0
    }

    find_app_bundle_path() {
        return 1
    }

    get_bundle_identifier_for_app_path() {
        return 1
    }

    read_command_output_into_array() {
        local array_name="$1"
        shift

        reset_named_array "$array_name"
        return 0
    }

    collect_disk_usage_summary() {
        printf "count=0\ntotal_kib=0\nunreadable=0"
    }

    prompt_yes_no() {
        return 1
    }

    run_cask_uninstall_flow() {
        uninstall_called="1"
        return 0
    }

    print_blank_line() {
        true
    }

    print_section_title() {
        true
    }

    print_candidate_list() {
        true
    }

    print_message() {
        true
    }

    print_status_message() {
        output="${output}$2\n"
    }

    run_cask_uninstall_batch "c1" "c2"

    assert_equal "0" "$uninstall_called" "declined confirmations should still skip batch cask uninstall execution"
    printf "%b" "$output" | grep -F "未能创建 cask 元数据临时文件，将降级为 Homebrew 卸载 + 本地残留探测。" >/dev/null
    printf "%b" "$output" | grep -F "未能加载完整 cask 元数据，将降级为 Homebrew 卸载 + 本地残留探测。" >/dev/null
    assert_equal "1" "$(printf "%b" "$output" | grep -F -c "未能创建 cask 元数据临时文件，将降级为 Homebrew 卸载 + 本地残留探测。")" "temp-file failure warning should only apply to the cask that actually hit that error"

    source "$script_dir/brew-app-manager.sh"
}

test_run_cask_uninstall_batch_skips_target_when_receipt_discovery_fails_in_fallback() {
    local output=""
    local uninstall_called="0"

    fetch_cask_metadata_json() {
        return 1
    }

    read_command_output_into_array() {
        local array_name="$1"
        shift

        case "$1" in
            find_cask_install_receipts)
                reset_named_array "$array_name"
                return 1
                ;;
            collect_cask_cleanup_candidates)
                reset_named_array "$array_name"
                return 0
                ;;
            *)
                reset_named_array "$array_name"
                return 0
                ;;
        esac
    }

    run_cask_uninstall_flow() {
        uninstall_called="1"
        return 0
    }

    print_blank_line() {
        true
    }

    print_section_title() {
        true
    }

    print_candidate_list() {
        true
    }

    print_message() {
        output="${output}$1\n"
    }

    print_status_message() {
        output="${output}$2\n"
    }

    run_cask_uninstall_batch "test-cask"

    assert_equal "0" "$uninstall_called" "fallback uninstall planning should skip a cask when receipt discovery fails"
    printf "%b" "$output" | grep -F "未能读取这个 cask 的安装记录，已跳过：test-cask" >/dev/null
    printf "%b" "$output" | grep -F "当前已进入降级模式，且 receipt 发现失败，无法可靠生成本地残留清理候选项。" >/dev/null

    source "$script_dir/brew-app-manager.sh"
}

test_cleanup_command_plan() {
    local cleanup_plan
    cleanup_plan="$(render_cleanup_plan)"

    assert_equal "brew cleanup --prune=all
brew cleanup
brew autoremove
brew services cleanup" "$cleanup_plan" "cleanup flow should expose the expected Homebrew cleanup commands"
}

test_run_formula_selection_menu_reports_inventory_failure() {
    local output=""

    load_formula_inventory() {
        return 1
    }

    output="$(run_formula_selection_menu)"

    printf "%s\n" "$output" | grep -Fq "未能读取已安装 formula 列表。"
    printf "%s\n" "$output" | grep -Fq "失败命令：brew list --formula"
}

test_run_cask_selection_menu_reports_inventory_failure() {
    local output=""

    load_cask_inventory() {
        return 1
    }

    output="$(run_cask_selection_menu)"

    printf "%s\n" "$output" | grep -Fq "未能读取已安装 cask 列表。"
    printf "%s\n" "$output" | grep -Fq "失败命令：brew list --cask"
}

test_delete_paths_with_optional_elevation_requires_confirmation() {
    local protected_path=""

    source "$script_dir/brew-app-manager.sh"
    DELETE_TEST_PROMPT_SEEN="0"
    protected_path="$(mktemp -d "/tmp/brew-app-manager-protected.XXXXXX")"

    remove_path_without_elevation() {
        DELETE_LAST_ERROR_MESSAGE="Operation not permitted"
        return 10
    }

    remove_path_with_elevation() {
        echo "unexpected-elevation"
        return 1
    }

    prompt_yes_no() {
        DELETE_TEST_PROMPT_SEEN="1"
        return 1
    }

    print_status_message() {
        true
    }

    delete_paths_with_optional_elevation "是否提权删除？" "$protected_path"

    assert_equal "1" "$DELETE_TEST_PROMPT_SEEN" "permission-blocked paths should require an explicit follow-up confirmation before sudo deletion"
    assert_equal "$protected_path" "$(printf "%s\n" "${DELETE_REPORT_PERMISSION_SKIPPED[@]}")" "declined elevation should leave the path in the permission-skipped report"

    rm -rf "$protected_path"

    source "$script_dir/brew-app-manager.sh"
}

test_delete_paths_with_optional_elevation_records_elevated_success() {
    local protected_path=""

    source "$script_dir/brew-app-manager.sh"
    protected_path="$(mktemp -d "/tmp/brew-app-manager-protected.XXXXXX")"

    remove_path_without_elevation() {
        DELETE_LAST_ERROR_MESSAGE="Permission denied"
        return 10
    }

    remove_path_with_elevation() {
        [ "$1" = "$protected_path" ]
    }

    prompt_yes_no() {
        return 0
    }

    print_status_message() {
        true
    }

    delete_paths_with_optional_elevation "是否提权删除？" "$protected_path"

    assert_equal "$protected_path" "$(printf "%s\n" "${DELETE_REPORT_ELEVATED[@]}")" "confirmed elevation should record successful sudo deletions separately"

    rm -rf "$protected_path"

    source "$script_dir/brew-app-manager.sh"
}

test_delete_error_requires_elevation_uses_path_probe() {
    local protected_root=""

    protected_root="$(mktemp -d "/tmp/brew-app-manager-probe.XXXXXX")"
    chmod 500 "$protected_root"

    assert_equal "0" "$(delete_error_requires_elevation "$protected_root/child" "unexpected failure"; printf "%s" "$?")" "elevation detection should use path permission probes even when stderr text is inconclusive"

    chmod 700 "$protected_root"
    rm -rf "$protected_root"
}

test_collect_homebrew_tmp_cleanup_paths_uses_only_defined_homebrew_temp_roots() {
    local temp_root=""
    local roots_log=""
    local collected_paths=""

    source "$script_dir/brew-app-manager.sh"
    temp_root="$(mktemp -d "/tmp/brew-app-manager-homebrew-temp.XXXXXX")"
    roots_log="$(mktemp "/tmp/brew-app-manager-find-log.XXXXXX")"

    find() {
        printf "%s\n" "$1" >>"$roots_log"
        printf "%s\n" "$1/stale-temp"
    }

    HOMEBREW_TEMP="$temp_root/"
    collected_paths="$(collect_homebrew_tmp_cleanup_paths)"

    assert_equal "$temp_root/stale-temp" "$collected_paths" "tmp cleanup should emit entries only from the explicit Homebrew temp root"
    assert_equal "$temp_root" "$(cat "$roots_log")" "tmp cleanup should not scan unrelated global tmp paths"

    rm -rf "$temp_root"
    rm -f "$roots_log"
    unset -f find

    source "$script_dir/brew-app-manager.sh"
}

test_collect_homebrew_tmp_cleanup_paths_falls_back_to_tmp_roots_when_homebrew_temp_unset() {
    local temp_root=""
    local roots_log=""
    local collected_paths=""

    source "$script_dir/brew-app-manager.sh"
    temp_root="$(mktemp -d "/tmp/brew-app-manager-homebrew-fallback.XXXXXX")"
    roots_log="$(mktemp "/tmp/brew-app-manager-find-log.XXXXXX")"

    find() {
        printf "%s\n" "$1" >>"$roots_log"
        printf "%s\n" "$1/homebrew-stale-temp"
    }

    unset HOMEBREW_TEMP
    TMPDIR="$temp_root/"
    collected_paths="$(collect_homebrew_tmp_cleanup_paths)"

    printf "%s\n" "$collected_paths" | grep -Fqx "$temp_root/homebrew-stale-temp"
    printf "%s\n" "$collected_paths" | grep -Fqx "/tmp/homebrew-stale-temp"
    assert_equal "$temp_root
/tmp" "$(cat "$roots_log")" "tmp cleanup fallback should scan TMPDIR and /tmp when HOMEBREW_TEMP is not configured"

    rm -rf "$temp_root"
    rm -f "$roots_log"
    unset -f find

    source "$script_dir/brew-app-manager.sh"
}

test_run_cleanup_flow_measures_only_local_cleanup_scope() {
    local measurement_log=""

    measurement_log="$(mktemp "/tmp/brew-app-manager-measure.XXXXXX")"
    require_homebrew_for_feature() {
        return 0
    }

    prompt_yes_no() {
        return 0
    }

    collect_homebrew_local_cleanup_paths() {
        printf "/tmp/cache-a\n/tmp/log-b\n"
    }

    measure_cleanup_paths_footprint_kib() {
        printf "%s:%s\n" "$#" "$*" >>"$measurement_log"
        if [ "$(wc -l < "$measurement_log" | tr -d ' ')" = "1" ]; then
            printf "2048"
        else
            printf "1024"
        fi
    }

    brew() {
        case "$1" in
            --prefix)
                printf "/opt/homebrew"
                return 0
                ;;
            cleanup|autoremove|services|list)
                return 0
                ;;
        esac
        return 0
    }

    cleanup_homebrew_services() {
        true
    }

    delete_paths_with_optional_elevation() {
        DELETE_REPORT_DELETED=("/tmp/cache-a")
        DELETE_REPORT_ELEVATED=()
        DELETE_REPORT_PERMISSION_SKIPPED=()
        DELETE_REPORT_FAILED=()
        return 0
    }

    print_section_title() {
        true
    }

    print_message() {
        true
    }

    print_status_message() {
        true
    }

    print_output_boundary() {
        true
    }

    run_cleanup_flow

    assert_equal "2:/tmp/cache-a /tmp/log-b
2:/tmp/cache-a /tmp/log-b" "$(cat "$measurement_log")" "cleanup measurement should use the same local path scope before and after execution"

    rm -f "$measurement_log"
    source "$script_dir/brew-app-manager.sh"
}

test_collect_homebrew_local_cleanup_paths_fails_when_homebrew_queries_fail() {
    brew() {
        case "$1" in
            --prefix|--cache)
                return 1
                ;;
        esac
        return 0
    }

    assert_equal "1" "$(collect_homebrew_local_cleanup_paths >/dev/null; printf "%s" "$?")" "local cleanup path collection should fail closed when Homebrew prefix or cache cannot be resolved"
}

test_run_cleanup_flow_reports_homebrew_command_failures() {
    local output=""

    require_homebrew_for_feature() {
        return 0
    }

    prompt_yes_no() {
        return 0
    }

    collect_homebrew_local_cleanup_paths() {
        printf "/tmp/cache-a\n"
    }

    measure_cleanup_paths_footprint_kib() {
        printf "0"
    }

    brew() {
        case "$1" in
            --prefix)
                printf "/opt/homebrew"
                return 0
                ;;
            cleanup)
                if [ "${2:-}" = "--prune=all" ]; then
                    return 1
                fi
                return 0
                ;;
            autoremove)
                return 1
                ;;
            services)
                return 0
                ;;
            list)
                return 0
                ;;
        esac
        return 0
    }

    delete_paths_with_optional_elevation() {
        DELETE_REPORT_DELETED=()
        DELETE_REPORT_ELEVATED=()
        DELETE_REPORT_PERMISSION_SKIPPED=()
        DELETE_REPORT_FAILED=()
        return 0
    }

    output="$(run_cleanup_flow)"

    printf "%s\n" "$output" | grep -Fq "Homebrew 命令执行状态："
    printf "%s\n" "$output" | grep -Fq "brew cleanup --prune=all"
    printf "%s\n" "$output" | grep -Fq "brew autoremove"
    printf "%s\n" "$output" | grep -Fq "有 Homebrew 清理命令执行失败"
}

test_print_homebrew_counts_reports_unknown_when_queries_fail() {
    local output=""

    load_formula_inventory() {
        return 1
    }

    load_cask_inventory() {
        return 1
    }

    print_message() {
        output="${output}$1\n"
    }

    print_status_message() {
        output="${output}$2\n"
    }

    print_homebrew_counts || true

    printf "%b" "$output" | grep -F "已安装 formula 数量：<unknown>" >/dev/null
    printf "%b" "$output" | grep -F "已安装 cask 数量：<unknown>" >/dev/null
    printf "%b" "$output" | grep -F "未能读取已安装 formula 数量。" >/dev/null
    printf "%b" "$output" | grep -F "未能读取已安装 cask 数量。" >/dev/null
}

test_run_install_xcode_command_line_tools_flow_reports_launcher_failure() {
    local output=""
    local status=0

    is_xcode_command_line_tools_installed() {
        return 1
    }

    prompt_yes_no() {
        return 0
    }

    xcode-select() {
        return 1
    }

    print_section_title() {
        true
    }

    print_message() {
        output="${output}$1\n"
    }

    print_status_message() {
        output="${output}$2\n"
    }

    if run_install_xcode_command_line_tools_flow >/dev/null; then
        status=0
    else
        status="$?"
    fi

    assert_equal "1" "$status" "CLT install flow should fail when the system installer cannot be launched"
    printf "%b" "$output" | grep -F "未能成功发起 Xcode Command Line Tools 系统安装器。" >/dev/null
}

test_run_install_homebrew_flow_reports_temp_script_creation_failure() {
    local output=""
    local status=0

    ensure_homebrew_available() {
        return 1
    }

    is_homebrew_installed() {
        return 1
    }

    is_xcode_command_line_tools_installed() {
        return 0
    }

    prompt_yes_no() {
        return 0
    }

    mktemp() {
        return 1
    }

    print_section_title() {
        true
    }

    print_message() {
        output="${output}$1\n"
    }

    print_status_message() {
        output="${output}$2\n"
    }

    if run_install_homebrew_flow >/dev/null; then
        status=0
    else
        status="$?"
    fi

    assert_equal "1" "$status" "Homebrew install flow should fail when the installer temp script cannot be created"
    printf "%b" "$output" | grep -F "未能创建 Homebrew 安装脚本临时文件，已取消安装。" >/dev/null
}

test_run_install_homebrew_flow_reports_configured_success() {
    local output=""
    local temp_home=""
    local prompt_count=0

    source "$script_dir/brew-app-manager.sh"
    temp_home="$(mktemp -d "/tmp/brew-app-manager-home.XXXXXX")"
    HOME="$temp_home"
    SHELL="/bin/zsh"

    is_homebrew_installed() {
        return 1
    }

    is_xcode_command_line_tools_installed() {
        return 0
    }

    prompt_yes_no() {
        prompt_count=$((prompt_count + 1))
        return 0
    }

    curl() {
        local output_path=""

        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o)
                    output_path="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done

        printf "#!/bin/bash\nexit 0\n" >"$output_path"
        return 0
    }

    ensure_homebrew_available() {
        return 0
    }

    resolve_homebrew_binary_path() {
        printf "/opt/homebrew/bin/brew"
    }

    initialize_homebrew_shellenv() {
        return 0
    }

    command_exists() {
        [ "$1" = "brew" ]
    }

    brew() {
        if [ "$1" = "--version" ]; then
            printf "Homebrew 4.3.0\n"
            return 0
        fi
        return 0
    }

    print_section_title() {
        true
    }

    print_output_boundary() {
        true
    }

    print_message() {
        output="${output}$1\n"
    }

    print_status_message() {
        output="${output}$2\n"
    }

    run_install_homebrew_flow >/dev/null

    assert_equal "2" "$prompt_count" "Homebrew install flow should confirm both installation and zprofile persistence"
    printf "%b" "$output" | grep -F "Homebrew 安装完成。" >/dev/null
    printf "%b" "$output" | grep -F "版本：Homebrew 4.3.0" >/dev/null
    printf "%b" "$output" | grep -F "Homebrew 环境已配置完成。以后重新打开终端即可直接使用 brew。" >/dev/null
    printf "%b" "$output" | grep -F "当前会话与后续新的 zsh 终端都可以直接使用 brew。" >/dev/null
    grep -Fqx 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$temp_home/.zprofile"

    rm -rf "$temp_home"
    source "$script_dir/brew-app-manager.sh"
}

test_build_install_parallel_command_avoids_login_shell() {
    local command_script=""

    source "$script_dir/brew-app-manager.sh"
    INSTALLABLE_CASKS=("chatgpt" "warp")
    MANAGER_SCRIPT_PATH="/tmp/brew-app-manager.sh"

    command_script="$(build_install_parallel_command "/tmp/install-logs" "/tmp/failed.txt")"

    assert_equal "" "$(printf "%s\n" "$command_script" | grep -F "bash -lc" || true)" "parallel install helper should avoid login shells for reproducible execution"
    printf "%s\n" "$command_script" | grep -F "bash -c" >/dev/null

    source "$script_dir/brew-app-manager.sh"
}

test_load_outdated_inventory() {
    load_outdated_formula_inventory() {
        printf "python@3.14\nopenjdk@21\n"
    }

    load_outdated_cask_inventory() {
        printf "google-chrome\nchatgpt\n"
    }

    load_outdated_inventory

    assert_equal "2" "${#OUTDATED_FORMULAS[@]}" "outdated formula loader should populate the global formula array"
    assert_equal "2" "${#OUTDATED_CASKS[@]}" "outdated cask loader should populate the global cask array"
    assert_equal "python@3.14
openjdk@21" "$(printf "%s\n" "${OUTDATED_FORMULAS[@]}")" "outdated formula loader should preserve item ordering"
    assert_equal "google-chrome
chatgpt" "$(printf "%s\n" "${OUTDATED_CASKS[@]}")" "outdated cask loader should preserve item ordering"
}

test_load_outdated_inventory_propagates_query_failure() {
    local status=0

    load_outdated_formula_inventory() {
        return 1
    }

    load_outdated_cask_inventory() {
        return 0
    }

    if load_outdated_inventory; then
        status=0
    else
        status="$?"
    fi

    assert_equal "1" "$status" "outdated inventory loading should fail when either Homebrew query fails"
}

test_run_update_projects_flow_reports_outdated_query_failure() {
    local output=""

    require_homebrew_for_feature() {
        return 0
    }

    load_outdated_inventory() {
        return 1
    }

    pause_before_return() {
        true
    }

    output="$(run_update_projects_flow)"

    printf "%s\n" "$output" | grep -Fq "未能读取可升级项目列表。"
    printf "%s\n" "$output" | grep -Fq "失败命令：brew outdated --formula / brew outdated --cask"
}

test_run_update_projects_flow_all_skips_empty_upgrade_bucket() {
    local formula_upgrade_called="0"
    local cask_upgrade_called="0"
    local prompt_count=0

    require_homebrew_for_feature() {
        return 0
    }

    load_outdated_inventory() {
        OUTDATED_FORMULAS=("sqlite")
        OUTDATED_CASKS=()
        return 0
    }

    prompt_yes_no() {
        prompt_count=$((prompt_count + 1))
        return 0
    }

    read() {
        REPLY="all"
        printf -v "$2" '%s' "all"
        return 0
    }

    pause_before_return() {
        true
    }

    print_section_title() {
        true
    }

    print_message() {
        true
    }

    print_status_message() {
        true
    }

    print_output_boundary() {
        true
    }

    render_numbered_list() {
        true
    }

    print_outdated_inventory_report() {
        true
    }

    brew() {
        case "$1" in
            upgrade)
                if [ "${2:-}" = "--cask" ]; then
                    cask_upgrade_called="1"
                else
                    formula_upgrade_called="1"
                fi
                return 0
                ;;
        esac
        return 0
    }

    run_update_projects_flow

    assert_equal "1" "$formula_upgrade_called" "all-selection upgrades should still execute the non-empty formula bucket"
    assert_equal "0" "$cask_upgrade_called" "all-selection upgrades should not invoke an empty cask upgrade bucket"
}

test_homebrew_install_script_url_is_pinned() {
    assert_equal "https://raw.githubusercontent.com/Homebrew/install/$HOMEBREW_INSTALL_SCRIPT_REF/install.sh" "$HOMEBREW_INSTALL_SCRIPT_URL" "Homebrew installer URL should be pinned to an explicit commit"
}

test_build_updatable_item_catalog() {
    OUTDATED_FORMULAS=("python@3.14" "sqlite")
    OUTDATED_CASKS=("chatgpt" "google-chrome")

    build_updatable_item_catalog

    assert_equal "4" "${#UPDATABLE_ITEMS[@]}" "catalog builder should include all outdated items"
    assert_equal "python@3.14 [formula]
sqlite [formula]
chatgpt [cask]
google-chrome [cask]" "$(printf "%s\n" "${UPDATABLE_ITEMS[@]}")" "catalog builder should annotate item types"
    assert_equal "formula:python@3.14
formula:sqlite
cask:chatgpt
cask:google-chrome" "$(printf "%s\n" "${UPDATABLE_TYPES[@]}")" "catalog builder should preserve upgrade command metadata"
}

run_test_case test_main_menu_labels
run_test_case test_uninstall_menu_labels
run_test_case test_tap_menu_labels
run_test_case test_update_menu_labels
run_test_case test_environment_menu_labels
run_test_case test_should_exit_only_at_top_level
run_test_case test_dispatch_main_action
run_test_case test_dispatch_tap_action
run_test_case test_dispatch_update_action
run_test_case test_dispatch_environment_action
run_test_case test_render_inventory_lines
run_test_case test_parse_numeric_choice
run_test_case test_parse_multi_numeric_choice
run_test_case test_populate_array_from_selection
run_test_case test_build_typed_display_items
run_test_case test_describe_tap_associated_cask_state
run_test_case test_describe_tap_associated_cask_state_reports_scan_failure_when_receipt_discovery_fails
run_test_case test_load_cask_app_name_from_receipt_uses_structured_parser
run_test_case test_extract_tap_from_install_receipt_uses_structured_parser
run_test_case test_build_tap_association_display_items
run_test_case test_run_install_flow_prints_installable_catalog_before_confirmation
run_test_case test_run_install_flow_aborts_when_log_directory_creation_fails
run_test_case test_prompt_for_multi_selection_sets_result
run_test_case test_is_valid_tap_name
run_test_case test_collect_installed_items_for_tap
run_test_case test_collect_installed_items_for_tap_fails_closed_when_receipt_parse_fails
run_test_case test_collect_installed_items_for_tap_fails_closed_when_formula_receipt_discovery_fails
run_test_case test_collect_installed_items_for_tap_fails_closed_when_cask_receipt_discovery_fails
run_test_case test_read_command_output_into_array
run_test_case test_read_command_output_into_array_propagates_command_failure
run_test_case test_render_entries_in_columns_column_major
run_test_case test_calculate_column_count_caps_at_six
run_test_case test_calculate_column_count_uses_two_columns_when_terminal_is_too_narrow_for_three
run_test_case test_get_terminal_width_prefers_live_terminal_measurement
run_test_case test_get_terminal_width_falls_back_cleanly
run_test_case test_collect_disk_usage_summary
run_test_case test_print_candidate_list_with_no_items
run_test_case test_create_temp_cask_metadata_file
run_test_case test_fetch_cask_metadata_json_fails_cleanly_when_temp_file_creation_fails
run_test_case test_require_homebrew_for_feature_fails_when_shellenv_initialization_fails
run_test_case test_persist_homebrew_shellenv_to_zprofile_is_idempotent
run_test_case test_persist_homebrew_shellenv_to_zprofile_preserves_existing_line_without_trailing_newline
run_test_case test_configure_homebrew_shellenv_persistence_skips_non_zsh_shells
run_test_case test_is_valid_bundle_identifier
run_test_case test_print_formula_plan_uses_multicolumn_lists
run_test_case test_print_formula_plan_reports_managed_path_scan_failure
run_test_case test_print_formula_plan_reports_managed_path_scan_failure_when_homebrew_query_fails
run_test_case test_collect_formula_plan
run_test_case test_collect_formula_plan_finds_transitive_orphans
run_test_case test_parse_cask_metadata
run_test_case test_collect_formula_plan_with_no_dependencies
run_test_case test_load_formula_uninstall_plan_aborts_when_dependency_user_query_fails
run_test_case test_run_formula_uninstall_flow_stops_after_main_failure
run_test_case test_run_formula_uninstall_batch_respects_post_scan_confirmation
run_test_case test_build_cask_candidate_patterns
run_test_case test_build_cask_temp_candidate_patterns
run_test_case test_filter_cask_candidates_excludes_app_cleaner_metadata
run_test_case test_build_cask_scan_roots_includes_application_scripts_and_http_storages
run_test_case test_collect_cask_cleanup_candidates_expands_zap_patterns
run_test_case test_prune_nested_cask_candidates_removes_descendants
run_test_case test_build_cask_scan_terms_filters_short_final_component
run_test_case test_build_cask_scan_terms_falls_back_to_specific_app_name
run_test_case test_build_cask_candidate_patterns_without_bundle_id_stays_exact
run_test_case test_build_cask_temp_candidate_patterns_without_bundle_id_stay_empty
run_test_case test_find_app_bundle_path_uses_spotlight_when_default_locations_miss
run_test_case test_install_package_with_retries_treats_installed_cask_as_success
run_test_case test_print_installation_summary_marks_missing_worker_results_as_unknown
run_test_case test_scan_cask_roots_for_terms_skips_when_no_safe_terms_exist
run_test_case test_scan_cask_roots_for_terms_uses_app_name_fallback_when_bundle_identifier_missing
run_test_case test_run_cask_uninstall_flow_order
run_test_case test_run_cask_uninstall_flow_skips_residue_deletion_when_homebrew_uninstall_fails
run_test_case test_run_cask_uninstall_flow_with_no_candidates
run_test_case test_remove_path_without_elevation_aborts_when_temp_error_file_creation_fails
run_test_case test_remove_path_with_elevation_aborts_when_temp_error_file_creation_fails
run_test_case test_run_cask_uninstall_batch_respects_per_item_confirmation
run_test_case test_run_cask_uninstall_batch_skips_target_when_candidate_scan_fails
run_test_case test_run_cask_uninstall_batch_falls_back_when_metadata_unavailable
run_test_case test_run_cask_uninstall_batch_resets_metadata_status_per_item
run_test_case test_run_cask_uninstall_batch_skips_target_when_receipt_discovery_fails_in_fallback
run_test_case test_cleanup_command_plan
run_test_case test_run_formula_selection_menu_reports_inventory_failure
run_test_case test_run_cask_selection_menu_reports_inventory_failure
run_test_case test_delete_paths_with_optional_elevation_requires_confirmation
run_test_case test_delete_paths_with_optional_elevation_records_elevated_success
run_test_case test_delete_error_requires_elevation_uses_path_probe
run_test_case test_collect_homebrew_tmp_cleanup_paths_uses_only_defined_homebrew_temp_roots
run_test_case test_collect_homebrew_tmp_cleanup_paths_falls_back_to_tmp_roots_when_homebrew_temp_unset
run_test_case test_run_cleanup_flow_measures_only_local_cleanup_scope
run_test_case test_collect_homebrew_local_cleanup_paths_fails_when_homebrew_queries_fail
run_test_case test_run_cleanup_flow_reports_homebrew_command_failures
run_test_case test_print_homebrew_counts_reports_unknown_when_queries_fail
run_test_case test_run_install_xcode_command_line_tools_flow_reports_launcher_failure
run_test_case test_run_install_homebrew_flow_reports_temp_script_creation_failure
run_test_case test_run_install_homebrew_flow_reports_configured_success
run_test_case test_build_install_parallel_command_avoids_login_shell
run_test_case test_load_outdated_inventory
run_test_case test_load_outdated_inventory_propagates_query_failure
run_test_case test_build_updatable_item_catalog
run_test_case test_run_update_projects_flow_reports_outdated_query_failure
run_test_case test_run_update_projects_flow_all_skips_empty_upgrade_bucket
run_test_case test_homebrew_install_script_url_is_pinned

echo "PASS"
