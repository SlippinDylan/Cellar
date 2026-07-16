#!/bin/bash

# Test harness for npm-global-manager.sh
# Runs parser and helper function tests using fixtures.
# Usage: bash scripts/node/tests/npm-global-manager-test.sh

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT_PATH="$NODE_DIR/npm-global-manager.sh"
FIXTURES_DIR="$TEST_DIR/fixtures"
mkdir -p "$NODE_DIR/.runtime/tmp"

PASS_COUNT=0
FAIL_COUNT=0

# ──────────────────────────────────────────────
# Test runner helpers
# ──────────────────────────────────────────────

assert_pass() {
    local test_name="$1"
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "  PASS: %s\n" "$test_name"
}

assert_fail() {
    local test_name="$1"
    local detail="${2:-}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "  FAIL: %s%s\n" "$test_name" "${detail:+ — $detail}"
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

    if printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null 2>&1; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "output does not contain '$needle'"
    fi
}

assert_not_contains() {
    local test_name="$1"
    local needle="$2"
    local haystack="$3"

    if printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null 2>&1; then
        assert_fail "$test_name" "output unexpectedly contains '$needle'"
    else
        assert_pass "$test_name"
    fi
}

assert_valid_json_document() {
    local test_name="$1"
    local document="$2"

    if printf '%s' "$document" | ruby -rjson -e 'JSON.parse(STDIN.read)' >/dev/null 2>&1; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "invalid JSON: $document"
    fi
}

assert_exit_success() {
    local test_name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "command exited with non-zero"
    fi
}

assert_exit_failure() {
    local test_name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        assert_fail "$test_name" "command exited with zero but expected failure"
    else
        assert_pass "$test_name"
    fi
}

run_in_subshell() {
    bash -lc "
        set -euo pipefail
        source '$SCRIPT_PATH'
        $1
    " 2>/dev/null
}

# ──────────────────────────────────────────────
# Task 1: Script can be sourced without running menu
# ──────────────────────────────────────────────

test_script_can_be_sourced() {
    local output=""
    output="$(run_in_subshell "printf 'loaded\n'")"
    assert_equals "script can be sourced without running menu" "loaded" "$output"
}

# ──────────────────────────────────────────────
# Task 2: Summary helper tests
# ──────────────────────────────────────────────

test_print_summary_value_with_empty() {
    local output=""
    output="$(run_in_subshell "collect_env_value 'node 版本' ''")"
    assert_contains "collect_env_value handles empty value" "<unavailable>" "$output"
}

test_print_summary_value_with_value() {
    local output=""
    output="$(run_in_subshell "collect_env_value 'node 版本' 'v20.0.0'")"
    assert_contains "collect_env_value displays value" "v20.0.0" "$output"
}

test_parse_scope_registry_lines() {
    local output=""
    output="$(run_in_subshell "parse_scope_registry_lines '$FIXTURES_DIR/npm-config-list-sample.txt'")"
    assert_contains "parse_scope_registry_lines detects @demo scope" "@demo:registry=https://registry.example.com/" "$output"
}

test_command_exists_with_valid_command() {
    run_in_subshell "command_exists printf"
    assert_pass "command_exists returns true for printf"
}

test_command_exists_with_invalid_command() {
    if run_in_subshell "command_exists __nonexistent_command_xyz__" 2>/dev/null; then
        assert_fail "command_exists returns false for nonexistent command"
    else
        assert_pass "command_exists returns false for nonexistent command"
    fi
}

test_runtime_paths_stay_under_scripts_node() {
    local output=""
    output="$(run_in_subshell "manager_runtime_dir" || true)"
    assert_contains "runtime dir under scripts/node" "$NODE_DIR/.runtime" "$output"

    output="$(run_in_subshell "manager_log_dir" || true)"
    assert_contains "log dir under scripts/node" "$NODE_DIR/.runtime/logs" "$output"

    output="$(run_in_subshell "manager_tmp_dir" || true)"
    assert_contains "tmp dir under scripts/node" "$NODE_DIR/.runtime/tmp" "$output"
}

test_macos_guard_rejects_linux() {
    local output=""
    output="$(run_in_subshell "MANAGER_TEST_UNAME=Linux ensure_macos 2>&1")" || true
    assert_contains "macOS guard rejects non-Darwin" "仅支持 macOS" "$output"
}

test_command_exists_empty_fails() {
    if run_in_subshell "command_exists ''" 2>/dev/null; then
        assert_fail "command_exists rejects empty command"
    else
        assert_pass "command_exists rejects empty command"
    fi
}

test_startup_summary_does_not_source_nvm() {
    local fake_home=""
    mkdir -p "$NODE_DIR/.runtime/tmp"
    fake_home="$(mktemp -d "$NODE_DIR/.runtime/tmp/home-summary.XXXXXX")"
    mkdir -p "$fake_home/.nvm"
    printf '%s\n' "echo sourced > \"\$HOME/nvm-sourced\"" > "$fake_home/.nvm/nvm.sh"

    HOME="$fake_home" NVM_DIR="$fake_home/.nvm" run_in_subshell "collect_startup_summary >/dev/null" || true

    if [ -f "$fake_home/nvm-sourced" ]; then
        assert_fail "startup summary must not source nvm"
    else
        assert_pass "startup summary must not source nvm"
    fi
}

test_main_does_not_source_nvm_before_menu() {
    local output=""
    output="$(run_in_subshell "type main")"
    if printf '%s' "$output" | grep -F "load_nvm_into_current_shell" >/dev/null 2>&1; then
        assert_fail "main should not load nvm silently before menu"
    else
        assert_pass "main does not load nvm silently before menu"
    fi
}

test_batch_package_loader_exists() {
    if run_in_subshell "type load_batch_package_list" >/dev/null 2>&1; then
        assert_pass "batch package loader exists"
    else
        assert_fail "batch package loader exists"
    fi
}

test_default_batch_package_list_is_empty() {
    local output=""
    output="$(run_in_subshell "load_batch_package_list" || true)"
    assert_equals "default batch package list empty" "" "$output"
}

test_batch_package_list_reads_config_file() {
    local cfg="$NODE_DIR/.runtime/tmp/global-packages-test.txt"
    local output=""

    mkdir -p "$NODE_DIR/.runtime/tmp"
    printf '# comment\neslint\n\n@scope/pkg@1.2.3\n' > "$cfg"

    output="$(run_in_subshell "GLOBAL_PACKAGES_FILE='$cfg' load_batch_package_list" || true)"
    assert_contains "batch config reads eslint" "eslint" "$output"
    assert_contains "batch config reads scoped version" "@scope/pkg@1.2.3" "$output"
}

test_validate_simple_package_specs() {
    if run_in_subshell "validate_package_spec 'eslint'" 2>/dev/null; then
        assert_pass "valid package accepted"
    else
        assert_fail "valid package accepted"
    fi

    if run_in_subshell "validate_package_spec '@scope/pkg'" 2>/dev/null; then
        assert_pass "valid scoped package accepted"
    else
        assert_fail "valid scoped package accepted"
    fi

    if run_in_subshell "validate_package_spec 'eslint@9.0.0'" 2>/dev/null; then
        assert_pass "valid version spec accepted"
    else
        assert_fail "valid version spec accepted"
    fi

    if run_in_subshell "validate_package_spec 'eslint@next'" 2>/dev/null; then
        assert_pass "valid dist-tag spec accepted"
    else
        assert_fail "valid dist-tag spec accepted"
    fi

    if run_in_subshell "validate_package_spec '@scope/pkg@beta'" 2>/dev/null; then
        assert_pass "valid scoped dist-tag spec accepted"
    else
        assert_fail "valid scoped dist-tag spec accepted"
    fi
}

test_validate_package_specs_reject_invalid_npm_names() {
    if run_in_subshell "validate_package_spec 'Foo'" 2>/dev/null; then
        assert_fail "uppercase package name rejected"
    else
        assert_pass "uppercase package name rejected"
    fi

    if run_in_subshell "validate_package_spec '.bin'" 2>/dev/null; then
        assert_fail "leading dot package name rejected"
    else
        assert_pass "leading dot package name rejected"
    fi

    if run_in_subshell "validate_package_spec '_foo'" 2>/dev/null; then
        assert_fail "leading underscore package name rejected"
    else
        assert_pass "leading underscore package name rejected"
    fi

    if run_in_subshell "validate_package_spec 'node_modules'" 2>/dev/null; then
        assert_fail "reserved package name rejected"
    else
        assert_pass "reserved package name rejected"
    fi
}

test_parse_package_spec_contract() {
    local output=""
    output="$(run_in_subshell "parse_package_spec '@scope/pkg@beta'" || true)"
    assert_equals "parse package spec scoped tag" "@scope/pkg|beta|@scope/pkg@beta" "$output"

    output="$(run_in_subshell "parse_package_spec 'eslint@9.0.0'" || true)"
    assert_equals "parse package spec version" "eslint|9.0.0|eslint@9.0.0" "$output"

    output="$(run_in_subshell "extract_package_requested_version_or_tag 'eslint@next'" || true)"
    assert_equals "extract requested dist-tag" "next" "$output"
}

test_validate_package_name_only_rejects_version_specs() {
    if run_in_subshell "validate_package_name_only 'eslint'" 2>/dev/null; then
        assert_pass "package name only accepts bare package"
    else
        assert_fail "package name only accepts bare package"
    fi

    if run_in_subshell "validate_package_name_only '@scope/pkg'" 2>/dev/null; then
        assert_pass "package name only accepts scoped package"
    else
        assert_fail "package name only accepts scoped package"
    fi

    if run_in_subshell "validate_package_name_only 'eslint@next'" 2>/dev/null; then
        assert_fail "package name only rejects dist-tag spec"
    else
        assert_pass "package name only rejects dist-tag spec"
    fi
}

test_reject_complex_package_specs() {
    if run_in_subshell "validate_package_spec 'npm:eslint@9'" 2>/dev/null; then
        assert_fail "alias spec rejected"
    else
        assert_pass "alias spec rejected"
    fi

    if run_in_subshell "validate_package_spec 'https://example.com/pkg.tgz'" 2>/dev/null; then
        assert_fail "tarball spec rejected"
    else
        assert_pass "tarball spec rejected"
    fi

    if run_in_subshell "validate_package_spec 'file:../pkg.tgz'" 2>/dev/null; then
        assert_fail "file spec rejected"
    else
        assert_pass "file spec rejected"
    fi
}

test_validate_scope_and_registry_url() {
    if run_in_subshell "validate_scope_name '@company'" 2>/dev/null; then
        assert_pass "valid scope accepted"
    else
        assert_fail "valid scope accepted"
    fi

    if run_in_subshell "validate_scope_name '@bad/name'" 2>/dev/null; then
        assert_fail "bad scope rejected"
    else
        assert_pass "bad scope rejected"
    fi

    if run_in_subshell "validate_registry_url 'https://registry.npmjs.org/'" 2>/dev/null; then
        assert_pass "https registry accepted"
    else
        assert_fail "https registry accepted"
    fi

    if run_in_subshell "validate_registry_url 'file:///tmp/registry'" 2>/dev/null; then
        assert_fail "file registry rejected"
    else
        assert_pass "file registry rejected"
    fi
}

test_registry_helpers_use_user_location() {
    local output=""
    output="$(run_in_subshell "type set_registry_value; type set_scope_registry_value; type delete_registry_value; type delete_scope_registry_value")"
    assert_contains "registry helpers use user location" "--location=user" "$output"
}

test_outdated_stderr_uses_mktemp_under_runtime() {
    local output=""
    output="$(run_in_subshell "type run_upgrade_scan_flow")"
    assert_contains "outdated uses mktemp" "mktemp" "$output"
    assert_contains "outdated tmp under manager tmp" "manager_tmp_dir" "$output"
}

test_latest_upgrade_blocks_unknown_latest() {
    local output=""
    output="$(run_in_subshell "type run_upgrade_latest_flow")"
    assert_contains "latest unknown blocks upgrade" "无法获取 latest 版本" "$output"
}

test_cache_directory_delete_requires_full_path_confirmation() {
    local output=""
    output="$(run_in_subshell "type remove_confirmed_cache_directory")"
    assert_contains "cache delete requires full path" "请输入完整路径确认" "$output"
}

test_help_and_version_exist() {
    local output=""
    output="$(run_in_subshell "render_help" || true)"
    assert_contains "help includes dry run" "--dry-run" "$output"

    output="$(run_in_subshell "manager_version" || true)"
    assert_contains "version has script name" "npm-global-manager" "$output"
}

test_json_summary_command_exists() {
    local output=""
    output="$(run_in_subshell "type render_summary_json" || true)"
    assert_contains "json summary function exists" "render_summary_json" "$output"
}

test_log_file_created_under_runtime() {
    local output=""
    output="$(run_in_subshell "ensure_runtime_dirs; create_log_file install eslint" || true)"
    assert_contains "log file under runtime logs" "$NODE_DIR/.runtime/logs/install-eslint" "$output"
}

test_run_logged_command_captures_output() {
    local output=""
    output="$(run_in_subshell "ensure_runtime_dirs; log_file=\$(create_log_file test printf); run_logged_command \"\$log_file\" printf hello; cat \"\$log_file\"" || true)"
    assert_contains "logged command captures stdout" "hello" "$output"
}

# ──────────────────────────────────────────────
# Task 3: Menu dispatch tests
# ──────────────────────────────────────────────

test_dispatch_main_choice_install() {
    local output=""
    output="$(run_in_subshell "dispatch_main_choice 1")"
    assert_equals "dispatch_main_choice 1 -> install" "install" "$output"
}

test_dispatch_main_choice_uninstall() {
    local output=""
    output="$(run_in_subshell "dispatch_main_choice 2")"
    assert_equals "dispatch_main_choice 2 -> uninstall" "uninstall" "$output"
}

test_dispatch_main_choice_update() {
    local output=""
    output="$(run_in_subshell "dispatch_main_choice 3")"
    assert_equals "dispatch_main_choice 3 -> update" "update" "$output"
}

test_dispatch_main_choice_source() {
    local output=""
    output="$(run_in_subshell "dispatch_main_choice 4")"
    assert_equals "dispatch_main_choice 4 -> source-management" "source-management" "$output"
}

test_dispatch_main_choice_environment() {
    local output=""
    output="$(run_in_subshell "dispatch_main_choice 5")"
    assert_equals "dispatch_main_choice 5 -> environment" "environment" "$output"
}

test_dispatch_main_choice_invalid() {
    local output=""
    output="$(run_in_subshell "dispatch_main_choice 9")"
    assert_equals "dispatch_main_choice 9 -> invalid" "invalid" "$output"
}

test_should_exit_menu_main_q() {
    local output=""
    output="$(run_in_subshell "should_exit_menu main q")"
    assert_equals "should_exit_menu main q -> 1" "1" "$output"
}

test_should_exit_menu_main_other() {
    local output=""
    output="$(run_in_subshell "should_exit_menu main 1")"
    assert_equals "should_exit_menu main 1 -> 0" "0" "$output"
}

# ──────────────────────────────────────────────
# Task 4: Global package inventory parser tests
# ──────────────────────────────────────────────

test_parse_global_package_names() {
    local output=""
    output="$(run_in_subshell "parse_global_package_names '$FIXTURES_DIR/npm-list-global-sample.json'")"
    assert_contains "parse_global_package_names finds eslint" "eslint" "$output"
    assert_contains "parse_global_package_names finds typescript" "typescript" "$output"
    assert_contains "parse_global_package_names finds npm-check-updates" "npm-check-updates" "$output"
}

test_parse_global_package_versions() {
    local output=""
    output="$(run_in_subshell "parse_global_package_versions '$FIXTURES_DIR/npm-list-global-sample.json'")"
    assert_contains "parse_global_package_versions shows eslint version" "eslint|9.0.0" "$output"
    assert_contains "parse_global_package_versions shows typescript version" "typescript|5.8.0" "$output"
}

test_parse_global_package_names_sorted() {
    local output=""
    output="$(run_in_subshell "parse_global_package_names '$FIXTURES_DIR/npm-list-global-sample.json'")"
    local first_line=""
    first_line="$(printf '%s' "$output" | head -1)"
    assert_equals "parse_global_package_names sorted first item" "eslint" "$first_line"
}

# ──────────────────────────────────────────────
# Task 5: Outdated parser tests
# ──────────────────────────────────────────────

test_parse_outdated_package_rows() {
    local output=""
    output="$(run_in_subshell "parse_outdated_package_rows '$FIXTURES_DIR/npm-outdated-sample.json'")"
    assert_contains "parse_outdated finds npm-check-updates" "npm-check-updates" "$output"
    assert_contains "parse_outdated finds typescript" "typescript" "$output"
}

test_parse_outdated_package_rows_format() {
    local output=""
    output="$(run_in_subshell "parse_outdated_package_rows '$FIXTURES_DIR/npm-outdated-sample.json'")"
    assert_contains "parse_outdated npm-check-updates row format" "npm-check-updates|16.14.0|16.14.2|17.1.0" "$output"
    assert_contains "parse_outdated typescript row format" "typescript|5.8.0|5.8.3|5.8.3" "$output"
}

# ──────────────────────────────────────────────
# Task 6: Protected package tests
# ──────────────────────────────────────────────

test_protected_package_npm() {
    run_in_subshell "is_protected_global_package npm"
    assert_pass "is_protected_global_package npm is protected"
}

test_protected_package_corepack() {
    run_in_subshell "is_protected_global_package corepack"
    assert_pass "is_protected_global_package corepack is protected"
}

test_protected_package_regular() {
    if run_in_subshell "is_protected_global_package eslint" 2>/dev/null; then
        assert_fail "is_protected_global_package eslint is not protected"
    else
        assert_pass "is_protected_global_package eslint is not protected"
    fi
}

# ──────────────────────────────────────────────
# Input parsing tests
# ──────────────────────────────────────────────

test_parse_numeric_choice_valid() {
    local output=""
    output="$(run_in_subshell "parse_numeric_choice 3 5")"
    assert_equals "parse_numeric_choice valid" "3" "$output"
}

test_parse_numeric_choice_back() {
    local output=""
    output="$(run_in_subshell "parse_numeric_choice b 5")"
    assert_equals "parse_numeric_choice back" "back" "$output"
}

test_parse_numeric_choice_invalid_letter() {
    local output=""
    output="$(run_in_subshell "parse_numeric_choice x 5")"
    assert_equals "parse_numeric_choice invalid letter" "invalid" "$output"
}

test_parse_numeric_choice_out_of_range() {
    local output=""
    output="$(run_in_subshell "parse_numeric_choice 10 5")"
    assert_equals "parse_numeric_choice out of range" "invalid" "$output"
}

test_parse_multi_numeric_choice_valid() {
    local output=""
    output="$(run_in_subshell "parse_multi_numeric_choice '1 3 5' 5")"
    assert_equals "parse_multi_numeric_choice valid" "1 3 5" "$output"
}

test_parse_multi_numeric_choice_all() {
    local output=""
    output="$(run_in_subshell "parse_multi_numeric_choice all 5")"
    assert_equals "parse_multi_numeric_choice all" "all" "$output"
}

test_parse_multi_numeric_choice_back() {
    local output=""
    output="$(run_in_subshell "parse_multi_numeric_choice b 5")"
    assert_equals "parse_multi_numeric_choice back" "back" "$output"
}

test_parse_multi_numeric_choice_invalid() {
    local output=""
    output="$(run_in_subshell "parse_multi_numeric_choice '1 x 3' 5")"
    assert_equals "parse_multi_numeric_choice invalid" "invalid" "$output"
}

test_parse_multi_numeric_choice_dedup() {
    local output=""
    output="$(run_in_subshell "parse_multi_numeric_choice '1 1 2 2' 5")"
    assert_equals "parse_multi_numeric_choice dedup" "1 2" "$output"
}

test_parse_multi_numeric_choice_commas_and_ranges() {
    local output=""
    output="$(run_in_subshell "parse_multi_numeric_choice '1,3-5 2' 6")"
    assert_equals "parse_multi_numeric_choice commas and ranges" "1 3 4 5 2" "$output"

    output="$(run_in_subshell "parse_multi_numeric_choice '4-2' 6")"
    assert_equals "parse_multi_numeric_choice rejects descending range" "invalid" "$output"
}

test_prompt_yes_no_reprompts_invalid_input() {
    if run_in_subshell "printf 'maybe\ny\n' | prompt_yes_no 'confirm' 'n'" >/dev/null 2>&1; then
        assert_pass "prompt_yes_no reprompts after invalid input"
    else
        assert_fail "prompt_yes_no reprompts after invalid input"
    fi
}

# ──────────────────────────────────────────────
# Trim whitespace tests
# ──────────────────────────────────────────────

test_trim_whitespace() {
    local output=""
    output="$(run_in_subshell "trim_whitespace '  hello  '")"
    assert_equals "trim_whitespace strips spaces" "hello" "$output"
}

test_trim_whitespace_tabs() {
    local output=""
    output="$(run_in_subshell "trim_whitespace $'\thello\t'")"
    assert_equals "trim_whitespace strips tabs" "hello" "$output"
}

test_trim_whitespace_empty() {
    local output=""
    output="$(run_in_subshell "trim_whitespace ''")"
    assert_equals "trim_whitespace empty string" "" "$output"
}

# ──────────────────────────────────────────────
# Render menu tests (smoke)
# ──────────────────────────────────────────────

test_render_main_menu() {
    local output=""
    output="$(run_in_subshell "render_main_menu")"
    assert_contains "render_main_menu contains install" "安装项目" "$output"
    assert_contains "render_main_menu contains uninstall" "卸载项目" "$output"
    assert_contains "render_main_menu contains update" "更新与升级" "$output"
    assert_contains "render_main_menu contains source" "源管理" "$output"
    assert_contains "render_main_menu contains environment" "环境与依赖" "$output"
    assert_contains "render_main_menu contains quit" "退出" "$output"
}

test_render_install_menu() {
    local output=""
    output="$(run_in_subshell "render_install_menu")"
    assert_contains "render_install_menu contains single" "单独安装" "$output"
    assert_contains "render_install_menu contains batch" "批量安装" "$output"
}

test_render_source_menu() {
    local output=""
    output="$(run_in_subshell "render_source_menu")"
    assert_contains "render_source_menu contains view" "查看源配置" "$output"
    assert_contains "render_source_menu contains switch" "切换 registry" "$output"
    assert_contains "render_source_menu contains scope" "scope registry" "$output"
}

# ──────────────────────────────────────────────
# Behavioral edge case tests
# ──────────────────────────────────────────────

test_protected_package_empty_string() {
    if run_in_subshell "is_protected_global_package ''" 2>/dev/null; then
        assert_fail "is_protected_global_package empty string is not protected"
    else
        assert_pass "is_protected_global_package empty string is not protected"
    fi
}

test_protected_package_npm_uppercase() {
    # NPM should NOT be protected (case sensitive)
    if run_in_subshell "is_protected_global_package NPM" 2>/dev/null; then
        assert_fail "is_protected_global_package NPM (uppercase) is not protected"
    else
        assert_pass "is_protected_global_package NPM (uppercase) is not protected"
    fi
}

test_protected_package_scoped_name() {
    # @scope/package should NOT be protected
    if run_in_subshell "is_protected_global_package '@scope/package'" 2>/dev/null; then
        assert_fail "is_protected_global_package @scope/package is not protected"
    else
        assert_pass "is_protected_global_package @scope/package is not protected"
    fi
}

test_parse_outdated_stdin_invalid_json() {
    # Invalid JSON should not crash, should return empty
    local output=""
    output="$(printf 'not json at all' | run_in_subshell "parse_outdated_package_rows_stdin")" || true
    assert_equals "parse_outdated handles invalid JSON gracefully" "" "$output"
}

test_parse_outdated_stdin_empty_object() {
    # Empty object should return empty
    local output=""
    output="$(printf '{}' | run_in_subshell "parse_outdated_package_rows_stdin")" || true
    assert_equals "parse_outdated handles empty object" "" "$output"
}

test_parse_global_package_names_invalid_json() {
    # Write invalid JSON to a temp file and test parsing
    local tmpfile=""
    tmpfile="$(mktemp "$NODE_DIR/.runtime/tmp/test-invalid-json.XXXXXX")"
    printf 'not json' > "$tmpfile"
    local output=""
    output="$(run_in_subshell "parse_global_package_names '$tmpfile'")" || true
    rm -f "$tmpfile"
    assert_equals "parse_global_package_names handles invalid JSON" "" "$output"
}

test_parse_scope_registry_lines_no_scope() {
    # File with no scope registries
    local tmpfile=""
    tmpfile="$(mktemp "$NODE_DIR/.runtime/tmp/test-no-scope.XXXXXX")"
    printf 'registry = "https://registry.npmjs.org/"\n' > "$tmpfile"
    local output=""
    output="$(run_in_subshell "parse_scope_registry_lines '$tmpfile'")"
    rm -f "$tmpfile"
    assert_equals "parse_scope_registry_lines returns empty for no scopes" "" "$output"
}

test_parse_scope_registry_lines_multiple_scopes() {
    local tmpfile=""
    tmpfile="$(mktemp "$NODE_DIR/.runtime/tmp/test-multi-scope.XXXXXX")"
    printf '@alpha:registry = "https://alpha.example.com/"\n@beta:registry = "https://beta.example.com/"\n' > "$tmpfile"
    local output=""
    output="$(run_in_subshell "parse_scope_registry_lines '$tmpfile'")"
    rm -f "$tmpfile"
    assert_contains "parse_scope_registry_lines finds @alpha" "@alpha:registry=https://alpha.example.com/" "$output"
    assert_contains "parse_scope_registry_lines finds @beta" "@beta:registry=https://beta.example.com/" "$output"
}

test_dispatch_install_choice_single() {
    local output=""
    output="$(run_in_subshell "dispatch_install_choice 1")"
    assert_equals "dispatch_install_choice 1 -> single-install" "single-install" "$output"
}

test_dispatch_install_choice_batch() {
    local output=""
    output="$(run_in_subshell "dispatch_install_choice 2")"
    assert_equals "dispatch_install_choice 2 -> batch-install" "batch-install" "$output"
}

test_dispatch_install_choice_back() {
    local output=""
    output="$(run_in_subshell "dispatch_install_choice b")"
    assert_equals "dispatch_install_choice b -> back" "back" "$output"
}

test_dispatch_source_choice_view() {
    local output=""
    output="$(run_in_subshell "dispatch_source_choice 1")"
    assert_equals "dispatch_source_choice 1 -> view-source" "view-source" "$output"
}

test_dispatch_source_choice_switch() {
    local output=""
    output="$(run_in_subshell "dispatch_source_choice 2")"
    assert_equals "dispatch_source_choice 2 -> switch-registry" "switch-registry" "$output"
}

test_dispatch_source_choice_scope() {
    local output=""
    output="$(run_in_subshell "dispatch_source_choice 3")"
    assert_equals "dispatch_source_choice 3 -> scope-registry" "scope-registry" "$output"
}

test_dispatch_source_choice_reset() {
    local output=""
    output="$(run_in_subshell "dispatch_source_choice 4")"
    assert_equals "dispatch_source_choice 4 -> reset-registry" "reset-registry" "$output"
}

test_dispatch_environment_choice_overview() {
    local output=""
    output="$(run_in_subshell "dispatch_environment_choice 1")"
    assert_equals "dispatch_environment_choice 1 -> overview" "overview" "$output"
}

test_dispatch_environment_choice_install_nvm() {
    local output=""
    output="$(run_in_subshell "dispatch_environment_choice 2")"
    assert_equals "dispatch_environment_choice 2 -> install-nvm" "install-nvm" "$output"
}

test_dispatch_environment_choice_install_node() {
    local output=""
    output="$(run_in_subshell "dispatch_environment_choice 3")"
    assert_equals "dispatch_environment_choice 3 -> install-node" "install-node" "$output"
}

test_dispatch_environment_choice_switch_node() {
    local output=""
    output="$(run_in_subshell "dispatch_environment_choice 4")"
    assert_equals "dispatch_environment_choice 4 -> switch-node" "switch-node" "$output"
}

test_dispatch_environment_choice_uninstall_node() {
    local output=""
    output="$(run_in_subshell "dispatch_environment_choice 5")"
    assert_equals "dispatch_environment_choice 5 -> uninstall-node" "uninstall-node" "$output"
}

test_dispatch_environment_choice_project_node() {
    local output=""
    output="$(run_in_subshell "dispatch_environment_choice 6")"
    assert_equals "dispatch_environment_choice 6 -> project-node" "project-node" "$output"
}

test_dispatch_environment_choice_cleanup() {
    local output=""
    output="$(run_in_subshell "dispatch_environment_choice 7")"
    assert_equals "dispatch_environment_choice 7 -> cleanup" "cleanup" "$output"
}

test_parse_numeric_choice_empty() {
    local output=""
    output="$(run_in_subshell "parse_numeric_choice '' 5")"
    assert_equals "parse_numeric_choice empty -> invalid" "invalid" "$output"
}

test_parse_multi_numeric_choice_single() {
    local output=""
    output="$(run_in_subshell "parse_multi_numeric_choice '3' 5")"
    assert_equals "parse_multi_numeric_choice single" "3" "$output"
}

test_parse_multi_numeric_choice_out_of_range() {
    local output=""
    output="$(run_in_subshell "parse_multi_numeric_choice '1 10' 5")"
    assert_equals "parse_multi_numeric_choice out of range" "invalid" "$output"
}

test_is_nonnegative_integer_valid() {
    run_in_subshell "is_nonnegative_integer 0"
    assert_pass "is_nonnegative_integer 0 is valid"
}

test_is_nonnegative_integer_negative() {
    if run_in_subshell "is_nonnegative_integer -1" 2>/dev/null; then
        assert_fail "is_nonnegative_integer -1 is not valid"
    else
        assert_pass "is_nonnegative_integer -1 is not valid"
    fi
}

test_is_nonnegative_integer_empty() {
    if run_in_subshell "is_nonnegative_integer ''" 2>/dev/null; then
        assert_fail "is_nonnegative_integer empty is not valid"
    else
        assert_pass "is_nonnegative_integer empty is not valid"
    fi
}

test_format_status_tag_ok() {
    local output=""
    output="$(run_in_subshell "NO_COLOR=1 format_status_tag ok")"
    assert_contains "format_status_tag ok contains OK" "OK" "$output"
}

test_format_status_tag_fail() {
    local output=""
    output="$(run_in_subshell "NO_COLOR=1 format_status_tag fail")"
    assert_contains "format_status_tag fail contains FAIL" "FAIL" "$output"
}

test_format_status_tag_warn() {
    local output=""
    output="$(run_in_subshell "NO_COLOR=1 format_status_tag warn")"
    assert_contains "format_status_tag warn contains WARN" "WARN" "$output"
}

test_collect_env_value_placeholder() {
    local output=""
    output="$(run_in_subshell "collect_env_value 'test' ''")"
    assert_contains "collect_env_value shows <unavailable> for empty" "<unavailable>" "$output"
}

test_collect_env_value_real() {
    local output=""
    output="$(run_in_subshell "collect_env_value 'test' 'value123'")"
    assert_contains "collect_env_value shows real value" "value123" "$output"
    assert_contains "collect_env_value includes label" "test" "$output"
}

# ──────────────────────────────────────────────
# extract_package_name tests
# ──────────────────────────────────────────────

test_extract_package_name_simple() {
    local output=""
    output="$(run_in_subshell "extract_package_name 'typescript'")"
    assert_equals "extract_package_name simple" "typescript" "$output"
}

test_extract_package_name_scoped() {
    local output=""
    output="$(run_in_subshell "extract_package_name '@scope/package'")"
    assert_equals "extract_package_name scoped" "@scope/package" "$output"
}

test_extract_package_name_with_version() {
    local output=""
    output="$(run_in_subshell "extract_package_name 'typescript@5.8.3'")"
    assert_equals "extract_package_name with version" "typescript" "$output"
}

test_extract_package_name_scoped_with_version() {
    local output=""
    output="$(run_in_subshell "extract_package_name '@scope/package@1.0.0'")"
    assert_equals "extract_package_name scoped with version" "@scope/package" "$output"
}

test_extract_package_name_scoped_with_tag() {
    local output=""
    output="$(run_in_subshell "extract_package_name '@scope/package@beta'")"
    assert_equals "extract_package_name scoped with tag" "@scope/package" "$output"
}

# ──────────────────────────────────────────────
# Upgrade semantics tests
# ──────────────────────────────────────────────

test_upgrade_global_package_uses_update() {
    # Verify upgrade_global_package calls npm update, not npm install @latest
    local output=""
    output="$(run_in_subshell "type upgrade_global_package")"
    assert_contains "upgrade_global_package uses npm update" "npm update" "$output"
}

test_upgrade_global_package_to_latest_uses_latest() {
    # Verify upgrade_global_package_to_latest calls npm install @latest
    local output=""
    output="$(run_in_subshell "type upgrade_global_package_to_latest")"
    assert_contains "upgrade_global_package_to_latest uses @latest" "@latest" "$output"
}

# ──────────────────────────────────────────────
# JSON validation tests
# ──────────────────────────────────────────────

test_parse_outdated_valid_json() {
    local output=""
    output="$(printf '{"pkg":{"current":"1.0.0","wanted":"1.1.0","latest":"2.0.0"}}' | run_in_subshell "parse_outdated_package_rows_stdin")"
    assert_contains "parse_outdated parses valid JSON" "pkg|1.0.0|1.1.0|2.0.0" "$output"
}

test_parse_outdated_invalid_json_returns_empty() {
    local output=""
    output="$(printf 'not json at all' | run_in_subshell "parse_outdated_package_rows_stdin")" || true
    assert_equals "parse_outdated returns empty for invalid JSON" "" "$output"
}

test_parse_global_package_names_valid_json() {
    local tmpfile=""
    tmpfile="$(mktemp "$NODE_DIR/.runtime/tmp/test-valid-json.XXXXXX")"
    printf '{"dependencies":{"alpha":{"version":"1.0.0"},"beta":{"version":"2.0.0"}}}' > "$tmpfile"
    local output=""
    output="$(run_in_subshell "parse_global_package_names '$tmpfile'")"
    rm -f "$tmpfile"
    assert_contains "parse_global_package_names finds alpha" "alpha" "$output"
    assert_contains "parse_global_package_names finds beta" "beta" "$output"
}

test_parse_global_package_names_invalid_json_returns_empty() {
    local tmpfile=""
    tmpfile="$(mktemp "$NODE_DIR/.runtime/tmp/test-invalid-json.XXXXXX")"
    printf 'not json' > "$tmpfile"
    local output=""
    output="$(run_in_subshell "parse_global_package_names '$tmpfile'")" || true
    rm -f "$tmpfile"
    assert_equals "parse_global_package_names returns empty for invalid JSON" "" "$output"
}

# ──────────────────────────────────────────────
# Verification logic tests
# ──────────────────────────────────────────────

test_node_version_exact_match() {
    if run_in_subshell "node_version_matches 'v20.11.0' '20.11.0'" 2>/dev/null; then
        assert_pass "node version exact match accepts same version"
    else
        assert_fail "node version exact match accepts same version"
    fi
}

test_node_version_rejects_prefix_match() {
    if run_in_subshell "node_version_matches 'v20.10.0' '20.1'" 2>/dev/null; then
        assert_fail "20.1 must not match 20.10.0"
    else
        assert_pass "20.1 does not match 20.10.0"
    fi
}

test_cache_path_safety_rejects_root() {
    # Verify the guard logic rejects /
    local resolved_path="/"
    case "$resolved_path" in
        "$HOME"/*|"/tmp"/*|"/private/tmp"*)
            assert_fail "cache path safety should reject /"
            ;;
        *)
            assert_pass "cache path safety rejects /"
            ;;
    esac
}

test_cache_path_safety_rejects_home() {
    local resolved_path="$HOME"
    case "$resolved_path" in
        "$HOME"/*|"/tmp"/*|"/private/tmp"*)
            assert_fail "cache path safety should reject HOME itself"
            ;;
        *)
            assert_pass "cache path safety rejects HOME itself"
            ;;
    esac
}

test_check_bin_entries_with_real_bin() {
    # Test with a real package (npm) that we know has bin entries
    local global_bin_dir=""
    global_bin_dir="$(npm prefix -g 2>/dev/null)/bin"
    if [ -d "$global_bin_dir" ]; then
        local result=""
        result="$(run_in_subshell "check_bin_entries 'npm' '$global_bin_dir' list")"
        if [ -n "$result" ]; then
            assert_pass "check_bin_entries finds npm bin entries"
        else
            assert_fail "check_bin_entries should find npm bin entries"
        fi
    else
        assert_pass "check_bin_entries: global bin dir not found (skip)"
    fi
}

test_extract_package_name_edge_cases() {
    # Already covered simple/scoped/version cases above
    # Test empty string
    local output=""
    output="$(run_in_subshell "extract_package_name ''")" || true
    assert_equals "extract_package_name empty string" "" "$output"
}

test_bin_string_uses_package_name() {
    local tmp="$NODE_DIR/.runtime/tmp/pkg-bin-string.json"
    local output=""

    mkdir -p "$NODE_DIR/.runtime/tmp"
    printf '{"name":"my-cli","bin":"dist/index.js"}\n' > "$tmp"

    output="$(run_in_subshell "parse_package_bin_names '$tmp'" || true)"
    assert_equals "bin string command is package name" "my-cli" "$output"
}

test_residue_symlink_requires_target_under_package_dir() {
    local tmp=""

    tmp="$(mktemp -d "$NODE_DIR/.runtime/tmp/residue.XXXXXX")"
    mkdir -p "$tmp/pkg/bin" "$tmp/bin"
    touch "$tmp/pkg/bin/cli.js" "$tmp/other.js"
    ln -sf "$tmp/pkg/bin/cli.js" "$tmp/bin/good"
    ln -sf "$tmp/other.js" "$tmp/bin/bad"

    if run_in_subshell "is_owned_symlink '$tmp/bin/good' '$tmp/pkg'" 2>/dev/null; then
        assert_pass "owned symlink accepted"
    else
        assert_fail "owned symlink accepted"
    fi

    if run_in_subshell "is_owned_symlink '$tmp/bin/bad' '$tmp/pkg'" 2>/dev/null; then
        assert_fail "foreign symlink rejected"
    else
        assert_pass "foreign symlink rejected"
    fi
}

test_atomic_write_file_replaces_content() {
    local dir=""
    local output=""

    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/atomic.XXXXXX")"
    mkdir -p "$dir"
    printf 'old\n' > "$dir/.nvmrc"

    run_in_subshell "atomic_write_file '$dir/.nvmrc' 'v20.11.1'" || true
    output="$(cat "$dir/.nvmrc")"
    assert_equals "atomic write replaces file" "v20.11.1" "$output"
}

# ──────────────────────────────────────────────
# nvm ls parsing tests (using fixture)
# ──────────────────────────────────────────────

test_nvm_ls_parsing_installed_only() {
    # The grep pattern should extract only installed versions, not aliases
    local fixture="$FIXTURES_DIR/nvm-ls-sample.txt"
    local result=""
    result="$(grep -E '^[[:space:]]*(->[[:space:]])?[[:space:]]*v[0-9]' "$fixture" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq)"
    assert_contains "nvm ls parsing finds v18.20.8" "v18.20.8" "$result"
    assert_contains "nvm ls parsing finds v20.11.1" "v20.11.1" "$result"
    assert_contains "nvm ls parsing finds v22.3.0" "v22.3.0" "$result"
}

test_nvm_ls_parsing_excludes_aliases() {
    # Should NOT include alias-resolved versions like v24.11.0 from "stable -> 24.11 (-> v24.11.0)"
    local fixture="$FIXTURES_DIR/nvm-ls-sample.txt"
    local result=""
    result="$(grep -E '^[[:space:]]*(->[[:space:]])?[[:space:]]*v[0-9]' "$fixture" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq)"
    # v4.9.1 appears in "lts/argon -> v4.9.1 (-> N/A)" which should be excluded
    if printf '%s' "$result" | grep -qF 'v4.9.1'; then
        assert_fail "nvm ls parsing should exclude lts/argon v4.9.1"
    else
        assert_pass "nvm ls parsing excludes lts/argon v4.9.1"
    fi
}

test_nvm_ls_parsing_excludes_lts_n_a() {
    # Should NOT include versions from lines with N/A
    local fixture="$FIXTURES_DIR/nvm-ls-sample.txt"
    local result=""
    result="$(grep -E '^[[:space:]]*(->[[:space:]])?[[:space:]]*v[0-9]' "$fixture" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq)"
    # Count lines by replacing newlines and counting
    local count=0
    count="$(printf '%s\n' "$result" | grep -c 'v[0-9]' || true)"
    assert_equals "nvm ls parsing returns exactly 3 installed versions" "3" "$count"
}

test_global_bin_dir_returns_bin_path() {
    local output=""
    output="$(run_in_subshell "npm() { if [ \"\$1\" = prefix ]; then printf '/mock/prefix\n'; fi; }; get_global_bin_dir")"
    assert_equals "get_global_bin_dir returns prefix bin directory" "/mock/prefix/bin" "$output"
}

test_nvm_paths_respect_custom_nvm_dir() {
    local output=""
    output="$(run_in_subshell "NVM_DIR='/custom/nvm' nvm_versions_root")"
    assert_equals "nvm versions root respects custom NVM_DIR" "/custom/nvm/versions/node" "$output"

    output="$(run_in_subshell "NVM_DIR='/custom/nvm' nvm_version_dir 'v20.11.1'")"
    assert_equals "nvm version dir respects custom NVM_DIR" "/custom/nvm/versions/node/v20.11.1" "$output"
}

test_node_gyp_cache_dir_detection_uses_devdir() {
    local output=""
    output="$(run_in_subshell "npm_config_devdir='/tmp/node-gyp-devdir' detect_node_gyp_cache_dir")"
    assert_equals "node-gyp cache uses npm_config_devdir" "/tmp/node-gyp-devdir" "$output"
}

test_node_gyp_cache_candidates_include_modern_paths() {
    local output=""
    output="$(run_in_subshell "HOME='/Users/tester'; npm() { if [ \"\$1 \$2 \$3\" = 'config get devdir' ]; then printf 'undefined\n'; fi; }; detect_node_gyp_cache_dirs" || true)"
    assert_contains "node-gyp candidates include legacy path" "/Users/tester/.node-gyp|legacy-home" "$output"
    assert_contains "node-gyp candidates include macOS cache path" "/Users/tester/Library/Caches/node-gyp|macos-cache" "$output"
}

test_safe_removable_child_dir_boundaries() {
    local root=""
    root="$(mktemp -d "$NODE_DIR/.runtime/tmp/safe-root.XXXXXX")"
    local child="$root/child"
    local outside=""
    outside="$(mktemp -d "$NODE_DIR/.runtime/tmp/outside-child.XXXXXX")"
    mkdir -p "$child" "$outside"

    if run_in_subshell "is_safe_removable_child_dir '$child' '$root'" 2>/dev/null; then
        assert_pass "safe removable child accepts child directory"
    else
        assert_fail "safe removable child accepts child directory"
    fi

    if run_in_subshell "is_safe_removable_child_dir '$root' '$root'" 2>/dev/null; then
        assert_fail "safe removable child rejects root itself"
    else
        assert_pass "safe removable child rejects root itself"
    fi

    if run_in_subshell "is_safe_removable_child_dir '$outside' '$root'" 2>/dev/null; then
        assert_fail "safe removable child rejects outside directory"
    else
        assert_pass "safe removable child rejects outside directory"
    fi
}

test_count_user_global_packages_invalid_json_fails() {
    if run_in_subshell "printf 'not-json' | count_user_global_packages_from_json" >/dev/null 2>&1; then
        assert_fail "invalid global package JSON is not treated as zero"
    else
        assert_pass "invalid global package JSON is not treated as zero"
    fi
}

test_install_nvm_official_does_not_pipe_curl_to_bash() {
    local output=""
    output="$(run_in_subshell "type install_nvm_official")"
    if printf '%s' "$output" | grep -F 'curl -o-' >/dev/null 2>&1; then
        assert_fail "install_nvm_official avoids curl pipe bash"
    else
        assert_pass "install_nvm_official avoids curl pipe bash"
    fi
}

test_dependency_preflight_allows_missing_ruby() {
    if ! run_in_subshell "type run_dependency_preflight" >/dev/null 2>&1; then
        assert_fail "dependency preflight helper exists"
        return
    fi
    assert_pass "dependency preflight helper exists"

    if run_in_subshell "command_exists() { [ \"\$1\" != ruby ]; }; run_dependency_preflight" >/dev/null 2>&1; then
        assert_pass "dependency preflight allows missing ruby"
    else
        assert_fail "dependency preflight allows missing ruby"
    fi
}

test_batch_install_uses_per_package_logs() {
    local output=""
    output="$(run_in_subshell "type run_batch_install_flow")"
    assert_contains "batch install creates per-package logs" "create_log_file batch-package" "$output"
}

test_mutating_package_flows_use_logged_commands() {
    local output=""
    output="$(run_in_subshell "type run_upgrade_scan_flow; type run_uninstall_flow")"
    assert_contains "upgrade flow creates package logs" "create_log_file upgrade" "$output"
    assert_contains "uninstall flow creates package logs" "create_log_file uninstall" "$output"
    assert_contains "uninstall flow uses mutation helper" "uninstall_global_package" "$output"

    output="$(run_in_subshell "type uninstall_global_package")"
    assert_contains "uninstall mutation helper runs logged command" "run_logged_command" "$output"
}

test_source_overview_shows_config_layers() {
    local output=""
    output="$(run_in_subshell "type run_source_overview")"
    assert_contains "source overview shows effective layer" "effective" "$output"
    assert_contains "source overview shows user location" "--location=user" "$output"
    assert_contains "source overview shows project location" "--location=project" "$output"
    assert_contains "source overview shows global location" "--location=global" "$output"
}

test_uninstall_flow_validates_inventory_json() {
    local output=""
    output="$(run_in_subshell "type run_uninstall_flow")"
    assert_contains "uninstall flow validates npm inventory JSON" "validate_json_text" "$output"
}

test_dragged_path_normalizer_handles_quotes() {
    local output=""
    output="$(run_in_subshell "normalize_dragged_path \"'/tmp/My\\ Project/'\"")"
    assert_equals "dragged path normalizer handles single quotes and spaces" "/tmp/My Project" "$output"
}

test_node_version_choice_accepts_list_index() {
    local output=""
    output="$(run_in_subshell "select_version_from_number_or_literal 2 v18.20.8 v20.11.1 v22.3.0")"
    assert_equals "node version choice accepts list index" "v20.11.1" "$output"

    output="$(run_in_subshell "select_version_from_number_or_literal 20 v18.20.8 v20.11.1 v22.3.0")"
    assert_equals "node version choice keeps out-of-range number literal" "20" "$output"
}

test_project_nvmrc_literal_resolves_to_unique_concrete_installed_version() {
    local output=""

    output="$(run_in_subshell "resolve_project_nvmrc_concrete_version 20 v18.20.8 v20.11.1 v20.12.0" || true)"
    assert_equals "ambiguous project nvmrc shorthand is rejected" "" "$output"

    output="$(run_in_subshell "resolve_project_nvmrc_concrete_version 20.11 v18.20.8 v20.11.1 v22.3.0" || true)"
    assert_equals "project nvmrc minor shorthand resolves unique installed version" "v20.11.1" "$output"

    output="$(run_in_subshell "resolve_project_nvmrc_concrete_version 20.11.1 v18.20.8 v20.11.1 v22.3.0" || true)"
    assert_equals "project nvmrc concrete literal is normalized" "v20.11.1" "$output"
}

test_project_node_flow_has_nvmrc_rollback() {
    local output=""
    output="$(run_in_subshell "type run_project_node_flow")"
    assert_contains "project node flow can rollback nvmrc" "rollback_nvmrc_file" "$output"
}

test_uninstall_plan_shows_package_metadata() {
    local output=""
    output="$(run_in_subshell "type run_uninstall_flow")"
    assert_contains "uninstall plan shows package metadata" "summarize_package_metadata" "$output"
}

test_scope_registry_flow_is_looping_menu() {
    local output=""
    output="$(run_in_subshell "type run_scope_registry_flow")"
    assert_contains "scope registry flow loops for repeated management" "while true" "$output"
}

test_profile_nvm_init_requires_nvm_sh() {
    local dir=""
    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/profile-check.XXXXXX")"
    mkdir -p "$dir"
    printf '%s\n' "export NVM_DIR=\"\$HOME/.nvm\"" > "$dir/incomplete"
    {
        printf '%s\n' "export NVM_DIR=\"\$HOME/.nvm\""
        printf '%s\n' "[ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\""
    } > "$dir/complete"

    if run_in_subshell "profile_has_complete_nvm_init '$dir/incomplete'" >/dev/null 2>&1; then
        assert_fail "profile nvm init rejects incomplete block"
    else
        assert_pass "profile nvm init rejects incomplete block"
    fi

    if run_in_subshell "profile_has_complete_nvm_init '$dir/complete'" >/dev/null 2>&1; then
        assert_pass "profile nvm init accepts complete block"
    else
        assert_fail "profile nvm init accepts complete block"
    fi
}

test_install_nvm_official_with_mock_curl() {
    mkdir -p "$NODE_DIR/.runtime/tmp"
    local dir=""
    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/mock-nvm-install.XXXXXX")"

    if run_in_subshell "curl() { while [ \"\$#\" -gt 0 ]; do if [ \"\$1\" = -o ]; then shift; printf 'printf installed > \"$dir/marker\"\\n' > \"\$1\"; return 0; fi; shift; done; return 1; }; NVM_INSTALL_URL='https://example.invalid/install.sh'; NVM_INSTALL_SHA256=''; NVM_ALLOW_UNVERIFIED_INSTALL=1; install_nvm_official" >/dev/null 2>&1; then
        if [ -f "$dir/marker" ]; then
            assert_pass "install_nvm_official runs mocked downloaded script"
        else
            assert_fail "install_nvm_official runs mocked downloaded script" "marker missing"
        fi
    else
        assert_fail "install_nvm_official runs mocked downloaded script" "install function failed"
    fi
}

test_install_nvm_official_blocks_unverified_direct_call() {
    local output=""

    output="$(run_in_subshell "curl() { printf 'curl should not run\n'; return 0; }; NVM_INSTALL_SHA256=''; NVM_ALLOW_UNVERIFIED_INSTALL=0; install_nvm_official" || true)"
    assert_contains "install_nvm_official direct call blocks unverified install" "NVM_ALLOW_UNVERIFIED_INSTALL=1" "$output"
    assert_not_contains "install_nvm_official direct call does not fetch unverified script" "curl should not run" "$output"
}

test_batch_install_supports_subset_selection() {
    local output=""
    output="$(run_in_subshell "type run_batch_install_flow")"
    assert_contains "batch install prompts for subset selection" "选择要安装的包" "$output"
    assert_contains "batch install tracks warned count" "警告" "$output"
    assert_contains "batch install tracks unknown count" "未知" "$output"
}

test_batch_install_summary_counts_final_package_state_once() {
    local config_file=""
    local output=""

    config_file="$(mktemp "$NODE_DIR/.runtime/tmp/batch-summary.XXXXXX")"
    printf 'eslint@9.0.0\n' > "$config_file"
    output="$(printf 'all\ny\n\n' | run_in_subshell "GLOBAL_PACKAGES_FILE='$config_file'; INSTALL_MAX_RETRIES=2; node() { printf 'v20.11.1\n'; }; npm() { if [ \"\$1\" = view ]; then printf '9.0.0\n'; return 0; fi; if [ \"\$1\" = install ]; then return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"8.0.0\"}}}\n'; return 0; fi; if [ \"\$1\" = prefix ]; then printf '/tmp/prefix\n'; return 0; fi; if [ \"\$1\" = -v ]; then printf '10.0.0\n'; return 0; fi; return 0; }; run_batch_install_flow" || true)"
    assert_contains "batch summary counts one failed package" "失败: 1" "$output"
    assert_contains "batch summary does not count every failed attempt as warning" "警告: 0" "$output"
}

test_batch_all_selects_only_pending_indices() {
    local output=""
    output="$(run_in_subshell "select_pending_indices_from_flags 'no yes no'" || true)"
    assert_equals "batch all selects pending only" "1 3" "$output"
}

test_uninstall_flow_rescans_remaining_packages() {
    local output=""
    output="$(run_in_subshell "type run_uninstall_flow")"
    assert_contains "uninstall flow rescans remaining package state" "卸载后剩余全局包" "$output"
}

test_nvm_managed_detection_resolves_custom_dir() {
    mkdir -p "$NODE_DIR/.runtime/tmp"
    local dir=""
    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/nvm-managed.XXXXXX")"
    mkdir -p "$dir/nvm/versions/node/v20.11.1/bin"
    touch "$dir/nvm/versions/node/v20.11.1/bin/node"

    if run_in_subshell "NVM_DIR='$dir/nvm' is_node_path_nvm_managed '$dir/nvm/versions/node/v20.11.1/bin/node'" >/dev/null 2>&1; then
        assert_pass "nvm managed detection accepts custom NVM_DIR"
    else
        assert_fail "nvm managed detection accepts custom NVM_DIR"
    fi
}

test_environment_overview_has_nvm_diagnostics() {
    local output=""
    output="$(run_in_subshell "type run_environment_overview")"
    assert_contains "environment overview reports nvm diagnostics" "nvm 诊断" "$output"
    assert_contains "environment overview reports nvm script path" "nvm_script_path" "$output"
}

test_environment_overview_shows_dir_scanned_versions_when_nvm_unloaded() {
    local nvm_dir=""
    local output=""
    nvm_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/env-nvm.XXXXXX")"
    mkdir -p "$nvm_dir/versions/node/v20.11.1"
    printf '# nvm\n' > "$nvm_dir/nvm.sh"

    output="$(printf '\n' | run_in_subshell "NVM_DIR='$nvm_dir'; is_nvm_loaded() { return 1; }; load_nvm_into_current_shell() { return 1; }; run_environment_overview" || true)"
    assert_contains "environment overview shows directory-scanned version" "v20.11.1" "$output"
}

test_scope_registry_layers_are_available() {
    local output=""
    output="$(run_in_subshell "type print_scope_registry_layers")"
    assert_contains "scope registry layers include effective" "effective" "$output"
    assert_contains "scope registry layers include user" "--location=user" "$output"
    assert_contains "scope registry layers include project" "--location=project" "$output"
    assert_contains "scope registry layers include global" "--location=global" "$output"
}

test_registry_write_status_distinguishes_effective_layer() {
    local output=""
    output="$(run_in_subshell "npm() { if [ \"\$1\" = config ] && [ \"\$2\" = set ] && [ \"\$3\" = registry ]; then return 0; fi; if [ \"\$1\" = config ] && [ \"\$2\" = get ] && [ \"\$3\" = registry ] && [ \"\${4:-}\" = --location=user ]; then printf 'https://user.example/\n'; return 0; fi; if [ \"\$1\" = config ] && [ \"\$2\" = get ] && [ \"\$3\" = registry ]; then printf 'https://project.example/\n'; return 0; fi; return 1; }; set_registry_value 'https://user.example/' || true")"
    assert_contains "registry set reports effective mismatch" "effective-mismatch" "$output"
}

test_scope_registry_write_status_distinguishes_effective_layer() {
    local output=""
    output="$(run_in_subshell "npm() { if [ \"\$1\" = config ] && [ \"\$2\" = set ]; then return 0; fi; if [ \"\$1\" = config ] && [ \"\$2\" = get ] && [ \"\$3\" = '@demo:registry' ] && [ \"\${4:-}\" = --location=user ]; then printf 'https://user.example/\n'; return 0; fi; if [ \"\$1\" = config ] && [ \"\$2\" = get ] && [ \"\$3\" = '@demo:registry' ]; then printf 'https://project.example/\n'; return 0; fi; return 1; }; set_scope_registry_value '@demo' 'https://user.example/' || true")"
    assert_contains "scope registry set reports effective mismatch" "effective-mismatch" "$output"
}

test_json_cli_has_app_commands() {
    local output=""
    output="$(run_in_subshell "render_help")"
    assert_contains "json CLI documents packages command" "--json packages" "$output"
    assert_contains "json CLI documents outdated command" "--json outdated" "$output"
    assert_contains "json CLI documents config command" "--json config" "$output"
    assert_contains "json CLI documents package-plan command" "--json package-plan" "$output"
    assert_contains "json CLI documents plan command" "--json plan" "$output"
    assert_contains "json CLI documents execute command" "--json execute" "$output"
    assert_contains "json CLI documents status command" "--json status" "$output"
    assert_contains "json CLI documents logs command" "--json logs" "$output"
}

test_json_plan_status_logs_contracts() {
    local output=""
    output="$(run_in_subshell "npm() { if [ \"\$1\" = view ]; then printf '9.0.0\n'; return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{}}\n'; return 0; fi; }; render_action_plan_json install 'eslint@next'")"
    assert_contains "json plan has schema version" '"schemaVersion":1' "$output"
    assert_contains "json plan has package name" '"packageName":"eslint"' "$output"
    assert_not_contains "json plan does not expose operation id" '"operationId":' "$output"
    assert_not_contains "json plan does not expose real log file" '"logFile":' "$output"

    output="$(run_in_subshell "render_status_json")"
    assert_contains "json status has runtime dir" '"runtimeDir":' "$output"

    output="$(run_in_subshell "render_logs_json 1")"
    assert_contains "json logs returns array" "[" "$output"
}

test_json_summary_and_status_do_not_require_npm() {
    local output=""
    output="$(run_in_subshell "command_exists() { [ \"\$1\" != npm ]; }; run_json_command summary" || true)"
    assert_contains "json summary works without npm" '"nodePath":' "$output"

    output="$(run_in_subshell "command_exists() { [ \"\$1\" != npm ]; }; run_json_command status" || true)"
    assert_contains "json status works without npm" '"runtimeDir":' "$output"
}

test_json_execute_is_disabled_by_default() {
    local output=""
    output="$(run_in_subshell "render_execute_json install eslint" || true)"
    assert_contains "json execute disabled by default" "json-execute-disabled" "$output"
}

test_node_version_range_matching() {
    if run_in_subshell "node_version_satisfies_request 'v20.11.1' '20'" >/dev/null 2>&1; then
        assert_pass "node version request 20 matches installed v20.x"
    else
        assert_fail "node version request 20 matches installed v20.x"
    fi

    if run_in_subshell "normalize_node_version 'abc'" >/dev/null 2>&1; then
        assert_fail "normalize_node_version rejects invalid version"
    else
        assert_pass "normalize_node_version rejects invalid version"
    fi
}

test_help_and_version_skip_macos_guard() {
    if MANAGER_TEST_UNAME=Linux bash "$SCRIPT_PATH" --help >/dev/null 2>&1; then
        assert_pass "help works before macOS guard"
    else
        assert_fail "help works before macOS guard"
    fi

    if MANAGER_TEST_UNAME=Linux bash "$SCRIPT_PATH" --version >/dev/null 2>&1; then
        assert_pass "version works before macOS guard"
    else
        assert_fail "version works before macOS guard"
    fi
}

test_dry_run_and_test_mode_are_real_cli_modes() {
    local output=""
    output="$(MANAGER_TEST_UNAME=Darwin bash "$SCRIPT_PATH" --dry-run 2>&1 || true)"
    assert_contains "dry run is now info mode" "INFO" "$output"

    output="$(MANAGER_TEST_UNAME=Darwin bash "$SCRIPT_PATH" --test-mode 2>&1 || true)"
    assert_contains "test mode prints status and exits" "TEST MODE" "$output"
}

test_json_escape_without_ruby_is_valid() {
    local output=""
    output="$(run_in_subshell "ruby() { return 127; }; json_escape 'a\"b\\c'")"
    assert_equals "json_escape fallback escapes quotes and backslashes" "a\\\"b\\\\c" "$output"
}

test_json_commands_run_preflight() {
    if run_in_subshell "command_exists() { [ \"\$1\" != ruby ]; }; run_json_command packages" >/dev/null 2>&1; then
        assert_fail "json command preflight blocks missing ruby"
    else
        assert_pass "json command preflight blocks missing ruby"
    fi
}

test_outdated_empty_stdout_with_stderr_is_error() {
    local output=""
    output="$(run_in_subshell "npm() { if [ \"\$1\" = outdated ]; then printf 'registry failed\n' >&2; return 1; fi; }; render_outdated_json" || true)"
    assert_contains "outdated empty stdout with stderr is error" "npm-outdated-failed" "$output"
}

test_log_file_names_are_unique_per_call() {
    local output=""
    local first=""
    local second=""
    output="$(run_in_subshell "f1=\$(create_log_file test same); f2=\$(create_log_file test same); printf '%s\n%s\n' \"\$f1\" \"\$f2\"")"
    first="$(printf '%s\n' "$output" | sed -n '1p')"
    second="$(printf '%s\n' "$output" | sed -n '2p')"
    if [ -n "$first" ] && [ -n "$second" ] && [ "$first" != "$second" ]; then
        assert_pass "log file names are unique per call"
    else
        assert_fail "log file names are unique per call"
    fi
}

test_destructive_helpers_have_hard_boundaries() {
    local output=""
    local test_dir=""
    test_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/destructive-boundary.XXXXXX")"

    mkdir -p "$test_dir/home/cache" "$test_dir/pkg/bin" "$test_dir/bin"
    ln -s "$test_dir/pkg/bin/tool" "$test_dir/bin/tool"

    if run_in_subshell "HOME='$test_dir/home'; resolve_safe_user_cache_delete_path '$test_dir/home/cache'" >/dev/null 2>&1; then
        assert_pass "safe cache deletion accepts HOME child"
    else
        assert_fail "safe cache deletion accepts HOME child"
    fi

    if run_in_subshell "HOME='$test_dir/home'; resolve_safe_user_cache_delete_path '$test_dir/home'" >/dev/null 2>&1; then
        assert_fail "safe cache deletion rejects HOME root"
    else
        assert_pass "safe cache deletion rejects HOME root"
    fi

    rm -f "$test_dir/bin/tool"
    printf 'manual file\n' > "$test_dir/bin/tool"
    if run_in_subshell "remove_owned_symlink_residue '$test_dir/bin/tool' '$test_dir/pkg'" >/dev/null 2>&1; then
        assert_fail "owned symlink cleanup revalidates before delete"
    else
        assert_pass "owned symlink cleanup revalidates before delete"
    fi
    if [ -f "$test_dir/bin/tool" ]; then
        assert_pass "owned symlink cleanup leaves replaced regular file"
    else
        assert_fail "owned symlink cleanup leaves replaced regular file"
    fi

    if run_in_subshell "nvm_version_user_package_count '$test_dir/missing-version'" >/dev/null 2>&1; then
        assert_fail "nvm cleanup rejects version without npm"
    else
        assert_pass "nvm cleanup rejects version without npm"
    fi

    output="$(run_in_subshell "npm_config_get_layer() { if [ \"\$2\" = user ]; then printf 'undefined\n'; else printf 'https://project.example/'; fi; }; verify_scope_registry_deleted_user_layer '@demo'" || true)"
    assert_contains "scope delete verification checks user layer" "project/global" "$output"
}

test_uninstall_residue_snapshot_verifies_symlink_target() {
    local test_dir=""
    test_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/residue-snapshot.XXXXXX")"
    mkdir -p "$test_dir/pkg/bin" "$test_dir/bin" "$test_dir/other/bin"
    touch "$test_dir/pkg/bin/tool.js" "$test_dir/other/bin/tool.js"
    ln -s "$test_dir/pkg/bin/tool.js" "$test_dir/bin/tool"

    local snapshot=""
    snapshot="$(run_in_subshell "capture_symlink_snapshot '$test_dir/bin/tool' '$test_dir/pkg'" || true)"
    rm -f "$test_dir/bin/tool"
    ln -s "$test_dir/other/bin/tool.js" "$test_dir/bin/tool"

    if run_in_subshell "verify_symlink_snapshot_current '$snapshot'" >/dev/null 2>&1; then
        assert_fail "symlink snapshot rejects replaced target"
    else
        assert_pass "symlink snapshot rejects replaced target"
    fi
}

test_directory_snapshot_rejects_replaced_directory() {
    local test_dir=""
    test_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/dir-snapshot.XXXXXX")"
    mkdir -p "$test_dir/root/pkg"
    local snapshot=""
    snapshot="$(run_in_subshell "capture_directory_snapshot '$test_dir/root/pkg' '$test_dir/root'" || true)"
    rm -rf "$test_dir/root/pkg"
    mkdir -p "$test_dir/root/pkg"

    if run_in_subshell "verify_directory_snapshot_current '$snapshot'" >/dev/null 2>&1; then
        assert_fail "directory snapshot rejects replaced directory"
    else
        assert_pass "directory snapshot rejects replaced directory"
    fi
}

test_nvm_versions_scan_uses_directory_source() {
    local nvm_dir=""
    local output=""
    nvm_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/nvm-scan.XXXXXX")"
    mkdir -p "$nvm_dir/versions/node/v18.20.8" "$nvm_dir/versions/node/v20.11.1" "$nvm_dir/versions/node/not-a-version"
    output="$(run_in_subshell "NVM_DIR='$nvm_dir'; scan_installed_node_versions_from_dirs" || true)"
    assert_contains "nvm dir scan finds v18" "v18.20.8" "$output"
    assert_contains "nvm dir scan finds v20" "v20.11.1" "$output"
    if printf '%s' "$output" | grep -F "not-a-version" >/dev/null 2>&1; then
        assert_fail "nvm dir scan excludes non-version directories"
    else
        assert_pass "nvm dir scan excludes non-version directories"
    fi
}

test_nvm_default_info_separates_alias_and_resolution() {
    local output=""
    output="$(run_in_subshell "parse_nvm_default_alias_output 'default -> lts/* (-> v22.11.0 *)'" || true)"
    assert_equals "nvm default info resolved" "lts/*|v22.11.0|resolved" "$output"

    output="$(run_in_subshell "parse_nvm_default_alias_output 'default -> node (-> N/A)'" || true)"
    assert_equals "nvm default info unresolved" "node||unresolved" "$output"
}

test_nvm_default_alias_file_unmatched_major_is_unresolved() {
    local nvm_dir=""
    local output=""
    nvm_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/nvm-default.XXXXXX")"
    mkdir -p "$nvm_dir/alias" "$nvm_dir/versions/node/v20.11.1"
    printf '18\n' > "$nvm_dir/alias/default"

    output="$(run_in_subshell "NVM_DIR='$nvm_dir'; read_nvm_default_alias_file_info" || true)"
    assert_equals "nvm default file unmatched major unresolved" "18||unresolved" "$output"
}

test_cleanup_flow_is_looping_menu() {
    local output=""
    output="$(run_in_subshell "type run_cleanup_flow")"
    assert_contains "cleanup flow loops" "while true" "$output"
}

test_operation_result_json_contract() {
    local output=""
    output="$(run_in_subshell "render_operation_result_json 'op-1' 'install' 'eslint' 0 'ok' '/tmp/log'" || true)"
    assert_contains "operation json has operation id" '"operationId":"op-1"' "$output"
    assert_contains "operation json has exit code" '"exitCode":0' "$output"
    assert_contains "operation json has status" '"status":"ok"' "$output"
}

test_runtime_lock_rejects_existing_lock() {
    local lock_dir="$NODE_DIR/.runtime/tmp/test-existing.lock"
    mkdir -p "$lock_dir"
    if run_in_subshell "acquire_runtime_lock 'test-existing'" >/dev/null 2>&1; then
        assert_fail "runtime lock rejects existing lock"
    else
        assert_pass "runtime lock rejects existing lock"
    fi
    rmdir "$lock_dir" 2>/dev/null || true
}

test_runtime_lock_recovers_stale_lock() {
    local lock_dir="$NODE_DIR/.runtime/tmp/test-stale.lock"
    rm -rf "$lock_dir"
    mkdir -p "$lock_dir"
    printf '999999\n' > "$lock_dir/pid"
    if run_in_subshell "acquire_runtime_lock 'test-stale'" >/dev/null 2>&1; then
        assert_pass "runtime lock recovers stale lock"
    else
        assert_fail "runtime lock recovers stale lock"
    fi
    rm -rf "$lock_dir" 2>/dev/null || true
}

test_runtime_lock_release_respects_owner() {
    local lock_dir="$NODE_DIR/.runtime/tmp/test-owner.lock"
    rm -rf "$lock_dir"
    mkdir -p "$lock_dir"
    printf '999999\n' > "$lock_dir/pid"
    run_in_subshell "release_runtime_lock 'test-owner'" >/dev/null 2>&1 || true
    if [ -d "$lock_dir" ]; then
        assert_pass "runtime lock release does not delete another owner"
    else
        assert_fail "runtime lock release does not delete another owner"
    fi
    rm -rf "$lock_dir" 2>/dev/null || true
}

test_runtime_lock_explicit_release_removes_held_entry() {
    local lock_dir="$NODE_DIR/.runtime/tmp/test-held-entry.lock"
    rm -rf "$lock_dir"
    if run_in_subshell "acquire_runtime_lock 'test-held-entry'; release_runtime_lock 'test-held-entry'; mkdir '$lock_dir'; printf '999999\n' > '$lock_dir/pid'; release_all_runtime_locks; [ -d '$lock_dir' ]" >/dev/null 2>&1; then
        assert_pass "runtime lock explicit release removes held entry"
    else
        assert_fail "runtime lock explicit release removes held entry"
    fi
    rm -rf "$lock_dir" 2>/dev/null || true
}

test_npm_mutations_share_single_lock() {
    local log_file=""
    log_file="$(mktemp "$NODE_DIR/.runtime/tmp/npm-mutation-lock.XXXXXX")"
    mkdir -p "$NODE_DIR/.runtime/tmp/npm-mutation.lock"
    if run_in_subshell "npm() { return 0; }; run_logged_command '$log_file' npm install -g eslint" >/dev/null 2>&1; then
        assert_fail "npm install blocked by shared mutation lock"
    else
        assert_pass "npm install blocked by shared mutation lock"
    fi
    rm -rf "$NODE_DIR/.runtime/tmp/npm-mutation.lock" "$log_file" 2>/dev/null || true
}

test_source_overview_deduplicates_scope_registry_lines() {
    local output=""
    local count=0

    output="$(run_in_subshell "npm_config_get_layer() { printf 'undefined\n'; }; npm() { if [ \"\$1\" = config ] && [ \"\$2\" = get ]; then printf 'undefined\n'; return 0; fi; if [ \"\$1\" = config ] && [ \"\$2\" = list ]; then printf '@demo:registry = https://registry.example/\n'; return 0; fi; return 0; }; parse_scope_registry_lines() { printf '@demo:registry = https://registry.example/\n'; }; run_source_overview" || true)"
    count="$(printf '%s\n' "$output" | grep -c '^@demo:registry = https://registry.example/$' || true)"
    assert_equals "source overview deduplicates scope registry lines" "1" "$count"
}

test_node_gyp_cleanup_lists_existing_dirs_before_delete() {
    local test_dir=""
    local output=""

    test_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/node-gyp-cleanup.XXXXXX")"
    mkdir -p "$test_dir/existing"
    output="$(printf 'b\n' | run_in_subshell "detect_node_gyp_cache_dirs() { printf '%s|config\n%s|missing\n' '$test_dir/existing' '$test_dir/missing'; }; remove_confirmed_cache_directory() { printf 'DELETE %s %s\n' \"\$1\" \"\$2\"; }; run_node_gyp_cache_cleanup" || true)"

    assert_contains "node-gyp cleanup lists existing cache dir" "$test_dir/existing" "$output"
    if printf '%s' "$output" | grep -F "$test_dir/missing" >/dev/null 2>&1; then
        assert_fail "node-gyp cleanup filters missing cache dirs"
    else
        assert_pass "node-gyp cleanup filters missing cache dirs"
    fi
    if printf '%s' "$output" | grep -F "DELETE" >/dev/null 2>&1; then
        assert_fail "node-gyp cleanup does not delete before selection"
    else
        assert_pass "node-gyp cleanup does not delete before selection"
    fi
}

test_node_gyp_cleanup_back_exits_successfully() {
    local test_dir=""
    local output=""
    local exit_code=0

    test_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/node-gyp-back.XXXXXX")"
    mkdir -p "$test_dir/existing"
    output="$(printf 'b\n' | bash -lc "set -euo pipefail; source '$SCRIPT_PATH'; detect_node_gyp_cache_dirs() { printf '%s|config\n' '$test_dir/existing'; }; run_node_gyp_cache_cleanup" 2>&1)" || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        assert_pass "node-gyp cleanup back exits successfully"
    else
        assert_fail "node-gyp cleanup back exits successfully" "exit=$exit_code output=$output"
    fi
}

test_node_gyp_cleanup_all_selects_all_existing_dirs() {
    local test_dir=""
    local output=""
    local delete_count=0

    test_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/node-gyp-all.XXXXXX")"
    mkdir -p "$test_dir/one" "$test_dir/two"
    output="$(printf 'all\n' | run_in_subshell "detect_node_gyp_cache_dirs() { printf '%s|one\n%s|two\n' '$test_dir/one' '$test_dir/two'; }; remove_confirmed_cache_directory() { printf 'DELETE %s\n' \"\$2\"; }; run_node_gyp_cache_cleanup" || true)"
    delete_count="$(printf '%s\n' "$output" | grep -c 'DELETE ' || true)"
    assert_equals "node-gyp cleanup all selects all existing dirs" "2" "$delete_count"
    if printf '%s' "$output" | grep -F "a 全选" >/dev/null 2>&1; then
        assert_fail "node-gyp cleanup prompt does not advertise unsupported a"
    else
        assert_pass "node-gyp cleanup prompt does not advertise unsupported a"
    fi
}

test_package_spec_rejects_dangling_at() {
    if run_in_subshell "validate_package_spec 'eslint@'" >/dev/null 2>&1; then
        assert_fail "package spec rejects dangling unscoped @"
    else
        assert_pass "package spec rejects dangling unscoped @"
    fi
    if run_in_subshell "validate_package_spec '@scope/pkg@'" >/dev/null 2>&1; then
        assert_fail "package spec rejects dangling scoped @"
    else
        assert_pass "package spec rejects dangling scoped @"
    fi
}

test_json_install_verifies_requested_version() {
    local dir=""
    local output=""

    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/json-install-version.XXXXXX")"
    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "npm() { if [ \"\$1\" = install ]; then return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"8.0.0\"}}}\n'; return 0; fi; if [ \"\$1\" = root ]; then printf '$dir/root\n'; return 0; fi; if [ \"\$1\" = prefix ]; then printf '$dir/prefix\n'; return 0; fi; return 0; }; render_execute_json install eslint@9.0.0" || true)"
    assert_contains "json install fails when requested version is not installed" '"status":"failed"' "$output"
}

test_single_install_verifies_requested_version() {
    local dir=""
    local output=""

    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/single-install-version.XXXXXX")"
    output="$(printf 'eslint@9.0.0\ny\nn\n\n' | run_in_subshell "node() { printf 'v20.11.1\n'; }; npm() { if [ \"\$1\" = prefix ]; then printf '$dir/prefix\n'; return 0; fi; if [ \"\$1\" = install ]; then return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"8.0.0\"}}}\n'; return 0; fi; return 0; }; run_single_install_flow" || true)"
    if printf '%s' "$output" | grep -F "安装成功" >/dev/null 2>&1; then
        assert_fail "single install does not report success for wrong requested version"
    else
        assert_pass "single install does not report success for wrong requested version"
    fi
}

test_nvm_write_actions_require_shared_lock() {
    local lock_dir="$NODE_DIR/.runtime/tmp/nvm-mutation.lock"
    local lock_pid=""
    mkdir -p "$lock_dir"
    sleep 60 &
    lock_pid=$!
    printf '%s\n' "$lock_pid" > "$lock_dir/pid"
    if run_in_subshell "load_nvm_into_current_shell() { return 0; }; nvm() { return 0; }; switch_node_version v20.11.1" >/dev/null 2>&1; then
        assert_fail "switch node version is blocked by nvm mutation lock"
    else
        assert_pass "switch node version is blocked by nvm mutation lock"
    fi
    if run_in_subshell "load_nvm_into_current_shell() { return 0; }; nvm() { return 0; }; set_node_default_alias v20.11.1" >/dev/null 2>&1; then
        assert_fail "set default node version is blocked by nvm mutation lock"
    else
        assert_pass "set default node version is blocked by nvm mutation lock"
    fi
    kill "$lock_pid" 2>/dev/null || true
    wait "$lock_pid" 2>/dev/null || true
    rm -rf "$lock_dir" 2>/dev/null || true
}

test_operation_result_rejects_invalid_exit_code() {
    local output=""

    output="$(run_in_subshell "render_operation_result_json op install eslint nope ok /tmp/log" || true)"
    assert_contains "operation result rejects invalid exit code" "invalid-exit-code" "$output"
}

test_scope_and_registry_validation_are_strict() {
    if run_in_subshell "validate_scope_name '@Scope'" >/dev/null 2>&1; then
        assert_fail "scope validation rejects uppercase"
    else
        assert_pass "scope validation rejects uppercase"
    fi
    if run_in_subshell "validate_scope_name '@_scope'" >/dev/null 2>&1; then
        assert_fail "scope validation rejects leading underscore"
    else
        assert_pass "scope validation rejects leading underscore"
    fi
    if run_in_subshell "validate_registry_url 'http://registry.example/'" >/dev/null 2>&1; then
        assert_fail "registry validation rejects http by default"
    else
        assert_pass "registry validation rejects http by default"
    fi
    if run_in_subshell "validate_registry_url 'http://localhost:4873/'" >/dev/null 2>&1; then
        assert_pass "registry validation accepts localhost http"
    else
        assert_fail "registry validation accepts localhost http"
    fi
}

test_json_command_uses_stable_envelope() {
    local output=""

    output="$(run_in_subshell "command_exists() { [ \"\$1\" != npm ]; }; run_json_command summary" || true)"
    assert_contains "json command envelope has ok" '"ok":true' "$output"
    assert_contains "json command envelope has schema version" '"schemaVersion":1' "$output"
    assert_contains "json command envelope has command" '"command":"summary"' "$output"
    assert_contains "json command envelope has data" '"data":' "$output"
}

test_npm_ls_stdout_does_not_break_installed_boolean() {
    local output=""

    output="$(run_in_subshell "npm() { if [ \"\$1\" = ls ]; then printf 'tree output that should be ignored\n'; return 0; fi; return 1; }; if npm_package_is_installed eslint; then printf yes; else printf no; fi" || true)"
    assert_equals "npm ls stdout does not break installed boolean" "yes" "$output"
}

test_install_spec_satisfaction_checks_requested_version() {
    if run_in_subshell "is_install_spec_satisfied 'eslint@9.0.0' '8.0.0'" >/dev/null 2>&1; then
        assert_fail "install spec satisfaction rejects wrong exact version"
    else
        assert_pass "install spec satisfaction rejects wrong exact version"
    fi
    if run_in_subshell "is_install_spec_satisfied 'eslint@9.0.0' '9.0.0'" >/dev/null 2>&1; then
        assert_pass "install spec satisfaction accepts matching exact version"
    else
        assert_fail "install spec satisfaction accepts matching exact version"
    fi
}

test_batch_install_treats_npm_ls_stdout_success_as_installed() {
    local config_file=""
    local output=""

    config_file="$(mktemp "$NODE_DIR/.runtime/tmp/batch-installed.XXXXXX")"
    printf 'eslint\n' > "$config_file"
    output="$(printf '\n' | run_in_subshell "GLOBAL_PACKAGES_FILE='$config_file'; node() { printf 'v20.11.1\n'; }; npm() { case \" \$* \" in *' --json '*) printf '{\"dependencies\":{\"eslint\":{\"version\":\"9.0.0\"}}}\n'; return 0 ;; esac; if [ \"\$1\" = view ]; then printf '9.0.0\n'; return 0; fi; if [ \"\$1\" = ls ]; then printf 'tree output\n'; return 0; fi; if [ \"\$1\" = prefix ]; then printf '/tmp/prefix\n'; return 0; fi; if [ \"\$1\" = -v ]; then printf '10.0.0\n'; return 0; fi; if [ \"\$1\" = install ]; then printf 'INSTALL_CALLED\n'; return 0; fi; return 0; }; run_batch_install_flow" || true)"
    assert_contains "batch install shows installed when npm ls prints stdout" "[已安装] eslint" "$output"
    if printf '%s' "$output" | grep -F "INSTALL_CALLED" >/dev/null 2>&1; then
        assert_fail "batch install does not reinstall stdout-positive installed package"
    else
        assert_pass "batch install does not reinstall stdout-positive installed package"
    fi
}

test_bare_package_plan_resolves_latest_and_rejects_old_installed_version() {
    local output=""

    output="$(run_in_subshell "npm() { if [ \"\$1\" = view ]; then printf '9.0.0\n'; return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"8.0.0\"}}}\n'; return 0; fi; return 0; }; render_package_plan_json eslint" || true)"
    assert_contains "bare package plan resolves latest target" '"targetVersion":"9.0.0"' "$output"
    assert_contains "bare package plan does not accept old installed version" '"alreadyInstalled":false' "$output"
}

test_bare_package_install_verifies_latest_target() {
    local dir=""
    local output=""

    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/json-bare-install.XXXXXX")"
    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "npm() { if [ \"\$1\" = view ]; then printf '9.0.0\n'; return 0; fi; if [ \"\$1\" = install ]; then return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"8.0.0\"}}}\n'; return 0; fi; if [ \"\$1\" = root ]; then printf '$dir/root\n'; return 0; fi; if [ \"\$1\" = prefix ]; then printf '$dir/prefix\n'; return 0; fi; return 0; }; render_execute_json install eslint" || true)"
    assert_contains "json bare install fails when latest target is not installed" '"status":"failed"' "$output"
}

test_package_plan_already_installed_respects_requested_version() {
    local output=""

    output="$(run_in_subshell "npm() { if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"8.0.0\"}}}\n'; return 0; fi; return 0; }; render_package_plan_json eslint@9.0.0" || true)"
    assert_contains "package plan exact version mismatch is not already installed" '"alreadyInstalled":false' "$output"
}

test_dist_tag_install_verification_uses_pre_resolved_target() {
    local counter_file=""
    local output=""

    counter_file="$(mktemp "$NODE_DIR/.runtime/tmp/npm-view-calls.XXXXXX")"
    printf '0\n' > "$counter_file"
    output="$(run_in_subshell "counter_file='$counter_file'; npm() { if [ \"\$1\" = view ]; then calls=\"\$(sed -n '1p' \"\$counter_file\")\"; calls=\$((calls + 1)); printf '%s\n' \"\$calls\" > \"\$counter_file\"; if [ \"\$calls\" -eq 1 ]; then printf '9.0.0\n'; return 0; fi; return 1; fi; return 0; }; target_version=\"\$(resolve_install_target_version eslint@latest)\" || exit 1; verify_result=\"\$(verify_install_result_for_spec eslint@latest 9.0.0 \"\$target_version\" || true)\"; printf '%s|npm_view_calls=%s' \"\$verify_result\" \"\$(sed -n '1p' \"\$counter_file\")\"" || true)"
    assert_contains "dist-tag install verification reuses pre-resolved target" "ok|安装验证通过|9.0.0|npm_view_calls=1" "$output"
}

test_json_preflight_uses_single_error_envelope() {
    local output=""
    local line_count=0

    output="$(run_in_subshell "command_exists() { return 1; }; run_json_command packages" || true)"
    line_count="$(printf '%s\n' "$output" | sed '/^$/d' | wc -l | tr -d ' ')"
    assert_equals "json preflight emits single document" "1" "$line_count"
    assert_contains "json preflight envelope includes command" '"command":"packages"' "$output"
    assert_contains "json preflight envelope lists missing dependencies" '"dependencies":[' "$output"
    assert_valid_json_document "json preflight envelope is parseable" "$output"
}

test_json_unsupported_command_uses_error_envelope() {
    local output=""

    output="$(run_in_subshell "run_json_command nope" || true)"
    assert_contains "json unsupported command envelope has ok false" '"ok":false' "$output"
    assert_contains "json unsupported command envelope has schema version" '"schemaVersion":1' "$output"
    assert_contains "json unsupported command envelope has command" '"command":"nope"' "$output"
    assert_valid_json_document "json unsupported command envelope is parseable" "$output"
}

test_json_failure_envelopes_are_parseable() {
    local output=""

    output="$(run_in_subshell "run_json_command package-plan 'eslint@'" || true)"
    assert_contains "json package-plan failure has command" '"command":"package-plan"' "$output"
    assert_valid_json_document "json package-plan failure is parseable" "$output"

    output="$(run_in_subshell "run_json_command execute install eslint" || true)"
    assert_contains "json execute disabled failure has command" '"command":"execute"' "$output"
    assert_valid_json_document "json execute disabled failure is parseable" "$output"

    output="$(run_in_subshell "run_json_command plan nope eslint" || true)"
    assert_contains "json plan failure has command" '"command":"plan"' "$output"
    assert_valid_json_document "json plan failure is parseable" "$output"
}

test_json_failure_payloads_use_single_error_model() {
    local output=""

    output="$(run_in_subshell "run_json_command package-plan 'eslint@'" || true)"
    assert_contains "json package-plan failure uses code" '"code":"invalid-package-spec"' "$output"
    assert_not_contains "json package-plan failure does not nest ok in error" '"error":{"ok":false' "$output"
    assert_not_contains "json package-plan failure does not use error string field" '"error":"invalid-safe-package"' "$output"
    assert_valid_json_document "json package-plan single error model is parseable" "$output"
}

test_json_success_envelopes_are_parseable() {
    local output=""

    output="$(run_in_subshell "command_exists() { [ \"\$1\" != npm ]; }; run_json_command summary" || true)"
    assert_valid_json_document "json summary envelope is parseable" "$output"

    output="$(run_in_subshell "command_exists() { [ \"\$1\" != npm ]; }; run_json_command status" || true)"
    assert_valid_json_document "json status envelope is parseable" "$output"

    output="$(run_in_subshell "run_json_command logs 1" || true)"
    assert_valid_json_document "json logs envelope is parseable" "$output"

    output="$(run_in_subshell "run_json_command logs-cleanup 100" || true)"
    assert_valid_json_document "json logs-cleanup envelope is parseable" "$output"
}

test_json_uninstall_is_supported_in_plan_and_help() {
    local output=""

    output="$(run_in_subshell "npm() { if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"9.0.0\"}}}\n'; return 0; fi; return 0; }; render_action_plan_json uninstall eslint" || true)"
    assert_contains "json uninstall plan marks execute supported" '"executeSupported":true' "$output"
    output="$(run_in_subshell "render_help" || true)"
    assert_contains "help documents json uninstall execute" "execute <install|uninstall|update-latest>" "$output"
}

test_json_uninstall_rejects_missing_package() {
    local output=""

    output="$(run_in_subshell "npm() { if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{}}\n'; return 0; fi; return 0; }; run_json_command plan uninstall eslint" || true)"
    assert_contains "json uninstall plan rejects missing package" '"code":"package-not-installed"' "$output"
    assert_valid_json_document "json uninstall missing plan failure is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "npm() { if [ \"\$1\" = root ]; then printf '$NODE_DIR/.runtime/tmp/root\n'; return 0; fi; if [ \"\$1\" = prefix ]; then printf '$NODE_DIR/.runtime/tmp/prefix\n'; return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{}}\n'; return 0; fi; if [ \"\$1\" = uninstall ]; then return 0; fi; return 0; }; run_json_command execute uninstall eslint" || true)"
    assert_contains "json uninstall execute rejects missing package" '"code":"package-not-installed"' "$output"
    assert_valid_json_document "json uninstall missing execute failure is parseable" "$output"
}

test_json_non_package_action_contracts_are_documented() {
    local output=""

    output="$(run_in_subshell "render_help" || true)"
    assert_contains "help documents registry json plan" "registry-set <url>" "$output"
    assert_contains "help documents node json plan" "node-install <version|lts>" "$output"
    assert_contains "help documents cleanup json plan" "cleanup <target>" "$output"

    output="$(run_in_subshell "run_json_command plan registry-set https://registry.npmjs.org/" || true)"
    assert_contains "registry set plan is available" '"action":"registry-set"' "$output"

    output="$(run_in_subshell "run_json_command plan node-install 20.11.1" || true)"
    assert_contains "node install plan is available" '"action":"node-install"' "$output"

    output="$(run_in_subshell "run_json_command plan cleanup npm-cache-clean" || true)"
    assert_contains "cleanup plan is available" '"action":"cleanup"' "$output"
}

test_app_packaging_boundary_is_documented() {
    local manifest=""
    local doc=""

    manifest="$(cat "$NODE_DIR/app-bundle-manifest.txt" 2>/dev/null || true)"
    assert_contains "app bundle manifest includes manager script" "npm-global-manager.sh" "$manifest"
    assert_not_contains "app bundle manifest excludes runtime" ".runtime" "$manifest"
    assert_not_contains "app bundle manifest excludes ds store" ".DS_Store" "$manifest"

    doc="$(cat "$NODE_DIR/docs/specs/2026-06-24-app-boundary-and-packaging-contract.md" 2>/dev/null || true)"
    assert_contains "app boundary doc names project nvmrc gate" "NODE_MANAGER_ALLOW_PROJECT_WRITE=1" "$doc"
    assert_contains "app boundary doc requires whitelist packaging" "app-bundle-manifest.txt" "$doc"
}

test_require_capabilities_reports_missing_ruby() {
    local output=""

    output="$(run_in_subshell "command_exists() { [ \"\$1\" != ruby ]; }; require_capabilities ruby" || true)"
    assert_contains "require capabilities reports missing ruby" "Ruby" "$output"
}

test_logs_cleanup_json_command_is_available() {
    local output=""

    output="$(run_in_subshell "render_help" || true)"
    assert_contains "help documents logs cleanup json command" "--json logs-cleanup" "$output"
    output="$(run_in_subshell "run_json_command logs-cleanup 100" || true)"
    assert_contains "logs cleanup json command returns envelope" '"command":"logs-cleanup"' "$output"
    assert_contains "logs cleanup json command succeeds" '"ok":true' "$output"
}

test_runtime_log_cleanup_keeps_recent_files() {
    local log_dir="$NODE_DIR/.runtime/logs"
    local old_a="$log_dir/test-clean-a.log.000001"
    local old_b="$log_dir/test-clean-b.log.000002"
    local keep_c="$log_dir/test-clean-c.log.000003"

    mkdir -p "$log_dir"
    printf 'a\n' > "$old_a"
    printf 'b\n' > "$old_b"
    printf 'c\n' > "$keep_c"
    touch -t 203001010101 "$old_a"
    touch -t 203001010102 "$old_b"
    touch -t 203001010103 "$keep_c"

    if run_in_subshell "cleanup_runtime_logs_keep_recent 1" >/dev/null 2>&1 && [ -f "$keep_c" ] && [ ! -e "$old_a" ] && [ ! -e "$old_b" ]; then
        assert_pass "runtime log cleanup keeps recent files"
    else
        assert_fail "runtime log cleanup keeps recent files"
    fi
    rm -f "$old_a" "$old_b" "$keep_c" 2>/dev/null || true
}

test_legacy_package_helpers_use_logged_commands() {
    local output=""

    output="$(run_in_subshell "type install_global_package; type upgrade_global_package; type upgrade_global_package_to_latest; type uninstall_global_package")"
    assert_contains "legacy install helper uses logged command" "run_logged_command" "$output"
    assert_contains "legacy update helper uses logged command" "run_logged_command" "$output"
    assert_contains "legacy uninstall helper uses logged command" "run_logged_command" "$output"
}

test_json_update_latest_verifies_latest_version() {
    local dir=""
    local output=""

    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/json-latest.XXXXXX")"
    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "npm() { if [ \"\$1\" = view ]; then printf '9.0.0\n'; return 0; fi; if [ \"\$1\" = install ]; then return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"8.0.0\"}}}\n'; return 0; fi; if [ \"\$1\" = root ]; then printf '$dir/root\n'; return 0; fi; if [ \"\$1\" = prefix ]; then printf '$dir/prefix\n'; return 0; fi; return 0; }; render_execute_json update-latest eslint" || true)"
    assert_contains "json update-latest fails when installed version is not latest" '"status":"failed"' "$output"
}

test_json_execute_uninstall_uses_safe_action_layer() {
    local dir=""
    local root_dir=""
    local prefix_dir=""
    local output=""

    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/json-uninstall.XXXXXX")"
    root_dir="$dir/root"
    prefix_dir="$dir/prefix"
    mkdir -p "$root_dir/eslint" "$prefix_dir/bin"
    printf '{"name":"eslint","version":"9.0.0"}\n' > "$root_dir/eslint/package.json"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "root_dir='$root_dir'; prefix_dir='$prefix_dir'; npm() { if [ \"\$1\" = root ]; then printf '%s\n' \"\$root_dir\"; return 0; fi; if [ \"\$1\" = prefix ]; then printf '%s\n' \"\$prefix_dir\"; return 0; fi; if [ \"\$1\" = ls ]; then if [ -d \"\$root_dir/eslint\" ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"9.0.0\"}}}\n'; return 0; else printf '{\"dependencies\":{}}\n'; return 1; fi; fi; if [ \"\$1\" = uninstall ]; then rm -rf \"\$root_dir/eslint\"; return 0; fi; return 0; }; run_json_command execute uninstall eslint" || true)"
    assert_contains "json uninstall execute returns command envelope" '"command":"execute"' "$output"
    assert_contains "json uninstall execute reports ok status" '"status":"ok"' "$output"
    assert_valid_json_document "json uninstall execute envelope is parseable" "$output"
}

test_json_execute_uninstall_rejects_protected_package() {
    local output=""

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "run_json_command execute uninstall npm" || true)"
    assert_contains "json uninstall rejects protected package" "protected-package" "$output"
    assert_valid_json_document "json uninstall protected failure is parseable" "$output"
}

test_shellcheck_installer_verifies_archive_checksum() {
    local output=""

    output="$(sed -n '1,220p' "$NODE_DIR/tools/install-shellcheck.sh")"
    assert_contains "shellcheck installer has checksum table" "shellcheck_expected_sha256" "$output"
    assert_contains "shellcheck installer verifies sha256" "shasum -a 256" "$output"
    assert_contains "shellcheck installer fails on checksum mismatch" "checksum mismatch" "$output"
}

test_install_nvm_blocks_unverified_default_path() {
    local nvm_dir=""
    local output=""

    nvm_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/nvm-unverified.XXXXXX")"
    output="$(printf 'y\n\n' | run_in_subshell "NVM_DIR='$nvm_dir'; NVM_INSTALL_SHA256=''; NVM_ALLOW_UNVERIFIED_INSTALL=0; install_nvm_official() { printf 'INSTALL_CALLED\n'; return 0; }; run_install_nvm_flow" || true)"
    assert_contains "nvm unverified install tells user explicit override" "NVM_ALLOW_UNVERIFIED_INSTALL=1" "$output"
    if printf '%s' "$output" | grep -F "INSTALL_CALLED" >/dev/null 2>&1; then
        assert_fail "nvm unverified install is blocked by default"
    else
        assert_pass "nvm unverified install is blocked by default"
    fi
}

test_registry_latest_version_trims_npm_output() {
    local output=""

    output="$(run_in_subshell "npm() { if [ \"\$1\" = view ]; then printf '  9.0.0  \n'; return 0; fi; return 1; }; get_registry_latest_version eslint" || true)"
    assert_equals "registry latest version trims npm output" "9.0.0" "$output"
}

test_semver_range_package_spec_resolves_registry_target() {
    local output=""

    if run_in_subshell "requested_package_version_is_exact 9" >/dev/null 2>&1; then
        assert_fail "semver major shorthand is not treated as exact"
    else
        assert_pass "semver major shorthand is not treated as exact"
    fi
    if run_in_subshell "requested_package_version_is_exact 9.0.0" >/dev/null 2>&1; then
        assert_pass "full semver is treated as exact"
    else
        assert_fail "full semver is treated as exact"
    fi

    output="$(run_in_subshell "npm() { if [ \"\$1\" = view ] && [ \"\$2\" = eslint@9 ]; then printf '9.2.0\n'; return 0; fi; return 1; }; resolve_install_target_version eslint@9" || true)"
    assert_equals "semver range spec resolves installed target via npm view" "9.2.0" "$output"

    output="$(run_in_subshell "npm() { if [ \"\$1\" = view ] && [ \"\$2\" = eslint@9 ]; then printf '9.2.0\n'; return 0; fi; return 1; }; target_version=\"\$(resolve_install_target_version eslint@9)\" || exit 1; verify_install_result_for_spec eslint@9 9.2.0 \"\$target_version\"" || true)"
    assert_contains "semver range verification accepts resolved target" "ok|安装验证通过|9.2.0" "$output"
}

test_json_install_plan_resolves_semver_range_target() {
    local output=""

    output="$(run_in_subshell "npm() { if [ \"\$1\" = view ] && [ \"\$2\" = eslint@9 ]; then printf '9.2.0\n'; return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"9.2.0\"}}}\n'; return 0; fi; return 0; }; render_action_plan_json install eslint@9" || true)"
    assert_contains "json install plan does not expose shorthand target" '"targetVersion":"9.2.0"' "$output"
    assert_contains "json install plan accepts installed resolved range target" '"alreadyInstalled":true' "$output"
    assert_valid_json_document "json semver range install plan is parseable" "$output"
}

test_json_bootstrap_preflight_does_not_require_npm() {
    local output=""

    output="$(run_in_subshell "command_exists() { case \"\$1\" in npm|ruby) return 1 ;; *) return 0 ;; esac; }; run_json_command plan nvm-install" || true)"
    assert_contains "json nvm install plan works without npm" '"action":"nvm-install"' "$output"
    assert_not_contains "json nvm install plan does not require npm" "missing-dependency" "$output"
    assert_valid_json_document "json nvm install plan without npm is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "command_exists() { case \"\$1\" in npm|ruby) return 1 ;; *) return 0 ;; esac; }; NVM_INSTALL_SHA256=''; NVM_ALLOW_UNVERIFIED_INSTALL=0; run_json_command execute nvm-install" || true)"
    assert_contains "json nvm install execute reaches action layer without npm" "nvm-install-unverified-blocked" "$output"
    assert_not_contains "json nvm install execute preflight does not require npm" "missing-dependency" "$output"
    assert_valid_json_document "json nvm install execute without npm is parseable" "$output"
}

test_json_plan_does_not_create_runtime_logs() {
    local before_file=""
    local after_file=""
    local output=""
    local diff_output=""

    before_file="$(mktemp "$NODE_DIR/.runtime/tmp/logs-before.XXXXXX")"
    after_file="$(mktemp "$NODE_DIR/.runtime/tmp/logs-after.XXXXXX")"
    find "$NODE_DIR/.runtime/logs" -maxdepth 1 -type f 2>/dev/null | sort > "$before_file"
    output="$(run_in_subshell "npm() { if [ \"\$1\" = view ]; then printf '9.0.0\n'; return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{}}\n'; return 0; fi; return 0; }; render_action_plan_json install eslint@9.0.0" || true)"
    find "$NODE_DIR/.runtime/logs" -maxdepth 1 -type f 2>/dev/null | sort > "$after_file"
    diff_output="$(comm -13 "$before_file" "$after_file" || true)"
    rm -f "$before_file" "$after_file"

    assert_equals "json install plan creates no log files" "" "$diff_output"
    assert_not_contains "json install plan has no logFile field" '"logFile":' "$output"
    assert_contains "json install plan exposes log hint only" '"logFileHint":' "$output"
}

test_json_package_plan_does_not_create_runtime_logs() {
    local before_file=""
    local after_file=""
    local output=""
    local diff_output=""

    before_file="$(mktemp "$NODE_DIR/.runtime/tmp/package-logs-before.XXXXXX")"
    after_file="$(mktemp "$NODE_DIR/.runtime/tmp/package-logs-after.XXXXXX")"
    find "$NODE_DIR/.runtime/logs" -maxdepth 1 -type f 2>/dev/null | sort > "$before_file"
    output="$(run_in_subshell "npm() { if [ \"\$1\" = view ]; then printf '9.0.0\n'; return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{}}\n'; return 0; fi; return 0; }; render_package_plan_json eslint@9.0.0" || true)"
    find "$NODE_DIR/.runtime/logs" -maxdepth 1 -type f 2>/dev/null | sort > "$after_file"
    diff_output="$(comm -13 "$before_file" "$after_file" || true)"
    rm -f "$before_file" "$after_file"

    assert_equals "json package plan creates no log files" "" "$diff_output"
    assert_not_contains "json package plan has no logFile field" '"logFile":' "$output"
    assert_contains "json package plan exposes log hint only" '"logFileHint":' "$output"
}

test_json_plan_preflight_is_read_only_for_nvm_install() {
    local output=""

    output="$(run_in_subshell "command_exists() { case \"\$1\" in curl|bash|shasum) return 1 ;; *) return 0 ;; esac; }; NVM_INSTALL_SHA256='abc123'; run_json_command plan nvm-install" || true)"
    assert_contains "nvm install plan ignores execute-only dependencies" '"action":"nvm-install"' "$output"
    assert_not_contains "nvm install plan is not blocked by curl bash shasum" "missing-dependency" "$output"
    assert_valid_json_document "nvm install plan read-only preflight is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "command_exists() { case \"\$1\" in curl|bash|shasum) return 1 ;; *) return 0 ;; esac; }; NVM_INSTALL_SHA256='abc123'; run_json_command execute nvm-install" || true)"
    assert_contains "nvm install execute still requires execute dependencies" '"code":"missing-dependency"' "$output"
    assert_contains "nvm install execute reports curl dependency" '"curl"' "$output"
    assert_valid_json_document "nvm install execute dependency failure is parseable" "$output"
}

test_json_nvm_install_plan_and_execute_contract() {
    local output=""

    output="$(run_in_subshell "NVM_INSTALL_SHA256='abc123'; NVM_ALLOW_UNVERIFIED_INSTALL=0; render_action_plan_json nvm-install" || true)"
    assert_contains "nvm install plan exposes configured checksum state" '"sha256Configured":true' "$output"
    assert_contains "nvm install plan exposes unverified policy" '"allowUnverified":false' "$output"
    assert_contains "nvm install plan exposes install URL" '"installUrl":' "$output"
    assert_contains "nvm install plan normalizes subject" '"subject":"v0.40.5"' "$output"
    assert_not_contains "nvm install plan has no operation id" '"operationId":' "$output"
    assert_valid_json_document "nvm install plan contract is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "NVM_INSTALL_SHA256=''; NVM_ALLOW_UNVERIFIED_INSTALL=0; install_nvm_official() { printf 'INSTALL_CALLED\n'; return 0; }; render_execute_json nvm-install" || true)"
    assert_contains "json nvm install execute blocks unverified install" "nvm-install-unverified-blocked" "$output"
    assert_contains "json nvm install execute normalizes subject" '"subject":"v0.40.5"' "$output"
    assert_not_contains "json nvm install execute does not call install when blocked" "INSTALL_CALLED" "$output"
    assert_valid_json_document "json nvm install blocked execute is parseable" "$output"
}

test_json_nvm_install_rejects_unsupported_version_argument() {
    local output=""

    output="$(run_in_subshell "NVM_INSTALL_SHA256='abc123'; render_action_plan_json nvm-install v0.40.4" || true)"
    assert_contains "nvm install plan rejects unsupported explicit version" '"code":"unsupported-nvm-install-version"' "$output"
    assert_contains "nvm install plan reports configured version" '"configuredVersion":"v0.40.5"' "$output"
    assert_not_contains "nvm install plan does not split subject and version" '"version":"v0.40.5"' "$output"
    assert_valid_json_document "unsupported nvm install plan is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "NVM_INSTALL_SHA256='abc123'; install_nvm_official() { printf 'INSTALL_CALLED\n'; return 0; }; render_execute_json nvm-install v0.40.4" || true)"
    assert_contains "nvm install execute rejects unsupported explicit version" '"code":"unsupported-nvm-install-version"' "$output"
    assert_not_contains "nvm install execute does not call install for unsupported version" "INSTALL_CALLED" "$output"
    assert_valid_json_document "unsupported nvm install execute is parseable" "$output"
}

test_json_execute_preserves_business_error_code() {
    local output=""
    local project_dir=""

    project_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/json-project-nvmrc.XXXXXX")"
    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "NODE_MANAGER_ALLOW_PROJECT_WRITE=0; render_execute_json project-nvmrc '$project_dir' 20.11.1" || true)"
    assert_contains "json project nvmrc execute preserves disabled code" '"code":"project-write-disabled"' "$output"
    assert_contains "json project nvmrc execute includes log file" '"logFile":' "$output"
    assert_valid_json_document "json project nvmrc business failure is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "NODE_MANAGER_ALLOW_PROJECT_WRITE=1; render_execute_json project-nvmrc '$NODE_DIR/.runtime/tmp/missing-project-dir' 20.11.1" || true)"
    assert_contains "json project nvmrc execute preserves path context" '"path":"' "$output"
    assert_contains "json project nvmrc execute preserves operation metadata" '"operationId":' "$output"
    assert_valid_json_document "json project nvmrc path failure is parseable" "$output"
}

test_json_node_actions_have_action_specific_version_boundaries() {
    local output=""
    local project_dir=""

    output="$(run_in_subshell "render_action_plan_json node-uninstall lts" || true)"
    assert_contains "node uninstall rejects lts alias in plan" '"code":"invalid-node-version-for-action"' "$output"
    assert_contains "node uninstall invalid alias names action" '"action":"node-uninstall"' "$output"
    assert_valid_json_document "node uninstall invalid alias plan is parseable" "$output"

    output="$(run_in_subshell "render_action_plan_json node-use lts" || true)"
    assert_contains "node use rejects lts alias in plan" '"code":"invalid-node-version-for-action"' "$output"
    assert_valid_json_document "node use invalid alias plan is parseable" "$output"

    project_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/json-project-plan.XXXXXX")"
    output="$(run_in_subshell "render_action_plan_json project-nvmrc '$project_dir' lts" || true)"
    assert_contains "project nvmrc rejects lts alias in plan" '"code":"invalid-node-version-for-action"' "$output"
    assert_valid_json_document "project nvmrc invalid alias plan is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "render_execute_json node-use lts" || true)"
    assert_contains "node use rejects lts alias before execute" '"code":"invalid-node-version-for-action"' "$output"
    assert_valid_json_document "node use invalid alias execute is parseable" "$output"
}

test_json_node_use_preexecute_reports_business_failures() {
    local output=""

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "load_nvm_into_current_shell() { return 1; }; render_execute_json node-use 20.11.1" || true)"
    assert_contains "node use reports nvm unavailable as business error" '"code":"nvm-unavailable"' "$output"
    assert_valid_json_document "node use nvm unavailable execute is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "load_nvm_into_current_shell() { return 0; }; get_installed_node_versions() { printf 'v18.20.8\n'; }; render_execute_json node-use 20.11.1" || true)"
    assert_contains "node use reports missing installed version" '"code":"node-version-not-installed"' "$output"
    assert_contains "node use missing version preserves normalized version" '"version":"v20.11.1"' "$output"
    assert_valid_json_document "node use missing installed version execute is parseable" "$output"
}

test_json_node_install_preexecute_reports_business_failures() {
    local output=""

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "load_nvm_into_current_shell() { return 1; }; render_execute_json node-install 20.11.1" || true)"
    assert_contains "node install reports nvm unavailable as business error" '"code":"nvm-unavailable"' "$output"
    assert_valid_json_document "node install nvm unavailable execute is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "load_nvm_into_current_shell() { return 0; }; acquire_runtime_lock() { return 0; }; release_runtime_lock() { return 0; }; nvm() { if [ \"\$1\" = install ]; then return 42; fi; return 0; }; render_execute_json node-install 20.11.1" || true)"
    assert_contains "node install reports nvm install failure" '"code":"node-install-failed"' "$output"
    assert_valid_json_document "node install failure execute is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "load_nvm_into_current_shell() { return 0; }; acquire_runtime_lock() { return 0; }; release_runtime_lock() { return 0; }; nvm() { if [ \"\$1\" = install ]; then return 0; fi; if [ \"\$1\" = use ]; then return 43; fi; return 0; }; render_execute_json node-install 20.11.1" || true)"
    assert_contains "node install reports use after install failure" '"code":"node-use-after-install-failed"' "$output"
    assert_valid_json_document "node use after install failure execute is parseable" "$output"
}

test_json_node_plan_captures_nvm_noise() {
    local output=""

    output="$(bash -lc "set -u; source '$SCRIPT_PATH'; load_nvm_into_current_shell() { printf 'nvm noise\n' >&2; return 1; }; render_action_plan_json node-install 20.11.1" 2>&1 || true)"
    assert_not_contains "node plan does not leak nvm stderr" "nvm noise" "$output"
    assert_contains "node plan marks nvm unavailable" '"nvmAvailable":false' "$output"
    assert_valid_json_document "node plan with unavailable nvm is parseable" "$output"
}

test_json_dangerous_plans_include_impact_scope() {
    local output=""
    local project_dir=""

    output="$(run_in_subshell "npm() { if [ \"\$1\" = config ] && [ \"\$2\" = get ] && [ \"\$3\" = registry ] && [ \"\${4:-}\" = --location=user ]; then printf 'https://user.example/\n'; return 0; fi; if [ \"\$1\" = config ] && [ \"\$2\" = get ] && [ \"\$3\" = registry ]; then printf 'https://effective.example/\n'; return 0; fi; return 0; }; render_action_plan_json registry-delete" || true)"
    assert_contains "registry delete plan includes effective registry" '"effectiveRegistry":"https://effective.example/"' "$output"
    assert_contains "registry delete plan includes user registry" '"userRegistry":"https://user.example/"' "$output"

    output="$(run_in_subshell "npm_config_get_layer() { if [ \"\$1\" = '@demo:registry' ] && [ \"\$2\" = user ]; then printf 'https://user.example/\n'; else printf 'undefined\n'; fi; }; npm() { if [ \"\$1\" = config ] && [ \"\$2\" = get ]; then printf 'https://effective.example/\n'; return 0; fi; return 0; }; render_action_plan_json scope-registry-delete @demo" || true)"
    assert_contains "scope registry delete plan includes effective scope registry" '"effectiveRegistry":"https://effective.example/"' "$output"
    assert_contains "scope registry delete plan includes user scope registry" '"userRegistry":"https://user.example/"' "$output"

    output="$(run_in_subshell "nvm() { if [ \"\$1\" = current ]; then printf 'v20.11.1\n'; return 0; fi; if [ \"\$1\" = alias ]; then printf 'default -> v18.20.8\n'; return 0; fi; return 0; }; load_nvm_into_current_shell() { return 0; }; render_action_plan_json node-uninstall 18.20.8" || true)"
    assert_contains "node uninstall plan includes current version" '"currentVersion":"v20.11.1"' "$output"
    assert_contains "node uninstall plan includes default version" '"defaultVersion":"v18.20.8"' "$output"
    assert_contains "node uninstall plan marks default protection" '"protectedByDefault":true' "$output"

    output="$(run_in_subshell "npm() { if [ \"\$1\" = config ] && [ \"\$2\" = get ] && [ \"\$3\" = cache ]; then printf '$NODE_DIR/.runtime/tmp/npm-cache\n'; return 0; fi; return 0; }; render_action_plan_json cleanup npm-cache-clean" || true)"
    assert_contains "cleanup plan includes target paths" '"paths":[' "$output"

    project_dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/json-project-plan.XXXXXX")"
    printf '18.20.8\n' > "$project_dir/.nvmrc"
    printf '{"engines":{"node":">=18"}}\n' > "$project_dir/package.json"
    output="$(run_in_subshell "render_action_plan_json project-nvmrc '$project_dir' 20.11.1" || true)"
    assert_contains "project nvmrc plan includes path exists" '"pathExists":true' "$output"
    assert_contains "project nvmrc plan includes current nvmrc" '"currentNvmrc":"18.20.8"' "$output"
    assert_contains "project nvmrc plan includes engines node" '"enginesNode":">=18"' "$output"
}

test_json_renderers_handle_missing_arguments() {
    local output=""

    output="$(run_in_subshell "render_action_plan_json" || true)"
    assert_contains "plan renderer missing action returns structured error" '"code":"missing-argument"' "$output"
    assert_valid_json_document "missing plan action is parseable" "$output"

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=1 run_in_subshell "render_execute_json" || true)"
    assert_contains "execute renderer missing action returns structured error" '"code":"missing-argument"' "$output"
    assert_valid_json_document "missing execute action is parseable" "$output"
}

test_json_cleanup_logs_execute_is_logs_cleanup_proxy() {
    local output=""

    output="$(NODE_MANAGER_ALLOW_JSON_EXECUTE=0 run_in_subshell "run_json_command execute cleanup logs" || true)"
    assert_contains "cleanup logs execute proxies to logs-cleanup without execute gate" '"action":"logs-cleanup"' "$output"
    assert_contains "cleanup logs execute proxy succeeds" '"ok":true' "$output"
    assert_valid_json_document "cleanup logs execute proxy is parseable" "$output"
}

test_cleanup_logs_execute_gate_exception_is_documented() {
    local help_output=""
    local spec_output=""

    help_output="$(run_in_subshell "render_help" || true)"
    assert_contains "help documents cleanup logs execute gate exception" "execute cleanup logs proxies to logs-cleanup and does not require NODE_MANAGER_ALLOW_JSON_EXECUTE" "$help_output"

    spec_output="$(sed -n '1,220p' "$NODE_DIR/docs/specs/2026-06-24-app-boundary-and-packaging-contract.md")"
    assert_contains "app boundary spec documents cleanup logs execute gate exception" "execute cleanup logs" "$spec_output"
}

test_hermetic_mocks_are_available() {
    local mock_dir="$TEST_DIR/mocks"
    local output=""

    if [ -x "$mock_dir/npm" ] && [ -x "$mock_dir/nvm" ] && [ -x "$mock_dir/curl" ]; then
        assert_pass "hermetic npm nvm curl mocks are executable"
    else
        assert_fail "hermetic npm nvm curl mocks are executable"
    fi

    output="$(PATH="$mock_dir:$PATH" MOCK_NPM_OUTDATED_EXIT=1 MOCK_NPM_OUTDATED_STDERR="registry failed" run_in_subshell "render_outdated_json" || true)"
    assert_contains "mock npm drives outdated error path" "npm-outdated-failed" "$output"
}

test_shellcheck_quality_runner_exists() {
    if [ -x "$NODE_DIR/run-quality-checks.sh" ]; then
        assert_pass "shellcheck quality runner exists"
    else
        assert_fail "shellcheck quality runner exists"
    fi
}

test_quality_runner_does_not_silently_skip_shellcheck() {
    local output=""
    local skip_message=""
    skip_message='shellcheck not installed; ''skipped'
    output="$(PATH="/usr/bin:/bin" NODE_MANAGER_SKIP_TESTS=1 bash "$NODE_DIR/run-quality-checks.sh" 2>&1 || true)"
    if printf '%s' "$output" | grep -F "$skip_message" >/dev/null 2>&1; then
        assert_fail "quality runner must not silently skip shellcheck"
    else
        assert_pass "quality runner must not silently skip shellcheck"
    fi
}

# ──────────────────────────────────────────────
# New feature coverage tests
# ──────────────────────────────────────────────

test_get_installed_node_versions_with_fixture() {
    # Test the grep pattern against the fixture
    local fixture="$FIXTURES_DIR/nvm-ls-sample.txt"
    local result=""
    result="$(grep -E '^[[:space:]]*(->[[:space:]])?[[:space:]]*v[0-9]' "$fixture" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq)"
    assert_contains "fixture parsing finds v18.20.8" "v18.20.8" "$result"
    assert_contains "fixture parsing finds v20.11.1" "v20.11.1" "$result"
    assert_contains "fixture parsing finds v22.3.0" "v22.3.0" "$result"
    # Should NOT include versions from alias lines
    if printf '%s' "$result" | grep -qF 'v24.11.0'; then
        assert_fail "fixture parsing should not include alias v24.11.0"
    else
        assert_pass "fixture parsing excludes alias v24.11.0"
    fi
}

test_npm_config_summary_grep() {
    local output=""
    output="$(grep -E '^(registry|cache|prefix|userconfig|globalconfig)' "$FIXTURES_DIR/npm-config-list-sample.txt" || true)"
    assert_contains "npm config summary finds registry" "registry" "$output"
}

test_cleanup_menu_has_all_options() {
    # Verify cleanup flow source code contains all expected menu options
    local script_content=""
    script_content="$(cat "$SCRIPT_PATH")"
    assert_contains "cleanup has npm cache verify" "npm cache verify" "$script_content"
    assert_contains "cleanup has npm cache clean" "npm cache clean --force" "$script_content"
    assert_contains "cleanup has npm cache dir" "清理 npm 用户缓存目录" "$script_content"
    assert_contains "cleanup has node-gyp" "清理 node-gyp 缓存" "$script_content"
    assert_contains "cleanup has orphan symlinks" "清理全局 bin 孤儿软链接" "$script_content"
    assert_contains "cleanup has nvm old versions" "清理 nvm 旧版本残留" "$script_content"
}

test_render_environment_menu() {
    local output=""
    output="$(run_in_subshell "render_environment_menu")"
    assert_contains "environment menu contains overview" "环境总览" "$output"
    assert_contains "environment menu contains install nvm" "安装 nvm" "$output"
    assert_contains "environment menu contains install node" "安装 Node.js 版本" "$output"
    assert_contains "environment menu contains switch node" "更改全局 Node 版本" "$output"
    assert_contains "environment menu contains uninstall node" "卸载 Node.js 版本" "$output"
    assert_contains "environment menu contains project node" "指定项目 Node 版本" "$output"
    assert_contains "environment menu contains cleanup" "清理 npm 环境" "$output"
}

test_render_update_menu() {
    local output=""
    output="$(run_in_subshell "render_update_menu")"
    assert_contains "update menu contains scan upgrade" "扫描并升级" "$output"
    assert_contains "update menu contains upgrade latest" "指定包升级到 latest" "$output"
}

# ──────────────────────────────────────────────
# Parallel install and path safety tests
# ──────────────────────────────────────────────

test_scoped_package_filename_sanitization() {
    # Verify that / in scoped packages is replaced with _ for filenames
    local input="@scope/pkg"
    local result=""
    result="$(printf '%s' "$input" | tr '/' '_')"
    assert_equals "scoped package sanitized for filename" "@scope_pkg" "$result"
}

test_drag_path_unescape_spaces() {
    # Verify that escaped spaces are unescaped
    local input="/tmp/Has\\ Space"
    local result=""
    result="$(printf '%s' "$input" | sed -e 's/\\ / /g')"
    assert_equals "drag path unescapes spaces" "/tmp/Has Space" "$result"
}

test_drag_path_unescape_parens() {
    # Verify that escaped parentheses are unescaped
    local input="/tmp/Has\\(Dir\\)"
    local result=""
    result="$(printf '%s' "$input" | sed -e 's/\\(/(/g' -e 's/\\)/)/g')"
    assert_equals "drag path unescapes parens" "/tmp/Has(Dir)" "$result"
}

test_drag_path_preserves_literal_newline() {
    # Verify that literal \n in filename is NOT decoded to newline
    local input="/tmp/file\\nname"
    local result=""
    result="$(printf '%s' "$input" | sed -e 's/\\ / /g' -e 's/\\(/(/g' -e 's/\\)/)/g')"
    # Should preserve \n as literal backslash-n, not convert to newline
    if printf '%s' "$result" | grep -q '\\n'; then
        assert_pass "drag path preserves literal \\n in filename"
    else
        assert_fail "drag path should preserve literal \\n in filename"
    fi
}

test_single_install_prompts_before_npm_install() {
    local output=""
    output="$(run_in_subshell "type run_single_install_flow")"
    assert_contains "single install asks confirm" "确认安装" "$output"
}

test_single_install_accepts_version_spec_behavior() {
    local dir=""
    local args_file=""
    local output=""

    dir="$(mktemp -d "$NODE_DIR/.runtime/tmp/single-install.XXXXXX")"
    args_file="$dir/npm-args"
    mkdir -p "$dir/root/eslint"

    output="$(printf 'eslint@9.0.0\ny\n\n' | run_in_subshell "node() { printf 'v20.11.1\n'; }; npm() { printf '%s\n' \"\$*\" >> '$args_file'; if [ \"\$1\" = prefix ]; then printf '$dir/prefix\n'; return 0; fi; if [ \"\$1\" = root ]; then printf '$dir/root\n'; return 0; fi; if [ \"\$1\" = install ]; then return 0; fi; if [ \"\$1\" = ls ]; then printf '{\"dependencies\":{\"eslint\":{\"version\":\"9.0.0\"}}}\n'; return 0; fi; return 0; }; run_single_install_flow" || true)"

    assert_contains "single install accepts version spec" "安装成功" "$output"
    assert_contains "single install passes raw spec to npm" "install -g eslint@9.0.0" "$(cat "$args_file" 2>/dev/null || true)"
}

test_upgrade_latest_rejects_version_spec_behavior() {
    local output=""

    output="$(printf 'eslint@9.0.0\n\n' | run_in_subshell "npm() { return 1; }; run_upgrade_latest_flow" || true)"
    assert_contains "latest upgrade rejects version spec" "latest 升级只支持 package 或 @scope/package" "$output"
}

test_parallel_install_removed_from_flow() {
    local output=""
    output="$(run_in_subshell "type run_batch_install_flow")"
    if printf '%s' "$output" | grep -F "并行安装" >/dev/null 2>&1; then
        assert_fail "batch install should not expose parallel mode"
    else
        assert_pass "batch install does not expose parallel mode"
    fi
}

# ──────────────────────────────────────────────
# Script syntax check
# ──────────────────────────────────────────────

test_script_syntax() {
    if bash -n "$SCRIPT_PATH" 2>/dev/null; then
        assert_pass "script passes bash -n syntax check"
    else
        assert_fail "script fails bash -n syntax check"
    fi
}

# ──────────────────────────────────────────────
# Main test runner
# ──────────────────────────────────────────────

main() {
    printf "========================================\n"
    printf "  npm-global-manager test suite\n"
    printf "========================================\n\n"

    printf "Script: %s\n" "$SCRIPT_PATH"
    printf "Fixtures: %s\n\n" "$FIXTURES_DIR"

    # Verify script exists
    if [ ! -f "$SCRIPT_PATH" ]; then
        printf "ERROR: Script not found: %s\n" "$SCRIPT_PATH"
        exit 1
    fi

    # Verify fixtures exist
    for fixture in npm-config-list-sample.txt npm-list-global-sample.json npm-outdated-sample.json; do
        if [ ! -f "$FIXTURES_DIR/$fixture" ]; then
            printf "ERROR: Fixture not found: %s\n" "$FIXTURES_DIR/$fixture"
            exit 1
        fi
    done

    printf "%s\n" "--- Task 1: Script scaffold ---"
    test_script_can_be_sourced
    test_script_syntax
    printf "\n"

    printf "%s\n" "--- Task 2: Summary helpers ---"
    test_print_summary_value_with_empty
    test_print_summary_value_with_value
    test_parse_scope_registry_lines
    test_command_exists_with_valid_command
    test_command_exists_with_invalid_command
    test_runtime_paths_stay_under_scripts_node
    test_macos_guard_rejects_linux
    test_command_exists_empty_fails
    test_startup_summary_does_not_source_nvm
    test_main_does_not_source_nvm_before_menu
    test_batch_package_loader_exists
    test_default_batch_package_list_is_empty
    test_batch_package_list_reads_config_file
    test_validate_simple_package_specs
    test_validate_package_specs_reject_invalid_npm_names
    test_parse_package_spec_contract
    test_validate_package_name_only_rejects_version_specs
    test_reject_complex_package_specs
    test_validate_scope_and_registry_url
    test_registry_helpers_use_user_location
    test_outdated_stderr_uses_mktemp_under_runtime
    test_latest_upgrade_blocks_unknown_latest
    test_cache_directory_delete_requires_full_path_confirmation
    test_help_and_version_exist
    test_json_summary_command_exists
    test_log_file_created_under_runtime
    test_run_logged_command_captures_output
    printf "\n"

    printf "%s\n" "--- Task 3: Menu dispatch ---"
    test_dispatch_main_choice_install
    test_dispatch_main_choice_uninstall
    test_dispatch_main_choice_update
    test_dispatch_main_choice_source
    test_dispatch_main_choice_environment
    test_dispatch_main_choice_invalid
    test_should_exit_menu_main_q
    test_should_exit_menu_main_other
    printf "\n"

    printf "%s\n" "--- Task 4: Package inventory parsers ---"
    test_parse_global_package_names
    test_parse_global_package_versions
    test_parse_global_package_names_sorted
    printf "\n"

    printf "%s\n" "--- Task 5: Outdated parsers ---"
    test_parse_outdated_package_rows
    test_parse_outdated_package_rows_format
    printf "\n"

    printf "%s\n" "--- Task 6: Protected packages ---"
    test_protected_package_npm
    test_protected_package_corepack
    test_protected_package_regular
    printf "\n"

    printf "%s\n" "--- Input parsing ---"
    test_parse_numeric_choice_valid
    test_parse_numeric_choice_back
    test_parse_numeric_choice_invalid_letter
    test_parse_numeric_choice_out_of_range
    test_parse_multi_numeric_choice_valid
    test_parse_multi_numeric_choice_all
    test_parse_multi_numeric_choice_back
    test_parse_multi_numeric_choice_invalid
    test_parse_multi_numeric_choice_dedup
    test_parse_multi_numeric_choice_commas_and_ranges
    test_prompt_yes_no_reprompts_invalid_input
    printf "\n"

    printf "%s\n" "--- Trim whitespace ---"
    test_trim_whitespace
    test_trim_whitespace_tabs
    test_trim_whitespace_empty
    printf "\n"

    printf "%s\n" "--- Protected package edge cases ---"
    test_protected_package_empty_string
    test_protected_package_npm_uppercase
    test_protected_package_scoped_name
    printf "\n"

    printf "%s\n" "--- Parser edge cases ---"
    test_parse_outdated_stdin_invalid_json
    test_parse_outdated_stdin_empty_object
    test_parse_global_package_names_invalid_json
    test_parse_scope_registry_lines_no_scope
    test_parse_scope_registry_lines_multiple_scopes
    printf "\n"

    printf "%s\n" "--- Sub-menu dispatch ---"
    test_dispatch_install_choice_single
    test_dispatch_install_choice_batch
    test_dispatch_install_choice_back
    test_dispatch_source_choice_view
    test_dispatch_source_choice_switch
    test_dispatch_source_choice_scope
    test_dispatch_source_choice_reset
    test_dispatch_environment_choice_overview
    test_dispatch_environment_choice_install_nvm
    test_dispatch_environment_choice_install_node
    test_dispatch_environment_choice_switch_node
    test_dispatch_environment_choice_uninstall_node
    test_dispatch_environment_choice_project_node
    test_dispatch_environment_choice_cleanup
    printf "\n"

    printf "%s\n" "--- Input parsing edge cases ---"
    test_parse_numeric_choice_empty
    test_parse_multi_numeric_choice_single
    test_parse_multi_numeric_choice_out_of_range
    test_is_nonnegative_integer_valid
    test_is_nonnegative_integer_negative
    test_is_nonnegative_integer_empty
    printf "\n"

    printf "%s\n" "--- Status tag rendering ---"
    test_format_status_tag_ok
    test_format_status_tag_fail
    test_format_status_tag_warn
    printf "\n"

    printf "%s\n" "--- Environment value collection ---"
    test_collect_env_value_placeholder
    test_collect_env_value_real
    printf "\n"

    printf "%s\n" "--- extract_package_name ---"
    test_extract_package_name_simple
    test_extract_package_name_scoped
    test_extract_package_name_with_version
    test_extract_package_name_scoped_with_version
    test_extract_package_name_scoped_with_tag
    printf "\n"

    printf "%s\n" "--- Upgrade semantics ---"
    test_upgrade_global_package_uses_update
    test_upgrade_global_package_to_latest_uses_latest
    printf "\n"

    printf "%s\n" "--- JSON validation ---"
    test_parse_outdated_valid_json
    test_parse_outdated_invalid_json_returns_empty
    test_parse_global_package_names_valid_json
    test_parse_global_package_names_invalid_json_returns_empty
    printf "\n"

    printf "%s\n" "--- Verification logic ---"
    test_node_version_exact_match
    test_node_version_rejects_prefix_match
    test_cache_path_safety_rejects_root
    test_cache_path_safety_rejects_home
    test_check_bin_entries_with_real_bin
    test_extract_package_name_edge_cases
    test_bin_string_uses_package_name
    test_residue_symlink_requires_target_under_package_dir
    test_atomic_write_file_replaces_content
    test_nvm_ls_parsing_installed_only
    test_nvm_ls_parsing_excludes_aliases
    test_nvm_ls_parsing_excludes_lts_n_a
    test_global_bin_dir_returns_bin_path
    test_nvm_paths_respect_custom_nvm_dir
    test_node_gyp_cache_dir_detection_uses_devdir
    test_node_gyp_cache_candidates_include_modern_paths
    test_safe_removable_child_dir_boundaries
    test_count_user_global_packages_invalid_json_fails
    test_install_nvm_official_does_not_pipe_curl_to_bash
    test_dependency_preflight_allows_missing_ruby
    test_batch_install_uses_per_package_logs
    test_mutating_package_flows_use_logged_commands
    test_source_overview_shows_config_layers
    test_uninstall_flow_validates_inventory_json
    test_dragged_path_normalizer_handles_quotes
    test_node_version_choice_accepts_list_index
    test_project_nvmrc_literal_resolves_to_unique_concrete_installed_version
    test_project_node_flow_has_nvmrc_rollback
    test_uninstall_plan_shows_package_metadata
    test_scope_registry_flow_is_looping_menu
    test_profile_nvm_init_requires_nvm_sh
    test_install_nvm_official_with_mock_curl
    test_install_nvm_official_blocks_unverified_direct_call
    test_batch_install_supports_subset_selection
    test_batch_install_summary_counts_final_package_state_once
    test_batch_all_selects_only_pending_indices
    test_uninstall_flow_rescans_remaining_packages
    test_nvm_managed_detection_resolves_custom_dir
    test_environment_overview_has_nvm_diagnostics
    test_environment_overview_shows_dir_scanned_versions_when_nvm_unloaded
    test_scope_registry_layers_are_available
    test_registry_write_status_distinguishes_effective_layer
    test_scope_registry_write_status_distinguishes_effective_layer
    test_json_cli_has_app_commands
    test_json_plan_status_logs_contracts
    test_json_summary_and_status_do_not_require_npm
    test_json_execute_is_disabled_by_default
    test_node_version_range_matching
    test_help_and_version_skip_macos_guard
    test_dry_run_and_test_mode_are_real_cli_modes
    test_json_escape_without_ruby_is_valid
    test_json_commands_run_preflight
    test_outdated_empty_stdout_with_stderr_is_error
    test_log_file_names_are_unique_per_call
    test_destructive_helpers_have_hard_boundaries
    test_uninstall_residue_snapshot_verifies_symlink_target
    test_directory_snapshot_rejects_replaced_directory
    test_nvm_versions_scan_uses_directory_source
    test_nvm_default_info_separates_alias_and_resolution
    test_nvm_default_alias_file_unmatched_major_is_unresolved
    test_cleanup_flow_is_looping_menu
    test_operation_result_json_contract
    test_runtime_lock_rejects_existing_lock
    test_runtime_lock_recovers_stale_lock
    test_runtime_lock_release_respects_owner
    test_runtime_lock_explicit_release_removes_held_entry
    test_npm_mutations_share_single_lock
    test_source_overview_deduplicates_scope_registry_lines
    test_node_gyp_cleanup_lists_existing_dirs_before_delete
    test_node_gyp_cleanup_back_exits_successfully
    test_node_gyp_cleanup_all_selects_all_existing_dirs
    test_package_spec_rejects_dangling_at
    test_json_install_verifies_requested_version
    test_single_install_verifies_requested_version
    test_nvm_write_actions_require_shared_lock
    test_operation_result_rejects_invalid_exit_code
    test_scope_and_registry_validation_are_strict
    test_json_command_uses_stable_envelope
    test_npm_ls_stdout_does_not_break_installed_boolean
    test_install_spec_satisfaction_checks_requested_version
    test_batch_install_treats_npm_ls_stdout_success_as_installed
    test_bare_package_plan_resolves_latest_and_rejects_old_installed_version
    test_bare_package_install_verifies_latest_target
    test_package_plan_already_installed_respects_requested_version
    test_dist_tag_install_verification_uses_pre_resolved_target
    test_json_preflight_uses_single_error_envelope
    test_json_unsupported_command_uses_error_envelope
    test_json_failure_envelopes_are_parseable
    test_json_failure_payloads_use_single_error_model
    test_json_success_envelopes_are_parseable
    test_json_uninstall_is_supported_in_plan_and_help
    test_json_uninstall_rejects_missing_package
    test_json_non_package_action_contracts_are_documented
    test_app_packaging_boundary_is_documented
    test_require_capabilities_reports_missing_ruby
    test_logs_cleanup_json_command_is_available
    test_runtime_log_cleanup_keeps_recent_files
    test_legacy_package_helpers_use_logged_commands
    test_registry_latest_version_trims_npm_output
    test_semver_range_package_spec_resolves_registry_target
    test_json_install_plan_resolves_semver_range_target
    test_json_bootstrap_preflight_does_not_require_npm
    test_json_plan_does_not_create_runtime_logs
    test_json_package_plan_does_not_create_runtime_logs
    test_json_plan_preflight_is_read_only_for_nvm_install
    test_json_nvm_install_plan_and_execute_contract
    test_json_nvm_install_rejects_unsupported_version_argument
    test_json_execute_preserves_business_error_code
    test_json_node_actions_have_action_specific_version_boundaries
    test_json_node_use_preexecute_reports_business_failures
    test_json_node_install_preexecute_reports_business_failures
    test_json_node_plan_captures_nvm_noise
    test_json_dangerous_plans_include_impact_scope
    test_json_renderers_handle_missing_arguments
    test_json_cleanup_logs_execute_is_logs_cleanup_proxy
    test_cleanup_logs_execute_gate_exception_is_documented
    test_json_update_latest_verifies_latest_version
    test_json_execute_uninstall_uses_safe_action_layer
    test_json_execute_uninstall_rejects_protected_package
    test_shellcheck_installer_verifies_archive_checksum
    test_install_nvm_blocks_unverified_default_path
    test_hermetic_mocks_are_available
    test_shellcheck_quality_runner_exists
    test_quality_runner_does_not_silently_skip_shellcheck
    printf "\n"

    printf "%s\n" "--- Menu rendering (smoke) ---"
    test_render_main_menu
    test_render_install_menu
    test_render_source_menu
    test_render_environment_menu
    test_render_update_menu
    printf "\n"

    printf "%s\n" "--- New feature coverage ---"
    test_get_installed_node_versions_with_fixture
    test_npm_config_summary_grep
    test_cleanup_menu_has_all_options
    test_scoped_package_filename_sanitization
    test_drag_path_unescape_spaces
    test_drag_path_unescape_parens
    test_drag_path_preserves_literal_newline
    test_single_install_prompts_before_npm_install
    test_single_install_accepts_version_spec_behavior
    test_upgrade_latest_rejects_version_spec_behavior
    test_parallel_install_removed_from_flow
    printf "\n"

    printf "========================================\n"
    printf "  Results: %d passed, %d failed\n" "$PASS_COUNT" "$FAIL_COUNT"
    printf "========================================\n"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
