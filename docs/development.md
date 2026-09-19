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

App 没有第三方 Swift Package、Makefile、SwiftLint 或 SwiftFormat。Node.js 和 npm 是被探测的用户工具，不是构建 Cellar 的依赖。

Apple 平台构建和测试优先使用 XcodeBuildMCP。每个会话首次调用前先读取 session defaults，再设置工程、scheme、平台、架构和仓库内 DerivedData 路径。

## 测试隔离

自动测试不能读取或修改用户真实的开发环境：

- 不运行用户安装的 brew、node、npm、nvm 或 Zsh Manager。
- Node Bridge 测试在临时目录创建假 `main.sh`，只验证参数、JSON、错误和部分失败。
- Manager 安装测试注入临时 Application Support 根目录。
- 进程测试只执行测试自己创建的临时脚本。
- Hosted tests 通过 `XCTestConfigurationFilePath` 识别测试进程，禁止根视图自动刷新。
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
| Xcode 工程、资源或平台设置 | 完整测试、Debug 与 Release 构建、产物检查 |
| 真实 Homebrew、Node/nvm、窗口和退出行为 | 自动验证后执行相关人工清单 |

UI 改动不主动启动 App 或截图。完成编译和相关测试后交给用户视觉验收；用户明确要求运行或提供截图时再检查实际界面。

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

Node 快照遵循 `scripts/node-manager/app-bundle-manifest.txt`。Homebrew 快照由 `main.sh` 和生产 `lib/*.sh` 组成；Zsh 快照是 `scripts/zsh/omz-manager.sh`。生成或更新快照时：

1. 用户必须先解除对应 `scripts/` 冻结或明确授权刷新快照。
2. 记录来源 Git commit。
3. 按白名单复制，不带 `.DS_Store`、`.runtime`、测试、日志或临时文件。
4. 逐文件比较来源和副本。
5. 运行 Manager 安装与 Node JSON 契约测试。

快照业务逻辑有问题时修复来源并重新生成，不能只修补 `Resources/Managers/`。

## CI 与发布现状

仓库当前没有项目级 CI、发布清单、签名流水线、DMG、Sparkle 或 Homebrew Cask。不要把本地无签名构建描述为可发布版本，也不要从其他项目复制尚未采用的发布流程。

引入发布能力前需要单独确定：

- 版本和发布开关的唯一配置入口。
- 签名身份、是否公证及失败策略。
- DMG 结构和产物验证。
- 更新渠道与 Homebrew 分发。
- README 中的真实下载和安装说明。

## 开发产物与安全清理

使用本文命令时，仓库内会生成：

```text
build/DerivedData-Tests/
build/DerivedData-Debug/
build/DerivedData-Release/
```

其他可再生产物包括根目录 `DerivedData/`、`.build/`、`.swiftpm/`、`*.xcresult`、`*.app`、`*.dSYM` 和 `*.xcarchive`。只有用户明确要求清理时才删除。

清理步骤：

1. 解析目标的绝对路径，确认属于 Cellar 或本次构建。
2. 用 `du` 统计各目标及总占用。
3. 只删除可重新生成的构建或测试产物。
4. 删除后重新扫描并报告实际结果。

以下内容不是开发缓存：

- `Cellar.xcodeproj/`、源码、测试、文档和 `.git/`。
- `scripts/` 和 `Resources/Managers/`。
- `~/Library/Application Support/Cellar/` 中的 Manager 运行副本和未来用户状态。
- 用户的 `~/.nvm`、npm cache、npm 配置、Homebrew 安装和 Shell 配置。
- 无法可靠归属于 Cellar 的 `/tmp`、`/private/var/folders` 或 Xcode 全局 DerivedData。

## 完成检查

```bash
git diff --check
git status --short
git diff -- scripts
```

确认验证结果对应最终改动。如果验证后又修改了代码，重新运行受影响的检查。不要把 `build/`、测试结果、临时日志或 App 运行副本加入提交。
