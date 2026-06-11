# Homebrew Interactive Manager Implementation Plan

> Status note: this file records the implementation sequence. Early checklist snippets reflect the first-pass menu shape; the current intended behavior is defined by `2026-06-10-homebrew-manager-design.md` and the live regression tests.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single interactive macOS shell script that manages Homebrew install, uninstall, update, tap management, and environment bootstrap/cleanup flows with deep uninstall support and menu-based navigation.

**Architecture:** Add a new single-entry shell script in `macos/` and keep the current install and uninstall scripts untouched during the first implementation pass to minimize blast radius. Structure the new script as focused shell functions for menu handling, inventory loading, install execution, formula uninstall, cask uninstall, residue scanning, update flows, tap management, environment bootstrap/cleanup, and summary reporting, then validate behavior with a local shell-based test harness under the working directory.

**Tech Stack:** Bash, Homebrew CLI, macOS built-in tools (`osascript`, `mdls`, `find`, `plutil`, `pkgutil`), GNU `parallel` when available for the install flow, local shell test harness

---

## Planned File Structure

- Create: `macos/brew-app-manager.sh`
  - Final single-entry interactive script.
- Create: `macos/brew-tool-redesign/tests/brew-app-manager-test.sh`
  - Local shell regression harness used during implementation.
- Create: `macos/brew-tool-redesign/tests/fixtures/brew-info-sample.json`
  - Sample cask metadata fixture for cask parsing tests.
- Modify: `macos/README.md`
  - Document the new script and its intended role.
- Modify: `README.md`
  - Update the repository overview if the new script changes the top-level macOS script inventory.

The first implementation pass intentionally does not delete `macos/brew-install-app.sh` or `macos/brew-uninstall.sh`. The new script ships alongside them until the new flow is verified locally.

### Task 1: Scaffold the interactive script and local test harness

**Files:**
- Create: `macos/brew-app-manager.sh`
- Create: `macos/brew-tool-redesign/tests/brew-app-manager-test.sh`

- [ ] **Step 1: Write the failing test for top-level menu loop and exit behavior**

```bash
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

test_main_menu_labels() {
    local output
    output="$(render_main_menu)"

    assert_equal "1) Install
2) Uninstall
3) Clean Homebrew Environment
0) Exit" "$output" "main menu should expose the four top-level actions"
}

test_should_exit_only_at_top_level() {
    assert_equal "1" "$(should_exit_menu main 0)" "top-level 0 should exit"
    assert_equal "0" "$(should_exit_menu uninstall 0)" "submenu 0 should return, not exit"
}

test_main_menu_labels
test_should_exit_only_at_top_level
echo "PASS"
```

- [ ] **Step 2: Run the test to verify it fails before the script exists**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
bash: .../brew-app-manager.sh: No such file or directory
```

- [ ] **Step 3: Write the minimal interactive script skeleton**

```bash
#!/bin/bash
set -u

render_main_menu() {
    cat <<'EOF'
1) Install
2) Uninstall
3) Clean Homebrew Environment
0) Exit
EOF
}

should_exit_menu() {
    local menu_name="$1"
    local choice="$2"

    if [ "$menu_name" = "main" ] && [ "$choice" = "0" ]; then
        echo "1"
        return 0
    fi

    echo "0"
}

main() {
    while true; do
        render_main_menu
        break
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
```

- [ ] **Step 4: Run the test to verify the skeleton behavior passes**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
PASS
```

- [ ] **Step 5: Commit the scaffold**

```bash
git add macos/brew-app-manager.sh macos/brew-tool-redesign/tests/brew-app-manager-test.sh
git commit -m "feat: scaffold Homebrew interactive manager"
```

### Task 2: Port the install flow into the new top-level menu

**Files:**
- Modify: `macos/brew-app-manager.sh`
- Modify: `macos/brew-tool-redesign/tests/brew-app-manager-test.sh`

- [ ] **Step 1: Write the failing test for install menu dispatch**

```bash
test_dispatch_main_action() {
    assert_equal "install" "$(dispatch_main_choice 1)" "choice 1 should dispatch install"
    assert_equal "uninstall" "$(dispatch_main_choice 2)" "choice 2 should dispatch uninstall"
    assert_equal "cleanup" "$(dispatch_main_choice 3)" "choice 3 should dispatch cleanup"
    assert_equal "back" "$(dispatch_main_choice 9)" "unknown choice should not exit"
}

test_dispatch_main_action
```

- [ ] **Step 2: Run the test to verify dispatch is not implemented yet**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
dispatch_main_choice: command not found
```

- [ ] **Step 3: Move the existing install catalog and install executor into focused functions**

```bash
PARALLEL_JOBS=5
MAX_RETRIES=2

PACKAGES=(
    "1password"
    "airbuddy"
    "aldente"
    "aliwangwang"
    "android-platform-tools"
    "appcleaner"
    "baidunetdisk"
    "bettermouse"
    "bluestacks"
    "cleanmymac-zh"
    "coteditor"
    "dockdoor"
    "downie"
    "feishu"
    "google-chrome"
    "google-chrome@beta"
    "icollections"
    "iina"
    "jetbrains-toolbox"
    "microsoft-edge"
    "monitorcontrol"
    "obsidian"
    "one-switch"
    "pastenow"
    "permute"
    "progressive-downloader"
    "qq"
    "qspace-pro"
    "reqable"
    "spotify"
    "stats"
    "switchhosts"
    "tailscale-app"
    "termius"
    "the-unarchiver"
    "thunder"
    "tower"
    "typora"
    "videofusion"
    "visual-studio-code"
    "warp"
    "wechat"
    "wechatwebdevtools"
    "windows-app"
    "wpsoffice-cn"
    "zed"
)

dispatch_main_choice() {
    local choice="$1"

    case "$choice" in
        1) echo "install" ;;
        2) echo "uninstall" ;;
        3) echo "cleanup" ;;
        *) echo "back" ;;
    esac
}

run_install_flow() {
    echo "Starting install flow"
    echo "Package count: ${#PACKAGES[@]}"
}
```

- [ ] **Step 4: Run the tests and verify dispatch now passes**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
PASS
```

- [ ] **Step 5: Commit the install integration**

```bash
git add macos/brew-app-manager.sh macos/brew-tool-redesign/tests/brew-app-manager-test.sh
git commit -m "feat: port install flow into interactive manager"
```

### Task 3: Build inventory loading, numeric selection, and back-navigation helpers

**Files:**
- Modify: `macos/brew-app-manager.sh`
- Modify: `macos/brew-tool-redesign/tests/brew-app-manager-test.sh`

- [ ] **Step 1: Write the failing tests for item rendering and numeric selection parsing**

```bash
test_render_inventory_lines() {
    local rendered
    rendered="$(render_numbered_list "formula" "wget" "htop" "jq")"

    assert_equal "1) wget
2) htop
3) jq
0) Back" "$rendered" "inventory renderer should print all items and the back option"
}

test_parse_numeric_choice() {
    assert_equal "2" "$(parse_numeric_choice 2 3)" "valid choice should be returned"
    assert_equal "invalid" "$(parse_numeric_choice 4 3)" "out-of-range choice should be rejected"
    assert_equal "back" "$(parse_numeric_choice 0 3)" "zero should return to the parent menu"
}

test_render_inventory_lines
test_parse_numeric_choice
```

- [ ] **Step 2: Run the tests to confirm the inventory helpers are still missing**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
render_numbered_list: command not found
```

- [ ] **Step 3: Implement inventory helpers and Homebrew list loading**

```bash
render_numbered_list() {
    local label="$1"
    shift

    local items=("$@")
    local index=1

    for item in "${items[@]}"; do
        printf "%s) %s\n" "$index" "$item"
        index=$((index + 1))
    done

    printf "0) Back"
}

parse_numeric_choice() {
    local choice="$1"
    local max_index="$2"

    if [ "$choice" = "0" ]; then
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

load_formula_inventory() {
    brew list --formula
}

load_cask_inventory() {
    brew list --cask
}
```

- [ ] **Step 4: Run the tests and verify inventory behavior passes**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
PASS
```

- [ ] **Step 5: Commit the navigation and inventory layer**

```bash
git add macos/brew-app-manager.sh macos/brew-tool-redesign/tests/brew-app-manager-test.sh
git commit -m "feat: add inventory selection helpers"
```

### Task 4: Implement formula uninstall planning and execution

**Files:**
- Modify: `macos/brew-app-manager.sh`
- Modify: `macos/brew-tool-redesign/tests/brew-app-manager-test.sh`

- [ ] **Step 1: Write the failing tests for formula dependency cleanup planning**

```bash
test_collect_formula_plan() {
    mock_brew_dependencies() {
        cat <<'EOF'
openssl@3
readline
EOF
    }

    mock_brew_orphans_after_uninstall() {
        cat <<'EOF'
readline
EOF
    }

    local plan
    plan="$(collect_formula_uninstall_plan "python@3.12")"

    assert_equal "target=python@3.12
dependencies=openssl@3 readline
orphans=readline" "$plan" "formula plan should separate direct dependencies from orphan candidates"
}

test_collect_formula_plan
```

- [ ] **Step 2: Run the tests to verify formula planning is not implemented yet**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
collect_formula_uninstall_plan: command not found
```

- [ ] **Step 3: Implement formula planning, service stop, uninstall, and summary helpers**

```bash
brew_dependencies_for_formula() {
    local formula="$1"
    brew deps --installed "$formula"
}

brew_orphans_after_formula_removal() {
    local formula="$1"
    brew uses --installed --recursive "$formula" >/dev/null 2>&1 || true
    brew autoremove --dry-run 2>/dev/null | sed '1d'
}

collect_formula_uninstall_plan() {
    local formula="$1"
    local dependencies
    local orphans

    dependencies="$(brew_dependencies_for_formula "$formula" | xargs echo | sed 's/^ *//')"
    orphans="$(brew_orphans_after_formula_removal "$formula" | xargs echo | sed 's/^ *//')"

    printf "target=%s\n" "$formula"
    printf "dependencies=%s\n" "$dependencies"
    printf "orphans=%s" "$orphans"
}

stop_formula_service_if_needed() {
    local formula="$1"
    brew services stop "$formula" >/dev/null 2>&1 || true
}

run_formula_uninstall_flow() {
    local formula="$1"

    stop_formula_service_if_needed "$formula"
    brew uninstall "$formula"
    brew autoremove
}
```

- [ ] **Step 4: Run the tests and verify the formula plan now passes**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
PASS
```

- [ ] **Step 5: Commit the formula uninstall layer**

```bash
git add macos/brew-app-manager.sh macos/brew-tool-redesign/tests/brew-app-manager-test.sh
git commit -m "feat: add formula uninstall planning"
```

### Task 5: Implement cask identity resolution, residue scanning, and deep uninstall

**Files:**
- Modify: `macos/brew-app-manager.sh`
- Modify: `macos/brew-tool-redesign/tests/brew-app-manager-test.sh`
- Create: `macos/brew-tool-redesign/tests/fixtures/brew-info-sample.json`
- Extend list rendering to support terminal-width-aware multi-column display.
- Extend cask scan summaries to report candidate count and estimated reclaimable disk usage.
- Keep cask cleanup candidate paths single-column, while installed lists and formula dependency/orphan lists use adaptive multi-column rendering capped at six columns.

- [ ] **Step 1: Write the failing tests for cask metadata parsing and candidate aggregation**

```bash
test_parse_cask_metadata() {
    local fixture_path
    fixture_path="$(cd "$(dirname "$0")" && pwd)/fixtures/brew-info-sample.json"

    local metadata
    metadata="$(parse_cask_metadata_from_json "$fixture_path")"

    assert_equal "token=spotify
app_name=Spotify
zap_paths=$HOME/Library/Application Support/Spotify $HOME/Library/Caches/com.spotify.client" "$metadata" "cask metadata parser should extract token, app name, and zap paths"
}

test_parse_cask_metadata
```

- [ ] **Step 2: Run the tests to verify cask parsing is still missing**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
parse_cask_metadata_from_json: command not found
```

- [ ] **Step 3: Add the fixture and implement cask metadata parsing and scan helpers**

`macos/brew-tool-redesign/tests/fixtures/brew-info-sample.json`

```json
{
  "casks": [
    {
      "token": "spotify",
      "artifacts": [
        { "app": ["Spotify.app"] },
        {
          "zap": [
            {
              "trash": [
                "~/Library/Application Support/Spotify",
                "~/Library/Caches/com.spotify.client"
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

`macos/brew-app-manager.sh`

```bash
parse_cask_metadata_from_json() {
    local json_path="$1"

    ruby -rjson -e '
        data = JSON.parse(File.read(ARGV[0]))
        cask = data.fetch("casks").fetch(0)
        token = cask.fetch("token")
        app_name = ""
        zap_paths = []

        cask.fetch("artifacts", []).each do |artifact|
          app_name = artifact["app"][0].sub(/\.app$/i, "") if artifact["app"] && artifact["app"][0]
          next unless artifact["zap"]

          artifact["zap"].each do |zap_entry|
            next unless zap_entry["trash"]
            zap_entry["trash"].each { |path| zap_paths << path.gsub(/^~/, ENV["HOME"]) }
          end
        end

        puts "token=#{token}"
        puts "app_name=#{app_name}"
        puts "zap_paths=#{zap_paths.join(" ")}"
    ' "$json_path"
}

build_cask_scan_roots() {
    cat <<EOF
/Applications
$HOME/Library/Application Support
$HOME/Library/Caches
$HOME/Library/Containers
$HOME/Library/Preferences
$HOME/Library/Logs
$HOME/Library/LaunchAgents
$HOME/Library/Group Containers
$HOME/Library/Saved Application State
$HOME/Library/WebKit
/private/var/db/receipts
EOF
}
```

- [ ] **Step 4: Run the tests and verify the cask parser now passes**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
PASS
```

- [ ] **Step 5: Commit the cask deep-uninstall foundation**

```bash
git add macos/brew-app-manager.sh macos/brew-tool-redesign/tests/brew-app-manager-test.sh macos/brew-tool-redesign/tests/fixtures/brew-info-sample.json
git commit -m "feat: add cask deep uninstall scanning"
```

### Task 6: Implement top-level cleanup flow, wire the menus together, and update docs

**Files:**
- Modify: `macos/brew-app-manager.sh`
- Modify: `macos/README.md`
- Modify: `README.md`
- Modify: `macos/brew-tool-redesign/tests/brew-app-manager-test.sh`

- [ ] **Step 1: Write the failing tests for cleanup command planning and summary rendering**

```bash
test_cleanup_command_plan() {
    local cleanup_plan
    cleanup_plan="$(render_cleanup_plan)"

    assert_equal "brew cleanup --prune=all
brew cleanup
brew autoremove
brew services cleanup" "$cleanup_plan" "cleanup flow should expose the expected Homebrew maintenance commands"
}

test_cleanup_command_plan
```

- [ ] **Step 2: Run the tests to verify cleanup planning is still missing**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
```

Expected:

```text
render_cleanup_plan: command not found
```

- [ ] **Step 3: Implement the cleanup flow, top-level dispatch loop, and documentation updates**

`macos/brew-app-manager.sh`

```bash
render_cleanup_plan() {
    cat <<'EOF'
brew cleanup --prune=all
brew cleanup
brew autoremove
brew services cleanup
EOF
}

run_cleanup_flow() {
    brew cleanup --prune=all
    brew cleanup
    brew autoremove
    brew services cleanup
}

main() {
    local choice=""
    local action=""

    while true; do
        printf "%s\n" "$(render_main_menu)"
        read -r choice

        if [ "$(should_exit_menu main "$choice")" = "1" ]; then
            break
        fi

        action="$(dispatch_main_choice "$choice")"
        case "$action" in
            install) run_install_flow ;;
            uninstall) run_uninstall_menu ;;
            cleanup) run_cleanup_flow ;;
            back) echo "Invalid choice" ;;
        esac
    done
}
```

`macos/README.md`

```md
- `brew-app-manager.sh`
  - 统一的 Homebrew 交互式管理脚本，支持安装、卸载和 Homebrew 环境清理。
```

`README.md`

```md
- `macos/`
  - macOS 下直接执行的单文件脚本，例如应用安装卸载、Homebrew 交互管理、Shell 环境整理、DNS 测试、照片时间修复。
```

- [ ] **Step 4: Run the regression script and a syntax check**

Run:

```bash
bash macos/brew-tool-redesign/tests/brew-app-manager-test.sh
bash -n macos/brew-app-manager.sh
```

Expected:

```text
PASS
```

and no output from:

```text
bash -n macos/brew-app-manager.sh
```

- [ ] **Step 5: Commit the wired script and docs**

```bash
git add macos/brew-app-manager.sh macos/README.md README.md macos/brew-tool-redesign/tests/brew-app-manager-test.sh
git commit -m "feat: add interactive Homebrew manager"
```

## Manual Verification Checklist

- Run `bash macos/brew-app-manager.sh` and verify the top-level menu loops until `0` is entered.
- Enter `2` for uninstall, then `0`, and verify the script returns to the top-level menu.
- Verify the full formula list renders without pagination.
- Verify the full cask list renders without pagination.
- Select a low-risk formula and inspect the displayed orphan candidates before confirming.
- Select a low-risk cask and inspect the displayed residue candidate list before confirming.
- Run cleanup and verify the final summary includes formula and cask counts.
- Re-enter the script after one completed action and confirm it did not exit automatically.

## Self-Review

- Spec coverage checked: install, uninstall, cleanup, deep cask scan, formula orphan handling, return-to-parent behavior, and docs updates are all mapped to explicit tasks.
- Placeholder scan checked: no `TODO`, `TBD`, or open-ended "handle this later" instructions remain.
- Type and naming consistency checked: all tasks use `brew-app-manager.sh` as the final runtime script and reuse the same helper names across later tasks.
