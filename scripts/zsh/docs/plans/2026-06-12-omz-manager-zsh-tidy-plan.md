# OMZ Manager Zsh Tidy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `scripts/zsh/omz-manager.sh` with a fourth menu action that tidies scattered Zsh artifacts under `~` while keeping the script as the single entry point for Zsh setup and maintenance.

**Architecture:** Keep the runtime as one shell script. Add a small set of tidy-focused helper functions into `scripts/zsh/omz-manager.sh`, then expose them through a new main-menu action. Cover the behavior with a dedicated shell test harness under `scripts/zsh/tests/` that sources the script and runs against temporary home directories.

**Tech Stack:** Bash, shell test harness, temporary fixture directories

---

### Task 1: Add a dedicated Zsh manager test harness

**Files:**
- Create: `scripts/zsh/tests/omz-manager-test.sh`
- Modify: `scripts/zsh/omz-manager.sh`
- Reference: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write the failing test harness and menu assertions**

Create `scripts/zsh/tests/omz-manager-test.sh` with a minimal assertion library, a `run_in_subshell` helper that sources `scripts/zsh/omz-manager.sh`, and failing checks for the new menu item plus helper behavior that does not exist yet.

```bash
#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSH_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT_PATH="$ZSH_DIR/omz-manager.sh"

PASS_COUNT=0
FAIL_COUNT=0

assert_equals() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf "  PASS: %s\n" "$name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf "  FAIL: %s expected='%s' actual='%s'\n" "$name" "$expected" "$actual"
    fi
}

run_in_subshell() {
    bash -lc "
        set -euo pipefail
        source '$SCRIPT_PATH'
        $1
    " 2>/dev/null
}

test_main_menu_labels() {
    local output=""
    output="$(run_in_subshell "main_menu_text")"
    assert_equals "main menu includes tidy entry" \
"1) 安装 Oh My Zsh
2) 管理插件
3) 切换主题
4) 整理 Zsh 文件
q) 退出" "$output"
}

test_dispatch_main_choice() {
    local output=""
    output="$(run_in_subshell "dispatch_main_choice 4")"
    assert_equals "choice 4 dispatches tidy action" "tidy-zsh-files" "$output"
}
```

- [ ] **Step 2: Run the new test file and verify it fails for the expected reason**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: failure because `main_menu_text` and `dispatch_main_choice` are not implemented yet, or because the menu output does not include the fourth option.

- [ ] **Step 3: Add the smallest script seams needed for menu testing**

In `scripts/zsh/omz-manager.sh`, extract the static menu rendering into `main_menu_text` and add a `dispatch_main_choice` helper so the menu can be tested without driving an interactive `read` loop.

```bash
main_menu_text() {
    printf "%s\n" \
        "1) 安装 Oh My Zsh" \
        "2) 管理插件" \
        "3) 切换主题" \
        "4) 整理 Zsh 文件" \
        "q) 退出"
}

dispatch_main_choice() {
    case "$1" in
        1) printf "install-omz" ;;
        2) printf "manage-plugins" ;;
        3) printf "switch-theme" ;;
        4) printf "tidy-zsh-files" ;;
        q|Q) printf "quit" ;;
        *) printf "invalid" ;;
    esac
}
```

- [ ] **Step 4: Re-run the menu-focused test file and verify those checks pass**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: the menu assertions pass, while later tidy behavior tests still fail because the tidy helpers are not implemented yet.

### Task 2: Add failing tidy behavior tests against a temporary home directory

**Files:**
- Modify: `scripts/zsh/tests/omz-manager-test.sh`
- Modify: `scripts/zsh/omz-manager.sh`

- [ ] **Step 1: Add failing tests that exercise tidy behavior in isolation**

Extend `scripts/zsh/tests/omz-manager-test.sh` with temporary-home tests. Override `HOME`, `ZSH_DIR`, `BACKUP_DIR`, and `ZSHRC_PATH` inside the sourced script context so tests do not touch the real user profile.

```bash
make_temp_home() {
    mktemp -d "${TMPDIR:-/tmp}/omz-manager-test-home.XXXXXX"
}

test_tidy_moves_compdump_and_backups() {
    local temp_home=""
    local output=""

    temp_home="$(make_temp_home)"
    : >"$temp_home/.zcompdump"
    : >"$temp_home/.zcompdump-dev"
    : >"$temp_home/.zshrc.bak.123"
    : >"$temp_home/.zshrc.backup-legacy"
    : >"$temp_home/.zprofile.bak"
    printf '%s\n' '# existing rc' >"$temp_home/.zshrc"

    output="$(HOME='$temp_home' bash -lc "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSH_DIR=\"\$HOME/.zsh\"
        BACKUP_DIR=\"\$ZSH_DIR/backups\"
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        run_zsh_tidy_flow
    ")"

    assert_equals "compdump moved" "1" "$(test -f "$temp_home/.zsh/.zcompdump"; printf '%s' "$?")"
    assert_equals "legacy backup moved" "0" "$(test -f "$temp_home/.zsh/backups/.zshrc.backup-legacy"; printf '%s' "$?")"
    assert_equals "manager backup moved" "0" "$(test -f "$temp_home/.zsh/backups/.zshrc.bak.123"; printf '%s' "$?")"
    assert_equals "zprofile backup moved" "0" "$(test -f "$temp_home/.zsh/backups/.zprofile.bak"; printf '%s' "$?")"
}

test_tidy_normalizes_zsh_compdump_export() {
    local temp_home=""

    temp_home="$(make_temp_home)"
    cat >"$temp_home/.zshrc" <<'EOF'
export ZSH_COMPDUMP="$HOME/.cache/old-zcompdump"
EOF

    HOME="$temp_home" bash -lc "
        set -euo pipefail
        source '$SCRIPT_PATH'
        ZSH_DIR=\"\$HOME/.zsh\"
        BACKUP_DIR=\"\$ZSH_DIR/backups\"
        ZSHRC_PATH=\"\$HOME/.zshrc\"
        run_zsh_tidy_flow >/dev/null
    "

    assert_equals "compdump export normalized" \
'export ZSH_COMPDUMP="$HOME/.zsh/zcompdump"' \
"$(grep '^export ZSH_COMPDUMP=' "$temp_home/.zshrc")"
}
```

- [ ] **Step 2: Run the test file and verify it fails for missing tidy helpers**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: failure because `run_zsh_tidy_flow` and the config normalization helpers do not exist yet.

- [ ] **Step 3: Implement the minimum tidy helpers needed by the tests**

Add helpers in `scripts/zsh/omz-manager.sh` for:

- creating `~/.zsh` and `~/.zsh/backups`
- moving `~/.zcompdump*` files into `~/.zsh/`
- moving `.zshrc.backup-*`, `.zshrc.backup.*`, and `.zshrc.bak.*` into `~/.zsh/backups/`
- moving `.zprofile.bak`
- normalizing the `export ZSH_COMPDUMP=...` line in `~/.zshrc`

Use function boundaries such as:

```bash
ensure_zsh_tidy_directories() { ... }
move_zsh_compdump_files() { ... }
move_zsh_backup_files() { ... }
ensure_zsh_compdump_export() { ... }
run_zsh_tidy_flow() { ... }
```

- [ ] **Step 4: Re-run the test file and verify the tidy tests now pass**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: tidy behavior tests pass, and any remaining failures are isolated to the still-unwired interactive menu branch.

### Task 3: Wire the tidy flow into the interactive menu

**Files:**
- Modify: `scripts/zsh/omz-manager.sh`
- Modify: `scripts/zsh/tests/omz-manager-test.sh`

- [ ] **Step 1: Add the new interactive menu action**

Update the main menu loop to print the fourth option, dispatch through `dispatch_main_choice`, and run the tidy flow when the user selects `4`.

```bash
case "$(dispatch_main_choice "$choice")" in
    install-omz) menu_install_omz ;;
    manage-plugins) menu_plugins ;;
    switch-theme) menu_themes ;;
    tidy-zsh-files)
        run_zsh_tidy_flow || true
        pause_with_back_option || return 0
        ;;
    quit) return 0 ;;
    *)
        print_status_message warn "请输入 1、2、3、4 或 q。"
        pause_with_back_option || return 0
        ;;
esac
```

- [ ] **Step 2: Add a regression test for the idempotent tidy flow**

Extend `scripts/zsh/tests/omz-manager-test.sh` with a test that runs `run_zsh_tidy_flow` twice and verifies:

- there is only one active `export ZSH_COMPDUMP="$HOME/.zsh/zcompdump"` line
- files are not duplicated
- `.zprofile` itself remains in `~`

```bash
assert_equals "only one compdump export" \
"1" "$(grep -c '^export ZSH_COMPDUMP=' "$temp_home/.zshrc")"
assert_equals "zprofile remains in home" \
"0" "$(test -f "$temp_home/.zprofile"; printf '%s' "$?")"
```

- [ ] **Step 3: Run the test file and verify the full zsh test suite passes**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: all tests pass with `FAIL_COUNT=0`.

### Task 4: Final verification

**Files:**
- Modify: `scripts/zsh/omz-manager.sh`
- Modify: `scripts/zsh/tests/omz-manager-test.sh`

- [ ] **Step 1: Run the dedicated zsh test suite as the completion gate**

Run: `bash scripts/zsh/tests/omz-manager-test.sh`

Expected: exit code `0`, every test prints `PASS`, and the final summary reports zero failures.

- [ ] **Step 2: Run a shell syntax check on the manager script**

Run: `bash -n scripts/zsh/omz-manager.sh`

Expected: exit code `0` with no output.

- [ ] **Step 3: Run a shell syntax check on the new test file**

Run: `bash -n scripts/zsh/tests/omz-manager-test.sh`

Expected: exit code `0` with no output.
