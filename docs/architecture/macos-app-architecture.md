# Cellar macOS App 架构

状态：1.0 目标架构；当前基线已单独标注

更新日期：2026-10-04

本文描述实现 [Cellar 1.0 产品契约](../requirements/product-requirements.md)时必须保持的组件、数据流和安全边界。构建与测试见[开发指南](../development.md)，外部依据见[研究文档](../research.md)。

## 系统定位

Cellar 是单进程、非沙盒的原生 macOS 前台应用。SwiftUI 负责窗口、页面和 Settings scene；Foundation 负责网络、文件与进程边界；少量 AppKit 负责退出策略、系统打开行为和平台集成。App 没有后台守护进程、菜单栏入口或 Privileged Helper。

1.0 使用任务导向的信息架构，但不会把 Homebrew Formula、Homebrew Cask、npm、Node/nvm 和 Shell 压缩成一个通用命令协议。统一发生在展示与编排层；身份、环境、计划和执行仍由 typed model 与 provider client 保留。

## 当前基线与目标差异

当前源码已经实现：

- Overview/Homebrew/Node/Shell/Activity 的技术模块导航和主窗口内 Settings 页面；
- `AppModel` 状态、全局操作登记、启动刷新和内存中最多 100 条诊断 Activity；
- typed batch prepare/execute、可取消任务与最多 100 条结构化 Activity 持久摘要；
- Homebrew 直接 Bridge、Node Manager schema v1、Shell schema v1 adapter；
- 强类型计划、确认、单写操作、post-refresh、部分失败和进程组取消基础；
- Manager 版本化安装、Sparkle、arm64/macOS 26 构建边界。

1.0 要把这些能力组合为 Home/Library/Discover/Updates/Tools、底部 Activity 与标准 Settings scene，并将目录/setup、batch、取消和持久 Activity 接入任务页面，完成 String Catalog 与卡片展示。完成前，目标架构不能被描述为当前已交付实现。

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
- 结果包含每项 success/failure/cancelled/unknown 与整体 partial completion。

全局 mutation slot 覆盖 Homebrew、npm、Node、Registry、Shell 与 setup 写入，防止跨模块同时修改环境。只读刷新与 mutation 是否能并行由当前状态一致性契约决定；不能证明安全时拒绝刷新而非返回混合快照。

当前 `BatchOperationCoordinator` 在确认前准备有序单项计划，整批计划只能消费一次。执行通过 `ProviderBatchOperations` 复用既有 Homebrew/npm client；npm 在计划和执行前核对明确的已安装 Node/npm 环境，不回退到默认版本。`OperationStore` 登记覆盖执行、取消后的进程回收及最终复查；可取消 worker 与最终复查分开，取消不打断复查。Homebrew 保留单项执行契约要求的安全复查，再执行一次整批最终复查。最终复查失败独立报告，既有逐项结果保持不变。现有单项 Homebrew、Node 与 Shell 写操作也使用相同的取消登记。

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

当前 `HomebrewReleaseClient`、`HomebrewInstallerTrustClient` 和 `HomebrewSetupService` 已提供这些边界，尚未接入页面。失败或取消会删除本次自有临时目录；成功打开后保留安装包，调用方在系统安装流程结束后通过 `finishInstallerHandoff()` 释放，期间拒绝重复发起。系统打开成功不代表安装完成。

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
