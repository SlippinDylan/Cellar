# Changelog

All notable user-facing changes to Cellar are documented in this file.

## [Unreleased]

## [0.1.0-beta.2] - 2026-11-27

### Improved

- Compacted confirmation, completion, and progress sheets across Terminal, Tap, npm, Node, Home setup, and Maintenance views so short content hugs tightly without excess blank boxes.
- Simplified the Oh My Zsh and Zsh tidy confirmation sheets by folding target paths directly into the description when no file list is needed.
- Redesigned all Batch Install stages (checking indicator in footer, compact two-column review grid, live per-item spinners during execution, and unified result tiles).
- Removed the duplicate spinner inside the Formula and npm uninstall modal.

### Fixed

- Retried transient GitHub API errors, shared ETag caching when verifying the official Homebrew installer, and reported API rate limits explicitly.
- Fixed installing uninstalled global npm packages (such as `@antfu/ni`) on npm 11 when `npm ls -g <pkg> --depth=0 --json` omits the `dependencies` object.
- Preserved Discover search query, scope, and results across sidebar switches, fixed Homebrew cards remaining stuck on Uninstall after removal, and tinted uninstall card spinners red.
- Prevented the Batch Install package editor from clipping the last line horizontally after deleting rows.

## [0.1.0-beta.1] - 2026-11-27

### Added

- Native macOS 26+ Apple Silicon app with task-oriented Home, Library, Discover, Environment, Maintenance, Settings, and About navigation.
- Unified management for Homebrew Formulae and Casks, global npm packages bound to explicit Node environments, nvm-managed Node.js runtimes, Homebrew Taps, npm registries, and Oh My Zsh themes and plugins.
- First-run onboarding guide with animated intro and completion celebration, four-step environment check, auto-closing Full Disk Access permission guidance, Command Line Tools polling, silent verified `Homebrew.pkg` installation, automatic Terminal PATH setup (`~/.zprofile`), and one-click Node.js installation via Homebrew.
- App Store-style horizontal catalog cards with inline pending-update grouping, trailing circular progress indicators, sequential install/update queueing on Discover and Library cards, and global Discover search prioritizing the active tab while caching other scopes in the background.
- Enhanced Homebrew Cask uninstall with ownership-verified related-data cleanup, bounded confirmation plans, and optional one-shot macOS administrator authorization.
- Unified Maintenance grid with Homebrew diagnostics, npm cache verification, batch installation, bounded cleanup modals, and native macOS-style section footers across settings and environment forms.
- Configurable local file logging, session diagnostics redaction, Sparkle signed updates, drag-to-install DMG packaging, and full eight-language interface localization following system preferences by default.

### Improved

- Unified uninstall, terminal, tap, npm registry, Node, and update-all sheets so confirmation, progress, and completion stay within a single modal dialog constrained to the parent window width.
- Simplified the npm Registry settings layout with localized Chinese/English section headings and merged scope actions, and refined the uninstall sheet footer layout.
- Unified onboarding setup cards with trailing install actions, active spinners, right-aligned completion checkmarks, and inline progress bars.

### Fixed

- Fixed Library refresh timing so pending updates reload after a manual refresh, treated `brew outdated` as authoritative for updates, and displayed actual installed `.app` versions for auto-updating Casks.
- Locked onboarding navigation and window/app quit while installation or checks are running (with a single-button "Got It" alert), prevented Homebrew status from flashing "Not Installed" after silent installation, and cleared stale onboarding banners.
- Hardened app termination, read-only subprocess cancellation, clean-machine startup without Node/npm or Command Line Tools, and sheet confirmation guards.
- Removed the redundant global top task feedback banner, inline result cards, and Setup Guide entries from Settings and the menu bar.
