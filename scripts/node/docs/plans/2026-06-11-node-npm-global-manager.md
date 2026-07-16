# Node / npm Global Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an interactive macOS shell script that manages `nvm`, Node.js versions, `npm` global packages, and npm registry configuration without relying on Homebrew for Node installation, while remaining maintainable, stable, and structurally clean over time.

**Architecture:** Keep a single executable script at `scripts/node/npm-global-manager.sh`, but structure it as focused shell functions for menu rendering, state collection, npm package operations, registry management, and environment actions. Add shell tests and parser fixtures under `scripts/node/tests/` so the interactive flows rely on deterministic helper functions that can be verified without mutating the real environment. Avoid patch-style fixes, avoid scope creep, and keep each feature behind a narrow, deliberate boundary.

**Tech Stack:** Bash, macOS shell utilities, `nvm`, `npm`, shell test script with fixture-driven assertions

---

## File Structure

- Create: `scripts/node/npm-global-manager.sh`
  Responsibility: single interactive entrypoint and all runtime functions
- Create: `scripts/node/tests/npm-global-manager-test.sh`
  Responsibility: shell-level test runner for parser and helper functions
- Create: `scripts/node/tests/fixtures/npm-outdated-sample.json`
  Responsibility: sample `npm outdated -g --json` payload for upgrade parsing tests
- Create: `scripts/node/tests/fixtures/npm-list-global-sample.json`
  Responsibility: sample global package listing payload for inventory parsing tests
- Create: `scripts/node/tests/fixtures/npm-config-list-sample.txt`
  Responsibility: sample config output for registry and scope parsing tests
- Modify: `scripts/node/docs/specs/2026-06-11-node-npm-global-manager-spec.md`
  Responsibility: update only if implementation discovers real spec gaps
- Modify: `scripts/node/docs/specs/2026-06-11-node-npm-global-manager-open-questions.md`
  Responsibility: close questions only when the human explicitly decides them

## Implementation Guardrails

- Do not ship patch-style fixes whose only purpose is to silence failures.
- Do not widen the blast radius to unrelated menu flows or environment actions.
- Do not duplicate near-identical logic across install, uninstall, update, and source management flows.
- Prefer small, composable helper functions over giant procedural branches.
- Keep read-only collection logic separate from mutating execution logic.
- If a feature cannot be implemented cleanly in the current task, stop at a clean boundary and defer it explicitly instead of inserting a half-designed shortcut.

### Task 1: Scaffold the script entrypoint and test harness

**Files:**
- Create: `scripts/node/npm-global-manager.sh`
- Create: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write the failing test for loading the script without executing the menu**

```bash
#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_PATH="$ROOT_DIR/scripts/node/npm-global-manager.sh"

test_script_can_be_sourced() {
    local output=""
    output="$(
        bash -lc "
            set -euo pipefail
            source '$SCRIPT_PATH'
            printf 'loaded\n'
        "
    )"

    [ "$output" = "loaded" ]
}

test_script_can_be_sourced
printf 'PASS: script can be sourced without running the menu\n'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: FAIL with `No such file or directory` for `scripts/node/npm-global-manager.sh`

- [ ] **Step 3: Write the minimal script scaffold**

```bash
#!/bin/bash

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

main() {
    :
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: PASS with `PASS: script can be sourced without running the menu`

- [ ] **Step 5: Commit**

```bash
git add scripts/node/npm-global-manager.sh scripts/node/tests/npm-global-manager-test.sh
git commit -m "feat: scaffold npm global manager script"
```

### Task 2: Build environment loading and startup summary helpers

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`
- Create: `scripts/node/tests/fixtures/npm-config-list-sample.txt`

- [ ] **Step 1: Write failing tests for summary helper functions**

```bash
test_render_summary_handles_missing_values() {
    local output=""
    output="$(
        bash -lc "
            set -euo pipefail
            source '$SCRIPT_PATH'
            print_summary_value 'node 版本' ''
        "
    )"

    printf '%s' "$output" | grep -F '<unavailable>' >/dev/null
}

test_detect_scope_registry_lines() {
    local output=""
    output="$(
        bash -lc "
            set -euo pipefail
            source '$SCRIPT_PATH'
            parse_scope_registry_lines '$ROOT_DIR/scripts/node/tests/fixtures/npm-config-list-sample.txt'
        "
    )"

    printf '%s' "$output" | grep -F '@demo:registry=https://registry.example.com/' >/dev/null
}
```

- [ ] **Step 2: Add the fixture and run tests to verify failure**

```text
; "user" config from /Users/example/.npmrc
registry = "https://registry.npmjs.org/"
@demo:registry = "https://registry.example.com/"
```

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: FAIL because `print_summary_value` and `parse_scope_registry_lines` are undefined

- [ ] **Step 3: Implement environment and summary helpers**

```bash
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_summary_value() {
    local label="$1"
    local value="${2:-}"

    if [ -z "$value" ]; then
        value="<unavailable>"
    fi

    printf "%s: %s\n" "$label" "$value"
}

load_nvm_into_current_shell() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1090
        . "$NVM_DIR/nvm.sh"
        return 0
    fi
    return 1
}

parse_scope_registry_lines() {
    local file_path="$1"
    sed -n 's/^[[:space:]]*\(@[^:][^=]*:registry\)[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1=\2/p' "$file_path"
}
```

- [ ] **Step 4: Extend the script with startup-summary collection**

```bash
collect_startup_summary() {
    local node_path=""
    local npm_path=""
    local node_version=""
    local npm_version=""
    local registry=""

    node_path="$(command -v node 2>/dev/null || true)"
    npm_path="$(command -v npm 2>/dev/null || true)"
    node_version="$(node -v 2>/dev/null || true)"
    npm_version="$(npm -v 2>/dev/null || true)"
    registry="$(npm config get registry 2>/dev/null || true)"

    print_summary_value "node 路径" "$node_path"
    print_summary_value "npm 路径" "$npm_path"
    print_summary_value "node 版本" "$node_version"
    print_summary_value "npm 版本" "$npm_version"
    print_summary_value "当前 registry" "$registry"
}
```

- [ ] **Step 5: Run tests and commit**

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: PASS, including the new summary helper assertions

```bash
git add scripts/node/npm-global-manager.sh scripts/node/tests/npm-global-manager-test.sh scripts/node/tests/fixtures/npm-config-list-sample.txt
git commit -m "feat: add environment summary helpers"
```

### Task 3: Add top-level menu flow and read-only environment pages

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests for menu dispatch**

```bash
test_dispatch_main_choice() {
    local output=""
    output="$(
        bash -lc "
            set -euo pipefail
            source '$SCRIPT_PATH'
            dispatch_main_choice 4
        "
    )"

    [ "$output" = "source-management" ]
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: FAIL because `dispatch_main_choice` is undefined

- [ ] **Step 3: Implement menu rendering and summary page helpers**

```bash
render_main_menu() {
    cat <<'EOF'
1) 安装项目
2) 卸载项目
3) 更新与升级
4) 源管理
5) 环境与依赖
q) 退出
EOF
}

dispatch_main_choice() {
    case "$1" in
        1) echo "install" ;;
        2) echo "uninstall" ;;
        3) echo "update" ;;
        4) echo "source-management" ;;
        5) echo "environment" ;;
        *) echo "invalid" ;;
    esac
}

render_startup_page() {
    printf "当前环境摘要\n"
    collect_startup_summary
    printf "\n"
    render_main_menu
}
```

- [ ] **Step 4: Add environment overview page and safe pause helpers**

```bash
pause_before_return() {
    printf "\n按回车继续..."
    read -r _ || true
}

run_environment_overview() {
    printf "环境总览\n"
    collect_startup_summary
    pause_before_return
}
```

- [ ] **Step 5: Run tests and commit**

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: PASS, including the dispatch assertion

```bash
git add scripts/node/npm-global-manager.sh scripts/node/tests/npm-global-manager-test.sh
git commit -m "feat: add startup page and main menu flow"
```

### Task 4: Implement registry management and global package inventory

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`
- Create: `scripts/node/tests/fixtures/npm-list-global-sample.json`

- [ ] **Step 1: Write failing tests for inventory and registry parsers**

```bash
test_parse_global_package_names() {
    local output=""
    output="$(
        bash -lc "
            set -euo pipefail
            source '$SCRIPT_PATH'
            parse_global_package_names '$ROOT_DIR/scripts/node/tests/fixtures/npm-list-global-sample.json'
        "
    )"

    printf '%s' "$output" | grep -F 'eslint' >/dev/null
}
```

- [ ] **Step 2: Add fixture and run test to verify failure**

```json
{
  "name": "lib",
  "dependencies": {
    "eslint": {
      "version": "9.0.0"
    },
    "typescript": {
      "version": "5.8.0"
    }
  }
}
```

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: FAIL because `parse_global_package_names` is undefined

- [ ] **Step 3: Implement deterministic parsers and read-only source reporting**

```bash
parse_global_package_names() {
    local json_path="$1"
    ruby -rjson -e 'data = JSON.parse(File.read(ARGV[0])); deps = data["dependencies"] || {}; puts deps.keys.sort' "$json_path"
}

load_global_package_inventory() {
    npm ls -g --depth=0 --json 2>/dev/null
}

run_source_overview() {
    local registry=""
    registry="$(npm config get registry 2>/dev/null || true)"

    printf "当前 registry: %s\n" "${registry:-<unavailable>}"
    printf "用户级 .npmrc: %s\n" "$HOME/.npmrc"
    printf "项目级 .npmrc: %s\n" "$(pwd)/.npmrc"
}
```

- [ ] **Step 4: Add registry mutation helpers with verification**

```bash
set_registry_value() {
    local registry_url="$1"
    npm config set registry "$registry_url" || return 1
    [ "$(npm config get registry 2>/dev/null || true)" = "$registry_url" ]
}

set_scope_registry_value() {
    local scope_name="$1"
    local registry_url="$2"
    npm config set "${scope_name}:registry" "$registry_url" || return 1
    [ "$(npm config get "${scope_name}:registry" 2>/dev/null || true)" = "$registry_url" ]
}
```

- [ ] **Step 5: Run tests and commit**

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: PASS, including the fixture-based inventory parser test

```bash
git add scripts/node/npm-global-manager.sh scripts/node/tests/npm-global-manager-test.sh scripts/node/tests/fixtures/npm-list-global-sample.json
git commit -m "feat: add registry management and package inventory helpers"
```

### Task 5: Implement single install, batch install, and upgrade flows

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`
- Create: `scripts/node/tests/fixtures/npm-outdated-sample.json`

- [ ] **Step 1: Write failing tests for outdated parsing**

```bash
test_parse_outdated_packages() {
    local output=""
    output="$(
        bash -lc "
            set -euo pipefail
            source '$SCRIPT_PATH'
            parse_outdated_package_rows '$ROOT_DIR/scripts/node/tests/fixtures/npm-outdated-sample.json'
        "
    )"

    printf '%s' "$output" | grep -F 'npm-check-updates|17.0.0|17.1.0|18.0.0' >/dev/null
}
```

- [ ] **Step 2: Add fixture and run test to verify failure**

```json
{
  "npm-check-updates": {
    "current": "17.0.0",
    "wanted": "17.1.0",
    "latest": "18.0.0"
  }
}
```

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: FAIL because `parse_outdated_package_rows` is undefined

- [ ] **Step 3: Implement install and upgrade helpers**

```bash
INSTALLABLE_GLOBAL_PACKAGES=()
INSTALL_MAX_RETRIES=2

install_global_package() {
    local package_name="$1"
    npm install -g "$package_name"
}

upgrade_global_package_to_latest() {
    local package_name="$1"
    npm install -g "${package_name}@latest"
}

parse_outdated_package_rows() {
    local json_path="$1"
    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        data.keys.sort.each do |name|
          row = data[name] || {}
          puts [name, row["current"], row["wanted"], row["latest"]].join("|")
        end
    ' "$json_path"
}
```

- [ ] **Step 4: Add batch install and update menu flows**

```bash
run_single_install_flow() {
    local package_name=""
    printf "请输入包名: "
    read -r package_name || return 0
    [ -n "$package_name" ] || return 0
    install_global_package "$package_name"
}

run_batch_install_flow() {
    local package_name=""
    for package_name in "${INSTALLABLE_GLOBAL_PACKAGES[@]}"; do
        install_global_package "$package_name" || true
    done
}

run_update_scan_flow() {
    npm outdated -g --depth=0 --json 2>/dev/null || true
}
```

- [ ] **Step 5: Run tests and commit**

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: PASS, including outdated fixture parsing

```bash
git add scripts/node/npm-global-manager.sh scripts/node/tests/npm-global-manager-test.sh scripts/node/tests/fixtures/npm-outdated-sample.json
git commit -m "feat: add install and upgrade flows"
```

### Task 6: Implement uninstall scan, environment actions, and cleanup basics

**Files:**
- Modify: `scripts/node/npm-global-manager.sh`
- Modify: `scripts/node/tests/npm-global-manager-test.sh`

- [ ] **Step 1: Write failing tests for protected package logic**

```bash
test_protected_package_detection() {
    local output=""
    output="$(
        bash -lc "
            set -euo pipefail
            source '$SCRIPT_PATH'
            is_protected_global_package npm && echo yes || echo no
        "
    )"

    [ "$output" = "yes" ]
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: FAIL because `is_protected_global_package` is undefined

- [ ] **Step 3: Implement protected package, uninstall, and cleanup helpers**

```bash
PROTECTED_GLOBAL_PACKAGES=("npm" "corepack")

is_protected_global_package() {
    local package_name="$1"
    local item=""
    for item in "${PROTECTED_GLOBAL_PACKAGES[@]}"; do
        [ "$item" = "$package_name" ] && return 0
    done
    return 1
}

uninstall_global_package() {
    local package_name="$1"
    if is_protected_global_package "$package_name"; then
        return 2
    fi
    npm uninstall -g "$package_name"
}

get_npm_cache_path() {
    npm config get cache 2>/dev/null
}
```

- [ ] **Step 4: Implement environment actions for nvm and Node versions**

```bash
install_nvm_official() {
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh | bash
}

install_node_lts() {
    load_nvm_into_current_shell || return 1
    nvm install --lts && nvm use --lts
}

switch_node_version() {
    local version="$1"
    load_nvm_into_current_shell || return 1
    nvm use "$version"
}
```

- [ ] **Step 5: Run tests, smoke-test the script, and commit**

Run: `bash scripts/node/tests/npm-global-manager-test.sh`
Expected: PASS, including the protected-package assertion

Run: `bash -n scripts/node/npm-global-manager.sh`
Expected: no output

```bash
git add scripts/node/npm-global-manager.sh scripts/node/tests/npm-global-manager-test.sh
git commit -m "feat: add uninstall safeguards and environment actions"
```

## Self-Review

Spec coverage check:

- Startup summary: covered by Tasks 2 and 3
- Main menu and environment overview: covered by Task 3
- Source management: covered by Task 4
- Single and batch install: covered by Task 5
- Upgrade scan and execution: covered by Task 5
- Uninstall safeguards and execution: covered by Task 6
- `nvm` and Node environment actions: covered by Task 6
- Cleanup basics: covered by Task 6

Placeholder scan:

- No `TODO`, `TBD`, or “implement later” placeholders remain in the task steps
- Deferred features are explicitly called out in the spec and are not implied as part of this plan

Type and naming consistency:

- Script path stays `scripts/node/npm-global-manager.sh`
- Test path stays `scripts/node/tests/npm-global-manager-test.sh`
- Global package inventory and outdated parsing helpers use consistent names

## Execution Handoff

Plan complete and saved to `scripts/node/docs/plans/2026-06-11-node-npm-global-manager.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
