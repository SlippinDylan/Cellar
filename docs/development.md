# Cellar 开发与验证

本文记录 Cellar 的本地环境、测试、构建、产物检查和安全清理流程。产品行为见[产品需求](requirements/product-requirements.md)，组件和数据流见[总体架构](architecture/macos-app-architecture.md)。

## 1.0 实现纪律

- 产品需求是目标行为的唯一来源。架构文档中的“当前基线”用于理解现有代码，不覆盖目标契约。
- 任务导航统一发生在 Features/Services；Formula、Cask、npm 和 Node environment identity 必须保留到 Bridge，不引入通用命令执行器。
- 用户界面可以隐藏内部 plan 术语，但强类型计划、状态指纹、全局 mutation slot 和 post-refresh 不能删除。
- String Catalog 是用户可见静态字符串的来源；新增界面同步提供 English、简体中文和繁体中文，默认语言行为为 Follow System。
- 独立只读 IO 使用有界并发；批量 mutation 顺序执行。禁止轮询、高频装饰动画和未经测量的 cache/依赖。
- 普通自动开发可以读取必要的项目文件，但不以真实 Homebrew、npm、nvm、Shell、Registry 或系统 Installer 作为验证夹具。

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
- Homebrew mutation 测试必须断言需要确认的动作在确认前不启动进程，Formula/Cask 卸载禁止自动更新和 autoremove，Cask artifact 不触发 App 文件删除，Tap 有关联安装项时不能执行移除。
- Node Bridge 测试在临时目录创建假 `main.sh`，只验证参数、JSON、错误和部分失败。
- Node mutation 测试必须使用临时 HOME 和假 Manager，断言查询关闭 execute、确认执行才打开单次 write gate、项目写入使用独立 gate，且不访问真实 npm registry、cache、`~/.nvm` 或用户项目。
- Manager 安装测试注入临时 Application Support 根目录。
- 进程测试只执行测试自己创建的临时脚本。
- Hosted tests 通过 `XCTestConfigurationFilePath` 识别测试进程，禁止根视图自动刷新。
- Shell adapter 测试复制 Bundle Manager 到临时目录并注入临时 HOME，只允许修改测试 `.zshrc`、Oh My Zsh fixture 和 adapter runtime；不得访问用户真实 Shell 配置或网络。
- Catalog、线上版本和 npm Registry search 测试注入本地 fake transport，覆盖有界结果、ETag/cache、取消、超时、无效响应和独立部分失败；不得访问真实 endpoint。
- CLT/Homebrew setup 测试注入状态探测、下载、摘要/签名/trust check 和 system opener。只使用 fixture 与临时目录，不请求系统 CLT UI，不打开 Installer，不写 `/opt/homebrew`。
- Batch coordinator 测试使用 fake typed operations，断言同 provider/type、顺序执行、项目失败后继续、取消后停止未开始项、无回滚声明和正确 post-refresh。
- Activity 持久化测试注入临时 Application Support，断言最多 100 条、结构化本地化数据、凭证/原始输出不落盘和损坏数据隔离。
- Localization 检查必须覆盖 String Catalog 中 English、简体中文和繁体中文的缺失项，并搜索新增的非本地化用户字符串。
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
| Models、版本语义或纯解析规则 | 相关测试 suite |
| Bridge、环境解析、Process 或 Manager 契约 | 相关测试；跨边界时运行完整测试 |
| Catalog/setup、batch、Activity persistence | fake/临时根目录相关测试；跨边界时完整测试和 Debug 构建 |
| Services、生命周期、localization 或 Features | 相关测试、localization coverage 和 Debug 构建 |
| Homebrew 查询、计划或写操作 | Homebrew 相关测试、完整测试和 Debug 构建；真实操作仅进入人工验收 |
| Xcode 工程、资源或平台设置 | 完整测试、Debug 与 Release 构建、产物检查 |
| 真实 Homebrew、Node/nvm、窗口和退出行为 | 自动验证后执行相关人工清单 |

UI 改动不主动启动 App 或截图。完成编译和相关测试后交给用户视觉验收；用户明确要求运行或进入计划中的视觉验收任务时，只以只读方式启动和截图。任何视觉验收都不得触发真实 Homebrew/npm/nvm/Shell 写操作或系统 Installer。

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

发布由成功的 main CI 触发，只有 `Config/Release/manifest.json` 的 `release` 为 `true` 且版本、CHANGELOG 和历史顺序合法时才构建。流水线使用 Apple Development 证书签名但不公证，并在构建前确认 Sparkle 公私钥属于同一 Ed25519 keypair。DMG 先上传到 draft GitHub Release，之后的重跑把该 asset 视为不可变输入，不重新打包或覆盖；签名 appcast 和 Homebrew Cask 成功提交到 `SlippinDylan/homebrew-tap`、Cask SHA-256 与 draft DMG 一致、GitHub Pages 已能读到对应版本后，流水线才公开 GitHub Release。元数据或 Pages 验证失败时 Release 保持 draft，不会对外发布指向缺失 feed 的 App。

需要配置的 GitHub Secrets：`CERTIFICATES_P12`、`CERTIFICATES_PASSWORD`、`SPARKLE_PUBLIC_KEY`、`SPARKLE_ED_PRIVATE_KEY`、`HOMEBREW_TAP_TOKEN`；`DISCORD_WEBHOOK_URL` 可选。`SPARKLE_ED_PRIVATE_KEY` 必须是 Sparkle 2.10 `generate_keys -x` 导出的 canonical base64 32-byte seed，不接受 96-byte legacy 格式。Secrets 值不得写入仓库、日志或 Memory。

`Publish Distribution Metadata` 同时是 Release 调用的 reusable workflow 和已公开 Release 的人工恢复入口。正常发布失败时优先在原 Release run 重跑失败 job，它会复用同一 draft。如 GitHub Release 已公开但 tap 元数据需要恢复，手动运行该 workflow 并传入已公开 tag；完成后确认 `docs/cellar/appcast.xml` 和对应 channel Cask 的版本、DMG URL 与签名验证均通过。该入口不公开 draft Release。

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

仅文档变更还应检查：仓库内 Markdown 相对链接存在；旧技术模块导航术语没有被误写成 1.0 目标；`Formula`、`Cask`、`npm`、`nvm` 大小写一致；产品契约与 README/AGENTS/架构/人工清单互相可达。
