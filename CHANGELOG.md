# Changelog

All notable user-facing changes to Cellar are documented in this file.

## [Unreleased]

## [0.1.2] - 2026-11-26

### Added

- One-click Node.js installation via Homebrew in the onboarding guide, Home, and Environment views.
- Automatic background polling and cancellation detection for Command Line Tools installation in the onboarding guide.

### Improved

- Unified onboarding setup cards with trailing install actions, active spinners, right-aligned completion checkmarks, and inline progress bars for Homebrew, Node.js, and Oh My Zsh.
- Constrained confirmation sheets across the app so dialogs never exceed their parent window width.

### Fixed

- Cleared onboarding setup feedback so entering the main window no longer leaves setup banners pinned across pages.

## [0.1.1] - 2026-11-26

### Added

- First-run onboarding guide with animated intro and completion celebration, four-step environment check, and auto-closing Full Disk Access permission guidance.
- In-app Homebrew installation progress indicator and automatic Terminal PATH setup (`~/.zprofile`) upon Homebrew installation.

### Fixed

- Fixed official `Homebrew.pkg` signature verification to recognize Apple Developer ID Installer certificate chains and run silent system-authorized installation without external installer windows.
- Removed misleading uninstalled status circles and focus-switch spinner flashes in the onboarding guide, and enlarged setup action buttons.

## [0.1.0] - 2026-11-25

### Added

- Native macOS 26+ Apple Silicon app with task-oriented Home, Library, Discover, Environment, Maintenance, Settings, and About navigation.
- Unified management for Homebrew Formulae and Casks, global npm packages bound to explicit Node environments, nvm-managed Node.js runtimes, Homebrew Taps, npm registries, and Oh My Zsh themes and plugins.
- Guided Command Line Tools and verified official Homebrew installer setup on Home, plus local Cask `.app` icon resolution with CaskFlow fallback.
- Enhanced Homebrew Cask uninstall with ownership-verified related-data cleanup, bounded confirmation plans, and optional one-shot macOS administrator authorization.
- Unified Maintenance grid with Homebrew diagnostics, npm cache verification, batch installation, and bounded cleanup modals.
- Configurable local file logging, session diagnostics redaction, Sparkle signed updates, drag-to-install DMG packaging, and full eight-language interface localization following system preferences by default.

### Improved

- App Store-style horizontal catalog cards with inline pending-update grouping, linked titles, and unified search and scope controls.
- Receipt-styled Environment Information sheet in Settings displaying detected versions, paths, and controlled `PATH`.

### Fixed

- Hardened app termination, read-only subprocess cancellation, clean-machine startup without Node/npm or Command Line Tools, and sheet confirmation guards.
