# Cellar 研究依据

更新日期：2026-09-19

本文保存会影响 Cellar 架构和产品承诺的外部依据。实现事实以代码和测试为准；本文件区分官方文档、源码证据和项目推论，避免把尚未人工验证的行为写成平台保证。

## 证据分类

| 分类 | 含义 |
|---|---|
| Apple 官方 | Apple Developer Documentation、技术说明或系统发布说明直接描述 |
| npm 官方 | npm CLI 官方文档或 npm/cli 源码直接描述 |
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
