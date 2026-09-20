# Cellar 开发与验证

本文记录 Cellar 的本地环境、测试、构建、产物检查和安全清理流程。产品行为见[产品需求](requirements/product-requirements.md)，组件和数据流见[总体架构](architecture/macos-app-architecture.md)。

## 环境与工程

- macOS 26 或更高版本，Apple Silicon。
- Xcode 26 或更高版本，使用 macOS 26 SDK。
- Swift 6。
- 工程入口：`Cellar.xcodeproj`。
- 共享 scheme：`Cellar`。
- Targets：`Cellar` 和 `CellarTests`。
- Bundle identifier：`com.dylanwang.Cellar`。
- App Sandbox：关闭。

App 使用固定的 Sparkle 2.10.0 Swift Package。仓库没有 Makefile、SwiftLint 或 SwiftFormat。Homebrew、Node.js 和 npm 是运行时读取或管理的用户工具，不是构建 Cellar 的依赖。

Apple 平台构建和测试优先使用 XcodeBuildMCP。每个会话首次调用前先读取 session defaults，再设置工程、scheme、平台、架构和仓库内 DerivedData 路径。

## 测试隔离

自动测试不能读取或修改用户真实的开发环境：

- 不运行用户安装的 brew、node、npm、nvm 或 Zsh Manager。
- Homebrew Bridge 测试注入假 brew executable，覆盖查询 JSON、搜索文本、计划、精确参数、环境、退出码、部分完成和 post-refresh；测试不得访问网络、Homebrew cache 或真实安装目录。
- Homebrew mutation 测试必须断言未确认时不启动进程，Formula/Cask 卸载禁止自动更新和 autoremove，Cask artifact 不触发 App 文件删除，Tap 有关联安装项时不能执行移除。
- Node Bridge 测试在临时目录创建假 `main.sh`，只验证参数、JSON、错误和部分失败。
- Node mutation 测试必须使用临时 HOME 和假 Manager，断言查询关闭 execute、确认执行才打开单次 write gate、项目写入使用独立 gate，且不访问真实 npm registry、cache、`~/.nvm` 或用户项目。
- Manager 安装测试注入临时 Application Support 根目录。
- 进程测试只执行测试自己创建的临时脚本。
- Hosted tests 通过 `XCTestConfigurationFilePath` 识别测试进程，禁止根视图自动刷新。
- Shell adapter 测试复制 Bundle Manager 到临时目录并注入临时 HOME，只允许修改测试 `.zshrc`、Oh My Zsh fixture 和 adapter runtime；不得访问用户真实 Shell 配置或网络。
- 测试结束后不得留下 `~/Library/Application Support/Cellar/`、npm cache 变更或全局包变更。

需要验证真实环境时，使用[人工验收清单](manual-smoke-checklist.md)，并先向用户说明会读取的工具、网络和目录。真实环境检查不属于普通单元测试。

## 最小验证命令

### 工程与 Scheme

```bash
xcodebuild -project Cellar.xcodeproj -list
```

### 相关单元测试

```bash
xcodebuild test \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Tests \
  -only-testing:CellarTests/<SuiteName> \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

### 完整单元测试

```bash
xcodebuild test \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Tests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

### Debug 构建

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Debug \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

### Release 构建

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData-Release \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

无签名构建可以验证编译、资源、架构和最低系统版本，不能证明最终签名、Gatekeeper、DMG 或公证行为。

## 按改动选择验证

| 改动范围 | 最小验证 |
|---|---|
| 仅文档或 `AGENTS.md` | 链接、路径、术语和 diff 检查 |
| Models 或纯解析规则 | 相关测试 suite |
| Bridge、环境解析、Process 或 Manager 契约 | 相关测试；跨边界时运行完整测试 |
| Services、生命周期或 Features | 相关测试和 Debug 构建 |
| Homebrew 查询、计划或写操作 | Homebrew 相关测试、完整测试和 Debug 构建；真实操作仅进入人工验收 |
| Xcode 工程、资源或平台设置 | 完整测试、Debug 与 Release 构建、产物检查 |
| 真实 Homebrew、Node/nvm、窗口和退出行为 | 自动验证后执行相关人工清单 |

UI 改动不主动启动 App 或截图。完成编译和相关测试后交给用户视觉验收；用户明确要求运行或提供截图时再检查实际界面。普通自动验证不得为“顺便验收”而调用真实 Homebrew 写操作。

## Release 产物检查

Release App 位于：

```text
build/DerivedData-Release/Build/Products/Release/Cellar.app
```

至少检查：

1. `Info.plist` 的 bundle identifier 是 `com.dylanwang.Cellar`。
2. `LSMinimumSystemVersion` 是 `26.0`。
3. 不存在 `LSUIElement`，App 显示普通 Dock 图标和前台窗口。
4. App 内每个 Mach-O 只有 `arm64` slice。
5. `Contents/Resources/Managers/` 包含三套快照和 `SNAPSHOT.md`。
6. Bundle 内快照与仓库 `Resources/Managers/` 一致。
7. `Resources/Managers/` 不包含 `.runtime`、日志或临时文件。

不要只检查主程序。未来加入 Framework、Plug-in、Helper 或其他可执行文件时，逐项运行 `file` 或 `lipo -archs`。

## Manager 快照检查

Node 快照遵循 `scripts/node-manager/app-bundle-manifest.txt`。Homebrew 快照由 `main.sh` 和生产 `lib/*.sh` 组成；Zsh 的 `omz-manager.sh` 来自冻结脚本，相邻 `app-json.sh` 与模块是 Cellar-owned adapter。生成或更新快照时：

1. 用户必须先解除对应 `scripts/` 冻结或明确授权刷新快照。
2. 记录来源 Git commit。
3. 按白名单复制，不带 `.DS_Store`、`.runtime`、测试、日志或临时文件。
4. 逐文件比较来源和副本。
5. 运行 Manager 安装与 Node JSON 契约测试；Homebrew App 功能不依赖交互式 Manager 快照。

快照业务逻辑有问题时修复来源并重新生成，不能只修补 `Resources/Managers/`。

## CI 与发布现状

CI 先在 Ubuntu 校验 release manifest、版本同步、DMG/Sparkle 脚本和 Node 自动化测试；非纯文档改动、手动运行或开启发布时，再在 `macos-26` 上执行完整 XCTest 与无签名 arm64 Release 构建。

发布由成功的 main CI 触发，只有 `Config/Release/manifest.json` 的 `release` 为 `true` 且版本、CHANGELOG 和历史顺序合法时才构建。流水线使用 Apple Development 证书签名但不公证，生成并验证 DMG，发布 GitHub Release，然后使用 Sparkle 私钥生成签名 appcast 和 Homebrew Cask 并提交到 `SlippinDylan/homebrew-tap`。

需要配置的 GitHub Secrets：`CERTIFICATES_P12`、`CERTIFICATES_PASSWORD`、`SPARKLE_PUBLIC_KEY`、`SPARKLE_ED_PRIVATE_KEY`、`HOMEBREW_TAP_TOKEN`；`DISCORD_WEBHOOK_URL` 可选。Secrets 值不得写入仓库、日志或 Memory。

`Config/Release/manifest.json` 是版本和发布开关的唯一人工编辑入口；修改后运行 `node .github/scripts/sync-version.mjs`。普通构建从 `Config/Generated/Version.xcconfig` 读取 marketing version 和更新通道。

## 开发产物与安全清理

清理请求语义、仓库内外范围、Cellar 归属判定、用户开发环境保护、Agent 对话保护和空间报告要求统一见 [Cellar 开发产物清理规则](development-cleanup.md)。

本文构建命令生成 `build/DerivedData-Tests/`、`build/DerivedData-Debug/` 和 `build/DerivedData-Release/`；实际输出仍以执行的命令和脚本参数为准。

## 完成检查

```bash
git diff --check
git status --short
git diff -- scripts
```

确认验证结果对应最终改动。如果验证后又修改了代码，重新运行受影响的检查。不要把 `build/`、测试结果、临时日志或 App 运行副本加入提交。
