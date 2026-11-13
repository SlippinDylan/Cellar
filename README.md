<div align="center">
  <img src="docs/images/readme/app-icon.png" width="160" height="160" alt="Cellar app icon">
  <h1>Cellar</h1>
  <p>Manage your Mac's development tools in one native app.</p>
  <p>
    <strong>English</strong> ·
    <a href="docs/README.zh-CN.md">简体中文</a> ·
    <a href="docs/README.zh-TW.md">繁體中文</a> ·
    <a href="docs/README.ja.md">日本語</a> ·
    <a href="docs/README.ko.md">한국어</a> ·
    <a href="docs/README.de.md">Deutsch</a> ·
    <a href="docs/README.fr.md">Français</a> ·
    <a href="docs/README.es.md">Español</a>
  </p>
</div>

Cellar brings Homebrew software, npm global packages, Node.js versions, and terminal configuration into one macOS app. See what's installed, find what you need, update your tools, and review what will be removed before uninstalling.

> [!NOTE]
> Cellar 1.0 is not publicly released. There is no downloadable installer or Homebrew Cask yet. You can build from source; real environment and UI acceptance checks are still pending.

## What you can do

| Task | In Cellar |
|---|---|
| Check your environment | See Homebrew, Node.js, npm, nvm, and terminal status on Home. |
| Manage installed software | Browse, search, and filter Homebrew Formulae, Casks, and npm global packages in Library. Update individual items or a filtered batch, and uninstall individual items. |
| Find new tools | Search Homebrew and npm in Discover, then install individual items or a batch of the same package type. |
| Configure your environment | Manage Node.js versions with nvm, a selected project's `.nvmrc`, Homebrew taps, npm registries, and Oh My Zsh themes and plugins. |
| Check and clean up | Run Homebrew diagnostics and npm cache verification, then review supported cache, unused Node version, and old Manager log cleanup tasks. |

Task progress and recent results stay visible as you move between pages, including individual results when a batch only partly succeeds.

The interface supports **English, Simplified Chinese, Traditional Chinese, Japanese, Korean, German, French, and Spanish**. The default is **Follow System**. You can choose a language under Settings > General; changing it restarts Cellar.

## Requirements and availability

- **macOS 26 or later**, on an **Apple Silicon Mac** (`arm64`).
- **Xcode 26 or later** to build from source.
- Homebrew, Node.js, npm, and nvm are tools Cellar manages; they are not bundled with the app.

When Command Line Tools or Homebrew is missing, Cellar can open the system installation flow. Homebrew's official installer package is verified before opening. For nvm, Cellar provides installation guidance.

Sparkle is configured for app updates through the shared [Homebrew tap](https://github.com/SlippinDylan/homebrew-tap). The signed update feed and Cask will be created by the first matching release. Debug and ordinary local builds have app updates disabled.

## Build from source

```bash
git clone https://github.com/SlippinDylan/Cellar.git
cd Cellar
open Cellar.xcodeproj
```

In Xcode, select the **Cellar** scheme, **My Mac**, and the **Debug** configuration, then press **⌘R**. Debug uses local ad-hoc signing (Sign to Run Locally), so you do not need to sign in to an Apple developer account or install a signing certificate.

For a command-line build:

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Debug
```

The app is built at `build/DerivedData-Debug/Build/Products/Debug/Cellar.app`. See the [development guide](docs/development.md) for tests, signing, and release builds.

## Before changing your environment

- npm global packages belong to a specific Node.js installation. Searches and operations use the selected Node environment; Cellar does not manage project-local npm dependencies.
- Switching the Node version used by Cellar affects only the current Cellar session, not terminals already open. Saving a project's `.nvmrc` declares the required version; it does not automatically install Node or switch terminal sessions.
- Single-package installs and updates from Library and Discover cards start directly. Installing terminal components, batch operations, uninstalls, cleanup, and configuration changes ask you to confirm their scope. Running tasks cannot be stopped manually, and Cellar prevents quitting while tasks are active.
- Homebrew Cask uninstalls can also remove confirmed related data whose ownership can be verified. Shared or unverified data stays in place. Formula and npm uninstalls do not include this related-data cleanup. Cellar does not run Homebrew cleanup or automatically remove orphaned dependencies.
- Some residual-file cleanup needs macOS administrator authorization or Full Disk Access. macOS handles passwords; Cellar does not collect them or install a persistent privileged service. Authorization does not guarantee every file can be removed.
- Operations can partly succeed. Cellar reports completed and failed items; it does not promise rollback. It does not modify `.zprofile` or change your login shell.

## Data and network

Cellar has no accounts, telemetry, or backend of its own. Tool queries, searches, installs, plugins, and app updates contact official services or sources you configure. Homebrew and npm queries may also write to their own caches.

Official Homebrew Cask icons come from [CaskFlow](https://github.com/alielsokary/CaskFlow) through `cdn.jsdelivr.net`. The CDN receives the requested Cask identifier and normal connection information. CaskFlow's MIT license is included with the app; software logos remain the property of their respective owners.

| Local data | Location |
|---|---|
| Bundled Manager runtime copies | `~/Library/Application Support/Cellar/Managers/<version>/` |
| Logs | `~/Library/Logs/Cellar/` |
| Downloaded software icons | `~/Library/Caches/com.dylanwang.Cellar/CatalogIcons/` |

Log level and retention are configurable in Settings > General. File logs exclude raw commands and their stdout/stderr. Task results last for the current session.

## Documentation

The detailed project documents are currently in Chinese: [documentation index](docs/README.md), [product requirements](docs/requirements/product-requirements.md), [architecture](docs/architecture/macos-app-architecture.md), [development guide](docs/development.md), and [manual acceptance checklist](docs/manual-smoke-checklist.md).
