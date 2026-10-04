# Cellar macOS App 架构

状态：1.0 目标架构；当前基线已单独标注

更新日期：2026-10-04

本文描述实现 [Cellar 1.0 产品契约](../requirements/product-requirements.md)时必须保持的组件、数据流和安全边界。构建与测试见[开发指南](../development.md)，外部依据见[研究文档](../research.md)。

## 系统定位

Cellar 是单进程、非沙盒的原生 macOS 前台应用。SwiftUI 负责窗口、页面和 Settings scene；Foundation 负责网络、文件与进程边界；少量 AppKit 负责退出策略、系统打开行为和平台集成。App 没有后台守护进程、菜单栏入口或 Privileged Helper。

1.0 使用任务导向的信息架构，但不会把 Homebrew Formula、Homebrew Cask、npm、Node/nvm 和 Shell 压缩成一个通用命令协议。统一发生在展示与编排层；身份、环境、计划和执行仍由 typed model 与 provider client 保留。

## 当前基线与目标差异

当前源码已经实现：

- Home/Library/Discover/Updates/Tools 与底部 Activity 的原生任务导航、独立 Settings scene 和 General/Sources/Terminal/About 四个 pane；
- Home 已显示 Homebrew 与 Node/npm/nvm 的本机摘要、独立线上版本检查和内联安装指引；Library 已接入本机卡片、可见 scope、本地搜索和任务专用卸载确认；Discover/Updates/Tools/Activity、Sources 与 Terminal 仍显示明确的未开放占位；既有 provider 页面和业务实现保留供后续任务接入，不再作为主窗口路由；
- 共享目录卡片与自适应网格已提供类型、版本语义、目标 Node 环境、进度、单一主动作和网站链接，卡片本体不响应点击；
- shell/Settings 的三语 String Catalog、默认 Follow System、受操作退出保护约束的语言切换与受控重启；
- `AppModel` 状态、全局操作登记、启动刷新和内存中最多 100 条诊断 Activity；
- typed batch prepare/execute、可取消任务与最多 100 条结构化 Activity 持久摘要；
- Homebrew 直接 Bridge、Node Manager schema v1、Shell schema v1 adapter；
- 强类型计划、确认、单写操作、post-refresh、部分失败和进程组取消基础；
- Manager 版本化安装、Sparkle、arm64/macOS 26 构建边界。

1.0 仍需将目录、batch、持久 Activity 和 provider 设置接入对应任务页面，并完成这些页面的 String Catalog。完成前，目标架构不能被描述为当前已交付实现。

## 分层与依赖

```text
SwiftUI Features / Settings
            ↓ user intent + presentation state
App state / Coordinators / Activity store
            ↓ typed operations and queries
Provider services / Setup services / Manager clients
            ↓ bounded clients
ProcessRunner / URLSession / FileManager / system open APIs
            ↓
Homebrew / npm / nvm / Zsh / official endpoints / macOS Installer
```

- `Features` 展示状态并发送用户意图，不构造命令、不直接读写文件。
- `Models` 表达 provider identity、Node environment、version status、card state、typed operation 和 per-item outcome，不执行 IO。
- `Services` 负责本地优先刷新、bounded concurrency、batch 编排、Activity 摘要和跨模块状态。
- `Bridge`/client 封装外部进程、网络、环境、schema 和平台 API，不依赖具体页面。
- provider-specific client 不被“generic command executor”替代。

仓库继续沿用 `Features → Services → Bridge → 外部系统` 的方向。新增类型优先放入现有职责目录；不为目标架构提前建立没有当前用途的抽象层。

## Scene、导航与生命周期

`CellarApp` 提供普通 `WindowGroup` 和标准 SwiftUI `Settings` scene。主窗口首次默认内容尺寸为 1080 × 720 点；不设置 `LSUIElement`，不声明 `MenuBarExtra`。

主 `NavigationSplitView` 只包含 Home、Library、Discover、Updates、Tools，Activity 固定在 Sidebar 底部。Settings 由系统菜单和标准快捷键打开，含 General、Sources、Terminal、About panes。

`OperationStore` 是退出保护的事实来源：

- 没有活动任务时，`Command-Q` 与关闭最后窗口可以退出；
- 有活动任务时，`AppDelegate` 拒绝本次终止；
- 可取消任务在界面提供取消，任务结束后用户再次退出；
- App 退出后不得留下由 Cellar 启动的子进程。

菜单命令与 toolbar 动作共享同一 intent，不复制业务执行路径。

当前 shell 的刷新、Activity 导航和取消共同进入 `AppModel.performShellAction`；系统 `SidebarCommands` 提供侧边栏显隐。Library 使用原生 toolbar search，通过 focused scene intent 将 Find in Library（Command-F）与实际搜索焦点绑定；Manage 菜单与 toolbar 共用模式切换。尚无实际搜索内容的页面不提供搜索命令。Settings 由原生 `TabView` 管理 pane，保留最近所选 pane；About 保留 Sparkle 检查、版本、更新通道和开源入口。

## 状态与刷新

主状态所有者保持 `@MainActor`。启动加载分两阶段：

```text
install/reuse Manager snapshot
              ↓
read local Homebrew + Node/npm/nvm + Shell state
              ↓ publish immediately
start bounded independent online checks
              ↓
merge official versions / updates / partial errors
```

Hosted XCTest 仍通过测试进程环境禁止自动刷新。一个 provider、一个分区或一项线上检查失败时，只更新对应 error state，不清空已经成功的数据。

Home 的本机读取跳过 Homebrew/npm outdated 查询，先发布版本、清单和配置。本机刷新结束后，视图生命周期通过 `OperationStore` 登记一个可取消任务，并发持有两个 provider 的 outdated 查询和四个官方版本来源，各自独立发布结果、状态与检查时间；菜单/toolbar 的取消到达全部子读取，进程回收和子任务结束前继续拒绝退出。离开 Home 或新一轮刷新会取消旧任务，旧结果不能覆盖新任务状态，失效的 loading 状态会明确结束。同一次已完成的本机刷新不重复检查，空闲时没有循环。本机 Homebrew/Node 读取失败时保留先前成功快照与其时间，并单独显示刷新失败；outdated 失败只改变相应更新状态，不清空核心数据。npm outdated 保留核心快照的精确 Node/npm 可执行路径，先验证入口仍可执行，再复验路径、版本与全局目录，不按版本或 nvm default 重新选择环境。既有完整快照 API 继续供操作前后校验使用。

快速返回 Home 时，新请求只等待此前 Home owner 的取消与清理完成，随后复验自身生命周期、刷新时间和操作槽；不等待其他模块的任务，也不在其他任务结束后自动启动过期检查。同一轮健康的重叠请求共享已有 owner。owner 先释放操作槽再完成，确保有效的接管请求不会因旧槽仍忙而永久跳过；菜单取消同时撤销尚未接管的 Home 请求。

刷新与写操作不使用轮询。独立 IO 可以有界并发；批量 mutation 必须顺序执行。状态模型区分 not loaded、loading、available、partial failure 和 unavailable，不能用空集合替代失败。

## Catalog 与展示模型

共享卡片模型只包含展示所需字段和 typed action：provider/type、稳定 identity、名称、两行说明、current/available version、semantic status、website URL、Node environment、progress 和一个 primary action。

共享模型不丢失以下不变量：

- Formula 与 Cask identity 不可互换；
- npm package identity 包含明确 Node environment；
- `ahead`/`unknown` 不生成 update action；
- website URL 只交给系统打开，不在 App 内嵌浏览器；
- Cask icon 只来自低成本、明确的本机资源，否则使用 symbol。

Local library 从本机 provider 状态派生。Discover 通过官方 Homebrew 数据/受控 `brew` 查询和 npm Registry search 获取有界结果。Home 与 Updates 把本机状态和异步线上结果合并，但保持不同错误来源。

Library 的 All/Homebrew/npm 与 Homebrew All/Formula/Cask 筛选只处理已有快照，不发起网络或完整目录请求。npm identity 保留当前受控 Node executable 身份和 Node/npm 版本；未完成或失败的 enrichment 显示 unknown。Manage 一次只选择 Formula、Cask、npm 或独立 Node runtime 范围，最多 100 项；单项和批量都复用 typed coordinator，在唯一的任务专用确认之后执行。Library 的 Cask 卸载仅提供 standard；artifact 在确认前展示、执行后报告，不由 App 删除。

## Operation 与 batch coordinator

现有 provider plan 继续作为内部安全机制。普通 UI 不呈现通用“计划”页面；Feature 按产品确认矩阵决定直接提交或显示任务专用确认。

```text
intent → validate boundary → typed plan/fingerprint
       → optional task confirmation → acquire global mutation slot
       → execute one typed item → capture outcome
       → continue/stop-on-cancel → post-refresh → Activity summary
```

Batch coordinator 只组合现有单项 typed operation：

- 每次提交一个 provider/type；
- install/update/uninstall 按项目顺序执行；
- 项目失败后继续，用户取消后不开始后续项目；
- 不回滚已经完成的项目；
- 安全时整批结束后统一 post-refresh，否则 provider 单项契约要求的 refresh 优先；
- 结果包含每项 success/partial/failure/cancelled/unknown 与整体 partial completion。

全局 mutation slot 覆盖 Homebrew、npm、Node、Registry、Shell 与 setup 写入，防止跨模块同时修改环境。只读刷新与 mutation 是否能并行由当前状态一致性契约决定；不能证明安全时拒绝刷新而非返回混合快照。

当前 `BatchOperationCoordinator` 在确认前准备有序单项计划，整批计划只能消费一次。执行通过 `ProviderBatchOperations` 复用既有 Homebrew/npm client；npm 核对明确安装中的实际 Node/npm 入口与版本，计划、执行和复查复用验证后固定的 environment，PATH 只包含该安装的 bin 与系统工具路径，禁止其他 provider 提供 fallback。npm 复查合并时同步 App 内后续操作使用的 Node 会话版本。`OperationStore` 登记覆盖执行、取消后的进程回收及最终复查；可取消 worker 与最终复查分开，取消不打断复查。Homebrew 保留单项执行契约要求的安全复查，再执行一次整批最终复查；provider partial 单独保留为逐项部分完成，并计入整体部分完成。最终复查失败独立报告，既有逐项结果保持不变。现有单项 Homebrew、Node 与 Shell 写操作也使用相同的取消登记。

Node runtime 卸载批次与 npm 包批次使用不同 identity 和 scope，但均绑定确认中显示的受控 Node 环境。Bridge 执行前重新读取 Node runtime 计划，复验当前/default、精确目标目录及其全局包摘要；provider 对当前、默认或无法可靠读取的版本的拒绝仍生效。批次完成后只进行一次最终 Node 环境复查；Activity 保存独立的 Node runtime scope，清除环境路径后只保留版本语义。

npm 卸载的确认状态在当前会话中保存规范化的 Node/npm executable、globalPrefix 和 globalRoot。打开单次写入 gate 前重新读取同一环境的包计划及最终 summary，确认 package identity、installedVersion 和精确全局目标目录没有变化；变化后拒绝旧确认，不把同版本的其他 Node executable 当作已确认环境。原计划的有效期和 token 不因复验而延长。Manager 的 uninstall `warn`/零退出/`residue-detected` 表示移除成功但有残留，协调器保留为 partiallySucceeded；路径仅在当前会话 Library 结果中以可复制文字展示，不写入 Activity，也不由 App 删除。

Homebrew 整批最终复查遇到 packages 分区错误时视为 reconciliation failed，不发布空安装清单作为新快照。AppModel 保留先前成功的 Homebrew 快照与刷新时间，同时发布失败状态；Library 显示复查失败提示，逐项执行结果仍保留。

## Activity 与持久化

Activity store 保存最多 100 条结构化、可本地化的用户摘要。持久模型包含稳定 operation kind、provider scope、目标显示标识、时间、状态和 per-item outcomes；不保存命令行、完整 stdout/stderr、环境、token、registry credential 或不必要的绝对用户路径。

原始输出只在当前 App 会话的内存诊断对象或既有受控 Manager 日志中存在。UI 的“复制诊断”显式组合可公开信息，持久化前执行 sanitizer。Activity 文件位于 Cellar 自有 Application Support 范围，并通过可注入根目录测试；损坏数据作为独立读取错误处理，不阻止环境状态加载。

当前 `ActivityStore` 将 schema v1 摘要原子写入 `~/Library/Application Support/Cellar/Activity/activity.json`，保留最近 100 条并限制单文件大小为 1 MiB。持久目标使用 provider 包标识；npm 仅保留 Node/npm 版本与由版本派生的标识，不保留原始环境标识或安装路径。损坏或不支持版本的文件移到同一自有目录中的唯一 `.isolated` 文件并公开独立错误；写入失败保留原文件与内存摘要。旧 `ActivityEntry` 不迁移、不持久化。Hosted XCTest 不加载真实 Activity store。

## Homebrew

本机 Homebrew 操作继续由 client 使用已发现的绝对 `brew`、参数数组、受控环境、空 stdin 和分离输出执行，不驱动交互式 Homebrew Manager。

- Formula/Cask 查询保持类型；安装、更新和卸载显式传递类型。
- 搜索和详情结果有界；空查询不抓取完整目录。
- `brew update` 是独立 metadata operation。
- 卸载设置 `HOMEBREW_NO_AUTO_UPDATE` 与 `HOMEBREW_NO_AUTOREMOVE`。
- Cask standard/zap 是不同 typed intent；App 不删除 artifact。
- Tap 移除在执行前复验关联安装项，存在阻塞项时拒绝。
- 非零退出也可能部分改变状态，因此命令结果与 post-refresh 都保留。

### Homebrew setup

Setup service 把职责拆开且可注入：Homebrew 官方 latest stable Release metadata client、bounded downloader、SHA-256 validator、package-signature validator、Gatekeeper assessor、临时文件 owner 与 system opener。metadata 必须给出精确 `Homebrew.pkg` 的有效官方 SHA-256；digest 缺失/无效/不匹配、package signature 无法完成或无效、Gatekeeper assessment 无法完成或失败时一律 fail closed，不打开 package，并返回具体原因与 Homebrew 官方网站链接。不得降级为 shell installer。

当前 `HomebrewReleaseClient`、`HomebrewInstallerTrustClient` 和 `HomebrewSetupService` 已通过 Home 的显式按钮接入。失败或取消会删除本次自有临时目录；成功打开后保留安装包，用户确认系统安装已完成或取消后，Home 通过 `finishInstallerHandoff()` 释放并显式刷新本机状态，期间拒绝重复发起。系统打开成功不代表安装完成；释放失败时保留交接状态以允许再次尝试。已存在 Homebrew 目录但未检测到可用安装时不提供覆盖安装动作。

Homebrew 安装动作重新检测 CLT 与目标占用情况；setup service 的可注入 eligibility guard 在开始时和下载、digest、signature、Gatekeeper 全部通过后、紧邻系统 opener 之前再次执行。目录/文件占用、断开符号链接、访问失败或无法确定的目标均 fail closed，并返回结构化原因和官方链接，不使用首屏缓存状态作为交接授权。

通过系统 Installer 打开包不等于 Cellar 获得提权能力。Cellar 只请求系统打开已验证 package；系统随后实际显示的许可、认证或权限提示不属于 Cellar 契约。Cellar 不运行 `sudo`、不收集密码、不实现安装步骤。已检测到异常 Homebrew 时只提供诊断和官方恢复入口，不覆盖或删除现有目录。

Command Line Tools service 只检测状态并执行 Apple 文档规定的 `xcode-select --install`，由系统显示安装对话框；自动测试替换该边界，不弹系统 UI。nvm setup 只提供官方指引，不执行远端脚本。

## Node、npm 与 nvm

`NodeEnvironmentResolver` 继续从默认 `~/.nvm` 解析 `alias/default`，支持明确版本、数字前缀、`node`、`stable` 和 alias 链，检测循环；解析失败不选择任意最新版本。受控 PATH 不加载 `.zshrc`。

`NodeManagerClient` 继续使用 schema v1。核心本地读取与 `outdated`/线上版本错误分开。Mutation 只有在单次执行环境中打开 JSON execute gate，项目 `.nvmrc` 使用额外 project-write gate。

npm 目录能力只针对全局包：

- Library/Updates identity 包含当前受控 Node environment；
- Discover 使用用户选择/有效 Registry 的有界 search client；
- install/update/uninstall 只在卡片和确认中标注的 Node 环境执行；
- Registry 管理位于 Settings > Sources，Node runtime 位于 Tools；
- current/wanted/latest 不能比较时产生 `unknown`，不得猜测或自动降级。

## Shell 与 Settings

冻结的 `omz-manager.sh` 与来源逐字节一致。Cellar-owned `app-json.sh` 和模块继续作为独立 schema v1 adapter，不驱动交互菜单。

Settings > Terminal 读取内置/已安装插件与本机主题。自定义插件只接受规范化 GitHub HTTPS repository URL。一次 Apply 生成 typed plan，覆盖 `.zshrc` 状态 token，执行前复验，修改前备份普通文件并用 `zsh -n` 验证。符号链接或非普通 `.zshrc` 拒绝写入；不运行 `chsh`。

Zsh tidy 位于 Tools，只移动计划列出的受限文件到 `~/.zsh`，不删除用户数据。Oh My Zsh 安装继续设置 `RUNZSH=no`、`CHSH=no`、`KEEP_ZSHRC=yes`。

## 进程、网络与文件边界

`ProcessRunner` 继续为每个请求创建独立进程组，并明确 executable、arguments、environment、working directory、stdin/stdout/stderr、deadline 和每路 2 MiB 输出上限。取消/超时先发送 `SIGTERM`，500 ms 宽限后向仍存活的专属组发送 `SIGKILL`。不使用 `bash -c`。

网络 client 使用可注入 session、明确官方 host/用户配置来源、bounded response、deadline、取消和适当的 ETag/cache 语义。网络失败不触发无限重试或 polling。

当前 `CatalogHTTPClient` 使用有界内存 ETag 缓存，并遵守 `no-store`；`NPMRegistryClient` 将有界搜索结果绑定到调用方明确提供的 Node environment 和 Registry origin，用户明确配置的 Registry 可使用无凭证的 HTTP 或 HTTPS，不能跨 origin 响应或重定向；`NodeVersionMetadataClient` 并发查询三个官方版本来源并分别保留失败。内置官方来源保持 HTTPS；Homebrew 下载仅允许官方 GitHub HTTPS 资产来源及其 HTTPS Release CDN，按官方资产大小流式写入自有临时文件。网站链接只接受无凭证的 HTTP/HTTPS URL。

Manager 从只读 Bundle 快照安装到版本化 Application Support：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

运行时文件、Activity 与下载临时文件只写入各自 Cellar-owned 可写位置。安装包临时文件在交给系统打开或失败后按明确生命周期处理，不写入 Bundle，也不触碰用户包管理目录。

## 本地化与可访问性

所有用户可见静态字符串进入 String Catalog，支持 English、简体中文和繁体中文。Follow System 不覆盖系统首选语言；显式选择只影响 Cellar。持久 Activity 保存语义数据而不是已渲染句子，以便按当前语言显示。

应用语言偏好写入 App 自有 UserDefaults：Follow System 删除 App 域内 `AppleLanguages`，显式选择写入单一受支持语言。确认后通过受控退出和 `applicationWillTerminate` 中的一次新实例请求重启，使 Bundle 与系统菜单在新进程中使用一致语言。有活动操作时不提交语言变更；退出复验拒绝时恢复 App 域内原语言偏好与精确的 `AppleLanguages` 前态（包含键不存在），清除待重启状态并向 Settings 发布恢复后的选择，允许任务结束后重试。测试注入独立 defaults suite/domain、终止与重开闭包，生产重开入口另有 hosted XCTest 保护。

卡片、scope、状态、进度、错误和确认使用语义 label/value/hint，键盘顺序与视觉顺序一致。实现遵守系统 contrast、Reduce Motion 和 Reduce Transparency，不用颜色作为唯一信号。

## 测试与稳定不变量

自动测试使用 fake process、fake network、fixture、临时 HOME 和临时 Application Support；不得访问或修改真实 brew、npm、nvm、Zsh、Registry、Installer 或用户项目。

稳定不变量：

- View 不执行 IO，Models 不执行 IO；
- provider identity 和 Node environment 不在统一 UI 中丢失；
- 写任务全局互斥，批量顺序执行，失败不伪装成回滚；
- 只有产品契约允许的动作可以修改环境；
- 不执行 Homebrew cleanup、autoremove、App 自行 Cask 删除、`sudo` 或 `chsh`；
- 不修改冻结 `scripts/`，App-owned adapter 与快照来源分开；
- 不向 Bundle Resources 写入，不让自动测试触碰真实用户状态；
- 发布产物最低 macOS 26.0 且所有 Mach-O 只有 arm64。
