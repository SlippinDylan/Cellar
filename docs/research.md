# Cellar 研究依据

更新日期：2026-11-12

本文保存会影响 Cellar 架构和产品承诺的外部依据。实现事实以代码和测试为准；本文件区分官方文档、源码证据和项目推论，避免把尚未人工验证的行为写成平台保证。

## 证据分类

| 分类 | 含义 |
|---|---|
| Apple 官方 | Apple Developer Documentation、技术说明或系统发布说明直接描述 |
| npm 官方 | npm CLI 官方文档或 npm/cli 源码直接描述 |
| Homebrew 官方 | Homebrew 官方文档、manpage 或 brew 源码直接描述 |
| 本机验证 | 在当前 Xcode、SDK 或工具版本上读取和执行过 |
| 项目推论 | 根据官方 API 与当前实现得出的设计结论，仍可能需要真实系统验证 |

## 软件目录图标

- 源码证据：核对 Applite commit `cf9712ae57a23628f4946389192959eb7079c6be` 的 [CaskViewModel.swift](https://github.com/milanvarady/Applite/blob/cf9712ae57a23628f4946389192959eb7079c6be/Applite/Core/CaskCore/CaskViewModel.swift) 和 [AppIconView.swift](https://github.com/milanvarady/Applite/blob/cf9712ae57a23628f4946389192959eb7079c6be/Applite/AppViews/AppIconView.swift)，使用 CaskFlow token PNG、Kingfisher 缓存及名称首字母回退。
- 上游说明：[CaskFlow](https://github.com/alielsokary/CaskFlow) commit `fcea8e07c712d253d6de093cc6d8e3ab31e5a148` 的 README 说明 `icons` 分支发布 256 × 256 PNG，来自校验过的软件发行包提取。该说明不构成完整覆盖或 CDN 可用性保证；Cellar 不打包全量图标，不运行提取工具。
- Apple 官方：[URLCache](https://developer.apple.com/documentation/foundation/urlcache) 支持设置内存、磁盘容量和缓存目录；[CGImageSourceCopyPropertiesAtIndex](https://developer.apple.com/documentation/imageio/cgimagesourcecopypropertiesatindex(_:_:_:)) 提供尺寸等图像属性。
- 项目决策：Cellar 自行实现小范围图标展示，复用现有受限 transport 和系统缓存，不引入 Kingfisher；仅明确的官方 Cask 身份可请求图标，第三方 Tap、Formula、npm 保留本地占位。真实 CDN、磁盘跨进程复用和视觉验收仍见人工清单。

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

由上述语义得到的项目边界：查询与写操作都可能联网并更新 Homebrew 自己的 cache；写命令不是事务。Cellar 内部保留 typed plan，高风险或批量动作按产品矩阵确认，并在命令结束后重新查询真实状态。Formula/Cask 卸载显式设置禁止自动更新和 autoremove；Library 的增强 Cask 卸载以独立、可复验的确认清单约束额外残留清理，不把整个 zap stanza 交给 Homebrew。

## Cask 卸载参考

- 源码证据：本轮核对 [Mole commit `0cccf46692ea887c7f849aecca049f91c092ca08`](https://github.com/tw93/Mole/tree/0cccf46692ea887c7f849aecca049f91c092ca08) 的 `lib/uninstall/batch.sh`、`brew.sh`、`review.sh` 与 `lib/core/app_protection.sh`。实际 Cask 卸载传入 `nozap`，避免 zap 删除用户未预览的数据；关联文件扫描与共享安装副本保护分开执行。其后台 autoremove、终端 sudo 及全局清理不作为 Cellar 行为。
- 挂载副本依据：上述 Mole 版本 `lib/uninstall/batch.sh:1602–1629` 有界发现本地卷顶层应用与 Applications，`1711–1722` 区分完整与未知检查，不因挂载本身保留全部数据。Cellar 采用此应用发现范围，并复验本地卷身份；未知状态继续保留，大小统计与删除不跨挂载。
- Apple 官方：[activateFileViewerSelecting(_:)](https://developer.apple.com/documentation/appkit/nsworkspace/activatefileviewerselecting(_:)) 在访达中定位文件；[contentMargins(_:_:for:)](https://developer.apple.com/documentation/swiftui/view/contentmargins(_:_:for:)) 允许分离滚动内容与滚动条边距。
- Apple 官方：[NSWorkspace.icon(forFile:)](https://developer.apple.com/documentation/appkit/nsworkspace/icon(forfile:)) 可读取本机文件图标；[removeItem(at:)](https://developer.apple.com/documentation/foundation/filemanager/removeitem(at:)) 的目录删除包含其内容，不提供 App 归属判断。
- Apple 官方：[SecCodeCheckValidity](https://developer.apple.com/documentation/security/seccodecheckvalidity(_:_:_:)) 对运行代码执行动态验证，可施加精确代码要求，并明确抵抗对其文件系统来源的修改；项目将其与 root 私有副本的深度签名验证组合，用于阻止授权等待期间替换可执行文件。
- 项目推论：只读应用识别须按物理位置合并系统路径别名，不能仅比较路径字符串；这不放宽删除时的 no-follow 校验。完成状态以确认路径的最终复查为准，历史进度及授权结果不能单独证明文件已移除；安装状态或路径观察未知时保留未验证语义。
- 项目决策：Cellar 用 Swift 独立实现精确归属与文件身份保护，不复制或打包 Mole 的 GPLv3 脚本。系统管理员授权只覆盖受限残留清理，不将 Homebrew 进程提升为 root，不把 Homebrew 自身需要 sudo 的卸载钩子表述为已支持。授权成功与取消、真实残留覆盖率和弹窗外观仍须按人工清单验证。

## Homebrew 与系统安装引导

| 结论 | 分类 | 依据 |
|---|---|---|
| Homebrew 官方安装文档提供 macOS `.pkg` 安装器；该安装器仅支持 Apple Silicon，并安装到默认 `/opt/homebrew` prefix | Homebrew 官方 | [Installation](https://docs.brew.sh/Installation) |
| Homebrew 当前版本和 `.pkg` 资产由官方 `Homebrew/brew` releases 发布 | Homebrew 官方 | [Homebrew/brew Releases](https://github.com/Homebrew/brew/releases) |
| Apple 文档说明 `xcode-select --install` 会请求安装，并由随后出现的系统对话框完成 Install、许可同意与结束步骤 | Apple 官方 | [Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools) |
| 对从网络取得的 package file，Apple 指引用户打开 package 并按照 Installer 屏幕说明操作；该文档没有承诺每次会出现哪一种认证或权限提示 | Apple 官方 | [Install and uninstall apps from the internet or a disc](https://support.apple.com/guide/mac-help/install-and-uninstall-other-apps-mh35835/mac) |
| Gatekeeper 会检查从 App Store 外下载的软件，并结合 Developer ID/notarization 识别已知恶意内容 | Apple 官方 | [Safely open apps on your Mac](https://support.apple.com/102445) |

基于上述资料，1.0 采用更严格的项目决策：Cellar 只接受 Homebrew 官方 latest stable Release 中适用于当前平台的精确 `Homebrew.pkg`，而且该 Release 必须提供该资产的有效官方 SHA-256。Cellar 验证 digest 完整匹配、package signature 和 Gatekeeper assessment；digest 缺失/无效/不匹配，或任一 trust check 无法完成、结果缺失、无效或失败时一律 fail closed，不打开 package，并显示原因和 Homebrew 官方网站链接。这个 SHA-256 必需条件是 Cellar 安全契约，不是对 Homebrew Release 永远提供 digest 的事实声明。

通过全部验证后，Cellar 按 Apple 对网络 package 的指引请求系统打开，并将后续屏幕说明留给 Installer。Cellar 不执行远端 shell installer、不实现 package 内部步骤、不运行自己的 `sudo`，也不收集管理员密码。“安装引导不处理认证、许可或权限提示”是该流程的项目权限边界；Apple 资料只证明系统 Installer 的屏幕流程，不保证具体提示必然出现。

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
| `frame` 支持最小、理想与最大宽度；`NSViewRepresentable.sizeThatFits` 可以按布局提出的尺寸返回原生视图大小，适用于可压缩的工具栏搜索字段 | Apple 官方 | [`frame`](https://developer.apple.com/documentation/swiftui/view/frame(minwidth:idealwidth:maxwidth:minheight:idealheight:maxheight:alignment:))、[`sizeThatFits`](https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)) |
| `.lineLimit(2, reservesSpace: true)` 保留两行文本所需高度；macOS `.navigation` ControlGroup 提供带分隔的瞬时分段按钮组，不需要自绘玻璃胶囊 | Apple 官方 | [`lineLimit`](https://developer.apple.com/documentation/swiftui/view/linelimit(_:reservesspace:))、[`navigation`](https://developer.apple.com/documentation/swiftui/controlgroupstyle/navigation) |

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

## 首页统计图标配色

2026-11-12 核对官方站点与官方 Logo 仓库；首页 13 张统计卡片均使用随 App 打包的图像资源。六个品牌项使用彩色 SVG；Formula、Cask、更新、全局包与 nvm 默认版本使用微软 Fluent 的功能 SVG，两处更新共用一个资源；Command Line Tools 按用户选择使用本机 Apple Terminal 官方图标导出的 PNG。下载来源、固定 commit、原文件及许可记录见[品牌素材记录](images/home-icon-candidates/README.md)和[功能素材记录](images/home-icon-candidates/functional/README.md)。品牌原图保留原色，卡片图标底色与版本旁更新小标使用适配明暗外观的配色；下表记录官方来源的颜色依据，不将功能图标表述为对应工具的官方 Logo。Command Line Tools 的卡片配色使用系统蓝；更新数量继续使用绿色／橙色表达状态。

| 对象 | 官方依据 | 观察到的配色 |
|---|---|---|
| Homebrew（含 Formula/Cask） | [官网 Logo](https://brew.sh/assets/img/homebrew.svg) | 麦芽金 `#FBB040` |
| Node.js | [品牌资源](https://nodejs.org/en/about/branding) | 绿色 `#5FA04E`、`#3F873F`、`#6ABF4B` |
| npm（含全局包） | [官方红色 Logo](https://github.com/npm/logos/blob/cc343d8c50139f645d165aedfe4d375240599fd1/npm%20logo/npm-logo-red.svg) | 红色 `#C12127`；npm 官网请求返回 403，使用官方 Logo 仓库核对 |
| nvm（含默认版本） | [官方彩色 Logo](https://github.com/nvm-sh/logos/blob/414e1a32b2f0f07101717f1c301aa14f00f91f59/nvm-logo-color.svg) | 黄色 `#F4DD4B`、深灰 `#333333` |
| Zsh | [官网](https://www.zsh.org/) | 网站强调色橙色 `#F15A24`，不将网站用色表述为正式品牌规范 |
| Oh My Zsh | [官网](https://ohmyz.sh/) | 网站主要强调色黄绿色 `#C5D928`，不将网站用色表述为正式品牌规范 |

## 完全磁盘访问权限入口

Apple 官方 [NSWorkspace.open(_:)](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:)) 的返回值只说明 URL 是否已打开，不说明系统隐私权限是否已授予。[Apple 平台安全性](https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web) 说明用户控制 App 的文件访问。设置入口使用 macOS 的 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` 页面定位；该定位不是 Apple 承诺稳定的公共 API，因此始终提供手动导航文案，并处理无法打开的情况。真实页面定位与授权结果列入人工验收。

访问状态按用户选择采用实际目录访问验证，不冒充系统授权开关查询：以受限 FD 打开当前用户 Cookies 目录并尝试读取一个目录项，只有成功才显示“访问已验证”。刷新时机参考 Apple [didBecomeActiveNotification](https://developer.apple.com/documentation/appkit/nsapplication/didbecomeactivenotification)，绿色语义使用 [tint(_:)](https://developer.apple.com/documentation/swiftui/view/tint(_:)-93mfq)。目录缺失、权限拒绝和其他错误不等同于已授权，不触碰 TCC 数据库。


### PermissionFlow 拖拽授权引导

使用上游 [PermissionFlow 固定提交](https://github.com/jaywcjlove/PermissionFlow/tree/65434c9ae04dba97cf52c1dffbe3e4e62b547c82) 的原版 core 与 SystemSettingsKit，按 MIT 许可作为本地 Swift Package 维护。保留上游面板、拖拽和单屏跟随几何，修正拖拽提示字号、系统“减少动态效果”的响应，以及多屏时按系统设置窗口与屏幕最大相交面积选屏；包内记录来源摘要和维护差异。controller 让单次导航返回真实打开结果，并在打开前记住原前台；tracker 将可见目标丢失、冷启动等待和关闭后的排队回调纳入明确生命周期，避免宿主重复打开或引导结束后保留 Timer。原版跟随仅在有效引导期间运行，不请求额外辅助功能授权，不调用上游完整磁盘权限状态 provider。

Apple [NSWorkspace.open(_:)](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:)) 返回打开结果；[optionOnScreenOnly](https://developer.apple.com/documentation/coregraphics/cgwindowlistoption/optiononscreenonly) 只列出可见窗口，进程存在不能等同窗口可见。

### 安装定位与正常退出

[Homebrew Relocated](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cask/artifact/relocated.rb) 区分来源与安装目标，默认目标为来源 basename，target 按实际 appdir 解析；[Cask](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cask/cask.rb) 输出实际 target，配置保存在 caskroom/token/.metadata/config.json。[VS Code](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/v/visual-studio-code.rb)、[Chrome](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/g/google-chrome.rb) 的准确残留路径说明仅按应用名称拼接目录不足；[Zoom](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/z/zoom.rb) 的 pkg 与明确 uninstall.delete 则说明需要识别非直接 app artifact。

Apple [NSRunningApplication.terminate()](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate()) 仅发送正常退出请求，必须等待 isTerminated。Cellar 使用该属性的 KVO 确认，拒绝或超时不强杀；清理前仍核对运行状态和已确认文件身份。自动验证只使用临时目录、假运行实例和假 brew，不操作用户真实软件。

### Cask 安装定义与卸载依据

核查 Homebrew 固定提交 `53c5856230b72e866ee4da77cfb9d39880291a99`：

- [CaskLoader](https://github.com/Homebrew/brew/blob/53c5856230b72e866ee4da77cfb9d39880291a99/Library/Homebrew/cask/cask_loader.rb)：`load_prefer_installed` 先尝试当前定义，仅不可用时退回安装定义；名称不代表 artifacts 来自安装版本。
- [Caskroom](https://github.com/Homebrew/brew/blob/53c5856230b72e866ee4da77cfb9d39880291a99/Library/Homebrew/cask/caskroom.rb)：安装快照按各版本下的最新 timestamp 选择，文件优先级为 `.json`、`.internal.json`、`.rb`。
- [Cask Tab](https://github.com/Homebrew/brew/blob/53c5856230b72e866ee4da77cfb9d39880291a99/Library/Homebrew/cask/tab.rb)：`INSTALL_RECEIPT.json` 保存安装来源和 `uninstall_artifacts`；后者包含安装时的卸载与 zap 声明。compact JSON 自带 artifacts 时优先使用，否则使用收据声明，不从当前 API 补齐删除授权。

Homebrew 5.0 的 [Installer 保存原始 API JSON](https://github.com/Homebrew/brew/blob/5.0.0/Library/Homebrew/cask/installer.rb#L506)，其 [API Loader](https://github.com/Homebrew/brew/blob/5.0.0/Library/Homebrew/cask/cask_loader.rb#L338) 随后才合并平台变体、展开占位符；旧完整 JSON 不能直接作为已解析安装清单。Cellar 使用安装收据中的 resolved uninstall artifacts；精简安装 JSON 保留显式清单语义。[Caskroom 安装定位](https://github.com/Homebrew/brew/blob/53c5856230b72e866ee4da77cfb9d39880291a99/Library/Homebrew/cask/caskroom.rb#L47) 同时考虑 old_tokens，因此当前软件名称和物理安装目录名称分开保存，不通过模糊搜索补全。

项目推论：增强卸载通过本机结构化记录建立应用身份及清理声明并绑定文件指纹；旧 Ruby 快照只作安装来源证据，不在 Cellar 中解析或执行。结构化安装归属无法确认时，明确报告不完整并保留关联数据。
