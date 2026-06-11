# Homebrew Interactive Manager Design

Date: 2026-06-10
Status: Draft approved for spec review
Scope: Redesign the current Homebrew install/uninstall scripts into a single interactive macOS script with install, uninstall, update, tap management, and environment bootstrap/cleanup flows.

## Goals

- Provide one entry script for Homebrew app management in `macos/`.
- Keep install, uninstall, update, tap management, and environment bootstrap/cleanup as clearly separated interactive actions.
- Support deep uninstall for both `formula` and `cask` with clear, reviewable boundaries.
- Preserve interactive control with explicit menus and step-by-step navigation.
- Keep the final executable delivery as a single script in `macos/`.

## Non-Goals

- Reproduce a third-party GUI uninstaller feature-for-feature.
- Guarantee perfect historical reconstruction of why every dependency was originally installed.
- Introduce a multi-file runtime package as the final delivery artifact.
- Hide destructive actions behind implicit automation.

## Current Problems

The current scripts have useful intent but unclear boundaries:

- `brew-install-app.sh` is a fixed cask installer with retries and parallelism.
- `brew-uninstall.sh` mixes single-target uninstall, global Homebrew cleanup, permission repair, broad file deletion, and heuristic residue scanning in one path.
- The uninstall script currently treats "uninstall a target" and "repair/clean the whole Homebrew environment" as the same operation.

This redesign separates those concerns while keeping deep uninstall as a first-class goal.

## Final Product Shape

The final executable remains a single script in `macos/`. During redesign work, process artifacts live under `macos/brew-tool-redesign/`.

The script will expose a persistent interactive menu:

1. 安装项目
2. 卸载项目
3. 更新与升级
4. Tap 管理
5. 环境与依赖
q. 退出

Rules:

- Only the top-level menu can exit the script.
- Every submenu supports returning to the previous level.
- Completing install, uninstall, update, tap management, or environment actions returns to a menu instead of exiting.

## Top-Level Architecture

The script should be organized around small shell functions with clear responsibilities:

- menu rendering and input validation
- Homebrew inventory loading
- install flow
- formula uninstall flow
- cask uninstall flow
- deep scan and candidate aggregation
- cleanup flow
- summary reporting

The design favors deterministic Homebrew data first, then controlled heuristic scanning second.

## Install Flow

The install path reuses the current install behavior:

- fixed cask package list
- parallel installation
- retry handling
- per-package logging
- final success/failure summary

The redesign may move the install logic into functions, but its user-visible behavior should remain aligned with the current script.

## Uninstall Flow

The uninstall path is a second-level menu:

1. Formula
2. Cask
0. Back

After type selection:

- query all installed items of that type via Homebrew
- print the full numbered list with no pagination
- when terminal width permits, render long lists in multiple columns using column-major ordering from left to right, top to bottom
- shared list rendering should compute one uniform column width from the longest visible item and cap adaptive layout at six columns
- allow the user to select one item by numeric index
- resolve the target identity
- run a scan phase
- print the full candidate cleanup list
- show candidate count and estimated disk space to be reclaimed based on actual disk usage
- ask one confirmation question for "uninstall and clean all found items"
- execute
- print a structured summary
- return to the previous menu

## Formula Uninstall Strategy

Formula uninstall is Homebrew-centric, with controlled cleanup around it.

Execution model:

1. Stop matching `brew services` service if it exists.
2. Inspect the selected formula's dependency information.
3. Compute candidate dependencies that become orphaned after removal using the current dependency graph, not guessed historical install state.
4. Present:
   - target formula
   - direct dependencies
   - candidate orphan dependencies
   - related Homebrew-managed paths if applicable
5. On confirmation:
   - uninstall the target formula
   - optionally uninstall confirmed orphan candidates if they are still installed
   - run `brew autoremove`
6. Print a summary of:
   - removed formula
   - removed dependencies
   - skipped items
   - cleanup actions performed

Design boundary:

- The script must not pretend it can perfectly reconstruct the original install-time causal chain.
- Dependency cleanup is based on the current Homebrew graph and post-removal orphan status.

## Cask Uninstall Strategy

Cask uninstall is a layered deep-clean flow:

1. Resolve cask metadata from Homebrew.
2. Extract the main app identity:
   - cask token
   - app bundle name
   - bundle identifier if resolvable
   - zap-defined paths
3. Scan controlled macOS locations for related residue.
4. Merge and de-duplicate all candidate paths.
5. Print the full candidate list.
   - If the list is long and terminal width allows it, render it in multiple columns using column-major ordering.
   - Show the candidate count and estimated reclaimable disk usage before the confirmation step.
   - Exception: cask cleanup candidate paths remain single-column so every path is easy to audit line by line.
6. Ask for one confirmation to uninstall and clean all candidates.
7. Execute:
   - stop relevant `brew services` entries if present
   - remove candidate files
   - run `brew uninstall --zap`
   - remove leftover Homebrew registration paths such as stale Caskroom entries when still present
8. Print a summary of:
   - removed files
   - Homebrew uninstall result
   - skipped or permission-blocked paths

This flow is intentionally "deeper than Homebrew alone" while still being bounded and inspectable.

## Deep Scan Inputs

The scan phase may combine these evidence sources:

- Homebrew cask metadata
- zap paths declared by the cask
- app bundle name
- bundle identifier
- receipt identifiers when available
- Homebrew-managed install locations
- controlled user and system library paths

For `cask`, candidate locations may include:

- `/Applications`
- `~/Library/Application Support`
- `~/Library/Caches`
- `~/Library/Containers`
- `~/Library/Preferences`
- `~/Library/Logs`
- `~/Library/LaunchAgents`
- `~/Library/Group Containers`
- `~/Library/Saved Application State`
- `~/Library/WebKit`
- `/private/var/db/receipts`
- other tightly scoped macOS app residue locations justified by app identity

For `formula`, scanning stays much narrower and should remain centered on Homebrew-managed data, service state, and graph-based dependency cleanup.

## Environment Flow

Environment and bootstrap actions live under the dedicated `环境与依赖` submenu:

1. 清理 Homebrew 环境
2. 安装 Xcode Command Line Tools
3. 安装 Homebrew

Bootstrap rules:

- `安装 Xcode Command Line Tools` first checks whether CLT is already installed.
- `安装 Homebrew` first checks whether Homebrew is already installed.
- If CLT is missing when Homebrew install is requested, the script prompts to install CLT first, then asks again before proceeding with Homebrew installation.

## Cleanup Flow

Homebrew cleanup is a dedicated environment action, not a side effect of uninstall.

It will include:

- `brew cleanup --prune=all`
- standard `brew cleanup`
- `brew autoremove`
- cleanup of Homebrew cache directories
- cleanup of Homebrew-related log or temporary files within clearly defined Homebrew scope
- installation count summary for formula and cask

`brew update` is intentionally handled by the separate update action, not folded into cleanup.

It will not silently include high-blast-radius repair actions such as recursive ownership rewriting of the full Homebrew prefix.

## Permission and Safety Model

The script is intended for local interactive use on macOS and may require elevated privileges for some cleanup targets.

Safety rules:

- destructive actions happen only after the full candidate list is shown
- cleanup is scoped by strong identity evidence, not broad substring deletion across the entire filesystem
- permission failures are reported explicitly in the summary
- permission repair is not part of the default uninstall or cleanup flow

If permission problems are detected, the script should report them clearly and ask before any elevated deletion path.

## Summary Output

Each completed action should print a concise summary block including:

- selected mode
- selected target
- found candidate count
- estimated reclaimable disk usage from the scan phase
- removed count
- skipped count
- Homebrew command results
- follow-up notes if some items could not be removed

## Update and Tap Management

The script also exposes dedicated operational menus outside uninstall:

- `更新与升级`
  - `更新 Homebrew`
  - `更新已安装项目`
- `Tap 管理`
  - `添加 Tap`
  - `删除 Tap`

Tap removal rules:

- If a tap has no associated installed formula or cask, it can be removed directly after confirmation.
- If a tap still owns installed items, the script lists them first and requires the user to handle those items before untapping.
- Cask associations may be annotated when only Homebrew registration or stale Caskroom state remains, so the user can still clean the residual Homebrew state intentionally.

## List Rendering Rules

- Adaptive multi-column rendering applies to installed formula lists, installed cask lists, and formula scan sublists such as dependencies and orphan candidates.
- Cask cleanup candidate paths do not use multi-column rendering.
- Column count is recomputed on each render from current terminal width.
- Column width is uniform within a rendered block and is derived from the longest visible item in that block.
- Adaptive list rendering is capped at six columns.

## Implementation Constraints

- Final runtime artifact should remain a single shell script in `macos/`.
- Function and variable naming should follow repository conventions.
- The redesign should minimize user-visible behavioral surprises.
- Process artifacts may exist in this working directory during implementation, but repository-facing delivery should stay aligned with the repo rule that `macos/` holds directly executable single-file scripts.

## Open Design Decisions Resolved

- Final route: layered deep uninstall, not pure Homebrew and not unrestricted fuzzy deletion.
- Top-level menu includes install, uninstall, and cleanup.
- Exit is only allowed at the top-level menu.
- Cask uninstall uses `--zap` and an additional controlled residue scan.
- Formula uninstall uses current dependency graph analysis rather than historical guesswork.
- Top-level cleanup includes Homebrew environment maintenance tasks but excludes silent recursive permission repair.

## Validation Plan

Implementation should be validated against at least these scenarios:

- install flow still installs the current fixed cask set and reports failures
- uninstall formula with no extra orphaned dependencies
- uninstall formula with orphan candidates
- uninstall cask with zap entries and app residue
- uninstall cask where the app bundle is already missing
- cleanup flow on a healthy Homebrew installation
- invalid menu input at every level
- repeated return-to-parent navigation without accidental exit

## Risks

- Heuristic residue matching can over-match if not constrained tightly enough.
- Some files may require elevated privileges and need explicit handling.
- Not every cask provides rich zap metadata.
- Formula dependency cleanup cannot prove original install history.

These are acceptable as long as the script reports what it found, scopes deletions conservatively, and never hides uncertainty.
