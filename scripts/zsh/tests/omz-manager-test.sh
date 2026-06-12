#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSH_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT_PATH="$ZSH_DIR/omz-manager.sh"
MANAGED_THEME_START_MARKER="# >>> omz-manager theme >>>"

PASS_COUNT=0
FAIL_COUNT=0

assert_pass() {
    local test_name="$1"
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "  PASS: %s\n" "$test_name"
}

assert_fail() {
    local test_name="$1"
    local detail="${2:-}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "  FAIL: %s%s\n" "$test_name" "${detail:+ - $detail}"
}

assert_equals() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$expected" = "$actual" ]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "expected='$expected' actual='$actual'"
    fi
}

assert_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"

    if printf '%s' "$haystack" | grep -F "$needle" >/dev/null 2>&1; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "output does not contain '$needle'"
    fi
}

assert_not_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"

    if printf '%s' "$haystack" | grep -F "$needle" >/dev/null 2>&1; then
        assert_fail "$test_name" "output unexpectedly contains '$needle'"
    else
        assert_pass "$test_name"
    fi
}

assert_file_exists() {
    local test_name="$1"
    local path="$2"

    if [ -f "$path" ]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "missing file: $path"
    fi
}

run_in_subshell() {
    bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        $1
    " 2>/dev/null
}

make_temp_home() {
    mktemp -d "${TMPDIR:-/tmp}/omz-manager-test-home.XXXXXX"
}

normalize_spaces() {
    printf "%s" "$1" | awk '{$1=$1; print}'
}

run_tidy_in_temp_home() {
    local temp_home="$1"

    HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSH_TIDY_DIR=\"\$HOME/.zsh\"
        ZSH_TIDY_BACKUP_DIR=\"\$ZSH_TIDY_DIR/backups\"
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        reload_zshrc() { return 0; }
        run_zsh_tidy_flow
    " 2>/dev/null
}

test_script_can_be_sourced() {
    local output=""
    output="$(run_in_subshell "printf 'loaded\n'")"
    assert_equals "script can be sourced without running menu" "loaded" "$output"
}

test_main_menu_labels() {
    local output=""
    output="$(run_in_subshell "main_menu_text")"
    assert_equals "main menu shows tidy option" "1) 安装 Oh My Zsh
2) 管理插件
3) 切换主题
4) 整理 Zsh 文件
q) 退出" "$output"
}

test_dispatch_main_choice_tidy() {
    local output=""
    output="$(run_in_subshell "dispatch_main_choice 4")"
    assert_equals "dispatch_main_choice 4" "tidy-zsh-files" "$output"
}

test_remove_managed_block_fails_closed_on_missing_end_marker() {
    local temp_home=""
    local before=""
    local after=""
    local output=""

    temp_home="$(make_temp_home)"
    cat >"$temp_home/.zshrc" <<'EOF'
# >>> omz-manager theme >>>
ZSH_THEME="robbyrussell"
# marker is intentionally broken
export PATH="$HOME/bin:$PATH"
EOF

    before="$(cat "$temp_home/.zshrc")"

    if output="$(HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        remove_managed_block \"\$ZSHRC_PATH\" '# >>> omz-manager theme >>>' '# <<< omz-manager theme <<<'
    " 2>&1)"; then
        assert_fail "corrupted managed block should fail closed" "unexpected success"
    else
        assert_pass "corrupted managed block should fail closed"
    fi

    after="$(cat "$temp_home/.zshrc")"
    assert_equals "corrupted block leaves file unchanged" "$before" "$after"
    assert_contains "corrupted block reports missing end marker" "缺少结束标记" "$output"
}

test_remove_managed_block_reports_duplicate_start_marker() {
    local temp_home=""
    local before=""
    local after=""
    local output=""

    temp_home="$(make_temp_home)"
    cat >"$temp_home/.zshrc" <<'EOF'
# >>> omz-manager theme >>>
ZSH_THEME="robbyrussell"
# >>> omz-manager theme >>>
export PATH="$HOME/bin:$PATH"
EOF

    before="$(cat "$temp_home/.zshrc")"

    if output="$(HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        remove_managed_block \"\$ZSHRC_PATH\" '# >>> omz-manager theme >>>' '# <<< omz-manager theme <<<'
    " 2>&1)"; then
        assert_fail "duplicate start marker should fail closed" "unexpected success"
    else
        assert_pass "duplicate start marker should fail closed"
    fi

    after="$(cat "$temp_home/.zshrc")"
    assert_equals "duplicate start marker leaves file unchanged" "$before" "$after"
    assert_contains "duplicate start marker reports duplicate marker" "重复的 managed block 开始标记" "$output"
}

test_write_managed_block_preserves_unmanaged_conditional_theme_config() {
    local temp_home=""
    local config_after=""

    temp_home="$(make_temp_home)"
    cat >"$temp_home/.zshrc" <<'EOF'
if [[ "$HOST" == "work" ]]; then
    ZSH_THEME="powerlevel10k/powerlevel10k"
else
    ZSH_THEME="robbyrussell"
fi
EOF

    HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        write_managed_block theme 'ZSH_THEME=\"agnoster\"'
    " >/dev/null 2>&1

    config_after="$(cat "$temp_home/.zshrc")"
    assert_contains "unmanaged conditional theme remains untouched" \
'if [[ "$HOST" == "work" ]]; then' "$config_after"
    assert_contains "managed theme block appended separately" \
"$MANAGED_THEME_START_MARKER" "$config_after"
    assert_contains "original unmanaged theme line still active" \
'    ZSH_THEME="powerlevel10k/powerlevel10k"' "$config_after"
    assert_not_contains "unmanaged theme line was not commented out" \
'#     ZSH_THEME="powerlevel10k/powerlevel10k"' "$config_after"
}

test_get_active_plugins_string_supports_multiline_plugins_block() {
    local temp_home=""
    local output=""

    temp_home="$(make_temp_home)"
    cat >"$temp_home/.zshrc" <<'EOF'
plugins=(
  git
  zsh-autosuggestions
  zsh-autocomplete
)
EOF

    output="$(HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        get_active_plugins_string
    ")"

    assert_equals "multiline plugin list is preserved" \
"git zsh-autosuggestions zsh-autocomplete" "$(normalize_spaces "$output")"
}

test_get_active_plugins_string_ignores_inline_comments() {
    local temp_home=""
    local output=""

    temp_home="$(make_temp_home)"
    cat >"$temp_home/.zshrc" <<'EOF'
plugins=(
  git # version control
  zsh-autosuggestions
)
EOF

    output="$(HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        get_active_plugins_string
    ")"

    assert_equals "inline comments are stripped from plugin list" \
"git zsh-autosuggestions" "$(normalize_spaces "$output")"
}

test_sync_plugins_config_does_not_auto_enable_installed_only_plugin() {
    local temp_home=""
    local config_after=""

    temp_home="$(make_temp_home)"
    mkdir -p "$temp_home/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
    printf '%s\n' '# empty' >"$temp_home/.zshrc"

    HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        OMZ_DIR=\"\$HOME/.oh-my-zsh\"
        CUSTOM_PLUGINS_DIR=\"\$OMZ_DIR/custom/plugins\"
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        build_plugin_catalog
        sync_plugins_config
    " >/dev/null 2>&1

    config_after="$(cat "$temp_home/.zshrc")"
    assert_contains "git stays enabled by default" "plugins=(git)" "$config_after"
    assert_not_contains "installed-only plugin should stay disabled" \
"zsh-autosuggestions" "$config_after"
}

test_collect_installed_custom_plugins_ignores_unsafe_directory_names() {
    local temp_home=""
    local output=""

    temp_home="$(make_temp_home)"
    mkdir -p "$temp_home/.oh-my-zsh/custom/plugins/good-plugin"
    mkdir -p "$temp_home/.oh-my-zsh/custom/plugins/bad plugin"

    output="$(HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        OMZ_DIR=\"\$HOME/.oh-my-zsh\"
        CUSTOM_PLUGINS_DIR=\"\$OMZ_DIR/custom/plugins\"
        collect_installed_custom_plugins >/dev/null
        printf '%s\n' \"\${INSTALLED_CUSTOM_PLUGINS[@]}\"
    " 2>&1)"

    assert_contains "safe plugin directory is collected" "good-plugin" "$output"
    assert_not_contains "unsafe plugin directory is ignored" "bad plugin" "$output"
}

test_derive_plugin_name_from_url_rejects_unsafe_paths() {
    if run_in_subshell "derive_plugin_name_from_url 'https://example.com/plugins/..'" >/dev/null 2>&1; then
        assert_fail "unsafe plugin path should be rejected" "unexpected success"
    else
        assert_pass "unsafe plugin path should be rejected"
    fi
}

test_derive_plugin_name_from_url_normalizes_trailing_slash() {
    local output=""
    output="$(run_in_subshell "derive_plugin_name_from_url 'https://example.com/demo-plugin/'")"
    assert_equals "trailing slash is normalized before plugin extraction" "demo-plugin" "$output"
}

test_safe_remove_plugin_destination_refuses_path_outside_plugin_root() {
    local temp_home=""
    local outside_dir=""

    temp_home="$(make_temp_home)"
    outside_dir="$temp_home/outside"
    mkdir -p "$outside_dir"

    if HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        OMZ_DIR=\"\$HOME/.oh-my-zsh\"
        CUSTOM_PLUGINS_DIR=\"\$OMZ_DIR/custom/plugins\"
        safe_remove_plugin_destination '$outside_dir'
    " >/dev/null 2>&1; then
        assert_fail "cleanup outside plugin root should fail" "unexpected success"
    else
        assert_pass "cleanup outside plugin root should fail"
    fi
}

test_install_plugin_specs_returns_failure_when_clone_fails() {
    local output=""
    local status=""

    status=0
    output="$(bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        clone_plugin_with_retry() { return 1; }
        install_plugin_specs 'demo|https://example.com/demo.git'
    " 2>&1)" || status=$?

    assert_equals "failed clone returns non-zero status" "1" "$status"
}

test_get_current_theme_supports_single_quotes() {
    local temp_home=""
    local output=""

    temp_home="$(make_temp_home)"
    printf "%s\n" "ZSH_THEME='agnoster'" >"$temp_home/.zshrc"

    output="$(HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        get_current_theme
    ")"

    assert_equals "single-quoted theme parsed cleanly" "agnoster" "$output"
}

test_tidy_keeps_current_operation_backup_in_home_directory() {
    local temp_home=""
    local home_backup_count=""
    local archived_backup_count=""

    temp_home="$(make_temp_home)"
    printf '%s\n' '# rc' >"$temp_home/.zshrc"

    run_tidy_in_temp_home "$temp_home"

    home_backup_count="$(find "$temp_home" -maxdepth 1 -name '.zshrc.bak.*' | wc -l | awk '{print $1}')"
    archived_backup_count="$(find "$temp_home/.zsh/backups" -maxdepth 1 -name '.zshrc.bak.*' | wc -l | awk '{print $1}')"

    assert_equals "current operation backup stays in home" "1" "$home_backup_count"
    assert_equals "current operation backup is not immediately archived" "0" "$archived_backup_count"
}

test_write_managed_block_does_not_accumulate_blank_lines() {
    local temp_home=""
    local marker_line=""

    temp_home="$(make_temp_home)"
    printf '%s\n' '# rc' >"$temp_home/.zshrc"

    HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        write_managed_block theme 'ZSH_THEME=\"agnoster\"'
        write_managed_block theme 'ZSH_THEME=\"agnoster\"'
    " >/dev/null 2>&1

    marker_line="$(grep -n '^# >>> omz-manager theme >>>' "$temp_home/.zshrc" | cut -d: -f1)"
    assert_equals "managed block keeps a stable separator gap" "3" "$marker_line"
}

test_write_managed_block_rejects_multiline_content() {
    local temp_home=""
    local status=0

    temp_home="$(make_temp_home)"
    printf '%s\n' '# rc' >"$temp_home/.zshrc"

    HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        write_managed_block theme \$'ZSH_THEME=\"agnoster\"\\nZSH_THEME=\"robbyrussell\"'
    " >/dev/null 2>&1 || status=$?

    assert_equals "managed block content must stay single-line" "1" "$status"
}

test_omz_install_url_is_pinned() {
    local output=""
    output="$(run_in_subshell "printf '%s' \"\$OMZ_INSTALL_URL\"")"
    assert_not_contains "installer URL should not track master" "/master/" "$output"
}

test_tidy_moves_zsh_artifacts() {
    local temp_home=""

    temp_home="$(make_temp_home)"
    : >"$temp_home/.zcompdump"
    : >"$temp_home/.zcompdump-dev"
    : >"$temp_home/.zshrc.bak.123"
    : >"$temp_home/.zshrc.backup-legacy"
    : >"$temp_home/.zprofile.bak"
    printf '%s\n' '# existing rc' >"$temp_home/.zshrc"

    run_tidy_in_temp_home "$temp_home"

    assert_file_exists "moves .zcompdump into ~/.zsh" "$temp_home/.zsh/.zcompdump"
    assert_file_exists "moves .zcompdump-dev into ~/.zsh" "$temp_home/.zsh/.zcompdump-dev"
    assert_file_exists "moves .zshrc.bak.* into backups" "$temp_home/.zsh/backups/.zshrc.bak.123"
    assert_file_exists "moves legacy .zshrc backup into backups" "$temp_home/.zsh/backups/.zshrc.backup-legacy"
    assert_file_exists "moves .zprofile.bak into backups" "$temp_home/.zsh/backups/.zprofile.bak"
}

test_tidy_normalizes_zsh_compdump_export() {
    local temp_home=""
    local config_after=""

    temp_home="$(make_temp_home)"
    printf '%s\n' 'export ZSH_COMPDUMP="$HOME/.cache/old-zcompdump"' >"$temp_home/.zshrc"

    run_tidy_in_temp_home "$temp_home"

    config_after="$(cat "$temp_home/.zshrc")"
    assert_contains "preserves unmanaged ZSH_COMPDUMP export" \
'export ZSH_COMPDUMP="$HOME/.cache/old-zcompdump"' "$config_after"
    assert_contains "appends managed compdump block" \
'# >>> omz-manager compdump >>>' "$config_after"
    assert_contains "managed compdump block uses canonical export" \
'export ZSH_COMPDUMP="$HOME/.zsh/zcompdump"' "$config_after"
}

test_tidy_is_idempotent() {
    local temp_home=""
    local export_count=""

    temp_home="$(make_temp_home)"
    printf '%s\n' '# rc' >"$temp_home/.zshrc"
    printf '%s\n' '# profile' >"$temp_home/.zprofile"
    : >"$temp_home/.zcompdump"

    run_tidy_in_temp_home "$temp_home"
    run_tidy_in_temp_home "$temp_home"

    export_count="$(grep -c '^export ZSH_COMPDUMP=' "$temp_home/.zshrc")"
    assert_equals "keeps one active ZSH_COMPDUMP export" "1" "$export_count"
    assert_file_exists "keeps .zprofile in home" "$temp_home/.zprofile"
}

run_test_case() {
    local test_name="$1"
    printf "%s\n" "Running $test_name"
    "$test_name"
}

run_test_case test_script_can_be_sourced
run_test_case test_main_menu_labels
run_test_case test_dispatch_main_choice_tidy
run_test_case test_remove_managed_block_fails_closed_on_missing_end_marker
run_test_case test_remove_managed_block_reports_duplicate_start_marker
run_test_case test_write_managed_block_preserves_unmanaged_conditional_theme_config
run_test_case test_get_active_plugins_string_supports_multiline_plugins_block
run_test_case test_get_active_plugins_string_ignores_inline_comments
run_test_case test_sync_plugins_config_does_not_auto_enable_installed_only_plugin
run_test_case test_collect_installed_custom_plugins_ignores_unsafe_directory_names
run_test_case test_derive_plugin_name_from_url_rejects_unsafe_paths
run_test_case test_derive_plugin_name_from_url_normalizes_trailing_slash
run_test_case test_safe_remove_plugin_destination_refuses_path_outside_plugin_root
run_test_case test_install_plugin_specs_returns_failure_when_clone_fails
run_test_case test_get_current_theme_supports_single_quotes
run_test_case test_tidy_keeps_current_operation_backup_in_home_directory
run_test_case test_write_managed_block_does_not_accumulate_blank_lines
run_test_case test_write_managed_block_rejects_multiline_content
run_test_case test_omz_install_url_is_pinned
run_test_case test_tidy_moves_zsh_artifacts
run_test_case test_tidy_normalizes_zsh_compdump_export
run_test_case test_tidy_is_idempotent

printf "\nPASS: %s\nFAIL: %s\n" "$PASS_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
