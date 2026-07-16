# Node Manager Full Quality Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `scripts/node/npm-global-manager.sh` into a full-scope, durable Node/npm/nvm manager with safe destructive actions, deterministic runtime output inside `scripts/node`, and behavior-focused tests.

**Architecture:** Keep the current interactive shell script as the public entrypoint, but add small internal layers inside the same script first: runtime paths, preflight, validators, command execution, nvm loading, npm metadata, and residue safety. After those layers exist, wire all features through them instead of adding more ad hoc command calls.

**Tech Stack:** Bash 3.2-compatible shell, macOS command-line tools, npm/nvm CLI, Ruby JSON parser, hermetic shell tests with mock binaries.

---

## File Structure

- Modify: `scripts/node/npm-global-manager.sh`
  - Owns public interactive flows and internal helper functions.
  - All runtime output must stay under `scripts/node/.runtime`.
- Modify: `scripts/node/tests/npm-global-manager-test.sh`
  - Keeps existing parser tests.
  - Adds behavior tests that source the script with mocked `PATH`, `HOME`, `NVM_DIR`, and runtime directory.
- Create: `scripts/node/tests/mocks/npm`
  - Fake npm command for install, uninstall, update, config, cache, outdated, and view flows.
- Create: `scripts/node/tests/mocks/nvm`
  - Fake nvm command for current, alias, ls, install, use, uninstall, and ls-remote flows.
- Create: `scripts/node/tests/mocks/curl`
  - Fake curl command for nvm install preflight and failure-path tests.
- Create: `scripts/node/config/global-packages.txt`
  - Explicit user-controlled batch install list. Empty by default.
- Runtime-created by script: `scripts/node/.runtime/logs`, `scripts/node/.runtime/tmp`
  - Created by helper functions. Not committed unless manually needed.

## Task 1: Runtime Boundary And Preflight

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests that assert:

```bash
test_runtime_paths_stay_under_scripts_node() {
    local output=""
    output="$(run_in_subshell "manager_runtime_dir")"
    assert_contains "runtime dir under scripts/node" "$NODE_DIR/.runtime" "$output"

    output="$(run_in_subshell "manager_log_dir")"
    assert_contains "log dir under scripts/node" "$NODE_DIR/.runtime/logs" "$output"

    output="$(run_in_subshell "manager_tmp_dir")"
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
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because `manager_runtime_dir`, `manager_log_dir`, `manager_tmp_dir`, and `ensure_macos` are missing or do not enforce the expected behavior.

- [ ] **Step 3: Implement runtime helpers and preflight**

Add helpers near constants:

```bash
RUNTIME_DIR="$SCRIPT_DIR/.runtime"
CONFIG_DIR="$SCRIPT_DIR/config"
DEFAULT_GLOBAL_PACKAGES_FILE="$CONFIG_DIR/global-packages.txt"

manager_runtime_dir() { printf '%s\n' "$RUNTIME_DIR"; }
manager_log_dir() { printf '%s\n' "$RUNTIME_DIR/logs"; }
manager_tmp_dir() { printf '%s\n' "$RUNTIME_DIR/tmp"; }

ensure_runtime_dirs() {
    mkdir -p "$(manager_log_dir)" "$(manager_tmp_dir)" "$CONFIG_DIR" || return 1
}

platform_uname() {
    printf '%s\n' "${MANAGER_TEST_UNAME:-$(uname -s 2>/dev/null || true)}"
}

ensure_macos() {
    if [ "$(platform_uname)" != "Darwin" ]; then
        print_status_message "fail" "仅支持 macOS，本机系统: $(platform_uname)"
        return 1
    fi
    return 0
}

command_exists() {
    [ -n "${1:-}" ] || return 1
    command -v "$1" >/dev/null 2>&1
}
```

Call `ensure_macos` and `ensure_runtime_dirs` from `main` before rendering menus.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 2: Read-Only Summary Must Not Change Node Environment

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_startup_summary_does_not_source_nvm() {
    local fake_home=""
    fake_home="$(mktemp -d "$NODE_DIR/.runtime/tmp/home-summary.XXXXXX")"
    mkdir -p "$fake_home/.nvm"
    printf 'echo sourced > "$HOME/nvm-sourced"\n' > "$fake_home/.nvm/nvm.sh"

    HOME="$fake_home" run_in_subshell "collect_startup_summary >/dev/null"

    if [ -f "$fake_home/nvm-sourced" ]; then
        assert_fail "startup summary must not source nvm"
    else
        assert_pass "startup summary must not source nvm"
    fi
}

test_main_does_not_source_nvm_before_menu() {
    local output=""
    output="$(run_in_subshell "type main")"
    if printf '%s' "$output" | grep -F "load_nvm_into_current_shell 2>/dev/null || true" >/dev/null 2>&1; then
        assert_fail "main should not load nvm silently before menu"
    else
        assert_pass "main does not load nvm silently before menu"
    fi
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because summary and main currently load nvm.

- [ ] **Step 3: Implement read-only nvm detection**

Replace summary loading with detection-only helpers:

```bash
detect_nvm_dir() {
    if [ -n "${NVM_DIR:-}" ]; then
        printf '%s\n' "$NVM_DIR"
    elif [ -n "${XDG_CONFIG_HOME:-}" ] && [ -s "$XDG_CONFIG_HOME/nvm/nvm.sh" ]; then
        printf '%s\n' "$XDG_CONFIG_HOME/nvm"
    else
        printf '%s\n' "$HOME/.nvm"
    fi
}

nvm_script_path() {
    local dir=""
    dir="$(detect_nvm_dir)"
    printf '%s\n' "$dir/nvm.sh"
}

load_nvm_into_current_shell() {
    export NVM_DIR="${NVM_DIR:-$(detect_nvm_dir)}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1090
        . "$NVM_DIR/nvm.sh" --no-use
        return 0
    fi
    return 1
}
```

In `collect_startup_summary`, remove the silent `load_nvm_into_current_shell` call. In `main`, remove the silent startup load.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 3: Explicit Batch Package Configuration

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`
- Create: `scripts/node/config/global-packages.txt`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_default_batch_package_list_is_empty() {
    local output=""
    output="$(run_in_subshell "load_batch_package_list")"
    assert_equals "default batch package list empty" "" "$output"
}

test_batch_package_list_reads_config_file() {
    local cfg="$NODE_DIR/.runtime/tmp/global-packages-test.txt"
    mkdir -p "$NODE_DIR/.runtime/tmp"
    printf '# comment\neslint\n\n@scope/pkg@1.2.3\n' > "$cfg"
    local output=""
    output="$(run_in_subshell "GLOBAL_PACKAGES_FILE='$cfg' load_batch_package_list")"
    assert_contains "batch config reads eslint" "eslint" "$output"
    assert_contains "batch config reads scoped version" "@scope/pkg@1.2.3" "$output"
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because packages are hardcoded and no loader exists.

- [ ] **Step 3: Implement config loader**

Replace the hardcoded `INSTALLABLE_GLOBAL_PACKAGES` entries with an empty array. Add:

```bash
GLOBAL_PACKAGES_FILE="${GLOBAL_PACKAGES_FILE:-$DEFAULT_GLOBAL_PACKAGES_FILE}"

load_batch_package_list() {
    local file_path="${1:-$GLOBAL_PACKAGES_FILE}"
    [ -f "$file_path" ] || return 0
    sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file_path" | sed '/^$/d'
}
```

Update `run_batch_install_flow` to populate a local array from `load_batch_package_list`, falling back to the empty `INSTALLABLE_GLOBAL_PACKAGES` array only for tests or future explicit configuration.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 4: Validators For Package Specs, Registry URLs, Scope Names, And Versions

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_validate_simple_package_specs() {
    run_in_subshell "validate_package_spec 'eslint'"
    assert_pass "valid package accepted"
    run_in_subshell "validate_package_spec '@scope/pkg'"
    assert_pass "valid scoped package accepted"
    run_in_subshell "validate_package_spec 'eslint@9.0.0'"
    assert_pass "valid version spec accepted"
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
}

test_validate_scope_and_registry_url() {
    run_in_subshell "validate_scope_name '@company'"
    assert_pass "valid scope accepted"
    if run_in_subshell "validate_scope_name '@bad/name'" 2>/dev/null; then
        assert_fail "bad scope rejected"
    else
        assert_pass "bad scope rejected"
    fi
    run_in_subshell "validate_registry_url 'https://registry.npmjs.org/'"
    assert_pass "https registry accepted"
    if run_in_subshell "validate_registry_url 'file:///tmp/registry'" 2>/dev/null; then
        assert_fail "file registry rejected"
    else
        assert_pass "file registry rejected"
    fi
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because validators are missing.

- [ ] **Step 3: Implement validators**

Add:

```bash
validate_package_spec() {
    local spec="${1:-}"
    case "$spec" in
        ""|*"://"*|npm:*|file:*|git:*|github:*|*"/../"*|*".."*) return 1 ;;
    esac
    if [[ "$spec" =~ ^(@[A-Za-z0-9._-]+/[A-Za-z0-9._-]+|[A-Za-z0-9._-]+)(@[A-Za-z0-9._~+-]+)?$ ]]; then
        return 0
    fi
    return 1
}

validate_scope_name() {
    local scope="${1:-}"
    [[ "$scope" =~ ^@[A-Za-z0-9._-]+$ ]]
}

validate_registry_url() {
    local url="${1:-}"
    [[ "$url" =~ ^https?://[^[:space:]]+/$ ]]
}

normalize_package_name_from_spec() {
    extract_package_name "$1"
}
```

Use these validators in single install, batch install, latest upgrade, switch registry, and scope registry flows before confirmation.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 5: Command Execution And Logs

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_log_file_created_under_runtime() {
    local output=""
    output="$(run_in_subshell "ensure_runtime_dirs; create_log_file install eslint")"
    assert_contains "log file under runtime logs" "$NODE_DIR/.runtime/logs/install-eslint" "$output"
}

test_run_logged_command_captures_output() {
    local output=""
    output="$(run_in_subshell "ensure_runtime_dirs; log_file=\$(create_log_file test printf); run_logged_command \"\$log_file\" printf hello; cat \"\$log_file\"")"
    assert_contains "logged command captures stdout" "hello" "$output"
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because log helpers are missing.

- [ ] **Step 3: Implement log helpers**

Add:

```bash
sanitize_filename_component() {
    printf '%s' "${1:-item}" | tr '/:@ ' '____' | sed 's/[^A-Za-z0-9._-]/_/g'
}

create_log_file() {
    local action="$1"
    local subject="${2:-run}"
    ensure_runtime_dirs || return 1
    printf '%s/%s-%s-%s.log\n' "$(manager_log_dir)" "$action" "$(sanitize_filename_component "$subject")" "$(date +%Y%m%d-%H%M%S)"
}

run_logged_command() {
    local log_file="$1"
    shift
    {
        printf 'COMMAND:'
        printf ' %s' "$@"
        printf '\n'
        "$@"
    } >> "$log_file" 2>&1
}
```

Route install, uninstall, update, cache clean, nvm install, node install/use/uninstall, and registry writes through this logging layer.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 6: Install And Batch Install Safety

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests that inspect functions and run mocked install:

```bash
test_single_install_prompts_before_npm_install() {
    local output=""
    output="$(run_in_subshell "type run_single_install_flow")"
    assert_contains "single install asks confirm" "确认安装" "$output"
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
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because single install does not confirm and batch install exposes parallel mode.

- [ ] **Step 3: Implement install safety**

Change single install to:
- Validate package spec.
- Show Node version, npm version, global prefix/root, registry, package spec, normalized package name, and log path.
- Ask `确认安装？` before `npm install -g`.
- Write logs per package.

Change batch install to:
- Load explicit config file.
- Let user choose all or selected packages.
- Validate every spec.
- Use serial install only.
- Write one log per package plus a summary log.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 7: Package Metadata And Safe Uninstall Residue Cleanup

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_bin_string_uses_package_name() {
    local tmp="$NODE_DIR/.runtime/tmp/pkg-bin-string.json"
    mkdir -p "$NODE_DIR/.runtime/tmp"
    printf '{"name":"my-cli","bin":"dist/index.js"}\n' > "$tmp"
    local output=""
    output="$(run_in_subshell "parse_package_bin_names '$tmp'")"
    assert_equals "bin string command is package name" "my-cli" "$output"
}

test_residue_symlink_requires_target_under_package_dir() {
    local tmp="$NODE_DIR/.runtime/tmp/residue"
    mkdir -p "$tmp/pkg/bin" "$tmp/bin"
    touch "$tmp/pkg/bin/cli.js" "$tmp/other.js"
    ln -sf "$tmp/pkg/bin/cli.js" "$tmp/bin/good"
    ln -sf "$tmp/other.js" "$tmp/bin/bad"
    run_in_subshell "is_owned_symlink '$tmp/bin/good' '$tmp/pkg'"
    assert_pass "owned symlink accepted"
    if run_in_subshell "is_owned_symlink '$tmp/bin/bad' '$tmp/pkg'" 2>/dev/null; then
        assert_fail "foreign symlink rejected"
    else
        assert_pass "foreign symlink rejected"
    fi
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because bin string parsing and owned symlink checks are missing or wrong.

- [ ] **Step 3: Implement metadata and residue safety**

Add:

```bash
parse_package_bin_names() {
    ruby -rjson -e '
      data = JSON.parse(File.read(ARGV[0]))
      name = data["name"].to_s
      bin = data["bin"]
      case bin
      when Hash then puts bin.keys.sort
      when String then puts name unless name.empty?
      end
    ' "$1" 2>/dev/null
}

is_path_within_dir() {
    local path="$1"
    local dir="$2"
    local real_path=""
    local real_dir=""
    real_path="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")" || return 1
    real_dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
    case "$real_path" in "$real_dir"/*) return 0 ;; *) return 1 ;; esac
}

is_owned_symlink() {
    local symlink_path="$1"
    local package_dir="$2"
    [ -L "$symlink_path" ] || return 1
    local target=""
    target="$(readlink "$symlink_path" 2>/dev/null)" || return 1
    case "$target" in
        /*) ;;
        *) target="$(dirname "$symlink_path")/$target" ;;
    esac
    is_path_within_dir "$target" "$package_dir"
}
```

Use these helpers in uninstall planning and residue cleanup. Only automatically delete owned symlinks and package directories verified to live under `npm root -g`. Plain files and foreign symlinks must be shown as candidates and skipped by automated cleanup.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 8: Registry Location And Validation

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_registry_helpers_use_user_location() {
    local output=""
    output="$(run_in_subshell "type set_registry_value; type set_scope_registry_value; type delete_registry_value")"
    assert_contains "registry set uses user location" "--location=user" "$output"
}

test_switch_registry_rejects_invalid_url() {
    if run_in_subshell "validate_registry_url 'ftp://registry.example.com/'" 2>/dev/null; then
        assert_fail "ftp registry rejected"
    else
        assert_pass "ftp registry rejected"
    fi
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because helpers do not use `--location=user`.

- [ ] **Step 3: Implement registry location management**

Change helpers:

```bash
set_registry_value() {
    local registry_url="$1"
    validate_registry_url "$registry_url" || return 1
    npm config set registry "$registry_url" --location=user || return 1
    [ "$(npm config get registry --location=user 2>/dev/null || true)" = "$registry_url" ]
}

delete_registry_value() {
    npm config delete registry --location=user || return 1
    local value=""
    value="$(npm config get registry --location=user 2>/dev/null || true)"
    [ -z "$value" ] || [ "$value" = "undefined" ]
}
```

Apply the same pattern to scope registry helpers. Add a restore-default action that deletes the user registry key and then displays effective registry.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 9: Upgrade Flow Verification And Remaining Outdated Rescan

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
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
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because current code uses `/tmp/npm-outdated-stderr.$$` and latest unknown is allowed.

- [ ] **Step 3: Implement upgrade hardening**

Use `mktemp "$(manager_tmp_dir)/npm-outdated-stderr.XXXXXX"` and clean it after reading. After batch upgrade, rerun `npm outdated -g --depth=0 --json` and print remaining outdated count. In latest upgrade, if `npm view "$package_name" version` returns empty, stop before confirmation with `无法获取 latest 版本，已取消升级`.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 10: nvm And Node Version Operations

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_nvm_dir_uses_custom_env() {
    local output=""
    output="$(run_in_subshell "NVM_DIR=/custom/nvm detect_nvm_dir")"
    assert_equals "custom NVM_DIR respected" "/custom/nvm" "$output"
}

test_version_compare_does_not_prefix_match_minor() {
    if run_in_subshell "node_version_matches 'v20.10.0' '20.1'" 2>/dev/null; then
        assert_fail "20.1 must not match 20.10.0"
    else
        assert_pass "20.1 does not match 20.10.0"
    fi
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because exact version helper is missing.

- [ ] **Step 3: Implement nvm operations**

Add:

```bash
normalize_node_version() {
    local version="${1:-}"
    version="${version#v}"
    printf 'v%s\n' "$version"
}

node_version_matches() {
    local actual=""
    local expected=""
    actual="$(normalize_node_version "$1")"
    expected="$(normalize_node_version "$2")"
    [ "$actual" = "$expected" ]
}
```

Use `detect_nvm_dir` for all nvm paths. In install specified Node flow, if the user enters a displayed index, select that version; otherwise treat input as a version string. Never use prefix matching for verification.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 11: Project `.nvmrc` Atomic Write And Rollback

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_atomic_write_file_replaces_content() {
    local dir="$NODE_DIR/.runtime/tmp/atomic"
    mkdir -p "$dir"
    printf 'old\n' > "$dir/.nvmrc"
    run_in_subshell "atomic_write_file '$dir/.nvmrc' 'v20.11.1'"
    local output=""
    output="$(cat "$dir/.nvmrc")"
    assert_equals "atomic write replaces file" "v20.11.1" "$output"
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because `atomic_write_file` is missing.

- [ ] **Step 3: Implement atomic write and rollback**

Add:

```bash
atomic_write_file() {
    local target="$1"
    local content="$2"
    local dir=""
    local tmp=""
    dir="$(dirname "$target")"
    tmp="$(mktemp "$dir/.tmp.$(basename "$target").XXXXXX")" || return 1
    printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$target"
}
```

Update `.nvmrc` flow so it:
- Shows existing file and proposed content.
- Confirms before write.
- Writes atomically.
- Installs/switches only after a successful write.
- Prints clear summary if install or switch fails after write.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 12: Cleanup Flows With Candidate Selection And Safe Deletes

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_cache_directory_delete_requires_full_path_confirmation() {
    local output=""
    output="$(run_in_subshell "type run_cleanup_flow")"
    assert_contains "cache delete requires full path" "请输入完整路径确认"
}

test_cleanup_uses_npm_supported_cache_clean() {
    local output=""
    output="$(run_in_subshell "type run_cleanup_flow")"
    assert_contains "cache clean supported path" "npm cache clean --force"
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because direct cache deletion does not require full path confirmation.

- [ ] **Step 3: Implement cleanup safety**

Refactor cleanup into small functions:
- `run_npm_cache_verify_flow`
- `run_npm_cache_clean_flow`
- `run_cache_directory_candidate_flow`
- `run_node_gyp_cleanup_flow`
- `run_orphan_bin_cleanup_flow`
- `run_nvm_old_version_cleanup_flow`

Rules:
- Cache directory direct deletion must require the user to type the exact resolved path.
- node-gyp path must prefer `npm config get node_gyp` or `node-gyp` devdir when available; fallback `~/.node-gyp` is shown as fallback.
- Orphan bin cleanup must support multi-select.
- nvm old version cleanup must treat JSON parse failures as unknown and skip deletion.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 13: CLI Surface For Future macOS App

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests**

Add tests:

```bash
test_help_and_version_exist() {
    local output=""
    output="$(run_in_subshell "render_help")"
    assert_contains "help includes dry run" "--dry-run" "$output"
    output="$(run_in_subshell "manager_version")"
    assert_contains "version has script name" "npm-global-manager" "$output"
}

test_json_summary_command_exists() {
    local output=""
    output="$(run_in_subshell "type render_summary_json")"
    assert_contains "json summary function exists" "render_summary_json" "$output"
}
```

- [ ] **Step 2: Verify red**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: fail because CLI helpers are missing.

- [ ] **Step 3: Implement app-oriented CLI flags**

Add support for:
- `--help`
- `--version`
- `--dry-run`
- `--test-mode`
- `--json summary`

Dry-run must print the intended command and log path without executing mutations.

- [ ] **Step 4: Verify green**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

## Task 14: Final Verification

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Run syntax checks**

Run:

```bash
bash -n scripts/node/npm-global-manager.sh scripts/node/tests/npm-global-manager-test.sh
```

Expected: exit 0.

- [ ] **Step 2: Run test suite**

Run:

```bash
bash scripts/node/tests/npm-global-manager-test.sh
```

Expected: all tests pass.

- [ ] **Step 3: Run shellcheck when available**

Run:

```bash
if command -v shellcheck >/dev/null 2>&1; then shellcheck scripts/node/npm-global-manager.sh scripts/node/tests/npm-global-manager-test.sh; else echo "shellcheck not installed; skipped"; fi
```

Expected: either shellcheck passes or prints the explicit skip line.

- [ ] **Step 4: Inspect runtime boundary**

Run:

```bash
find scripts/node -maxdepth 3 -type d | sort
```

Expected: runtime output directories, if created, are under `scripts/node/.runtime`; no new output exists outside `scripts/node`.

## Self-Review

- Spec coverage: The plan covers full-scope install, uninstall, update, registry, nvm, Node install/switch/uninstall, `.nvmrc`, cleanup, logs, runtime paths, preflight, CLI flags, and tests.
- Placeholder scan: No task uses placeholder wording for required implementation; each task has concrete tests, commands, and implementation direction.
- Type consistency: Helper names introduced in earlier tasks are reused consistently in later tasks.
