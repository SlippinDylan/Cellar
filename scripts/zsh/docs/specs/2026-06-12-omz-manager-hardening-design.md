# OMZ Manager Hardening Design

Date: 2026-06-12
Status: Draft approved for implementation planning
Scope: Harden `scripts/zsh/omz-manager.sh` so it becomes a sustainable, long-lived Zsh manager with explicit ownership boundaries, safe file mutation behavior, reproducible installation behavior, and test-backed failure semantics.

## Goals

- Eliminate every confirmed review finding in `scripts/zsh/omz-manager.sh`, including high, medium, and low severity items.
- Tighten ownership boundaries so the manager only mutates configuration it is explicitly allowed to own.
- Prevent silent data loss, path escape, and partially successful operations that look successful.
- Keep the runtime delivery as one executable script while improving internal structure enough to support long-term maintenance.
- Expand automated shell coverage so every repaired behavior has regression protection.

## Non-Goals

- Rewrite the manager into another language.
- Introduce speculative features unrelated to the reviewed issues.
- Add a second runtime entrypoint.
- Expand support beyond the current macOS + Bash 3.2 compatibility target.

## Review Backlog

The merged review backlog contains 21 issues:

- High: H1-H5
- Medium: M1-M9
- Low: L1-L7

These issues cluster into four architectural problems:

1. The script edits too much of the user's `~/.zshrc`.
2. The script trusts path-like input too easily.
3. The script does not expose a strict success/failure contract.
4. The script has weak state modeling for plugins and status display.

The fix strategy should address those four roots instead of patching symptoms one by one in place.

## Ownership Contract For `~/.zshrc`

This is the most important boundary in the entire script.

New contract:

- The manager may fully own and rewrite only its own managed blocks.
- The manager may read the rest of `~/.zshrc` for discovery, but it may not broadly comment out or rewrite arbitrary user configuration outside its managed blocks.
- The manager must fail closed if a managed block is structurally corrupted.
- The manager must not silently normalize or delete unrelated top-level configuration.

Implications:

- `comment_active_config_lines()` in its current form is no longer acceptable.
- Plugin, theme, and `ZSH_COMPDUMP` management must move to explicit managed blocks or explicit owned lines.
- If the user's file already contains conflicting unmanaged configuration, the manager should report it clearly and either:
  - leave it untouched while writing its own managed block, or
  - require user confirmation before migration into a managed block.

For this codebase, the lower-blast-radius choice is:

- stop auto-commenting user lines outside managed blocks
- manage plugin, theme, and compdump settings only through manager-owned blocks
- surface conflicts as warnings instead of mutating user code

## Managed Block Rules

Managed blocks remain the correct primitive, but they need a stronger contract.

Rules:

- every block has a start marker and an end marker
- block removal must fail closed if either marker structure is invalid
- block insertion must avoid accumulating empty spacer lines
- plugin, theme, and compdump ownership should each have dedicated marker pairs
- block readers and writers should be centralized through one small mutation API instead of ad hoc `awk` snippets scattered through the file

This change is not a large refactor for its own sake. It reduces the script to one mutation model instead of three partially different ones.

## Plugin Model Contract

The current script conflates installation and enablement.

New contract:

- "installed" means the plugin directory exists on disk
- "enabled" means the plugin name appears in the manager-owned plugins block
- installation does not imply enablement
- enabling does not silently occur just because a directory exists

To keep the runtime simple, a separate state file is not required.

Recommended approach:

- the manager-owned plugins block is the source of truth for enabled plugins
- disk inspection remains a discovery mechanism for installed plugins
- UI labels must distinguish `[已安装]`, `[已启用]`, and `[已安装未启用]` when appropriate

This preserves one-script delivery and avoids inventing new persistence unless necessary.

## Path Safety Contract

User-provided plugin URLs must not be trusted as filesystem-safe names.

Rules:

- normalize trailing `/`
- derive a candidate plugin name
- validate the candidate against an allowlist pattern
- reject empty names, `.` / `..`, slashes, whitespace-only names, and shell-hostile directory names
- refuse cleanup if a computed destination is not within the expected plugin root

This is a hard boundary. The manager should never run `rm -rf` on a path that has not first been proven to live under its own plugin directory.

## Failure Contract

The script currently uses `|| true` in places where the caller needs real status.

New contract:

- mutation helpers return success only when the intended operation completed
- menu flows may continue after errors, but only after explicitly reporting the failure
- non-fatal continuation should be written as `if ! helper; then warn; fi`, not as `helper || true`
- validation helpers should distinguish:
  - mutation succeeded
  - mutation skipped
  - mutation failed

The top-level UX can remain interactive without lying about state.

## Parser Contract

Configuration readers must tolerate the formats that real users already have.

Required coverage:

- single-line and multi-line `plugins=(...)`
- `ZSH_THEME="name"` and `ZSH_THEME='name'`
- `export ZSH_COMPDUMP="$HOME/.zsh/zcompdump"` and the expanded absolute-path equivalent

For discovery code, correctness matters more than short awk one-liners. Slightly longer parsing logic is acceptable if it is deterministic and tested.

## Reproducibility Contract

Remote installer behavior should be pinned.

Rules:

- `OMZ_INSTALL_URL` must target a fixed commit or vendored script
- the pinned revision should be documented in comments or docs
- changing the pinned revision becomes an intentional maintenance action

## Testing Strategy

The hardening work should add and keep a dedicated test harness at `scripts/zsh/tests/omz-manager-test.sh`.

Coverage must include:

- corrupted managed block fails closed without rewriting the file
- multi-line plugin parsing preserves existing enabled plugins
- user-owned conditional plugin/theme config remains untouched
- plugin URL sanitization rejects unsafe names
- cleanup refuses to delete paths outside the managed plugin root
- install vs enable semantics remain distinct
- `ZSH_COMPDUMP` detection accepts both `$HOME` and expanded absolute path forms
- tidy flow preserves current-operation backups according to the final contract
- theme parsing supports single and double quotes
- status rendering reflects current on-disk and enabled state
- no silent success on failed clone, sync, theme switch, or tidy operations

## File Structure

The final implementation should still primarily modify one runtime file:

- Modify: `scripts/zsh/omz-manager.sh`
- Modify: `scripts/zsh/tests/omz-manager-test.sh`
- Add docs only as needed under `scripts/zsh/docs/`

Inside `omz-manager.sh`, the code should be conceptually regrouped into:

- shared shell helpers
- managed block readers/writers
- zshrc discovery/parsing helpers
- plugin lifecycle helpers
- theme helpers
- tidy helpers
- menu flows

This is an internal organization goal, not a mandate to split the runtime into multiple files.

## Success Criteria

The hardening work is complete only when all of the following are true:

- every confirmed review finding has either been fixed or deliberately rejected with a documented technical reason
- `~/.zshrc` mutation is fail-closed and manager-owned
- path-derived deletion cannot escape the plugin root
- plugin installation and enablement are distinct in behavior and UI
- remote installer behavior is pinned
- shell tests cover the repaired behaviors and pass cleanly
- `bash -n` passes for the runtime script and test script
