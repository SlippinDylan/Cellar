# Cellar 1.0 人工验收清单

本清单验证自动测试无法证明的真实 macOS、系统授权、本机工具、网络和 UI 行为。只把实际执行的项目标为完成；没有合适环境时保持未选中，并在交付说明中列为剩余风险。

## 安全准备

- [ ] 只读检查已说明可能访问 Homebrew/npm 网络并更新各自 cache。
- [ ] 所有安装、更新、卸载、Tap/Registry、Node、`.nvmrc` 和终端配置写入只在可丢弃的专用测试账户/环境执行。
- [ ] 已记录测试前的 Homebrew、npm、nvm、`.npmrc`、`.zshrc` 和项目状态，以便区分 Cellar 的真实影响；不假设事务回滚。
- [ ] 不使用有价值的生产环境测试批量操作、Cask zap、系统 Installer 或维护动作。

## App shell 与窗口

- [ ] 从 Finder 启动后普通前台窗口立即出现，首次默认内容尺寸为 1080 × 720 点且可调整。
- [ ] Dock 显示 Cellar；没有 `MenuBarExtra` 或后台常驻。
- [ ] 侧边栏顺序为 Home、Library、Discover、Updates、Tools；Activity 固定在底部。
- [ ] Settings 通过标准菜单/快捷键打开独立窗口，含 General、Sources、Terminal、About。
- [ ] 关闭最后窗口和无任务时 `Command-Q` 正常退出。
- [ ] 活动任务期间退出请求被拒绝；任务取消或结束后可以退出。
- [ ] App 退出后没有 Cellar 启动后遗留的 brew、npm、bash 或 zsh 进程。

## Home

- [ ] Home 只显示 Homebrew 与 Node/npm/nvm，不显示 Shell、Oh My Zsh 或 Manager 技术摘要。
- [ ] 本地状态先出现，线上版本随后异步合并，不阻塞首屏。
- [ ] Homebrew 显示安装状态、本机/线上版本、Formula/Cask 数量、更新时间和最多五个更新名称。
- [ ] Node 区域显示受控 Node/npm、nvm default、线上版本、当前环境全局包数量、更新时间和最多五个更新名称。
- [ ] 单个线上检查失败时保留本地状态，并显示该来源的可理解错误；不显示“全部最新”。
- [ ] 缺少 CLT、Homebrew 或 nvm 时使用内联 setup guidance，没有 onboarding carousel。

## 卡片与网站

- [ ] Library、Discover 和 Updates 使用响应式卡片；卡片 body 无导航动作。
- [ ] 卡片按可用数据显示名称、Formula/Cask/npm 类型、当前/可用版本、语义状态、最多两行说明和一个主动作。
- [ ] 网站链接通过系统默认浏览器打开正确 URL；键盘可以单独聚焦主动作和链接。
- [ ] Cask 只有在本机图标来源明确且读取便宜时显示真实图标，否则稳定回退到 symbol。
- [ ] loading、empty、offline、partial failure、behind/current/ahead/unknown 有文字或辅助功能值，不只靠颜色。

## Library

- [ ] All、Homebrew、npm scope 与 Formula/Cask subtype 的内容和数量正确。
- [ ] 本地搜索/筛选不发网络请求，长列表滚动和筛选保持响应。
- [ ] 每个 npm 包标明其 Node 环境；切换会话 Node 后不会把两个环境的包合并。
- [ ] 单项卸载显示任务专用确认，取消时不启动外部进程。
- [ ] Manage mode 只允许同一 provider/type 的批量卸载，逐项顺序执行。
- [ ] 某项失败后后续项继续；结果逐项显示，不宣称整体回滚。
- [ ] Cask 批量卸载默认 standard；zap 只影响用户明确选择的目标。

## Discover

- [ ] 空查询不下载完整目录；输入查询后结果有界且可取消。
- [ ] Homebrew Formula、Cask 与 npm Registry scope 清楚可见，同名 Formula/Cask 不混淆。
- [ ] npm 结果标注 Registry 与目标 Node 环境；安装只作用于该环境的全局 package。
- [ ] 单项安装从卡片开始，不出现通用“生成/执行计划”页面；失败后读取真实状态。
- [ ] 批量输入一行一项，正确去空、去重；超过 100 项时拒绝提交。
- [ ] 一个 batch 不能混合 Formula/Cask/npm；预览和一次确认后顺序执行并保留 per-item outcome。

## Updates

- [ ] All、Homebrew、npm 与 Formula/Cask scope 正确过滤卡片。
- [ ] current、available 与 behind/current/ahead/unknown 对真实版本关系表达正确。
- [ ] npm ahead/unknown 没有 update 或 downgrade 动作。
- [ ] 单项更新从卡片开始；Update All 只作用于当前可见 scope。
- [ ] All scope 中 provider/type 仍拆为 typed sequential operation，没有混合命令。
- [ ] 批量确认、项目失败后继续、取消后停止未开始项、partial completion 和 post-refresh 都正确。
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

## Activity、错误与取消

- [ ] 当前任务保持可见；底层可取消时有明确 Cancel，取消不会被显示为成功。
- [ ] Activity 可按 provider/状态筛选并复制用户摘要；默认不显示命令文本。
- [ ] 失败和 partial completion 显示可理解摘要；显式 diagnostics 区域可复制当前会话技术详情。
- [ ] 重启后恢复最近结构化摘要且最多 100 条；时间、状态和 per-item outcome 正确。
- [ ] 持久文件不含原始 stdout/stderr、命令、token、认证 Registry URL 或不必要的绝对用户路径。
- [ ] 损坏的 Activity 数据不阻止环境状态加载，并提供独立错误/安全恢复行为。
- [ ] 取消运行中的 batch 后，已完成项保留，当前项终止，未开始项标为未执行，随后刷新真实状态。

## Homebrew 与 Cask 安全边界

- [ ] Formula/Cask mutation 保持类型，不通过同名猜测。
- [ ] Formula/Cask 卸载禁止自动 Homebrew update 与 autoremove。
- [ ] Cask standard 与 zap 的影响说明清楚；Cellar 不自行 `rm` artifact 或补删失败残留。
- [ ] 写任务全局互斥；重复提交或跨 provider 写入不会并发启动。
- [ ] 权限不足只报告错误，不启动 Cellar 自有 `sudo`/Helper 或扩大删除范围。
- [ ] mutation 失败或取消后仍显示命令可能已造成的实际改变，不承诺回滚。

## Node/npm/nvm 与网络失败

- [ ] `~/.nvm/alias/default` 的具体版本、数字前缀、`node`/`stable` 和 alias 链解析正确。
- [ ] default 缺失、循环或无匹配时不擅自选择最新已安装版本。
- [ ] Finder 启动不依赖 `.zshrc`，受控 PATH 选择的 Node/npm 与 UI 一致。
- [ ] `npm outdated`、Registry search 或线上版本断网/超时/认证失败时，本地版本、包和配置继续显示。
- [ ] 网络恢复刷新后独立错误消失；失败不触发轮询或无限重试。

## 可访问性、外观与性能

- [ ] 仅键盘可到达导航、scope、卡片动作、网站、toolbar、确认、Settings 和取消，并有可见焦点。
- [ ] VoiceOver 读取合理顺序、名称、provider/type、版本、状态、进度和错误；卡片 body 不产生假按钮。
- [ ] Light/Dark、Increased Contrast、Reduce Motion、Reduce Transparency 下内容可辨认且不丢状态。
- [ ] 1080 × 720、较窄与较宽窗口无重叠、不可达控件或水平溢出；两行说明稳定截断。
- [ ] 大 Library/Discover 结果滚动、搜索和 scope 切换流畅，无 selection 更新环。
- [ ] App 空闲时没有轮询或持续高 CPU/网络；任务期间并发有界且取消及时。

## Application Support 与 Release

- [ ] Manager 快照安装在 `~/Library/Application Support/Cellar/Managers/<version>/`，Bundle Resources 无 runtime 写入。
- [ ] Activity 与临时 setup 文件只位于 Cellar-owned 可写位置，失败/取消后按明确生命周期处理。
- [ ] Bundle identifier 为 `com.dylanwang.Cellar`，不存在 `LSUIElement` 或 `MenuBarExtra`。
- [ ] App 及 Sparkle framework、Updater、Autoupdate、XPC 等每个 Mach-O 只有 `arm64`，最低系统版本为 macOS 26.0。
- [ ] Manager Bundle 快照与仓库来源一致，不含 `.runtime`、日志或临时文件。
- [ ] stable/beta/alpha 只接收 manifest 允许的 Sparkle channel；本轮未开启 release 开关、未发布。
