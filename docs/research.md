# Cellar 研究依据

更新日期：2026-09-20

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
| macOS 会把 `navigationSubtitle` 与导航标题一起显示在 titlebar | Apple 官方 | [navigationSubtitle(_:)](https://developer.apple.com/documentation/swiftui/view/navigationsubtitle(_:)-262n7) |
| `Divider` 在非 Stack 环境中水平延伸，可分隔 titlebar 与详情内容 | Apple 官方 | [Divider](https://developer.apple.com/documentation/swiftui/divider) |
| `GroupBox` 用于视觉上归组相关内容，弹性 frame 可以采用父级提供的完整宽度 | Apple 官方 | [GroupBox](https://developer.apple.com/documentation/swiftui/groupbox)、[frame](https://developer.apple.com/documentation/swiftui/view/frame(minwidth:idealwidth:maxwidth:minheight:idealheight:maxheight:alignment:)) |
| 内容较多时可以用 disclosure control 组织 Sidebar 层级；Sidebar 通常不应超过两级 | Apple 官方 | [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[DisclosureGroup](https://developer.apple.com/documentation/swiftui/disclosuregroup) |
| `scrollIndicators(.hidden)` 可以隐藏直接 `ScrollView` 的滚动指示器，同时保留滚动行为 | Apple 官方 | [scrollIndicators(_:axes:)](https://developer.apple.com/documentation/swiftui/view/scrollindicators(_:axes:)) |
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

当前 `ProcessRunner` 使用明确 executable、参数、环境、空 stdin 和分离 pipe。Apple 文档也说明 `terminate()` 不是强制终止保证，因此 deadline、升级到强制终止和子进程组策略仍需要单独设计，不能用现有取消路径冒充完整超时支持。

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

由上述语义得到的项目边界：查询与写操作都可能联网并更新 Homebrew 自己的 cache；写命令不是事务。Cellar 在确认前展示计划，在命令结束后重新查询真实状态。Formula/Cask 卸载显式设置禁止自动更新和 autoremove；Cask artifact 仅用于 standard/zap 影响说明和 postflight 报告，App 不自行删除文件。

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

`npm outdated` 的退出码 1 可以表示“存在更新”，不一定是执行错误。Cellar 使用的 Node Manager 已把这一语义转换成统一 JSON envelope；Swift 层只解析该契约，不重新解释 npm 原始文本。

## UI 状态

| 结论 | 分类 | 依据 |
|---|---|---|
| `Table` 适合展示可滚动的多列集合 | Apple 官方 | [Table](https://developer.apple.com/documentation/swiftui/table) |
| `ContentUnavailableView` 适合空数据和错误等无法展示内容的状态 | Apple 官方 | [ContentUnavailableView](https://developer.apple.com/documentation/swiftui/contentunavailableview) |
| Node 包列表使用 `Table`，模块失败使用明确空态，不用空表伪装成功 | 项目推论 | 与 v1 状态契约一致 |

## 仍需人工验证

- 首次窗口尺寸、窗口恢复和用户调整。
- `Command-Q`、关闭最后窗口和活动任务组合。
- Finder 启动下对 `/opt/homebrew` 和默认 nvm Node 的发现。
- `npm outdated` 在离线、registry 超时、认证失败和代理环境下的表现。
- App 退出后是否存在遗留的 bash、npm 或 brew 子进程。
- 中文 UI 在 1080 × 720 及更窄窗口中的截断和可读性。

这些项目进入[人工验收清单](manual-smoke-checklist.md)。人工验证失败时修改实现或收缩产品承诺，不增加未经证明的 fallback。
