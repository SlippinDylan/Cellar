# Changelog

All notable user-facing changes to Cellar are documented in this file.

## [Unreleased]

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
