# Cellar 研究依据

更新日期：2026-10-04

本文保存会影响 Cellar 架构和产品承诺的外部依据。实现事实以代码和测试为准；本文件区分官方文档、源码证据和项目推论，避免把尚未人工验证的行为写成平台保证。

## 证据分类

| 分类 | 含义 |
|---|---|
| Apple 官方 | Apple Developer Documentation、技术说明或系统发布说明直接描述 |
| npm 官方 | npm CLI 官方文档或 npm/cli 源码直接描述 |
| Homebrew 官方 | Homebrew 官方文档、manpage 或 brew 源码直接描述 |
| 本机验证 | 在当前 Xcode、SDK 或工具版本上读取和执行过 |
| 项目推论 | 根据官方 API 与当前实现得出的设计结论，仍可能需要真实系统验证 |

## 窗口与生命周期

| 结论 | 分类 | 依据 |
|---|---|---|
| `Scene.defaultSize(width:height:)` 设置新窗口的初始默认尺寸，用户之后仍可调整，状态恢复也可以覆盖默认值 | Apple 官方 | [defaultSize(width:height:)](https://developer.apple.com/documentation/swiftui/scene/defaultsize(width:height:)) |
| `NSApplicationDelegateAdaptor` 可以把 AppKit delegate 接入 SwiftUI App 生命周期，并且同一 App 只能声明一次 | Apple 官方 | [NSApplicationDelegateAdaptor](https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor) |
| `applicationShouldTerminate(_:)` 可以允许、取消或延迟退出 | Apple 官方 | [applicationShouldTerminate(_:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)) |
| 关闭最后一个窗口后返回 `true` 会继续进入终止确认 | Apple 官方 | [applicationShouldTerminateAfterLastWindowClosed(_:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminateafterlastwindowclosed(_:)) |
| `NavigationSplitView` 适合作为两栏根导航，前导选择控制详情页 | Apple 官方 | [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview) |
| SwiftUI `Settings` scene 用于声明 App 的标准设置窗口；这是外部 API 事实，Cellar 按用户确认的产品契约使用主窗口 Settings 页面，不采用该 scene | Apple 官方与项目决策 | [Settings](https://developer.apple.com/documentation/swiftui/settings)、[产品需求](requirements/product-requirements.md) |
| `openURL` 使用环境提供的系统 URL 打开行为，网站链接不需要内嵌浏览器 | Apple 官方 | [OpenURLAction](https://developer.apple.com/documentation/swiftui/openurlaction) |
| `LazyVGrid` 根据 grid item 定义按需创建二维布局，适合响应式卡片集合 | Apple 官方 | [LazyVGrid](https://developer.apple.com/documentation/swiftui/lazyvgrid) |
| Sidebar 应提供少量清晰的顶层目的地并保持一致位置 | Apple 官方与项目推论 | [HIG: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) |
| `searchable` 为集合界面提供平台一致的搜索入口；搜索词仍应由 App 在边界校验后交给数据层 | Apple 官方与项目推论 | [Adding a search interface to your app](https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app) |
| `confirmationDialog` 用于呈现与当前动作相关的一组选择；不可逆 Homebrew 动作仍需在内容中明确目标和影响 | Apple 官方与项目推论 | [confirmationDialog(_:isPresented:titleVisibility:actions:message:)](https://developer.apple.com/documentation/swiftui/view/confirmationdialog(_:ispresented:titlevisibility:actions:message:)) |
| Cellar 使用 1080 × 720 默认尺寸，同时允许系统窗口调整和恢复 | 项目推论 | 基于 `defaultSize` 语义和已确认产品要求 |
| 活动任务期间取消退出可以阻止 `Command-Q`，但窗口关闭与无窗口持续任务的真实组合仍需人工检查 | 项目推论 | AppKit 回调顺序与当前 `WindowGroup` 实现 |

## 进程与文件

| 结论 | 分类 | 依据 |
|---|---|---|
| `Process` 表示独立子进程，环境、工作目录和标准 IO 必须在启动前设置 | Apple 官方 | [Process](https://developer.apple.com/documentation/foundation/process) |
| `Process.run()` 是当前 throwing 启动 API | Apple 官方 | [Process.run()](https://developer.apple.com/documentation/foundation/process/run()) |
| `Process.terminate()` 发送 `SIGTERM`，目标可能忽略它 | Apple 官方 | [Process.terminate()](https://developer.apple.com/documentation/foundation/process/terminate()) |
| `FileHandle.readToEnd()` 同步读取至 EOF，stdout 与 stderr 需要并发消费以避免管道互相阻塞 | Apple 官方与项目推论 | [FileHandle.readToEnd()](https://developer.apple.com/documentation/foundation/filehandle/readtoend()) |
| 非沙盒 macOS App 的 `URL.applicationSupportDirectory` 位于用户的 `~/Library/Application Support` | Apple 官方 | [URL.applicationSupportDirectory](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory) |
| `FileManager.copyItem(at:to:)` 在目标存在时失败，目录复制包含子内容 | Apple 官方 | [copyItem(at:to:)](https://developer.apple.com/documentation/foundation/filemanager/copyitem(at:to:)) |
| Bundle Resources 保持只读，Manager 在 Application Support 的版本目录运行 | 项目推论 | 签名资源完整性和可写运行状态需要分离 |

当前 `ProcessRunner` 使用明确 executable、参数、环境、空 stdin 和分离 pipe。Apple 文档说明 `terminate()` 只发送可能被忽略的 `SIGTERM`；因此实现通过 `posix_spawn` 为每个请求原子创建独立进程组，deadline 与取消先向整组发送 `SIGTERM`，宽限期后再对仍存活的组发送 `SIGKILL`，并在强制回收结束后才回收组长身份。

进程组回收依赖受支持命令不主动调用 `setsid` 或 `setpgrp` 脱离 App 创建的组。Cellar 自带 Manager 和当前允许的 brew/npm/nvm/zsh 调用不以守护进程方式运行；未来接入会主动脱离会话的外部工具时，需要另行设计 helper 或服务生命周期，不能沿用当前命令协议。

## Homebrew 查询与写操作

本轮以 Homebrew 官方 manpage 和环境变量文档为命令契约来源。App 不把既有交互式 Homebrew Manager 的菜单输出视为 API。

| 结论 | 分类 | 依据 |
|---|---|---|
| `brew info --json=v2` 提供 Formula/Cask 的机器可读信息，`--installed` 可限制为已安装项 | Homebrew 官方 | [brew info](https://docs.brew.sh/Manpage#info-options-formulacask-) |
| `brew outdated --json=v2` 提供可升级 Formula/Cask 的 JSON 数据，适合保持两种包类型与版本信息 | Homebrew 官方 | [brew outdated](https://docs.brew.sh/Manpage#outdated-options-formulacask-) |
| `brew search --formula` 与 `--cask` 可以显式限定搜索类型；查询可以按子字符串或正则解释，因此 App 必须把用户输入作为单个参数传递 | Homebrew 官方 | [brew search](https://docs.brew.sh/Manpage#search-s-options-textregex-) |
| `brew config`、`--prefix`、`--repository`、`--cache` 分别暴露 Homebrew 配置和关键路径 | Homebrew 官方 | [brew config 与全局命令](https://docs.brew.sh/Manpage) |
| `brew doctor` 用于检查潜在系统问题；非零或警告输出是诊断结果，不应被 UI 当作空数据或无问题 | Homebrew 官方 | [brew doctor](https://docs.brew.sh/Manpage#doctor-options-diagnostic_check-) |
| `brew install`、`upgrade` 与 `uninstall` 支持 `--formula`/`--cask` 消除同名歧义；Cask `uninstall --zap` 还会移除其关联文件 | Homebrew 官方 | [brew install](https://docs.brew.sh/Manpage#install-options-formulacask-), [brew upgrade](https://docs.brew.sh/Manpage#upgrade-options-outdated_formulacask-), [brew uninstall](https://docs.brew.sh/Manpage#uninstall-remove-rm-options-installed_formulacask-) |
| `brew update` 更新 Homebrew 与 Tap 元数据，应作为用户明确触发的独立 mutation，而不是查看或卸载的隐式步骤 | Homebrew 官方与项目决策 | [brew update](https://docs.brew.sh/Manpage#update-up-options) |
| `brew tap` 添加仓库，`brew untap` 移除 Tap；Cellar 在 untap 前额外检查关联安装项并拒绝危险移除 | Homebrew 官方与项目决策 | [brew tap/untap](https://docs.brew.sh/Manpage#tap-options-userrepo-url) |
| `HOMEBREW_NO_AUTO_UPDATE` 禁止 install/upgrade/tap 等命令前自动更新，`HOMEBREW_NO_AUTOREMOVE` 禁止 cleanup/uninstall 自动移除未使用的依赖 Formula | Homebrew 官方 | [Homebrew environment variables](https://docs.brew.sh/Manpage#environment) |
| Homebrew 默认使用 API 安装时会读取并缓存远端 JSON；搜索、详情、过期检查和 mutation 不能承诺完全离线或零 cache 写入 | Homebrew 官方 | [API installation and JSON API](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap#installing) |

由上述语义得到的项目边界：查询与写操作都可能联网并更新 Homebrew 自己的 cache；写命令不是事务。Cellar 内部保留 typed plan，高风险或批量动作按产品矩阵确认，并在命令结束后重新查询真实状态。Formula/Cask 卸载显式设置禁止自动更新和 autoremove；Cask artifact 仅用于 standard/zap 影响说明和 postflight 报告，App 不自行删除文件。

## Homebrew 与系统安装引导

| 结论 | 分类 | 依据 |
|---|---|---|
| Homebrew 官方安装文档提供 macOS `.pkg` 安装器；该安装器仅支持 Apple Silicon，并安装到默认 `/opt/homebrew` prefix | Homebrew 官方 | [Installation](https://docs.brew.sh/Installation) |
| Homebrew 当前版本和 `.pkg` 资产由官方 `Homebrew/brew` releases 发布 | Homebrew 官方 | [Homebrew/brew Releases](https://github.com/Homebrew/brew/releases) |
| Apple 文档说明 `xcode-select --install` 会请求安装，并由随后出现的系统对话框完成 Install、许可同意与结束步骤 | Apple 官方 | [Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools) |
| 对从网络取得的 package file，Apple 指引用户打开 package 并按照 Installer 屏幕说明操作；该文档没有承诺每次会出现哪一种认证或权限提示 | Apple 官方 | [Install and uninstall apps from the internet or a disc](https://support.apple.com/guide/mac-help/install-and-uninstall-other-apps-mh35835/mac) |
| Gatekeeper 会检查从 App Store 外下载的软件，并结合 Developer ID/notarization 识别已知恶意内容 | Apple 官方 | [Safely open apps on your Mac](https://support.apple.com/102445) |

基于上述资料，1.0 采用更严格的项目决策：Cellar 只接受 Homebrew 官方 latest stable Release 中适用于当前平台的精确 `Homebrew.pkg`，而且该 Release 必须提供该资产的有效官方 SHA-256。Cellar 验证 digest 完整匹配、package signature 和 Gatekeeper assessment；digest 缺失/无效/不匹配，或任一 trust check 无法完成、结果缺失、无效或失败时一律 fail closed，不打开 package，并显示原因和 Homebrew 官方网站链接。这个 SHA-256 必需条件是 Cellar 安全契约，不是对 Homebrew Release 永远提供 digest 的事实声明。

通过全部验证后，Cellar 按 Apple 对网络 package 的指引请求系统打开，并将后续屏幕说明留给 Installer。Cellar 不执行远端 shell installer、不实现 package 内部步骤、不运行自己的 `sudo`，也不收集管理员密码。“Cellar 不处理认证、许可或权限提示”是项目权限边界；Apple 资料只证明系统 Installer 的屏幕流程，不保证具体提示必然出现。

Command Line Tools 则直接采用 Apple 文档中的 `xcode-select --install` 和系统对话框。Cellar 只做状态检测和发起请求，不下载或封装 CLT payload；系统对话框、许可、完成与取消状态进入人工验收。nvm 只链接其官方项目安装说明，1.0 不在 App 中执行远端安装脚本。

## 平台和架构

| 结论 | 分类 | 依据 |
|---|---|---|
| Apple Silicon 架构问题应通过现代 build settings 处理，不使用已废弃的 `VALID_ARCHS` | Apple 官方 | [TN3117](https://developer.apple.com/documentation/technotes/tn3117-resolving-build-errors-for-apple-silicon) |
| macOS target 可以包含 arm64 和 x86_64 slice；Cellar 必须显式验证发布制品 | Apple 官方 | [Building a universal macOS binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary) |
| macOS 26 SDK 随 Xcode 26 提供 | Apple 官方 | [macOS 26 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)、[Xcode 26 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes) |
| Cellar App、测试和未来嵌入 Mach-O 都只允许 arm64，最低版本固定为 macOS 26.0 | 产品决策 | [平台支持范围](requirements/platform-support.md) |

架构验收以最终 App Bundle 为准。仅检查 Xcode build setting 不能证明第三方 Framework 或未来嵌入工具没有 x86_64 slice。

## npm 读取语义

本机核对版本为 Node.js 22.22.0、npm 11.11.0。npm 资料通过 Context7 定位到官方 `/npm/cli` 仓库和文档。

| 结论 | 分类 | 依据 |
|---|---|---|
| `npm ls -g --depth=0 --json` 从磁盘加载实际全局依赖树，不访问 registry，也不执行写入 | npm 官方源码 | [npm ls](https://docs.npmjs.com/cli/v11/commands/npm-ls)、[npm/cli ls.js](https://github.com/npm/cli/blob/latest/lib/commands/ls.js) |
| `npm outdated` 加载实际依赖树并查询 registry metadata；发现过期包时退出码为 1 | npm 官方源码 | [npm outdated](https://docs.npmjs.com/cli/v11/commands/npm-outdated)、[npm/cli outdated.js](https://github.com/npm/cli/blob/latest/lib/commands/outdated.js) |
| `npm outdated --json` 通常返回以包名为 key 的对象，值包含 current、wanted、latest、dependent 和 location | npm 官方源码 | [npm/cli outdated.js](https://github.com/npm/cli/blob/latest/lib/commands/outdated.js) |
| `npm config get` 返回 default、builtin、global、user、project、env 和 CLI 层合并后的有效配置 | npm 官方源码 | [npm config](https://docs.npmjs.com/cli/v11/commands/npm-config)、[@npmcli/config](https://github.com/npm/cli/tree/latest/workspaces/config) |
| 全局 npm 包属于当前 npm/global prefix；切换 nvm Node 版本可能切换整套全局包 | npm/nvm 行为与项目事实 | [npm folders](https://docs.npmjs.com/cli/v11/configuring-npm/folders)、[nvm README](https://github.com/nvm-sh/nvm) |
| `npm search` 在 Registry 中搜索匹配 package term，并提供 JSON 输出；搜索行为会受配置的 Registry 影响 | npm 官方 | [npm search](https://docs.npmjs.com/cli/v11/commands/npm-search)、[npm registry](https://docs.npmjs.com/cli/v11/using-npm/registry) |
| Registry HTTP `GET /-/v1/search` 接受 `text`、`size` 和 `from`；官方 API 上限为 250，Cellar 的单次结果上限为 100。`GET /{package}/latest` 返回对应版本元数据 | npm 官方与项目约束 | [npm Public Registry API](https://github.com/npm/registry/blob/main/docs/REGISTRY-API.md) |
| Node 官方站点以 `https://nodejs.org/dist/index.json` 读取发布列表；Cellar 从中选择提供 macOS arm64 tar 的最新稳定语义版本。nvm 版本来自官方仓库 latest stable Release | 官方源码与项目约束 | [Node release-post source](https://github.com/nodejs/nodejs.org/blob/main/apps/site/scripts/release-post/index.mjs)、[nvm releases](https://github.com/nvm-sh/nvm/releases) |
| nvm 的版本、alias/default 与安装说明以官方 `nvm-sh/nvm` 项目为准 | nvm 官方项目 | [nvm README](https://github.com/nvm-sh/nvm) |

`npm outdated` 的退出码 1 可以表示“存在更新”，不一定是执行错误。Cellar 使用的 Node Manager 已把这一语义转换成统一 JSON envelope；Swift 层只解析该契约，不重新解释 npm 原始文本。

## 本地化、可访问性与 UI 状态

| 结论 | 分类 | 依据 |
|---|---|---|
| `ContentUnavailableView` 适合空数据和错误等无法展示内容的状态 | Apple 官方 | [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview) |
| String Catalog 管理可本地化字符串和多语言变体 | Apple 官方 | [Localizing and varying text with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog) |
| macOS App 应支持键盘导航、辅助技术和不只依赖颜色的状态表达 | Apple 官方 | [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| 系统提供 Reduce Motion、Increase Contrast 和 Reduce Transparency 等辅助功能环境值 | Apple 官方 | [Accessibility environment](https://developer.apple.com/documentation/swiftui/environmentvalues#Accessibility) |
| 1.0 卡片网格为 loading、empty、offline、partial error 提供不同语义状态，不用空结果伪装成功 | 当前实现与项目约束 | 与 1.0 产品状态契约一致；真实网络失败仍需人工验收 |

## SwiftUI 性能与 macOS 26 界面

| 结论 | 分类 | 依据 |
|---|---|---|
| SwiftUI Instrument 的 update groups 和 cause-and-effect graph 用于区分视图更新环、长 `body` 和非 SwiftUI CPU 成本；不应用延迟或动画掩盖状态重入 | Apple 官方 | [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)、[WWDC25: Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/) |
| `List` 和 lazy layout 适合稳定 ID 的集合；过滤应在构建 row/card 前完成，不在子视图构建时反向写 selection | Apple 官方与项目推论 | [WWDC23: Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)、[`LazyVGrid`](https://developer.apple.com/documentation/swiftui/lazyvgrid) |
| macOS Sidebar 应使用稳定的系统 selection；固定底部 Activity 不向 Sidebar `List` 注入树外 selection | Apple 官方与本机崩溃证据 | [HIG: Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)；macOS 26.7 崩溃栈为 `NSOutlineView → OutlineListCoordinator → AttributeGraph` |
| Liquid Glass 是导航和交互控件层；标准 toolbar、sheet、button 和 segmented control 优先使用系统适配，内容卡、表格行和日志不铺满自定义玻璃 | Apple 官方 | [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) |
| 进度只显示实际可证明的阶段或数量；无可靠百分比时使用不定 `ProgressView`，不使用常驻高帧率 shimmer | Apple 官方与项目推论 | [HIG: Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)、[`ProgressView`](https://developer.apple.com/documentation/swiftui/progressview) |

## Sparkle 签名密钥

| 结论 | 分类 | 依据 |
|---|---|---|
| Sparkle 2.10.0 新格式私钥是 base64 编码的 32-byte Ed25519 seed，旧格式是 64-byte private key 与 32-byte public key 的拼接；Cellar 发布流水线只接受可独立推导公钥的当前 32-byte seed 格式 | Sparkle 官方源码与项目约束 | [`common_cli/Secret.swift`](https://github.com/sparkle-project/Sparkle/blob/2.10.0/common_cli/Secret.swift) |
| `SUPublicEDKey` 必须是对应私钥的 Ed25519 公钥；仅分别验证两个 Secret 存在不能证明更新签名可被 App 接受 | Sparkle 官方源码与项目推论 | [`generate_keys/main.swift`](https://github.com/sparkle-project/Sparkle/blob/2.10.0/generate_keys/main.swift)、[`common_cli/Signing.swift`](https://github.com/sparkle-project/Sparkle/blob/2.10.0/common_cli/Signing.swift) |

## 仍需人工验证

- 首次窗口尺寸、窗口恢复和用户调整。
- `Command-Q`、关闭最后窗口和活动任务组合。
- Finder 启动下对 `/opt/homebrew` 和默认 nvm Node 的发现。
- `xcode-select --install` 系统对话框，以及 Homebrew 官方 `.pkg` 经三项验证后由 Installer 实际显示的屏幕流程和完成状态。
- 官方 release metadata、npm Registry search 与 Node/nvm 线上版本在离线、超时和限流场景下的表现。
- `npm outdated` 在离线、registry 超时、认证失败和代理环境下的表现。
- App 退出后是否存在遗留的 bash、npm 或 brew 子进程。
- English、简体中文和繁体中文 UI 在 1080 × 720 及更窄窗口中的截断、键盘与 VoiceOver 可用性。

这些项目进入[人工验收清单](manual-smoke-checklist.md)。人工验证失败时修改实现或收缩产品承诺，不增加未经证明的 fallback。
