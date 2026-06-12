# OMZ Manager Zsh Tidy Design

Date: 2026-06-12
Status: Draft approved for spec review
Scope: Extend `scripts/zsh/omz-manager.sh` so one interactive script can both manage Oh My Zsh and tidy scattered Zsh-related files in the user's home directory.

## Goals

- Keep `scripts/zsh/omz-manager.sh` as the single entry script for Zsh setup and maintenance.
- Add a fourth top-level menu action for tidying Zsh-related files under the home directory.
- Reduce clutter in `~` by moving Zsh cache and backup artifacts into `~/.zsh/` and `~/.zsh/backups/`.
- Preserve `.zprofile` in `~` while still cleaning up backup artifacts derived from it.
- Reuse the existing script's interaction, status output, and `.zshrc` validation flow.

## Non-Goals

- Move or rewrite `.zprofile` itself.
- Convert the runtime delivery from one script into multiple scripts.
- Add generic home-directory cleanup beyond Zsh-related files.
- Automatically manage shells other than Zsh.

## Current State

`scripts/zsh/omz-manager.sh` already provides a three-item interactive menu:

1. Install Oh My Zsh
2. Manage plugins
3. Switch theme

The script already owns:

- `~/.zshrc` existence checks
- `~/.zshrc` backup creation via `.zshrc.bak.<timestamp>.<pid>`
- managed block writes for plugin and theme configuration
- post-write `zsh -fc "source ~/.zshrc"` validation

The standalone tidy script provided by the user has the right intent, but it uses a separate error model, separate output style, and partial backup filename coverage that does not match the current manager script.

## Final Product Shape

The final script remains `scripts/zsh/omz-manager.sh`.

Its top-level menu becomes:

1. 安装 Oh My Zsh
2. 管理插件
3. 切换主题
4. 整理 Zsh 文件
q. 退出

The new fourth action runs a bounded Zsh tidy flow and returns to the main menu when complete.

## Tidy Flow

The new tidy action is idempotent and safe to run repeatedly.

It performs these actions in order:

1. Ensure `~/.zsh` exists.
2. Ensure `~/.zsh/backups` exists.
3. Move `~/.zcompdump*` regular files into `~/.zsh/`.
4. Move Zsh RC backup files into `~/.zsh/backups/`.
5. Move `~/.zprofile.bak` into `~/.zsh/backups/` when present.
6. Ensure `~/.zshrc` contains the canonical completion dump configuration:
   - `export ZSH_COMPDUMP="$HOME/.zsh/zcompdump"`
7. Reuse the existing `.zshrc` validation path so the user gets the same post-change guidance as other manager actions.

## Cleanup Scope

The tidy action should only move files that are clearly Zsh maintenance artifacts.

Included:

- `~/.zcompdump*`
- `~/.zshrc.backup-*`
- `~/.zshrc.backup.*`
- `~/.zshrc.bak.*`
- `~/.zprofile.bak`

Excluded:

- `~/.zprofile`
- `~/.zshrc`
- arbitrary dotfiles
- directories unless they are the managed targets `~/.zsh` and `~/.zsh/backups`

## ZSH_COMPDUMP Persistence Strategy

The tidy action should not append raw duplicate lines on every run.

Behavior rules:

- If `~/.zshrc` does not exist, create it.
- If the exact canonical `export ZSH_COMPDUMP="$HOME/.zsh/zcompdump"` line already exists, leave it unchanged.
- If another active `export ZSH_COMPDUMP=...` line exists, replace or normalize it to the canonical path instead of only warning.
- If no active `ZSH_COMPDUMP` export exists, append a small managed block or clearly labeled line in the script's established style.

The result should be deterministic after repeated runs.

## Integration Rules

The tidy feature should follow the current script architecture instead of embedding the standalone script verbatim.

Requirements:

- Do not use global `set -e`.
- Reuse existing `print_status_message`, `print_message`, `pause_with_back_option`, and `reload_zshrc` patterns.
- Keep failures local to the tidy action so the whole manager does not abort unexpectedly.
- Report moved file counts and whether the `.zshrc` completion dump line was added, updated, or already correct.

## Error Handling

The tidy action should:

- continue cleanly when optional files are absent
- fail with a clear status message when required target directories cannot be created
- avoid claiming success when a move or write fails
- still allow the user to return to the main menu after an error message

## Testing

The implementation should add or extend shell tests around the tidy behavior using temporary home directories.

Coverage should include:

- menu exposes the new fourth option
- `~/.zcompdump*` files move into `~/.zsh/`
- `.zshrc.bak.*` and legacy `.zshrc.backup-*` artifacts move into `~/.zsh/backups/`
- `.zprofile.bak` moves but `.zprofile` stays in place
- missing `~/.zshrc` is created
- missing `ZSH_COMPDUMP` line is added
- incorrect active `ZSH_COMPDUMP` line is normalized
- repeated tidy runs are idempotent
- tidy completion triggers the existing validation flow without requiring an interactive shell
