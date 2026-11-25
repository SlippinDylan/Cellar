# Cellar 开发与验证

本文记录 Cellar 的本地环境、测试、构建、产物检查和安全清理流程。产品行为见[产品需求](requirements/product-requirements.md)，组件和数据流见[总体架构](architecture/macos-app-architecture.md)。

## 1.0 实现纪律

- 产品需求是用户行为和安全边界的唯一来源。架构文档描述当前实现，不覆盖产品契约。
- 任务导航统一发生在 Features/Services；Formula、Cask、npm 和 Node environment identity 必须保留到 Bridge，不引入通用命令执行器。
- 用户界面可以隐藏内部 plan 术语，但强类型计划、状态指纹、全局 mutation slot 和 post-refresh 不能删除。
- String Catalog 是用户可见静态字符串的来源；新增界面同步提供 English、简体中文、繁体中文、日本語、한국어、Deutsch、Français、Español，默认语言行为为 Follow System。
- 独立只读 IO 使用有界并发；批量 mutation 顺序执行。禁止轮询、高频装饰动画和未经测量的 cache/依赖；用户明确要求的 PermissionFlow 原版授权引导为定向例外，仅在引导期间保留上游窗口跟随，结束即回收。
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

App 使用固定的 Sparkle 2.10.0 Swift Package。完全磁盘访问的拖拽引导通过 `Vendor/PermissionFlow` 本地 Swift Package 维护 PermissionFlow（MIT）原版组件，来源固定为 `65434c9ae04dba97cf52c1dffbe3e4e62b547c82`；保留原版面板、拖拽与单屏跟随几何，多屏时按系统设置窗口与屏幕的最大相交面积选屏；拖拽提示改为 10 点常规字重，方向箭头响应系统“减少动态效果”。无障碍、单次导航与窗口生命周期的维护差异和来源摘要记录在包内；来源与许可通过 `Resources/PermissionFlow-LICENSE.txt` 随 App 打包。仓库没有 Makefile、SwiftLint 或 SwiftFormat。Homebrew、Node.js 和 npm 是运行时读取或管理的用户工具，不是构建 Cellar 的依赖。

Apple 平台构建和测试优先使用 XcodeBuildMCP。每个会话首次调用前先读取 session defaults，再设置工程、scheme、平台、架构和仓库内 DerivedData 路径。

## 应用图标

图标设计源文件位于仓库根目录的 `Cellar.icon`，由 Apple Icon Composer 保存；App target 的 Debug 和 Release 均将 `ASSETCATALOG_COMPILER_APPICON_NAME` 设为 `Cellar`，并将该文件加入 Resources 构建阶段。Xcode 在命令行构建时编译图标并合并图标元数据，无需手工维护多尺寸 PNG 或修改 Info.plist。About 通过 `NSApplication.shared.applicationIconImage` 读取同一 App 图标。

README 顶部使用 `docs/images/readme/app-icon.png`。修改设计后，先构建 Debug，再从编译后的图标更新预览：

```bash
sips -s format png \
  build/DerivedData-Debug/Build/Products/Debug/Cellar.app/Contents/Resources/Cellar.icns \
  --out docs/images/readme/app-icon.png
```

首页图标位于 `Resources/BrandIcons.xcassets`，SVG 按原色和保留矢量数据编译；Command Line Tools 使用从本机 Apple 终端 App 官方图标导出的透明 PNG，明暗外观均使用近白色浅渐变底框保证原图深色笔画可辨，图标与底框分别添加轻阴影，由 `Image` 通过资源名称加载。下载原文件、来源与校验值保存在[素材记录](images/home-icon-candidates/README.md)；Devicon 与微软 Fluent UI System Icons 的许可通过 `Resources/BrandIcons-LICENSE.txt` 随 App 打包，不在运行时下载图标。

## 本地调试签名

打开 `Cellar.xcodeproj`，选择 `Cellar` scheme 和 My Mac，按 `⌘R` 使用 Debug 构建并运行。App 和测试 target 的 Debug 均使用 Manual 与本地临时签名（`CODE_SIGN_IDENTITY = "-"`，Xcode 显示为 Sign to Run Locally），无需登录 Apple 账号、选择开发团队或安装开发证书。使用默认 Debug 配置即可，不需要额外传入关闭签名的参数。

本地临时签名仅用于开发，不证明发布签名、Gatekeeper 或公证行为。macOS 也无法据此跨构建稳定识别应用身份，重新构建后可能需要重新授予隐私权限。Cellar 没有依赖团队签名互信的特权 Helper；Debug 的 Sparkle updater 仍默认关闭。Release 签名由发布流水线通过证书和团队参数覆盖。

构建脚本裁剪 Sparkle 架构并调整最低系统版本后，本地临时签名构建必须按依赖顺序重新签名其 XPC、Autoupdate、Updater 和 framework，再由 Xcode 签名主 App。脚本会校验 framework 的完整嵌套签名。构建后可用 `codesign --verify --deep --strict build/DerivedData-Debug/Build/Products/Debug/Cellar.app` 校验整个 App；只校验主程序不能发现嵌入框架的签名失效。无签名构建跳过此步骤，证书发布继续使用流水线的独立签名流程。

## 测试隔离

自动测试不能读取或修改用户真实的开发环境：

- 不运行用户安装的 brew、node、npm、nvm 或 Zsh Manager。
- Homebrew Bridge 测试注入假 brew executable，覆盖查询 JSON、搜索文本、计划、精确参数、环境、退出码、部分完成和 post-refresh；测试不得访问网络、Homebrew cache 或真实安装目录。
- Homebrew mutation 测试必须断言确认前不启动写进程，Formula/Cask 卸载禁止自动更新和 autoremove；standard/zap 原有计划不能隐式触发额外删除，增强 Cask 卸载只能删除已确认并复验的目标路径，Tap 有关联安装项时不能执行移除。
- Cask 清理测试注入临时 HOME、应用根目录、下载缓存和假 brew，覆盖共享身份与同名包保护、符号链接、文件替换、读取失败、Homebrew 失败后不补删及逐项部分完成。授权请求与签名替换检查使用临时夹具；允许对临时 App 做本地临时签名，自动测试不得请求真实管理员认证或以 root 删除文件。
- Cask 位置身份与完成复查测试覆盖同一物理应用的路径别名、大小写敏感卷上的真实副本、路径重新出现、授权中断后已消失路径及安装或路径未知时不标绿；删除安全测试继续独立约束 no-follow。主窗口关闭测试使用真实 SwiftUI Scene 验证活动任务拒绝关闭、空闲恢复且不影响独立面板；不启动生产 App。PermissionFlow 几何测试覆盖最大相交面积选屏，并保留原版单屏布局。
- Node Bridge 测试在临时目录创建假 `main.sh`，只验证参数、JSON、错误和部分失败。
- Node mutation 测试必须使用临时 HOME 和假 Manager，断言查询关闭 execute、确认执行才打开单次 write gate、项目写入使用独立 gate，且不访问真实 npm registry、cache、`~/.nvm` 或用户项目。
- Manager 安装测试注入临时 Application Support 根目录。
- 进程测试只执行测试自己创建的临时脚本。失败启动的文件描述符回收检查在独立 helper 中编译真实 `ProcessRunner`，逐次核对预期的 `ENOENT` 及完整描述符编号／类型；不得用异步测试前后整个 App 宿主的资源总数归因泄漏。异常结果须保留新增与消失的描述符信息。
- Hosted tests 通过 `XCTestConfigurationFilePath` 识别测试进程，禁止根视图自动刷新。
- Shell adapter 测试复制 Bundle Manager 到临时目录并注入临时 HOME，只允许修改测试 `.zshrc`、Oh My Zsh fixture 和 adapter runtime；不得访问用户真实 Shell 配置或网络。
- Catalog、线上版本和 npm Registry search 测试注入本地 fake transport，覆盖有界结果、ETag/cache、取消、超时、无效响应和独立部分失败；不得访问真实 endpoint。
- CLT/Homebrew setup 测试注入状态探测、latest stable Release metadata、下载、SHA-256、package signature、Gatekeeper assessment 和 system opener。必须分别断言 digest 缺失/无效/不匹配及两项 trust check 失败均不调用 opener，并返回原因和官方链接。只使用 fixture 与临时目录，不请求系统 CLT UI，不打开 Installer，不写 `/opt/homebrew`。
- Batch coordinator 测试使用 fake typed operations，断言同 provider/type、顺序执行、项目失败后继续、父任务取消时停止未开始项、无回滚声明和正确 post-refresh。
- 任务反馈测试断言会话内摘要、部分完成和逐项结果，以及重启后不恢复历史、不读写旧 `activity.json`。
- 文件日志测试注入临时日志目录、独立 UserDefaults 和时钟，验证等级过滤、设置持久化、UTC 跨日分卷、保留期限、单文件 10 MiB／总量 50 MiB 限制、去敏及 IO 失败重试；不写入用户日志目录。
- Shell 插件测试使用假 clone 和独立 staging，验证发布时目的地并发出现、失败清理和符号链接不逃逸；配置夹具包含官方模板初始化及假 loader，直接断言 source 时看到的插件、主题和 compdump。
- Node 配置特殊文件测试在独立 helper 进程内设置 deadline，验证无 writer FIFO、超限、替换及 descriptor 回收，不通过 sleep 判定正确性。
- Localization 检查必须覆盖 String Catalog 中 English、简体中文、繁体中文、日本語、한국어、Deutsch、Français、Español 的缺失项，并搜索新增的非本地化用户字符串。
- `node .github/scripts/validate-localizations.mjs` 无需启动 App，检查全部 catalog 翻译、格式占位与全部可达页面源码。新增用户可见来源时同步扩展脚本的 `presentationSources`；保留但不可达的旧 provider 页面不属于当前 UI。
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
  -derivedDataPath build/DerivedData-Debug
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
| Catalog/setup、batch、会话结果与文件日志 | fake/临时根目录相关测试；跨边界时完整测试和 Debug 构建 |
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

不要只检查主程序。当前 Sparkle Framework、Updater、Autoupdate 和 XPC，以及未来新增可执行文件，都应逐项运行 `file`/`lipo -archs` 与 `vtool -show-build`，确认仅 `arm64` 且 `minos` 为 `26.0`。同时确认 `en.lproj`、`zh-Hans.lproj`、`zh-Hant.lproj`、`ja.lproj`、`ko.lproj`、`de.lproj`、`fr.lproj`、`es.lproj` 中的编译字符串资源存在。

## Manager 快照检查

Node 快照遵循 `scripts/node-manager/app-bundle-manifest.txt`。Homebrew 快照由 `main.sh` 和生产 `lib/*.sh` 组成；Zsh 的 `omz-manager.sh` 来自冻结脚本，相邻 `app-json.sh` 与模块是 Cellar-owned adapter。生成或更新快照时：

1. 用户必须先解除对应 `scripts/` 冻结或明确授权刷新快照。
2. 记录来源 Git commit。
3. 按白名单复制，不带 `.DS_Store`、`.runtime`、测试、日志或临时文件。
4. 逐文件比较来源和副本。
5. 运行 Manager 安装与 Node JSON 契约测试；Homebrew App 功能不依赖交互式 Manager 快照。

快照业务逻辑有问题时修复来源并重新生成，不能只修补 `Resources/Managers/`。

## CI 与发布现状

CI 先在 Ubuntu 校验 release manifest、版本同步、DMG/Sparkle 脚本和 Node 自动化测试；非纯文档改动、手动运行或开启发布时，再在 `macos-26` 上先运行 PermissionFlow 的隔离 Package 测试（`swift test --package-path Vendor/PermissionFlow --scratch-path build/PermissionFlow-Package-Tests`），随后执行完整 XCTest 与无签名 arm64 Release 构建。

发布由成功的 main CI 触发，只有 `Config/Release/manifest.json` 的 `packagingEnabled` 为 `true` 且版本、构建号、CHANGELOG 和历史顺序合法时才构建。流水线使用 Apple Development 证书签名但不公证，并在构建前确认 Sparkle 公私钥属于同一 Ed25519 keypair。DMG 使用 `dmgbuild==1.6.7` 打包并先上传到 draft GitHub Release，之后的重跑把该 asset 视为不可变输入，不重新打包或覆盖；签名 appcast 和 Homebrew Cask 成功提交到 `SlippinDylan/homebrew-tap`、Cask SHA-256 与 draft DMG 一致、GitHub Pages 已能读到对应版本后，流水线才公开 GitHub Release。元数据或 Pages 验证失败时 Release 保持 draft，不会对外发布指向缺失 feed 的 App。

需要配置的 GitHub Secrets：`CERTIFICATES_P12`、`CERTIFICATES_PASSWORD`、`SPARKLE_PUBLIC_KEY`、`SPARKLE_ED_PRIVATE_KEY`、`HOMEBREW_TAP_TOKEN`；`DISCORD_WEBHOOK_URL` 可选。`SPARKLE_ED_PRIVATE_KEY` 必须是 Sparkle 2.10 `generate_keys -x` 导出的 canonical base64 32-byte seed，不接受 96-byte legacy 格式。Secrets 值不得写入仓库、日志或 Memory。

Cellar 的独立 Sparkle 密钥备份在 1Password 的「🗃️ 开发」保险库 →「Sparkle · Cellar」→「Sparkle-Cellar」分组，公钥字段为「公钥」，私钥字段为 `SPARKLE_ED_PRIVATE_KEY`。`HOMEBREW_TAP_TOKEN` 使用同保险库「GitHub Token」→「Personal access tokens」→「Homebrew Tap Automation」的共用凭证。上述三个值已配置为 `SlippinDylan/Cellar` 的 repository secrets。恢复配置时从这些条目读取，不重新生成或覆盖现有密钥；已分发 App 的密钥变更需要遵循 Sparkle 的密钥迁移流程。

发布流水线将签名更新源写入 `SlippinDylan/homebrew-tap` 的 `docs/cellar/appcast.xml`，由 GitHub Pages 的 `main:/docs` 提供服务；按版本通道生成 `Casks/cellar.rb`、`Casks/cellar@alpha.rb` 或 `Casks/cellar@beta.rb`。首次正式发布前不创建指向未发布 DMG 的 Cask 或 feed；完成凭证配置不会开启 `Config/Release/manifest.json` 的发布开关。

`Publish Distribution Metadata` 同时是 Release 调用的 reusable workflow 和已公开 Release 的人工恢复入口。正常发布失败时优先在原 Release run 重跑失败 job，它会复用同一 draft。如 GitHub Release 已公开但 tap 元数据需要恢复，手动运行该 workflow 并传入已公开 tag；完成后确认 `docs/cellar/appcast.xml` 和对应 channel Cask 的版本、DMG URL 与签名验证均通过。该入口不公开 draft Release。

`Config/Release/manifest.json` 是版本、构建号和发布开关的唯一人工编辑入口；修改后运行 `node .github/scripts/sync-version.mjs`。普通构建从 `Config/Generated/Version.xcconfig` 读取 marketing version、build（`CURRENT_PROJECT_VERSION`）和更新通道。

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

仅文档变更还应检查：仓库内 Markdown 相对链接存在；旧技术模块页面没有被误写成当前导航；`Formula`、`Cask`、`npm`、`nvm` 大小写一致；产品契约与 README/AGENTS/架构/人工清单互相可达。
