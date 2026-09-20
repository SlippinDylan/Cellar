# Cellar macOS App 架构

状态：当前实现

更新日期：2026-09-20

本文描述 Cellar v1 的组件、数据流和长期边界。页面行为见[产品需求](../requirements/product-requirements.md)，构建和测试见[开发指南](../development.md)，平台依据见[研究文档](../research.md)。

## 系统定位

Cellar 是单进程、非沙盒的原生 macOS 前台应用。它读取 Homebrew、Node/npm/nvm、Zsh 和 Oh My Zsh 状态，并提供受控的 Homebrew 管理操作。它不包含后台守护进程、菜单栏入口或 Privileged Helper。

App 使用 SwiftUI 构建窗口和页面，Foundation 负责文件与进程边界，AppKit delegate 处理退出请求。Node 使用随 App 打包的 Manager 机器协议，Homebrew 由 Bridge 直接调用绝对 `brew`，Shell 使用 App 专用 adapter 复用冻结 Manager 的配置函数。

## 仓库与组件

```text
Cellar/
├── CellarApp.swift             Scene、AppDelegate、退出策略
├── Features/                   页面、导航和展示
│   ├── Overview/
│   ├── Homebrew/
│   ├── Node/
│   ├── Shell/
│   └── Activity/
├── Services/                   App 状态、任务登记和探测编排
├── Models/                     页面状态与 JSON DTO
├── Bridge/                     Process、环境、快照和 Node Manager
├── Resources/Managers/         只读 Manager 快照
├── CellarTests/                单元与边界测试
├── scripts/                    冻结的 CLI Manager 来源
└── docs/                       产品与工程文档
```

依赖方向：

```text
Features → Services → Bridge → Manager / 系统 CLI
                ↓
              Models
```

- `Features` 展示状态并发送用户意图，不构造命令。
- `Services` 负责刷新流程和跨模块组合。
- `Bridge` 封装 IO、进程、环境和机器协议。
- `Models` 不执行 IO。
- `Resources/Managers` 是来源快照，不承载 App 专属适配。

## 应用生命周期

`CellarApp` 使用 `WindowGroup` 创建普通前台窗口，并通过 `defaultSize(width:height:)` 设置 1080 × 720 点的首次默认尺寸。App 不设置 `LSUIElement`，也不声明 `MenuBarExtra`。

`AppRootView` 统一为当前一级页面设置 `navigationTitle` 和 `navigationSubtitle`，并在 titlebar 下方绘制水平分割线。概览的最后刷新时间附在副标题后。各页面不再重复绘制内容区大标题，内容使用统一的 24pt 边距；概览使用两列状态卡片，模块页的横向状态总览卡占满内容宽度。

首次读取期间，各页面复用 `PageLoadingView` 占满详情区域并将 `ProgressView` 水平、垂直居中。失败空态同样占满详情区域，不依赖固定高度模拟居中。

左侧 Sidebar 使用 `DisclosureGroup` 表达两级导航。Homebrew、Node 和 Shell 是只负责展开收起的一级分类；具体页面是可选择的第二级项目，每个分类都以“概览”为首项。展开状态由 `AppRootView` 的本地 `@State` 持有，当前页面由 `AppModel.selectedDestination` 统一保存。三个模块的二级页面均承载对应真实功能。

左侧导航不使用会自行管理 AppKit scroller 的 SwiftUI `List`。它由 `ScrollView`、`LazyVStack`、`DisclosureGroup` 和自定义选择行组成，并通过 `scrollIndicators(.hidden)` 隐藏直接 ScrollView 的 indicator。滚轮和触控板滚动、分类展开、缩进与选择高亮仍然可用。

`AppDelegate` 通过 `NSApplicationDelegateAdaptor` 接入 AppKit：

- 关闭最后一个窗口会请求终止应用。
- `OperationStore` 没有活动任务时返回 `.terminateNow`。
- 有活动任务时返回 `.terminateCancel`，任务完成后用户可再次退出。

退出保护只描述当前终止决策。关闭窗口、任务持续时间和真实 `Command-Q` 交互仍需人工验证。

## App 状态与刷新

`AppModel` 是 `@MainActor` 的页面状态所有者。它持有当前页面、各模块状态、错误、刷新时间、操作记录、刷新标志和 Homebrew 操作状态。

正常启动时 `AppRootView.task` 发起一次刷新。刷新流程：

```text
OperationStore.begin
        ↓
安装或复用 Manager 运行快照
        ↓
并行读取 Homebrew / Node / Shell
        ↓
分别写入成功值和错误
        ↓
更新本次会话的 ActivityEntry
        ↓
OperationStore.end
```

`isRefreshing` 保证同一 `AppModel` 不会同时运行两次刷新。Hosted XCTest 通过 `XCTestConfigurationFilePath` 跳过启动自动刷新，避免测试访问真实开发环境。

Homebrew 写操作与全局刷新共享活动任务登记；同一时间只允许一个 Homebrew mutation，执行期间禁用重复提交并应用既有退出保护。操作开始前由 Bridge 生成计划，View 只负责展示计划和发送确认/取消意图。执行结束后无论成功或失败都 post-refresh 受影响状态。

当前操作记录只在内存中存在。没有持久化、独立任务队列或进度百分比。Homebrew 命令不是事务；执行结果记录退出码、stdout、stderr 和 post-refresh 错误，状态层不能把非零退出简单解释成“什么都没发生”。

## Manager 快照

仓库中的 `Resources/Managers/` 包含：

- `node-manager`：按 `scripts/node-manager/app-bundle-manifest.txt` 复制。
- `homebrew-manager`：`main.sh` 和生产 `lib/*.sh`。
- `zsh-manager`：`omz-manager.sh`。
- `SNAPSHOT.md`：来源 commit 和生成说明。

当前快照版本是 `1c9d71b`。`ManagerSnapshotInstaller` 从 `Bundle.main.resourceURL/Managers` 读取资源，并安装到：

```text
~/Library/Application Support/Cellar/Managers/1c9d71b/
```

安装过程先验证三套入口文件，再复制到同级随机 staging 目录，最后移动到版本目录。已有完整版本直接复用；缺少入口文件的版本目录会被删除并重新安装。安装后再次验证入口可读性。

Bundle Resources 不产生运行时写入。Node Manager 的 `.runtime` 位于 Application Support 工作副本内；查询环境关闭 JSON execute，确认后的 mutation 只在单次执行环境中打开对应开关。

当前完整性检查验证入口文件存在和可读，不在运行时计算整套快照的哈希。仓库和发布验收通过逐文件比较保证来源一致。

## 进程边界

`ProcessRunner` 是 actor，保存当前运行的 `Process` 对象。每个请求明确提供：

- executable URL；
- arguments；
- 完整 environment；
- 可选 current directory；
- 空 stdin；
- 分离的 stdout 和 stderr pipe。

stdout 与 stderr 在独立任务中读取，进程结束后返回 `ProcessResult` 和退出码。两路输出默认分别最多保留 8 MiB，超过上限后继续 drain pipe 并在结果中标记截断。请求可以设置 deadline；超时或调用任务取消时向对应进程发送 terminate。App 代码不使用 `bash -c`，Node Manager 通过固定 `/bin/bash` 加脚本路径和参数数组启动。

Homebrew 与 Node 查询使用 5 分钟 deadline，写操作使用 30 分钟 deadline。当前 terminate 仍没有强制终止升级或独立进程组保证；子进程忽略终止信号时仍可能延迟收尾。Shell 请求尚未配置 deadline，界面也没有用户取消入口。

## 受控环境与 Node 选择

`NodeEnvironmentResolver` 不继承用户完整 Shell 环境。它构造包含 HOME、PATH、TMPDIR、locale、NVM_DIR、USER 和 LOGNAME 的明确环境。查询固定关闭 JSON execute；确认执行时由 `NodeManagerClient` 为单次子进程打开，项目写入使用额外独立开关。

PATH 顺序：

1. 能明确解析的 `~/.nvm/alias/default` 对应版本 `bin`；
2. `/opt/homebrew/bin`、`/opt/homebrew/sbin`；
3. `/usr/local/bin`；
4. `/usr/bin`、`/bin`、`/usr/sbin`、`/sbin`。

alias 解析支持三段式版本、数字前缀、`node`、`stable` 和 alias 链，并检测循环。没有明确匹配时不选择任意已安装版本。

当前实现只检查 `~/.nvm`，没有读取自定义 `NVM_DIR`、XDG nvm 目录、asdf、fnm 或 Volta。这些环境不在当前支持保证内。

## Node Manager 协议

`NodeManagerClient` 只使用 schema v1：

```text
main.sh --json summary
main.sh --json packages
main.sh --json config
main.sh --json outdated
```

每次响应必须同时满足：

- 进程退出状态符合命令结果；
- JSON 可以解码为 `ManagerEnvelope<Payload>`；
- `schemaVersion == 1`；
- `ok == true` 且 `data` 存在。

前三项核心命令失败会终止 Node 页面加载。`outdated`、Manager status 和 logs 分别捕获错误；失败时保留核心数据并显示独立错误。

Mutation 使用 Manager 已有的 `plan` 与 `execute` 协议。App 保存结构化计划、五分钟有效期和当前会话选择的 Node 版本；确认后执行，结束后重新读取 summary、packages、config、outdated、已安装版本和维护状态。`node-use` 的进程内结果只作为校验，App 通过受控 PATH 保存本次会话选择，不把它描述成终端状态修改。

Node Manager 入口会加载自己的模块，但 App 不直接调用 `lib/*.sh`，也不驱动交互菜单。

## Homebrew Bridge

Homebrew 探测在受控 PATH 中寻找可执行的 `brew`。找不到时返回“未安装”；找到后固定绝对 executable URL，同一轮查询和操作不再次依赖 PATH 查找。`HomebrewClient` 使用参数数组、受控环境、空 stdin 与分离的 stdout/stderr 调用 Homebrew，不调用 Homebrew Manager 的交互入口。

查询按页面职责拆分：

- 概览读取版本、路径、prefix、repository、cache、Cellar 和计数。
- 已安装与详情优先解析 `brew info --json=v2` 的结构化 Formula/Cask 数据。
- 可升级解析 Homebrew 的 JSON 输出，并保持 Formula/Cask 身份类型。
- 发现分别运行 Formula/Cask 搜索，再按需加载单项 JSON 详情。
- 诊断由用户主动运行；保留诊断退出状态与输出。
- 配置读取 Homebrew 配置与 Tap，Tap 身份保持完整名称。

Homebrew mutation 使用 `HomebrewActionPlan` 表达动作、目标、包类型、Cask 卸载模式、预计命令语义、artifact 和 Tap 关联阻塞项。通用状态流为：

```text
query → plan → confirm → execute → result → post-refresh
```

- 安装与升级始终携带 Formula/Cask 类型，避免同名项目歧义。
- `brew update` 是独立计划，不作为其他动作的隐式前置步骤。
- Formula 卸载只接受一个目标，并显式禁止自动更新和 autoremove。
- Cask standard 与 zap 是两个独立计划；artifact 在确认前展示。Bridge 只检查 Homebrew 明确声明且不含 glob 的绝对路径、`~/` 路径和明确 App bundle，统计现存路径的占用空间；执行后复查并报告仍存在的路径，App 不调用 `rm` 补删文件，也不做 bundle-id 或名称模糊扫描。
- 移除 Tap 前复验该 Tap 关联的已安装 Formula/Cask；存在关联项时拒绝生成可执行计划。

计划确认不是事务边界。Homebrew 可能在非零退出前已经修改依赖、安装目录或 cache，因此结果模型同时保存命令输出和 post-refresh 快照。取消确认会丢弃计划，再次操作时重新生成。

## Shell Manager 协议

冻结的 `omz-manager.sh` 保持与 `scripts/zsh/omz-manager.sh` 逐字节一致。相邻的 Cellar-owned `app-json.sh` 和 `lib/app_json_*.sh` 作为 schema v1 adapter，source 冻结脚本以复用其解析、managed block、备份和整理函数，但不调用交互菜单。

adapter 提供 `snapshot`、`plan` 和 `execute`。查询环境关闭 execute；确认后单次环境打开。计划 token 覆盖 `.zshrc` 摘要和目标状态，防止确认期间配置漂移。所有运行日志写入 Application Support 工作副本的 `.runtime`，Bundle 内资源保持只读。

## 数据、网络与权限

Cellar 不使用 App Sandbox。Homebrew 功能不调用 `sudo`，也没有 Helper 或 XPC；权限不足时报告错误，不扩大为 App 自行删除或提权操作。

Cellar 自己管理的持久目录是版本化 Manager 运行副本：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

操作记录、页面状态和刷新时间不持久化。App 没有自己的账户、遥测或服务端。`npm outdated` 会访问用户当前配置的 npm registry，并使用 npm 自身的 cache 行为。Homebrew 的搜索、详情、过期检查、Tap、update、安装和升级可能访问 Homebrew 服务或第三方 Tap，并写入 Homebrew 自己管理的 API、下载 cache 和安装状态。

## 设置、About 与更新

操作记录和设置位于 Sidebar 底部 `safeAreaBar`。设置页使用 macOS 26 工具栏与 Liquid Glass selector，在 About 中展示 Bundle 版本并触发 `ApplicationUpdateController`。

更新使用固定 Sparkle 2.10.0。Debug 和普通本地 Release 默认 `CellarUpdaterEnabled=NO`，公钥为空；发布流水线必须从 `SPARKLE_PUBLIC_KEY` Secret 注入公钥并显式启用 updater。Feed 固定为 Homebrew tap GitHub Pages 下的 `cellar/appcast.xml`，stable/beta/alpha 通道由发布 manifest 注入。

Sparkle XCFramework 原始 macOS slice 是 universal。Cellar build phase 只处理当前 `TARGET_BUILD_DIR` 中嵌入的已知 Sparkle Mach-O，裁剪为 arm64；发布流水线随后按嵌套依赖顺序重新签名。Package cache 和源 XCFramework 不修改。

## 测试边界

`CellarTests` 覆盖：

- Manager envelope 和 payload 解码；
- nvm default alias 与版本匹配；
- executable PATH 查找；
- stdout、stderr 和退出码分离；
- Node 部分失败；
- 快照安装到临时 Application Support；
- 活动任务对应的退出策略。
- Homebrew JSON 解码、搜索分型和查询部分失败；
- Homebrew 计划验证、确认边界、精确参数和受控环境；
- 卸载禁止自动更新/autoremove、Tap 关联阻塞和 mutation 后刷新；
- 使用假 brew 模拟成功、失败和部分完成，不访问用户真实 Homebrew 或网络。

测试通过依赖注入、临时目录和假 Manager 隔离副作用，不读取用户真实包管理状态。真实 Finder 启动环境、brew/npm/nvm 组合、registry 网络和窗口交互由人工清单验证。

## 平台与构建

工程包含 `Cellar` App Target 和 `CellarTests` Target。两者最低部署版本为 macOS 26.0，显式排除 `x86_64`，发布产物只允许 arm64。App Sandbox 关闭。

仓库包含 CI、签名 Release、DMG、Discord 通知以及 Sparkle/Homebrew tap 分发自动化。`Config/Release/manifest.json` 默认关闭发布；缺少 GitHub Secrets 或未执行真实流水线时不能把本地无签名构建描述为正式版本。

## 稳定不变量

- 只有用户确认的 Homebrew、Node 或 Shell 操作可以修改对应状态。
- 不安装 Command Line Tools 或 Homebrew，不修改 `.zprofile`，不执行 cleanup、自动孤儿清理、`sudo` 或 App 自行残留删除。
- Homebrew mutation 必须计划、确认、单操作锁定、执行并 post-refresh；卸载禁止隐式 update 与 autoremove。
- 不把某个 Node 的 npm 全局包描述为整台机器唯一集合。
- 不因更新检查失败丢弃已经读取的 Node 数据。
- 不加载用户 `.zshrc`，不猜测无法解析的 nvm 默认版本。
- 不从 View 直接执行命令，不从 Models 执行 IO。
- 不修改冻结的 `scripts/`，不手工修补 Manager 快照。
- 不在 App Bundle Resources 中写运行数据。
- 不让自动测试访问真实用户环境或 Application Support。

## 当前已知限制

- Homebrew 与 Node 已配置 deadline 和输出上限；Shell 尚未配置 deadline。
- 界面没有用户取消入口；活动任务期间退出被拒绝。
- 自定义 nvm 目录和其他 Node 版本管理器未支持。
- Homebrew 长命令的取消、deadline、强制终止和子进程组策略仍受通用 `ProcessRunner` 限制。
- Homebrew 写操作不是事务，部分完成只能通过命令结果与 post-refresh 准确呈现，不能自动回滚。
- Homebrew 交互 Manager 未接入 App；Zsh 交互菜单也未接入，App 只调用独立 JSON adapter。
- 快照运行时验证入口完整性，不验证全部文件摘要。
- UI 文本当前直接写在 Swift 源码中，没有 String Catalog 和多语言支持。
- 普通 `WindowGroup`、最后窗口关闭和任务期间退出的组合仍需真实窗口验收。
