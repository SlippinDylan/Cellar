# Cellar macOS App 架构

状态：1.0 当前实现；未公开发布

更新日期：2026-11-12

本文描述已实现的 [Cellar 1.0 产品契约](../requirements/product-requirements.md)对应的组件、数据流和安全边界。构建与测试见[开发指南](../development.md)，外部依据见[研究文档](../research.md)。

## 系统定位

Cellar 是单进程、非沙盒的原生 macOS 前台应用。SwiftUI 负责主窗口与页面；Foundation 负责网络、文件与进程边界；少量 AppKit 负责退出策略、系统打开行为和平台集成。App 没有后台守护进程、菜单栏入口或 Privileged Helper。

1.0 使用任务导向的信息架构，但不会把 Homebrew Formula、Homebrew Cask、npm、Node/nvm 和 Shell 压缩成一个通用命令协议。统一发生在展示与编排层；身份、环境、计划和执行仍由 typed model 与 provider client 保留。

## 当前实现

当前源码已经实现：

- Home/Library/Discover/开发环境与底部 Settings/About 的原生任务导航；内部 tools 路由保留，开发环境包含 Node.js/Terminal/Sources/Environment Check，Settings 只提供 App 自身的语言与日志偏好；
- Home 依次显示 Homebrew、Node/npm/nvm 与终端环境摘要，每个统计项使用独立小卡片与品牌色圆角图标底，提供独立线上版本检查和内联安装指引；Library 已接入本机卡片、类型／待更新／搜索交集筛选、单项和批量更新、任务专用卸载确认；Discover 已接入 Formula/Cask/npm 搜索、直接单项安装和一次确认的批量安装；开发环境按 Node.js、终端、软件源与环境检查组织，项目版本归入 Node.js，维护归回对应对象；Sources 已接入 Tap/Registry，Terminal 已接入 Oh My Zsh、实际安装插件和本机主题；任务进度与最近结果跨页面显示，排错记录写入本地文件，环境检查提供显式会话诊断；既有 provider 页面和业务实现保留，不再作为主窗口路由；
- 共享目录卡片与自适应网格已提供软件图标、类型、版本语义、目标 Node 环境、进度、单一主动作和网站链接，卡片本体不响应点击；
- 全部可达页面的三语 String Catalog、默认 Follow System、受操作退出保护约束的语言切换与受控重启；
- `AppModel` 状态、全局操作登记、启动刷新和内存中最多 100 条会话诊断；
- typed batch prepare/execute、受控任务、会话内结构化结果与可配置的文件日志；
- Homebrew 直接 Bridge、Node Manager schema v1、Shell schema v1 adapter；
- 强类型计划、确认、单写操作、post-refresh、部分失败和进程组取消基础；
- Manager 版本化安装、Sparkle、arm64/macOS 26 构建边界。

1.0 源码实现已完成，真实工具、系统 Installer、网络、辅助功能和外观等人工验收仍按清单执行。未经实际验收的行为不能被描述为已验证，源码完成也不表示已公开发布。

## 分层与依赖

```text
SwiftUI Features / Settings
            ↓ user intent + presentation state
App state / Coordinators / Session results / File log store
            ↓ typed operations and queries
Provider services / Setup services / Manager clients
            ↓ bounded clients
ProcessRunner / URLSession / FileManager / system open APIs
            ↓
Homebrew / npm / nvm / Zsh / official endpoints / macOS Installer
```

- `Features` 展示状态并发送用户意图，不构造命令、不直接读写文件。
- `Models` 表达 provider identity、Node environment、version status、card state、typed operation 和 per-item outcome，不执行 IO。
- `Services` 负责本地优先刷新、bounded concurrency、batch 编排、会话结果、本地文件日志和跨模块状态。
- `Bridge`/client 封装外部进程、网络、环境、schema 和平台 API，不依赖具体页面。
- provider-specific client 不被“generic command executor”替代。

仓库沿用 `Features → Services → Bridge → 外部系统` 的方向。新增类型优先放入现有职责目录，不建立没有当前用途的抽象层。

目录图标由 `CatalogIcon.homebrew` 根据明确的官方 Tap 和精确 token 解析，Library/Discover 的卡片状态携带同一图标描述。`CatalogIconView` 仅负责展示及本地占位；独立的 `CatalogIconStore` actor 复用 `CatalogHTTPTransport`，限制 jsDelivr origin、10 秒超时、单张 1 MiB 和 PNG 尺寸／解码校验。最多并发 4 个请求，相同 URL 合并并独立记录每张卡片的订阅；卡片离开时立即结束该订阅，尚未开始且已无订阅的请求从队列移除，不产生失败缓存。已开始的共享请求在期限内完成并缓存，新卡片可重新加入；图标不登记为软件操作或影响退出保护。专用 `URLCache` 限制内存 8 MiB、磁盘 64 MiB，成功缓存 7 天，当前会话失败缓存 5 分钟。不扫描本机 App，不引入 Kingfisher，也不改变安装、更新、卸载流程。

## Scene、导航与生命周期

`CellarApp` 只提供绑定 `MainWindowIdentity.main` 的 typed-value `WindowGroup`，不声明独立 `Settings` scene。主窗口默认及最小内容尺寸均为 1080 × 720 点，通过内容最小尺寸约束保持可放大；不设置 `LSUIElement`，不声明 `MenuBarExtra`。

主 `NavigationSplitView` 的主导航包含 Home、Library、Discover、开发环境（内部 `AppDestination.tools`）；Settings 与 About 通过 Sidebar 的底部 safe-area bar 依次固定在左下方，不再声明 Activity 路由或菜单。Settings 是 `AppDestination.settings`，detail 区域复用 `SettingsView`，共享同一 `AppModel` 与 `OperationStore`。App 菜单和 Command-Comma 经 `AppModel.showDestination` 选择 Settings；About App 命令经同一导航入口选择独立的 AppDestination.about，并复用 App 的 updater controller。两者都以固定主窗口 identity 调用 `openWindow(id:value:)`，复用或重建主窗口。

六个侧边栏入口共用 SwiftUI Button 行，仅由 `selectedDestination` 驱动 10% primary 色的圆角背景，与侧栏材质混合，不使用 `List` 的自动强调色选中高亮。`listItemTint` 只控制内容着色，不能保证获得键盘焦点后仍使用灰色背景。`FocusState` 与方向键事件支持六个入口间的连续导航，首尾不循环；Tab 与按钮激活使用系统焦点机制，关闭自动焦点特效且不另外绘制焦点边框，避免焦点与选中状态产生两个视觉标记。辅助功能保留按钮名称与选中语义，共用 label 保持正常文字和无底色、系统强调色的 SF Symbol。

`OperationStore` 是退出保护的事实来源；空闲退出前会等待文件日志队列完成，等待期间新登记任务仍会阻止退出：

- 没有活动任务时，`Command-Q` 与关闭最后窗口可以退出；
- 有活动任务时，`AppDelegate` 拒绝本次终止；
- 运行中界面只显示进度、不提供手动停止，任务结束后用户再次退出；
- App 退出后不得留下由 Cellar 启动的子进程。

菜单命令与 toolbar 动作共享同一 intent，不复制业务执行路径。

全部主页面统一移除系统 toolbar title item；Home 在 navigation 位置显示本地化的 headline 页面标题，并隐藏该文字项的共享按钮背景。使用弹性 spacer 将动作推到右侧。工具栏背景与滚动边缘采用系统自动行为，不设置强制 `.visible` 或 `.hard`，也不添加自定义 hover 背景。开发环境使用 `ToolbarCategoryPicker` 的原生 `NSSegmentedControl` 切换四个分类，Settings 不再显示分类控件。Home/Library/Discover/About 的滚动容器铺满正文，留白通过 scroll-content margins 应用于内容。开发环境与 Settings 沿用 SettingsPage / SettingsSection 的单列分组布局，状态、操作和技术详情按实际内容组织。

当前 shell 的刷新进入 `AppModel.performShellAction`，不定义停止 intent；Go 和 Settings 的主窗口呈现共享可注入的 `AppModel.showDestination`。主窗口保留 `WindowGroup` 与原退出策略；已有相同 identity 的窗口由 SwiftUI 前置，主窗口不存在时创建，重复请求不新增窗口。系统 `SidebarCommands` 提供侧边栏显隐。Library 与 Discover 使用原生 toolbar search，通过共同的 focused scene intent 将 Find（Command-F）绑定到当前页面；Batch Install 菜单和 toolbar 共用动作。尚无实际搜索内容的页面不提供搜索命令。开发环境分类在根 toolbar 切换，直接绑定 App 状态；Settings 不再持有 pane 状态或 focused pane Binding，只展示语言与日志。原工具五分类重组为 Node.js、Terminal、Sources、Environment Check，项目版本是 Node.js 小节，维护分别归到对应对象的直接展示区域。输入保留明确标签，路径与内部配置逐行展示。About 保留 128 点图标、版本、Sparkle 检查及 Studio 版权署名，不再展示更新通道和开源入口。共享更新控制器观察 Sparkle 的检查可用状态并发布变化，About 与菜单订阅同一状态，后台检查结束后自动恢复按钮可用性。正文顶部的共享任务反馈独立于当前路由和日志等级，显示安装、配置与维护等任务进度与可展开、可关闭的最近完成结果；refresh 继续只在工具栏显示进度。

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

启动与手动本机刷新由一个 `OperationStore` owner 覆盖 Manager 安装、三个 provider 子读取及进程回收；toolbar 只在原刷新按钮中显示系统进度，不提供停止入口。已经成功的 provider 独立保留；任务所有者结束或超时导致的内部取消记录为 cancelled，不作为 provider 读取错误。写操作后的必要状态复查仍使用原来的不可取消收尾。

Home 的本机读取跳过 Homebrew/npm outdated 查询，先发布版本、清单和配置。本机刷新结束后，视图生命周期通过 `OperationStore` 登记一个受控任务，并发持有两个 provider 的 outdated 查询和四个官方版本来源，各自独立发布结果、状态与检查时间；界面不提供手动停止，进程回收和子任务结束前继续拒绝退出。离开 Home 或新一轮刷新会在内部取消旧任务，旧结果不能覆盖新任务状态，失效的 loading 状态会明确结束。同一次已完成的本机刷新不重复检查，空闲时没有循环。本机 Homebrew/Node 读取失败时保留先前成功快照与其时间，并单独显示刷新失败；outdated 失败只改变相应更新状态，不清空核心数据。npm outdated 保留核心快照的精确 Node/npm 可执行路径，先验证入口仍可执行，再复验路径、版本与全局目录，不按版本或 nvm default 重新选择环境。既有完整快照 API 继续供操作前后校验使用。

快速返回 Home 时，新请求只等待此前 Home owner 的内部取消与清理完成，随后复验自身生命周期、刷新时间和操作槽；不等待其他模块的任务，也不在其他任务结束后自动启动过期检查。同一轮健康的重叠请求共享已有 owner。owner 先释放操作槽再完成，确保有效的接管请求不会因旧槽仍忙而永久跳过。

刷新与写操作不使用轮询。独立 IO 可以有界并发；批量 mutation 必须顺序执行。状态模型区分 not loaded、loading、available、partial failure 和 unavailable，不能用空集合替代失败。

主窗口共用 `AppLayout.spacing`（16 点）作为内容边距基准，目录卡片间距共用 `AppLayout.cardSpacing`（8 点）。Home 的每个统计项使用独立小卡片。开发环境与 Settings 的正文铺满内容栏，使用 16 点滚动内容边距与组间距；分组内保持紧凑间距，行高按纯信息、带控件和带说明三类内容统一设置。版本、状态、官网和必要操作尽量同行，不为独立官网图标保留空行。软件源、终端和 Node 维护直接展示，通过分组与分割线区分内容，不使用折叠区域。Terminal 的插件继续通过原生 popover 与 checkbox Toggle 多选，480 点宽、360 点高的滚动面板中将已选项与未选项分组呈现，右侧保留来源标签，勾选保留在页面草稿中，仍由 Apply 统一提交。确认 sheet 与诊断窗口保持各自布局。

## Catalog 与展示模型

网站入口统一由 `WebsiteLink` 承载系统 `Link`，只显示蓝色 `safari` 指南针图标，不附加背景、边框或文字标签。符号继承调用方字体；首页标题使用 caption 字号，目录卡片网站图标与软件包名称使用 title3 semibold 字体，开发环境随相邻名称或标题。组件官网与标题同行，缺少组件时的官方安装指引位于相关任务附近；至少 20 点的透明点击区域、原悬停提示和辅助功能名称保留。URL、系统浏览器打开方式和安全边界不变，不增加图标网络请求。

共享卡片模型保留 provider/type、稳定 identity、名称、current/available version、semantic status、website URL、Node environment、progress 和 typed primary action。Library 的卸载卡片与 canonical update card 分别保留原操作契约，按钮组按动作传递对应卡片，不把卸载卡片伪装为更新目标。

Library/Discover 共用 `CatalogCardView`，网格横向、纵向间距使用 `AppLayout.cardSpacing`（8 点），滚动内容四周边距使用 `AppLayout.spacing`（16 点）。头部单行排列 title3 semibold 名称与操作按钮；头部固定为 32 点高，卡片内容间距为 8 点。第二行显示 callout 字号、secondary 颜色的无独立背景简介；第三行依次排列类型 Tag、网站链接和带“版本号 ”前缀的版本，不使用分割线。简介用 `.lineLimit(2, reservesSpace: true)` 并固定为 32 点高，缺少简介时直接留白且对辅助功能隐藏空文本。元信息行固定为 20 点高，任务状态在该行右侧显示，不预留独立尾部，保证有无简介、操作按钮或任务进度时所有卡片等高。版本使用 callout 字号，不重复显示 Node/npm 环境版本。Library 右上角使用 HStack 与系统 `.glassEffect(.regular, in: Capsule())` 提供更新／卸载按钮组；按钮使用 28 点点击区域，组内边距 2 点，私有 ButtonStyle 仅为悬停或按下的启用按钮显示次要颜色背景；更新图标为 `arrowshape.up.circle`，无更新资格时只显示卸载，Discover 的单项安装使用 `arrowshape.down.circle` 并共用同一 ButtonStyle、28 点点击区域与胶囊形 Liquid Glass 材质；只有 behind 显示版本箭头和更新资格，其他状态保留辅助功能语义。

共享模型不丢失以下不变量：

- Formula 与 Cask identity 不可互换；
- npm package identity 包含明确 Node environment；
- `ahead`/`unknown` 不生成 update action；
- website URL 只交给系统打开，不在 App 内嵌浏览器；
- 类型通过 Formula/Cask/NPM 文字 Tag 表达，卡片不读取或下载软件图标。

Local library 从本机 provider 状态派生。Discover 通过官方 Homebrew 数据/受控 `brew` 查询和 npm Registry search 获取有界结果。Home 与 Library 把本机状态和异步线上结果合并，但保持不同错误来源。

Library 移除系统 toolbar title，左侧沿用 `CatalogToolbarScopeTabs` 的原生 All/Brew/NPM 与展开的 All/Formula/Cask，并通过 `LibraryToolbarUpdateFilter` 提供独立单段 Pending Updates Tab，与类型组使用同一原生 `NSSegmentedControl` 组件。类型组与待更新均使用原生 `.automatic` 分段样式和 `.selectOne` 选择模式，保留系统工具栏背景；两组 item 和中间固定 spacer 均使用 `.automatic` placement，按普通工具栏项从左到右排列，避免导航区对项的特殊定位。不得隐藏两组背景或添加自绘材质。待更新点击时切换绑定的 `LibraryUpdateFilter`，同步原生选中状态，支持再次取消。Library 查询文本与搜索聚焦请求由 `AppRootView` 持有，`LibraryView` 接收 Binding，搜索项仅按当前页面是否为 Library 创建，不依赖可选 focused scene 搜索上下文。`onGeometryChange` 读取正文可用宽度及类型、待更新控件的实际宽度；右侧 HStack 工具栏项依次包含按需显示的 Update All、搜索框和圆形刷新，扣除左侧控件及系统间隔预算后分配宽度，搜索在 140～380 点之间承接剩余空间。刷新位于搜索框右侧，使用系统圆形 glass 外观并保留原位进度；整体分配空间，避免 Brew 展开时独立工具栏项被收入溢出菜单。类型筛选、弹性 spacer 与右侧容器均使用 `.automatic` placement，展开或收起 Brew 时保持右对齐。Library 与 Discover 的共享搜索字段均应用系统 `.glassEffect(.regular, in: Capsule())` 并隐藏外层共享背景，保证空输入、未聚焦时外观一致。`PackageUpdateActions.canUpdateAll` 同时要求待更新选中、当前目标非空及操作可用，菜单沿用相同资格。单个主 ScrollView 覆盖内容栏，内容 margins 不缩进滚动条；空状态居中，卡片从顶部排列。筛选只处理本机快照；类型、子类型、待更新和搜索按交集组合。每个 npm identity 继续绑定精确 Node executable 与版本。卸载仍只接受一个目标并进行任务专用确认，Cask 只提供 standard，artifact 不由 App 删除。

Discover 删除系统 toolbar 标题，左侧使用与批量安装弹窗共用的 `GlassCategoryPicker` 显示 All/Formula/Cask/NPM，默认 All；该组件使用 SwiftUI 按钮与系统胶囊形 Liquid Glass 材质，区别于 Library 和开发环境使用的原生 `NSSegmentedControl`。固定 360 点的共享 `CatalogToolbarSearchField` 使用 `.primaryAction` placement，与刷新、批量安装一起靠右，由弹性 spacer 与左侧范围分隔；查询、范围、聚焦和回车提交通过 focused scene context 交给根 toolbar。主内容使用铺满内容栏的 `ScrollView`，16 点内容边距不缩进滚动条；默认空状态按当前 viewport 高度居中，结果从顶部排列。内容区不显示 Registry/Node 摘要、结果数量提示或搜索按钮；批量确认继续保留来源和目的地。搜索由原生字段编辑 delegate 的 Return 命令发起。空输入不请求；每个来源默认最多 50 项，边界最多 100 项，Homebrew 仅为有界匹配逐项读取 typed 详情。All 通过最多三个子任务并发查询所有可用来源，以 Formula/Cask/NPM 顺序合并结果；来源缺失或查询失败保留其他成功结果，并提供对应来源提示。搜索范围由独立 `DiscoverSearchScope` 表达，不把 All 引入安装 provider/type；npm 结果继续绑定搜索时解析的有效 Registry 与 Node 环境。npm 搜索保留精确 Node context；普通查询使用有效默认 Registry，`@scope/name` 查询先读取该 scope 的有效 Registry，并将实际请求来源绑定到搜索结果。结果安装前准备的有效 Registry 必须与搜索结果绑定的来源相同，不能静默改用另一个 Registry。输入、范围或页面生命周期变化在内部取消旧搜索；替换查询等待旧任务清理后才登记新 owner，界面不提供手动停止。已安装卡片不提供重复安装，更新由 Library 负责。批量输入经本地规范化后，以受控只读操作准备全部 typed plan，再显示绑定的实际来源、Node/npm 入口、canonical globalPrefix/globalRoot、逐项可执行性和数量。最终一次确认仅执行原批次计划；执行或复查失败分别呈现，搜索结果保留。

软件更新不再拥有独立 AppDestination 或页面。Library 持有 `PackageUpdatesModel`，原确认与结果视图保留在 `LibraryUpdatePresentation`。`LibraryCatalog.updateTargets` 将当前可见安装项与 `AppModel.updateCards` 按精确 identity 和已安装版本匹配，只保留可执行 behind 目标；待更新筛选、单项按钮与批量动作均使用同一目标契约。批量更新捕获类型、子类型、状态和搜索后的目标，不随后续筛选扩大范围。Library 自动检查沿用原视图生命周期 owner、失败保留和重试入口；进度使用全部 activeIntents，涵盖排队的后续 provider/type 与最终复查。单项更新直接准备并执行；Update All 捕获当时可见的 behind 目标，在确认前准备全部 Formula、Cask 和明确 npm 环境的 typed groups，确认只消费原组一次。所有组由一个受控任务顺序持有全局槽，逐项准备失败与执行失败保留且继续，界面不提供手动停止。完成后 Homebrew Formula/Cask 共用一次最终库存复查，每个 npm 环境独立复查。核心读取不可用时保留原快照；核心成功但 outdated 返回分区错误时，复查状态仍为 failed，同一 Homebrew 安装或 npm 全局目录内安全合并新核心数据与旧版本补充信息，卡片保持 unknown 且不可更新。逐项结果保持不变，刷新警告与任务结果分别记录。更新后的复查不会触发重复自动检查，用户仍可显式重试。

## Operation 与 batch coordinator

现有 provider plan 继续作为内部安全机制。普通 UI 不呈现通用“计划”页面；Feature 按产品确认矩阵决定直接提交或显示任务专用确认。

```text
intent → validate boundary → typed plan/fingerprint
       → optional task confirmation → acquire global mutation slot
       → execute one typed item → capture outcome
       → continue/stop-on-owner-cancellation → post-refresh → session result + file log
```

Batch coordinator 只组合现有单项 typed operation：

- 每次提交一个 provider/type；
- batch install/update 按项目顺序执行，uninstall 只接受单个目标；
- 项目失败后继续；已开始的批次不提供手动停止；
- 不回滚已经完成的项目；
- 安全时整批结束后统一 post-refresh，否则 provider 单项契约要求的 refresh 优先；
- 结果包含每项 success/partial/failure/cancelled/unknown 与整体 partial completion。

全局 mutation slot 覆盖 Homebrew、npm、Node、Registry、Shell 与 setup 写入，防止跨模块同时修改环境。只读刷新与 mutation 是否能并行由当前状态一致性契约决定；不能证明安全时拒绝刷新而非返回混合快照。

当前 `BatchOperationCoordinator` 在确认前准备有序单项计划，整批计划只能消费一次。执行通过 `ProviderBatchOperations` 复用既有 Homebrew/npm client；npm 核对明确安装中的实际 Node/npm 入口与版本，计划、执行和复查复用验证后固定的 environment，PATH 只包含该安装的 bin 与系统工具路径，禁止其他 provider 提供 fallback。npm 复查合并时同步 App 内后续操作使用的 Node 会话版本。`OperationStore` 登记覆盖执行、内部取消后的进程回收及最终复查；受控 worker 与最终复查分开，父任务取消不打断复查。Homebrew 保留单项执行契约要求的安全复查，再执行一次整批最终复查；provider partial 单独保留为逐项部分完成，并计入整体部分完成。最终复查失败独立报告，既有逐项结果保持不变。现有单项 Homebrew、Node 与 Shell 写操作也使用相同的生命周期登记。

安装批次把准备不可用或已经安装的目标保留为 typed unavailable/alreadyInstalled 条目，预览明确说明这些项目不会安装，其他 eligible 项仍按原顺序准备和执行。准备失败不保存原始错误；最终 outcome 包含全部原目标的有序结果，已知不可用项为 failed，父任务内部取消后尚未开始的可执行项为 cancelled。零可执行项禁用用户确认按钮；协调器即使收到该批次，也只生成失败摘要，不调用 provider execute 或复查。既有卸载与 Node 当前/default 保护仍在准备时拒绝危险批次。

Node runtime 卸载批次与 npm 包批次使用不同 identity 和 scope，但均绑定确认中显示的受控 Node 环境。Bridge 执行前重新读取 Node runtime 计划，复验当前/default、精确目标目录及其全局包摘要；provider 对当前、默认或无法可靠读取的版本的拒绝仍生效。批次完成后只进行一次最终 Node 环境复查；会话结果与日志保留独立的 Node runtime scope，清除环境路径后只保留版本语义。

npm 卸载的确认状态在当前会话中保存规范化的 Node/npm executable、globalPrefix 和 globalRoot。打开单次写入 gate 前重新读取同一环境的包计划及最终 summary，确认 package identity、installedVersion 和精确全局目标目录没有变化；变化后拒绝旧确认，不把同版本的其他 Node executable 当作已确认环境。原计划的有效期和 token 不因复验而延长。Manager 的 uninstall `warn`/零退出/`residue-detected` 表示移除成功但有残留，协调器保留为 partiallySucceeded；路径仅在当前会话 Library 结果中以可复制文字展示，不写入文件日志，也不由 App 删除。

npm 安装保存会话内的原目标目录与每个 package spec 的有效 Registry；准备前后确认目的地没有变化，确认后在逐项执行前及打开 write gate 前复验原包名、已安装版本、解析目标版本、Node/npm 入口、目的地和 Registry，旧计划的有效期不延长。scope Registry 通过 Cellar-owned typed read 查询：只调用已验证安装中的绝对 npm，参数固定为 `config get <validated-scope>:registry`，采用与 Manager 相同的受控环境与工作目录、关闭 execute gate、20 秒 deadline 和有界输出；未配置 scope 才使用同次 summary 的默认 Registry，读取失败或无效来源均 fail closed。冻结 Manager 无法强制指定 Registry，因此来源变化必须拒绝执行，不重建已确认基线。Discover 的一个批次若包含不同有效 Registry，会要求用户分别提交；准备期间不同项目读到不同目的地也拒绝发布确认。安装完成但最终复查失败时保留原快照与逐项结果，标记对应 provider 状态未知，停止从该旧清单提供安装动作，直到显式刷新成功。

Homebrew 整批最终复查遇到 packages 分区错误时视为 reconciliation failed，不发布空安装清单作为新快照。AppModel 保留先前成功的 Homebrew 快照与刷新时间，同时发布失败状态；Library 显示复查失败提示，逐项执行结果仍保留。

npm 更新复用安装的会话 Registry 与 canonical destination 绑定，在准备前后及执行前复验；计划与最终复验的 installed/target 版本必须可靠比较为 behind，当前、ahead 与 unknown 均拒绝写入。确认中显示准备时的具体目标版本；实际写入通过冻结 Manager 已有的 install action 与精确 `name@version` spec 执行，不调用会再次解析 latest 的 update-latest write，App 的 typed intent、结果和日志仍为 update。冻结 install 的精确版本验证继续生效；Cellar 在同一 Node 入口与全局目的地读取安装版本，只有等于原目标才报告成功，读取不可用保留原退出状态并报告 unknown。Homebrew upgrade 的指纹绑定各自目标的类型、名称、已安装版本与可用版本，确认后目标版本变化会拒绝该项；其他项目的完成不会使无关目标的计划失效。`brew update` 仍只属于独立 metadata action。

## 会话任务反馈与文件日志

`ActivityStore` 保留内部名称，但只管理当前会话中最多 100 条去敏语义结果，不再承担文件持久化或历史页面。最近一次非查询任务的全部分组结果单独发布供主窗口共享反馈使用；搜索与后台刷新不覆盖该结果，用户关闭反馈不影响日志。任务后的复查失败单独保留警告，不覆盖已经完成的逐项结果。`OperationStore` 提供运行中的上下文、阶段和真实批次计数，最终复查结束前仍保持任务登记和退出保护。文件日志等级与 IO 故障不会过滤、隐藏或改变界面中的任务结果。

摘要仍使用稳定 operation kind、provider scope、目标显示标识、时间、终态和 per-item outcomes。sanitizer 在会话结果进入日志前约束包标识、版本与有限语义步骤；npm 仅保留 Node/npm 版本及由版本派生的标识，不保留原始环境标识或安装路径。Terminal 的插件/主题 Apply 使用 `.shell` scope 与有限步骤，记录成功、部分完成、失败或取消，不写入插件名、主题名、路径或诊断原文。旧 `~/Library/Application Support/Cellar/Activity/activity.json` 不再读取、写入、迁移、隔离或自动删除。

`FileLogStore` 负责日志等级、保存期限与后台串行文件写入。目录为 `~/Library/Logs/Cellar/`；每条记录包含时间、等级、模块、任务 ID 与去敏语义消息，不保存原始命令或 stdout/stderr。成功结果使用 Info，部分完成使用 Warning，失败使用 Error，逐项结果与任务 ID 保持关联。最低等级包含 Trace、Debug、Info、Warning、Error、Critical，默认 Info；保存期限可选 7、14、30 天，默认 7 天，均通过 App 自有 UserDefaults 保存并立即作用于后续队列任务。

每次写入按 UTC 当天日期选择文件，单文件 10 MiB 后分卷，日志总量上限为 50 MiB；启动、写入和设置变化时清理过期或最旧日志。清理只针对 Cellar 自有日志文件。写入只接受普通文件，不跟随目标符号链接；同名管道等特殊文件被明确拒绝，不阻塞日志队列和退出。异常目标、文件创建和写入错误统一发布到 Settings 及共享反馈，保留待写记录并允许重试；任务结果仍在当前会话可用。测试注入临时目录、独立 defaults 和时钟，不写入用户真实 Logs 或 Application Support 目录。

Homebrew 的 Tap 与元数据任务使用明确的 provider scope 和有限操作类型，Tap 只保存安全的 owner/repository 标识，元数据目标由有限语义范围在展示时生成；诊断同样保留 Homebrew 身份。doctor 使用共享的当前会话诊断 store 与视图，stdout/stderr 分开且各自限制 16,000 字符，始终提示敏感信息与截断。冻结 Node adapter 的 post-install/post-uninstall/update verification unavailable 原因表示写入结果不能复验，逐项记为 unknown；latest verification unavailable 保留已知变化并记为部分完成。协议边界只兼容冻结卸载已知的 operation-shaped 错误（exitCode 0、failed、post-uninstall-state-unavailable），不接受其他缺少 code 的错误。

共享任务反馈按当前语言渲染 operation、scope、状态、原因与步骤，完成结果可展开逐项检查并关闭。整个反馈区域按内容高度占用空间，空反馈不预留高度；内容较多时限制总高度并整体滚动，为下方主页面保留可用空间，不按每张结果卡片分别嵌套滚动。安装、配置与维护等任务进度跨页面可见，搜索只在页面结果区显示加载状态，refresh 只在工具栏显示进度，均不提供停止入口。Activity 页面、历史搜索、筛选和复制菜单已移除。

`ActivityDiagnosticsStore` 只在当前进程内保留最多 100 条、每字段最多 16,000 字符的去敏技术记录。单项任务和摘要共享会话内 ID；批次 provider 诊断作为单独的当前会话集合提供。用户从开发环境 > 环境检查的单一会话诊断入口显式打开诊断窗口并选择记录；命令、stdout、stderr 和技术详情只在此展示和复制，不进入文件日志，并提示截断与敏感信息风险。去敏处理覆盖已知凭证/header/私钥/用户路径模式，不声称可以识别所有秘密，也不读取诊断中引用的文件路径。有限原因区分状态变化、工具不可用、网络、权限、准备失败、取消和无法复验；批次逐项结果与普通页面反馈共享这些恢复建议。CLT 请求与已验证 Homebrew Installer 的系统交接以各自语义动作记录成功，不表示工具已安装。

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

开发环境的 Node.js 页面区分当前检测到的 Node/npm 与 nvm 管理的安装列表；前者保留真实版本和可执行路径，不以路径猜测 provider 归属，后者为空不表示整机没有 Node。nvm 状态及官方安装指引放在同一页面，未检查与缺失分开表达；Cellar 不执行远端安装脚本。用户主动打开版本安装后，从官方 Node 发布索引读取最多 100 个支持 macOS arm64 的具体版本，与 npm Registry 查询分离；读取中、失败与空结果分别呈现。恢复 nvm default 会先确认它能解析到已安装版本，Cellar 会话选择不改变现有终端。

项目版本作为 Node.js 内的小节，只读取用户通过系统目录选择器选择的项目；提供已安装版本选择并保留手动输入。写入确认继续绑定 `.nvmrc`、`package.json`、nvm default 与受控环境，执行前复验并消费一次；保存只写项目声明，不自动安装或切换 Node。Registry 确认另外绑定用户/当前工作目录的 npm 配置指纹与有效配置层，状态变化时关闭写入 gate。Node 的缓存、旧版本和 Manager 日志维护收在 Node.js 的维护区域；日志维护列出精确旧日志候选，确认后目录清单变化会拒绝执行。

Node 配置指纹通过 `O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC` 打开普通文件，读取前后核对 metadata、路径与 inode；`.nvmrc`/alias 上限 4 KiB，npm 配置上限 64 KiB，`package.json` 上限 1 MiB。FIFO、设备、目录、符号链接、超限、替换和读取期间变化均拒绝，文件描述符在所有路径关闭。Registry 包含默认安装的 global config 及显式引用的 userconfig/globalconfig/prefix 配置，引用集合最多 16 个文件。

Project 确认还在会话内绑定用户选择目录的 canonical URL、device/inode、owner/group/mode 与 birthtime，即使两个子文件都不存在也保留目录身份。目录通过 `O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC` 打开，canonical 路径由已打开 FD 的 `F_GETPATH` 取得；最终目录为 symlink、`.`/`..` 路径或非目录时拒绝。初始祖先 symlink（包括系统路径别名）可以使用，但确认后重新打开原选择路径必须仍对应同一 canonical 目录和身份。执行前重计划之前及紧邻 project-write gate 再次复验，Manager 实际收到的是已捕获 canonical 路径，保留原确认时效和单次消费。执行后再核对目录及有界读取的精确 `.nvmrc`；目录漂移或结果不能复验时记为 unknown，使用有限的 stateChanged/stateUnavailable 原因，不宣称回滚、不把路径写入任务摘要或文件日志。

普通 npm install 与 update 都把已确认的 packageName 和 targetVersion 组成精确安装参数；名称和标签只保留为请求身份。执行前仍复验原目标版本、安装状态、有效 Registry、精确 Node/npm 入口和全局目录；执行后核对该目标的实际版本，无法复验为 unknown，版本不匹配为 failed。

npm 目录能力只针对全局包：

- Library 安装项及更新目标的 identity 包含当前受控 Node environment；
- Discover 使用用户选择/有效 Registry 的有界 search client；
- install/update/uninstall 只在目标身份绑定的 Node 环境执行；
- Registry 管理位于开发环境 > 软件源，Node 版本与项目版本位于开发环境 > Node.js；
- current/wanted/latest 不能比较时产生 `unknown`，不得猜测或自动降级。

## Shell 与开发环境

冻结的 `omz-manager.sh` 与来源逐字节一致。Cellar-owned `app-json.sh` 和模块继续作为独立 schema v1 adapter，不驱动交互菜单。

开发环境的 Terminal 与主窗口共享同一 `AppModel` 和 `OperationStore`。Terminal 的内置插件直接枚举已安装 Oh My Zsh 的插件目录，不使用快照中的推荐列表；自定义插件只接受规范化 GitHub HTTPS repository URL，主题只来自本机安装。一次 Apply 绑定原 `.zshrc` 和有序 typed plugin/theme plans，在一个受控任务中执行；第二项使用第一项预期生成的精确文件内容作为基线，不接受外部漂移或第二次确认。每项保留原 adapter 的状态 token、备份、marker 与 `zsh -n`。语法失败时，仅在文件仍等于本项生成内容的条件下恢复本项原文；后续失败保留之前完成项与备份，不承诺整体事务回滚。符号链接或非普通 `.zshrc` 拒绝写入；不运行 `chsh`。

Zsh tidy 位于开发环境 > 终端的维护区域，只移动确认列出的受限文件到 `~/.zsh`；Bridge 拒绝符号链接候选、重定向的整理目录和已占用的目标文件，复验候选清单与 adapter 状态 token，不修改 `.zprofile` 正文。Oh My Zsh 安装继续设置 `RUNZSH=no`、`CHSH=no`、`KEEP_ZSHRC=yes`。

插件克隆先进入同一批准父目录下的独有 staging，adapter 在核验 marker/device/inode 后固定工作目录；Swift 以 `renameatx_np(RENAME_EXCL)` 原子发布，既有最终目录永不替换或删除。清理仅限已证明归属的 staging；发布后配置失败保留插件并报告 partial。

插件、主题与 tidy 的受管块必须位于唯一有效的 Oh My Zsh 初始化之前。Bridge 先验证冻结 writer 的精确输出，再通过普通文件/no-follow/身份复验边界迁移受管块并执行语法检查；不增加或复制 source。接受 `source $ZSH/oh-my-zsh.sh`、双引号包围路径的 `$ZSH`/`${ZSH}` 形式和 `. "$ZSH/oh-my-zsh.sh"`；初始化之前只接受注释、空行及完整单行赋值。缺失、重复、条件执行、动态 loader 或其他歧义布局在写入前拒绝。原备份、精确回滚和 tidy 已移动文件的 partial 语义保留。

## 进程、网络与文件边界

`ProcessRunner` 继续为每个请求创建独立进程组，并明确 executable、arguments、environment、working directory、stdin/stdout/stderr、deadline 和每路 2 MiB 输出上限。取消/超时先发送 `SIGTERM`，500 ms 宽限后向仍存活的专属组发送 `SIGKILL`。不使用 `bash -c`。

网络 client 使用可注入 session、明确官方 host/用户配置来源、bounded response、deadline、取消和适当的 ETag/cache 语义。网络失败不触发无限重试或 polling。

当前 `CatalogHTTPClient` 使用有界内存 ETag 缓存，并遵守 `no-store`；`NPMRegistryClient` 将有界搜索结果绑定到调用方明确提供的 Node environment 和 Registry origin，用户明确配置的 Registry 可使用无凭证的 HTTP 或 HTTPS，不能跨 origin 响应或重定向；`NodeVersionMetadataClient` 并发查询三个官方版本来源并分别保留失败。内置官方来源保持 HTTPS；Homebrew 下载仅允许官方 GitHub HTTPS 资产来源及其 HTTPS Release CDN，按官方资产大小流式写入自有临时文件。网站链接只接受无凭证的 HTTP/HTTPS URL。

Manager 从只读 Bundle 快照安装到版本化 Application Support：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

运行时文件、本地日志与下载临时文件只写入各自 Cellar-owned 可写位置。安装包临时文件在交给系统打开或失败后按明确生命周期处理，不写入 Bundle，也不触碰用户包管理目录。

## 本地化与可访问性

所有用户可见静态字符串进入 String Catalog，支持 English、简体中文和繁体中文。Follow System 不覆盖系统首选语言；显式选择只影响 Cellar。会话结果保留语义数据，在显示时按当前语言渲染；文件日志使用稳定语义记录，便于排查问题。

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
