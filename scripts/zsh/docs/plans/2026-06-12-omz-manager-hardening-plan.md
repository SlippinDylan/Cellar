# OMZ Manager Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair every confirmed review finding in `scripts/zsh/omz-manager.sh` without expanding blast radius, while turning the script into a fail-closed, test-backed, manager-owned Zsh configuration tool.

**Architecture:** Keep one runtime script, but centralize all `~/.zshrc` mutation through managed-block helpers and stop mutating unmanaged user config. Separate plugin installation from plugin enablement, add strict path validation for plugin destinations, and replace silent continuation with explicit status handling. Drive the work through shell tests against temporary home directories.

**Tech Stack:** Bash 3.2-compatible shell scripting, awk/sed/grep, shell test harness

---

### Task 1: Lock down `~/.zshrc` ownership and fail-closed block mutation

**Files:**
- Modify: `scripts/zsh/omz-manager.sh`
- Modify: `scripts/zsh/tests/omz-manager-test.sh`
- Reference: `scripts/zsh/docs/specs/2026-06-12-omz-manager-hardening-design.md`

- [ ] **Step 1: Write failing tests for corrupted managed blocks and unmanaged config preservation**

Extend `scripts/zsh/tests/omz-manager-test.sh` with tests that prove:

- a missing end marker causes block removal to fail without changing the file
- unmanaged conditional theme/plugin config remains byte-for-byte untouched after manager writes its own block
- block rewrites do not accumulate blank lines

Add tests in this shape:

```bash
test_remove_managed_block_fails_closed_on_missing_end_marker() {
    local temp_home=""
    local before=""
    local after=""

    temp_home="$(make_temp_home)"
    cat >"$temp_home/.zshrc" <<'EOF'
# >>> omz-manager theme >>>
ZSH_THEME="robbyrussell"
# marker is intentionally broken
export PATH="$HOME/bin:$PATH"
EOF

    before="$(cat "$temp_home/.zshrc")"
    if HOME="$temp_home" bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        remove_managed_block \"\$ZSHRC_PATH\" \"$MANAGED_THEME_START\" \"$MANAGED_THEME_END\"
    " >/dev/null 2>&1; then
        assert_fail "corrupted managed block should fail closed" "unexpected success"
    else
        assert_pass "corrupted managed block should fail closed"
    fi

    after="$(cat "$temp_home/.zshrc")"
    assert_equals "corrupted block leaves file unchanged" "$before" "$after"
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
"$MANAGED_THEME_START" "$config_after"
}
```

- [ ] **Step 2: Run the targeted test suite and verify these new tests fail**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: new ownership tests fail because current mutation helpers truncate malformed blocks and comment unmanaged config.

- [ ] **Step 3: Replace broad mutation with explicit manager-owned block helpers**

In `scripts/zsh/omz-manager.sh`:

- make `remove_managed_block()` fail if EOF is reached while still inside a managed block
- remove or retire `comment_active_config_lines()`
- add a compdump managed block with its own markers instead of rewriting arbitrary `export ZSH_COMPDUMP=...` lines
- make `write_managed_block()` only remove and rewrite manager-owned blocks
- keep unmanaged plugin/theme/compdump lines untouched and warn on conflicts instead

Target helper shape:

```bash
MANAGED_COMPDUMP_START="# >>> omz-manager compdump >>>"
MANAGED_COMPDUMP_END="# <<< omz-manager compdump <<<"

remove_managed_block() {
    local file_path="$1"
    local start_marker="$2"
    local end_marker="$3"
    local temp_file=""

    temp_file="$(mktemp "${TMPDIR:-/tmp}/omz-manager.zshrc.XXXXXX")" || return 1
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { skip = 1; saw_start = 1; next }
        $0 == end {
            if (skip != 1) exit 2
            skip = 0
            saw_end = 1
            next
        }
        skip != 1 { print }
        END {
            if (skip == 1) exit 3
        }
    ' "$file_path" >"$temp_file" || {
        rm -f "$temp_file"
        return 1
    }

    mv "$temp_file" "$file_path"
}
```

- [ ] **Step 4: Re-run the full test suite and verify the ownership tests pass**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: the new fail-closed and unmanaged-config-preservation tests pass.

- [ ] **Step 5: Commit the ownership-boundary repair**

```bash
git add scripts/zsh/omz-manager.sh scripts/zsh/tests/omz-manager-test.sh \
    scripts/zsh/docs/specs/2026-06-12-omz-manager-hardening-design.md \
    scripts/zsh/docs/plans/2026-06-12-omz-manager-hardening-plan.md
git commit -m "fix: harden omz manager zshrc ownership boundaries"
```

### Task 2: Fix plugin parsing and separate install from enable state

**Files:**
- Modify: `scripts/zsh/omz-manager.sh`
- Modify: `scripts/zsh/tests/omz-manager-test.sh`

- [ ] **Step 1: Write failing tests for multi-line plugin parsing and install/enable separation**

Add tests that prove:

- multi-line `plugins=(...)` is parsed correctly
- a cloned plugin directory does not become enabled unless the manager-owned plugin block says so
- status labels distinguish installed vs enabled

Add tests in this shape:

```bash
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
    assert_not_contains "installed-only plugin should stay disabled" \
"zsh-autosuggestions" "$config_after"
}
```

- [ ] **Step 2: Run the suite and verify the new plugin-state tests fail**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: current parser fails on multi-line `plugins`, and current sync logic auto-enables installed plugins.

- [ ] **Step 3: Make the manager-owned plugins block the source of truth for enabled plugins**

In `scripts/zsh/omz-manager.sh`:

- rewrite `get_active_plugins_string()` to support single-line and multi-line plugin syntax
- add a helper that reads enabled plugins from the manager-owned plugins block first
- stop auto-appending every installed plugin in `sync_plugins_config()`
- update `build_plugin_display_labels()` so labels can reflect:
  - enabled and installed
  - installed but not enabled
  - catalog entry not installed

Target logic shape:

```bash
get_active_plugins_string() {
    [ -f "$ZSHRC_PATH" ] || return 0
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*plugins=[[:space:]]*\(/ {
            in_plugins = 1
            line = $0
            sub(/^[[:space:]]*plugins=[[:space:]]*\(/, "", line)
        }
        in_plugins {
            if (line == "") line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /\)/) {
                sub(/\).*/, "", line)
                if (line != "") printf "%s ", line
                in_plugins = 0
                line = ""
                next
            }
            if (line != "") printf "%s ", line
            line = ""
        }
    ' "$ZSHRC_PATH" | awk '{$1=$1; print}'
}
```

- [ ] **Step 4: Re-run the suite and verify plugin parsing/state tests pass**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: plugin parsing and install-vs-enable tests pass.

- [ ] **Step 5: Commit the plugin-state repair**

```bash
git add scripts/zsh/omz-manager.sh scripts/zsh/tests/omz-manager-test.sh
git commit -m "fix: separate omz plugin install and enable state"
```

### Task 3: Eliminate path escape and destructive cleanup risk

**Files:**
- Modify: `scripts/zsh/omz-manager.sh`
- Modify: `scripts/zsh/tests/omz-manager-test.sh`

- [ ] **Step 1: Write failing tests for plugin name sanitization and safe cleanup**

Add tests that reject unsafe plugin names and refuse cleanup outside the plugin root.

```bash
test_derive_plugin_name_from_url_rejects_unsafe_paths() {
    if run_in_subshell "derive_plugin_name_from_url 'https://example.com/../../outside.git'" >/dev/null 2>&1; then
        assert_fail "unsafe plugin path should be rejected" "unexpected success"
    else
        assert_pass "unsafe plugin path should be rejected"
    fi
}

test_plugin_cleanup_refuses_path_outside_custom_plugin_root() {
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
```

- [ ] **Step 2: Run the suite and verify the new path-safety tests fail**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: current URL derivation and cleanup logic fail the new safety tests.

- [ ] **Step 3: Add strict plugin name validation and bounded cleanup**

In `scripts/zsh/omz-manager.sh`:

- normalize trailing slash before deriving plugin name
- validate plugin name against a strict allowlist
- add `safe_remove_plugin_destination()` that only deletes under `CUSTOM_PLUGINS_DIR`
- update `clone_plugin_with_retry()` to use the bounded cleanup helper

Target helper shape:

```bash
is_safe_plugin_name() {
    case "$1" in
        ''|.|..|*'/'*|*' '*|*$'\t'*|*'..'*)
            return 1
            ;;
        [A-Za-z0-9._-]*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

safe_remove_plugin_destination() {
    local destination="$1"
    case "$destination" in
        "$CUSTOM_PLUGINS_DIR"/*) rm -rf "$destination" ;;
        *)
            print_status_message err "目标路径异常，拒绝清理: $destination"
            return 1
            ;;
    esac
}
```

- [ ] **Step 4: Re-run the suite and verify path-safety tests pass**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: unsafe plugin names and out-of-root cleanup are rejected.

- [ ] **Step 5: Commit the path-safety repair**

```bash
git add scripts/zsh/omz-manager.sh scripts/zsh/tests/omz-manager-test.sh
git commit -m "fix: bound omz plugin path handling"
```

### Task 4: Replace silent continuation with explicit failure handling

**Files:**
- Modify: `scripts/zsh/omz-manager.sh`
- Modify: `scripts/zsh/tests/omz-manager-test.sh`

- [ ] **Step 1: Write failing tests for non-silent failure reporting**

Add tests that prove:

- failed clone does not silently continue as success
- failed `sync_plugins_config` surfaces a warning and does not claim success
- failed theme switch is observable

```bash
test_install_plugin_specs_reports_failed_clone() {
    local output=""
    output="$(bash -c "
        set -euo pipefail
        source '$SCRIPT_PATH'
        clone_plugin_with_retry() { return 1; }
        install_plugin_specs 'demo|https://example.com/demo.git'
    " 2>&1 || true)"
    assert_contains "failed clone is reported" "跳过 demo" "$output"
}
```

- [ ] **Step 2: Run the suite and verify the failure-contract tests fail**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: current `|| true` behavior prevents these tests from passing.

- [ ] **Step 3: Replace `|| true` with explicit control-flow handling**

In `scripts/zsh/omz-manager.sh`:

- replace `helper || true` with `if ! helper; then ...; fi` where continuation is intentional
- return a real status when the overall action failed
- keep menu loops alive without claiming success

Target pattern:

```bash
if ! clone_plugin_with_retry "$plugin_name" "$plugin_url"; then
    print_status_message warn "跳过 $plugin_name，继续处理其余插件。"
    return 1
fi
```

For menu flows:

```bash
if ! run_zsh_tidy_flow; then
    print_status_message warn "整理流程未完成，请先处理上面的错误。"
fi
pause_with_back_option || return 0
```

- [ ] **Step 4: Re-run the suite and verify failure-reporting tests pass**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: failures remain visible and do not masquerade as success.

- [ ] **Step 5: Commit the failure-contract repair**

```bash
git add scripts/zsh/omz-manager.sh scripts/zsh/tests/omz-manager-test.sh
git commit -m "fix: surface omz manager operation failures"
```

### Task 5: Repair compdump handling, theme parsing, and tidy behavior

**Files:**
- Modify: `scripts/zsh/omz-manager.sh`
- Modify: `scripts/zsh/tests/omz-manager-test.sh`

- [ ] **Step 1: Write failing tests for compdump equivalence, theme quoting, and tidy backup contract**

Add tests that prove:

- both `$HOME/.zsh/zcompdump` and the expanded absolute path are treated as equivalent
- `get_current_theme()` supports single quotes
- tidy flow does not mishandle the current operation's backup according to the new contract

```bash
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
```

- [ ] **Step 2: Run the suite and verify these new parsing/tidy tests fail**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: current implementation fails at least the single-quote and compdump-equivalence checks.

- [ ] **Step 3: Normalize compdump comparisons and simplify tidy backup flow**

In `scripts/zsh/omz-manager.sh`:

- compare active compdump exports semantically, not by exact fixed-string match
- decide one explicit contract for current-operation backups:
  - either leave new backups in `~`
  - or always move them to `~/.zsh/backups/` and print the exact path

Use the lower-surprise option:

- keep historical stray backups moving into `~/.zsh/backups/`
- leave the current operation's fresh backup where `backup_zshrc()` creates it
- print its path explicitly

Also update `get_current_theme()` to strip either single or double quotes.

- [ ] **Step 4: Re-run the suite and verify parsing/tidy tests pass**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: compdump, theme, and backup-contract tests pass.

- [ ] **Step 5: Commit the parsing and tidy repair**

```bash
git add scripts/zsh/omz-manager.sh scripts/zsh/tests/omz-manager-test.sh
git commit -m "fix: harden omz manager parsing and tidy behavior"
```

### Task 6: Pin installer, clean dead code, and align status/UX helpers

**Files:**
- Modify: `scripts/zsh/omz-manager.sh`
- Modify: `scripts/zsh/tests/omz-manager-test.sh`

- [ ] **Step 1: Write failing tests for installer pinning and status freshness**

Add tests that prove:

- the installer URL is pinned to a fixed revision
- `show_status()` reflects fresh disk/config state after rebuild

```bash
test_omz_install_url_is_pinned() {
    local output=""
    output="$(run_in_subshell "printf '%s' \"\$OMZ_INSTALL_URL\"")"
    assert_not_contains "installer URL should not track master" "/master/" "$output"
}
```

- [ ] **Step 2: Run the suite and verify these cleanup/pinning tests fail**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: current installer URL test fails.

- [ ] **Step 3: Apply the final low-level cleanups**

In `scripts/zsh/omz-manager.sh`:

- pin `OMZ_INSTALL_URL` to a fixed upstream commit
- remove `SCRIPT_NAME` if still unused
- simplify dead branches such as the redundant `render_separator()` fallback
- document why `append_to_array()` uses `eval` under Bash 3.2
- clarify or replace `pause_with_back_option()` so navigation intent is more legible
- ensure `show_status()` rebuilds any state it displays

- [ ] **Step 4: Re-run the full suite and syntax checks**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`  
Expected: all tests pass with `FAIL_COUNT=0`

Run: `bash -n scripts/zsh/omz-manager.sh`  
Expected: exit code `0` with no output

Run: `bash -n scripts/zsh/tests/omz-manager-test.sh`  
Expected: exit code `0` with no output

- [ ] **Step 5: Commit the final hardening pass**

```bash
git add scripts/zsh/omz-manager.sh scripts/zsh/tests/omz-manager-test.sh
git commit -m "chore: finish omz manager hardening pass"
```
