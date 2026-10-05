# Cellar 1.0 人工验收清单

本清单验证自动测试无法证明的真实 macOS、系统授权、本机工具、网络和 UI 行为。只把实际执行的项目标为完成；没有合适环境时保持未选中，并在交付说明中列为剩余风险。

当前 1.0.0 源码已实现，尚未公开发布。隔离、关闭真实环境读取的只读视觉检查和自动测试不替代本清单；真实 provider 写入、系统 Installer/CLT 对话框、网络、VoiceOver、Dark 与辅助设置等项目仍须单独执行。

## 安全准备

- [ ] 只读检查已说明可能访问 Homebrew/npm 网络并更新各自 cache。
- [ ] 所有安装、更新、卸载、Tap/Registry、Node、`.nvmrc` 和终端配置写入只在可丢弃的专用测试账户/环境执行。
- [ ] 已记录测试前的 Homebrew、npm、nvm、`.npmrc`、`.zshrc` 和项目状态，以便区分 Cellar 的真实影响；不假设事务回滚。
- [ ] 不使用有价值的生产环境测试批量操作、Cask zap、系统 Installer 或维护动作。

## App shell 与窗口

- [ ] 从 Finder 启动后普通前台窗口立即出现，首次默认内容尺寸为 1080 × 720 点且可调整。
- [ ] Dock 显示 Cellar；没有 `MenuBarExtra` 或后台常驻。
- [ ] 全部主页面采用同一原生工具栏与系统自动背景/滚动边缘，不再强制固定背景或硬分隔；分类在左、动作靠右，正文铺满内容栏，滚动指示器不随内容留白缩进。
- [ ] Tools 分类与 Settings 四个 pane 均在工具栏切换，内容区不重复显示分类条；最近选择、Command-Comma 和菜单 About 路由仍正确。
- [ ] 主侧边栏顺序为 Home、Library、Discover、Updates、Tools；左下方依次为 Settings 和 Activity，Activity 固定在最底部。
- [ ] 启动、手动刷新、软件更新检查、setup recheck 和 Runtime 版本读取等 refresh 任务只在右上角刷新按钮内显示系统进度动画，页面内容区不重复显示刷新动画或文字。
- [ ] Settings 是主窗口 detail 页面，含 General、Sources、Terminal、About；点击侧边栏、App 菜单或 Command-Comma 都选择该页面，不创建独立设置窗口；菜单重复调用复用主窗口，主窗口不存在时正确重建。
- [ ] 关闭最后窗口和无任务时 `Command-Q` 正常退出。
- [ ] 活动任务期间退出请求被拒绝；任务自行结束后可以退出，界面不提供手动停止。
- [ ] App 退出后没有 Cellar 启动后遗留的 brew、npm、bash 或 zsh 进程。

## Home

- [ ] Home 按 Homebrew、Node、终端环境的顺序显示三个单层数据卡片，不显示路径、配置文件或 Manager 技术摘要。
- [ ] 本地状态先出现，线上版本随后异步合并，不阻塞首屏。
- [ ] Homebrew 卡片显示 Homebrew 版本、Formula/Cask 与软件更新数量；官网入口是卡片内 Homebrew 字段标题后的统一小号填充式网站箭头，不显示检查时间或重复详情。
- [ ] Node 卡片以两行显示 Node/npm 版本、当前环境全局包与软件更新数量、nvm 状态和 nvm default，不显示检查时间或具体更新名称。
- [ ] 终端环境卡片显示 Command Line Tools 安装状态、Zsh 版本和 Oh My Zsh 安装状态；插件、主题和路径仍只在 Settings > Terminal 显示。
- [ ] 首次读取前三张卡片的完整字段与图标立即可见，未知值显示 `—`；后续刷新保留旧值并原位更新，不清空卡片。
- [ ] 只有线上版本明确更高时显示“当前版本 → 最新版本”及其后的圆形向上箭头；单个线上检查失败时保留本机版本，不伪装为需要更新或已经最新。
- [ ] 缺少 CLT 或 Homebrew 时 Home 提供必要安装动作；缺少 nvm 时 Home 只显示状态，安装指引仅保留在 Tools > Environment setup。

## 卡片与网站

- [ ] Library、Discover 和 Updates 使用响应式卡片；卡片 body 无导航动作。
- [ ] 三页卡片统一为“名称 + Formula/Cask/NPM Tag + 小号填充式网站箭头”，没有名称前图标、第二行类型或底部网站按钮；长名称截断后 Tag 与链接仍可见。
- [ ] 已安装卡片通常只显示当前版本；明确需要更新且有目标版本时显示“当前 → 新版本”与圆形向上箭头；不重复显示可用版本和最新状态行。发现中未安装的软件仍显示待安装版本。
- [ ] 网站链接通过系统默认浏览器打开正确 URL；键盘可以单独聚焦主动作和链接。
- [ ] 首页、目录卡片、Tools 安装指引与 About 开源入口均使用白色 `arrow.turn.right.up` 加蓝色实心圆角矩形；文字型链接保留文字，图标型链接有辅助功能名称和悬停说明。
- [ ] 卡片不读取或下载软件图标；类型 Tag 不可点击，网站箭头独立可聚焦。
- [ ] loading、empty、offline、partial failure、behind/current/ahead/unknown 有文字或辅助功能值，不只靠颜色。

## Library

- [ ] 软件库不显示页面标题或 scope 标题；原生系统 Tab 控件位于窗口 toolbar 左上角且没有空白尾部。默认显示 All、Brew、NPM，选择 Brew 后同一行按内容变宽并在 Brew 后完整显示 All、Formula、Cask，选择 All/NPM 后收起；右侧搜索框始终独立于刷新按钮，并在两种状态间保持同一宽度和可见性。
- [ ] All、Homebrew、npm scope 与 Formula/Cask subtype 的内容和数量正确。
- [ ] 本地搜索/筛选不发网络请求，长列表滚动和筛选保持响应。
- [ ] 默认 1080 点窗口且侧边栏可见时每行两张卡片，放大窗口后自动增加至三列或更多，卡片保持合理宽度且无水平溢出。
- [ ] 软件库在 Brew 展开和收起两种状态下，Tab 始终靠左，刷新按钮与 360 点搜索框一起靠右。
- [ ] 顶部没有重复的 Node 环境说明；主滚动区域覆盖工具栏下方的内容栏，滚动条位于内容栏右缘，卡片、提示和卸载结果一起滚动，卡片保留内容边距。
- [ ] 每个 npm 包标明其 Node 环境；切换会话 Node 后不会把两个环境的包合并。
- [ ] 单项卸载显示任务专用确认，取消时不启动外部进程。
- [ ] Library 没有管理模式、批量选择或批量卸载；每次卸载只接受一个卡片目标并显示任务专用确认。
- [ ] 单项卸载结果正确显示，不宣称事务回滚。
- [ ] Cask 单项卸载默认 standard；zap 只影响用户明确选择的目标。

## Discover

- [ ] 工具栏没有“发现”标题，左侧显示 Formula/Cask/NPM 与紧随其后的 360 点搜索框；范围 Tab 和搜索框各自独立、中间有间隔；右侧为刷新和批量安装。Command-F 聚焦搜索，回车提交查询。
- [ ] 页面整体滚动且滚动条位于内容栏右缘；默认空状态水平、垂直居中，结果卡从顶部排列；内容区没有 Registry/Node 摘要、搜索按钮或 50 项结果提示。
- [ ] 空查询不下载完整目录；输入查询后结果有界，新查询或离开页面会安全结束旧查询，界面不提供手动停止。
- [ ] Homebrew Formula、Cask 与 npm Registry scope 清楚可见，同名 Formula/Cask 不混淆。
- [ ] npm 结果卡保留目标 Node 环境，批量安装确认继续显示实际 Registry 与目标；安装只作用于该环境的全局 package。
- [ ] 单项安装从卡片开始，不出现通用“生成/执行计划”页面；失败后读取真实状态。
- [ ] 批量输入一行一项，正确去空、去重；超过 100 项时拒绝提交。
- [ ] 一个 batch 不能混合 Formula/Cask/npm；预览和一次确认后顺序执行并保留 per-item outcome。

## Updates

- [ ] 工具栏无“更新”标题；左侧 Tab 与软件库同款，默认 All/Brew/NPM，选 Brew 后同一行展开 All/Formula/Cask，离开后收起并保留子范围；刷新和 Update All 靠右。
- [ ] 空状态在内容区水平、垂直居中，结果卡从顶部排列，页面整体滚动且滚动条位于右缘；内容区没有重复范围标题、更新数量、Node 环境摘要和检查按钮，失败提示与执行结果仍可见。
- [ ] All、Homebrew、npm 与 Formula/Cask scope 正确过滤卡片。
- [ ] current、available 与 behind/current/ahead/unknown 对真实版本关系表达正确。
- [ ] npm ahead/unknown 没有 update 或 downgrade 动作。
- [ ] 单项更新从卡片开始；Update All 只作用于当前可见 scope。
- [ ] All scope 中 provider/type 仍拆为 typed sequential operation，没有混合命令。
- [ ] 批量确认、项目失败后继续、任务运行至完成、partial completion 和 post-refresh 都正确。
- [ ] `brew update` 只在 Tools 作为 metadata 动作，不被查看、卸载或 package update 隐式触发。

## Environment setup

### Command Line Tools

- [ ] 已安装 CLT 时显示可用，不提供重复安装动作。
- [ ] 缺少 CLT 时只执行 `xcode-select --install` 并出现 Apple 文档所述系统安装对话框；Cellar 不下载 payload、不模拟许可或安装。
- [ ] 用户取消或系统失败时显示真实状态，不继续假定 CLT 已安装。

### Homebrew

- [ ] 已安装且可用的 Apple Silicon Homebrew 显示 `/opt/homebrew` 和正确版本，不提供覆盖安装。
- [ ] 缺失时只从 Homebrew 官方 latest stable Release 选择精确 `Homebrew.pkg`，并取得该资产的有效官方 SHA-256。
- [ ] 官方 SHA-256 缺失、格式无效或与下载文件不匹配时 fail closed：不打开 package，显示具体原因和 Homebrew 官方网站链接。
- [ ] package signature 或 Gatekeeper assessment 无法完成、结果缺失、无效或失败时同样 fail closed，不允许用户绕过检查继续打开。
- [ ] 全部验证通过后只交给系统 Installer 打开；Cellar 不承诺系统将显示哪种提示，不请求或保存密码，也不运行自己的 `sudo`。
- [ ] 用户取消 Installer 或安装失败后重新探测真实状态，不显示假成功。
- [ ] 已有但损坏/来源异常的 Homebrew 不被删除或覆盖，只提供官方恢复说明。
- [ ] Cellar 不降级执行 `curl | bash` 或其他远端安装脚本。

### nvm

- [ ] 缺少 nvm 时只显示官方安装指引，不在 App 中执行远端脚本。
- [ ] 安装指引不会把 nvm 表示为 npm Registry 功能，也不会猜测未安装的默认 Node。

## Tools

- [ ] Node runtime 支持安装、用于本次 Cellar 会话、设置 nvm default 和安全卸载；会话切换不改变现有终端。
- [ ] 当前版本和 default 版本不能被误删，其他版本卸载前显示明确目标与影响。
- [ ] 项目 `.nvmrc` 只使用系统目录选择器选择的项目；符号链接、非普通文件或状态漂移被拒绝。
- [ ] `brew doctor` 保留警告、非零退出和可复制诊断，不把非零显示为“无问题”。
- [ ] PATH、prefix、repository、cache 等路径来自真实受控环境且可复制。
- [ ] npm/node-gyp/Manager maintenance 只处理确认中列出的候选并在执行前复验。
- [ ] Zsh tidy 只移动已声明文件到 `~/.zsh`，不删除用户数据。
- [ ] 没有 Homebrew cleanup、自动孤儿依赖删除或任意路径清理入口。

## Settings

### General 与 About

- [ ] 默认 Follow System；系统语言分别为 English、简体中文、繁体中文时选择正确资源。
- [ ] 显式语言选择只影响 Cellar，重启后保持；切回 Follow System 恢复系统行为。
- [ ] About 显示正确版本/通道，普通本地构建 updater 关闭，发布构建读取正确签名 appcast。

### Sources

- [ ] Tap 与 npm 默认/scope Registry 显示真实状态，并在任务专用确认后修改。
- [ ] 移除 Tap 前复验关联 Formula/Cask；存在安装项时拒绝并列出阻塞项。
- [ ] Registry 修改只影响确认的 key 和 scope，结束后重新读取有效配置。

### Terminal

- [ ] 插件列表只含 Oh My Zsh 内置、已安装自定义和必需项；没有推荐插件目录。
- [ ] 自定义插件只接受规范 GitHub HTTPS repository URL，其他 host/protocol/path 被拒绝。
- [ ] 主题只来自本机 `.zsh-theme`；插件与主题通过一次 Apply 提交。
- [ ] 修改前备份普通 `.zshrc`，只写 managed block 并通过 `zsh -n`；状态漂移时拒绝。
- [ ] `.zshrc` 为符号链接或非普通文件时不写入。
- [ ] Oh My Zsh 安装不运行 `chsh`、不启动新 Shell，并保留现有 `.zshrc`。

## Activity 与错误

- [ ] 工具栏独立搜索框保持 360 点，Command-F 聚焦且输入即时筛选；上下表格/详情分区继续独立滚动、选择和复制。
- [ ] 当前任务与进度保持可见；toolbar、菜单、Activity、Settings 和 Discover 均不提供手动停止入口。
- [ ] Activity 可按 provider/状态筛选并复制用户摘要；默认不显示命令文本。
- [ ] 失败和 partial completion 显示可理解摘要；显式 diagnostics 区域可复制当前会话技术详情。
- [ ] 重启后恢复最近结构化摘要且最多 100 条；时间、状态和 per-item outcome 正确。
- [ ] 持久文件不含原始 stdout/stderr、命令、token、认证 Registry URL 或不必要的绝对用户路径。
- [ ] 损坏的 Activity 数据不阻止环境状态加载，并提供独立错误/安全恢复行为。
- [ ] batch 因任务所有者或生命周期内部中断后，已完成项保留，当前项终止，未开始项标为未执行，随后刷新真实状态。

## Homebrew 与 Cask 安全边界

- [ ] Formula/Cask mutation 保持类型，不通过同名猜测。
- [ ] Formula/Cask 卸载禁止自动 Homebrew update 与 autoremove。
- [ ] Cask standard 与 zap 的影响说明清楚；Cellar 不自行 `rm` artifact 或补删失败残留。
- [ ] 写任务全局互斥；重复提交或跨 provider 写入不会并发启动。
- [ ] 权限不足只报告错误，不启动 Cellar 自有 `sudo`/Helper 或扩大删除范围。
- [ ] mutation 失败或内部中断后仍显示命令可能已造成的实际改变，不承诺回滚。

## Node/npm/nvm 与网络失败

- [ ] `~/.nvm/alias/default` 的具体版本、数字前缀、`node`/`stable` 和 alias 链解析正确。
- [ ] default 缺失、循环或无匹配时不擅自选择最新已安装版本。
- [ ] Finder 启动不依赖 `.zshrc`，受控 PATH 选择的 Node/npm 与 UI 一致。
- [ ] `npm outdated`、Registry search 或线上版本断网/超时/认证失败时，本地版本、包和配置继续显示。
- [ ] 网络恢复刷新后独立错误消失；失败不触发轮询或无限重试。

## 可访问性、外观与性能

- [ ] 仅键盘可到达导航、scope、卡片动作、网站、toolbar、确认和 Settings，并有可见焦点。
- [ ] VoiceOver 读取合理顺序、名称、provider/type、版本、状态、进度和错误；卡片 body 不产生假按钮。
- [ ] Light/Dark、Increased Contrast、Reduce Motion、Reduce Transparency 下内容可辨认且不丢状态。
- [ ] 1080 × 720、较窄与较宽窗口无重叠、不可达控件或水平溢出；两行说明稳定截断。
- [ ] 大 Library/Discover 结果滚动、搜索和 scope 切换流畅，无 selection 更新环。
- [ ] App 空闲时没有轮询或持续高 CPU/网络；任务期间并发有界，内部取消与超时回收及时。

## Application Support 与 Release

- [ ] Manager 快照安装在 `~/Library/Application Support/Cellar/Managers/<version>/`，Bundle Resources 无 runtime 写入。
- [ ] Activity 与临时 setup 文件只位于 Cellar-owned 可写位置，失败/取消后按明确生命周期处理。
- [ ] Bundle identifier 为 `com.dylanwang.Cellar`，不存在 `LSUIElement` 或 `MenuBarExtra`。
- [ ] App 及 Sparkle framework、Updater、Autoupdate、XPC 等每个 Mach-O 只有 `arm64`，最低系统版本为 macOS 26.0。
- [ ] Manager Bundle 快照与仓库来源一致，不含 `.runtime`、日志或临时文件。
- [ ] stable/beta/alpha 只接收 manifest 允许的 Sparkle channel；本轮未开启 release 开关、未发布。
