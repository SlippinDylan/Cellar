# Cellar 人工验收清单

本清单用于验证自动测试无法证明的真实 macOS、窗口和本机工具行为。检查会读取用户的 Homebrew、Node/npm/nvm 和 Shell 状态；Homebrew 写操作只允许在明确准备的专用测试环境执行。

只读检查也可能让 Homebrew 或 npm 访问网络并更新自身 cache。写操作会真实修改 Homebrew、npm、nvm 或项目 `.nvmrc` 状态且不提供事务回滚；不要使用有价值的生产环境验收安装、升级、卸载、清理或配置变更。

## 启动与窗口

- [ ] 从 Finder 启动 App，主窗口立即出现。
- [ ] 首次创建且没有窗口恢复状态时，内容尺寸为 1080 × 720 点。
- [ ] 窗口可以使用系统控件调整大小。
- [ ] Dock 显示 Cellar，菜单栏没有 Cellar 常驻图标。
- [ ] 侧边栏包含概览、Homebrew、Node、Shell 和操作记录，默认选择概览。
- [ ] 每个一级页面的 titlebar 同时显示标题和用途说明，下面有连续分割线。
- [ ] 页面内容与头部左侧视觉起点一致；概览每行两张等宽卡片，模块页状态总览卡占满内容宽度。
- [ ] Homebrew、Node 和 Shell 在左侧显示为可展开、收起的一级分类，具体功能缩进显示在分类下方。
- [ ] 侧边栏内容可以通过滚轮或触控板滚动，但不显示垂直滚动条。
- [ ] 选择二级页面时对应行保持高亮；分类标题只负责展开收起，不与页面选择产生歧义。
- [ ] Homebrew 六个和 Node 五个二级页面均显示对应真实功能；Shell 未实现的二级页面显示居中空态且不会启动外部命令。
- [ ] 关闭最后一个窗口后 App 退出。

## 启动刷新

- [ ] 正常启动自动执行一次刷新。
- [ ] 切换到任一尚未完成读取的页面时，进度指示器在详情区域水平、垂直居中。
- [ ] 刷新期间工具栏按钮禁用，没有启动第二轮并发刷新。
- [ ] 概览在首次刷新时显示进度，结束后显示刷新时间。
- [ ] 操作记录先出现进行中状态，结束后只保留完成状态。
- [ ] 一项读取失败时，其他已成功模块仍显示真实值。

## Homebrew

- [ ] Apple Silicon 默认安装显示 `/opt/homebrew/bin/brew` 和正确版本。
- [ ] 没有安装 Homebrew 的测试账户显示“未安装”，而不是崩溃或假版本。
- [ ] 概览显示 prefix、repository、cache，以及 Formula、Cask、Tap 和可升级项数量。
- [ ] Homebrew Manager 快照显示可用，但六个页面都不打开或驱动其交互菜单。
- [ ] 查询可能联网或更新 Homebrew API cache 时，界面或文档没有承诺“零写入”或“完全离线”。

### 已安装与卸载

- [ ] 已安装页分别显示 Formula/Cask，搜索、类型筛选、版本和详情与 `brew info --json=v2` 一致。
- [ ] Formula 详情中的依赖和被依赖项可读；数据不可用时不显示臆造值。
- [ ] Cask 详情显示 Homebrew 提供的 artifact，并区分 standard 与 zap 可能影响的范围。
- [ ] Formula 卸载只能选择一个目标，确认界面明确说明不会自动 autoremove。
- [ ] Formula 卸载执行时禁止 Homebrew 自动 update 和 autoremove；完成后重新读取已安装列表。
- [ ] Cask standard 与 zap 是两个明确选项，确认界面展示选定模式和 artifact。
- [ ] standard/zap 结束后报告 Homebrew 实际结果；Cellar 不自行 `rm` artifact，也不因失败补删文件。
- [ ] 用户取消确认时不启动 brew，已安装状态不变。

### 可升级、update 与升级

- [ ] 可升级页分组显示 Formula/Cask 的当前版本和可用版本，与 `brew outdated --json=v2` 一致。
- [ ] `brew update` 是独立按钮和独立确认计划，不由刷新、查看或卸载隐式触发。
- [ ] 单项和多选同类型升级均只包含确认计划中的目标；Formula/Cask 不在一个命令中混合。
- [ ] 升级成功、失败或部分完成后均重新读取已安装与可升级状态。
- [ ] 网络失败、Tap 失败或某个目标失败时保留可确认的实际结果，不宣称整体回滚。

### 发现与安装

- [ ] 空查询不发起全量搜索；输入查询后分别显示 Formula/Cask 结果。
- [ ] 同名 Formula/Cask 保持类型身份，打开详情或安装时不会靠名称猜测类型。
- [ ] 详情失败不会抹掉已有搜索结果，并提供可理解的错误。
- [ ] 安装确认界面显示精确名称、类型和动作；取消确认不启动 brew。
- [ ] Formula/Cask 安装完成或失败后重新读取已安装与可升级状态，并记录 stdout、stderr 和退出码。

### 诊断与配置

- [ ] 诊断页显示 Command Line Tools 状态，但没有安装 CLT 或 Homebrew 的入口。
- [ ] 用户主动运行 `brew doctor` 后，警告、非零退出、stdout 和 stderr 不会被显示成“无问题”。
- [ ] 配置页的 prefix、repository、cache、Cellar 和 Homebrew 配置与 CLI 一致。
- [ ] Tap 列表与真实 Homebrew 状态一致，添加 Tap 前展示计划并确认。
- [ ] 移除 Tap 前扫描关联的已安装 Formula/Cask；存在关联项时拒绝执行并列出阻塞项。
- [ ] 无关联项的 Tap 仍需确认才能移除，完成后重新读取 Tap 与包状态。

### Homebrew 安全边界

- [ ] 所有 mutation 在同一时间只能执行一个；重复点击不会启动第二个命令。
- [ ] mutation 执行期间 `Command-Q` 被拒绝，命令结束后可以退出。
- [ ] 取消确认会丢弃当前计划；再次操作时重新生成计划。
- [ ] 权限不足时只报告失败，不请求 `sudo`，不启动 Helper，不扩大删除范围。
- [ ] 所有 Homebrew 页面都没有安装 CLT/Homebrew、修改 `.zprofile`、cleanup 或自动孤儿依赖删除入口。
- [ ] 部分完成场景在操作记录中保留命令输出与 post-refresh 结果，不显示为原子回滚。

## Node 与 nvm

- [ ] `~/.nvm/alias/default` 指向具体已安装版本时，页面显示对应 Node/npm 路径和版本。
- [ ] default 使用主版本前缀时，选择该主版本中已安装的最高三段式版本。
- [ ] default 使用 `node`、`stable` 或 alias 链时，解析结果与 nvm 已安装目录一致。
- [ ] default 缺失、循环或无法匹配时，Cellar 不擅自选择最新 nvm 版本。
- [ ] Node 页面显示的是当前受控 Node 的全局包，不把其他 Node 版本的包混入列表。
- [ ] 包表按名称排列，显示当前、wanted 和 latest。
- [ ] npm registry、cache 和 prefix 与当前有效配置一致。
- [ ] 只读刷新前后比较全局包、`~/.npmrc`、nvm alias 和 Node 目录，确认没有修改。
- [ ] 全局包安装、更新和卸载只影响页面明确显示的受控 Node 环境，取消计划时不运行 npm。
- [ ] “用于本次 Cellar 会话”只切换 App 后续读取环境，不改变新开或已经打开的终端。
- [ ] 设置 default 后 `~/.nvm/alias/default` 与计划一致，执行结束后页面重新解析默认版本。
- [ ] 当前版本和默认版本不能被卸载；其他版本卸载前显示目录、占用和全局包摘要。
- [ ] 默认和 scope Registry 的设置、删除只修改用户确认的 key，完成后重新读取有效配置。
- [ ] npm cache、node-gyp、孤立 bin 和旧 Node 清理只处理计划列出的路径；计划后状态变化时拒绝执行。
- [ ] 项目 `.nvmrc` 只写入系统目录选择器明确选择的项目；符号链接或非普通文件被拒绝。
- [ ] Node 写操作期间 `Command-Q` 被拒绝，结束后可以退出。

## Node 网络失败

- [ ] 临时断网或使用不可达测试 registry 时，summary、包列表和配置仍可显示。
- [ ] 页面明确显示更新检查失败，不把空 latest 列解释为没有更新。
- [ ] 恢复网络并刷新后，错误消失并显示新的更新数据。
- [ ] 网络失败不会触发自动重试循环或包操作。

## Shell

- [ ] Shell 页面显示与 `/bin/zsh --version` 一致的结果，并读取当前主题、启用插件和已安装自定义插件。
- [ ] `~/.oh-my-zsh` 是目录时显示已安装，不存在时显示未安装。
- [ ] 只读刷新不会修改或生成 `.zshrc`。
- [ ] Oh My Zsh 安装计划不运行 `chsh`、不启动新 Shell，并保留现有 `.zshrc`。
- [ ] 插件只接受 GitHub HTTPS 地址；安装失败不会扩大删除到 custom plugin 目标之外。
- [ ] 应用插件和主题时先备份 `.zshrc`，只写入带 marker 的 managed block，并通过 `zsh -n` 校验。
- [ ] `.zshrc` 为符号链接、目录或其他非普通文件时计划不可执行。
- [ ] 整理只移动计划声明的 zcompdump 和备份文件到 `~/.zsh`，不删除用户 Shell 数据。
- [ ] Zsh Manager 原交互脚本未被 App 驱动，App 只调用 schema v1 adapter。

## 退出与子进程

- [ ] 没有任务时按 `Command-Q` 立即退出。
- [ ] 刷新进行中按 `Command-Q`，本次退出被拒绝。
- [ ] 刷新结束后再次按 `Command-Q`，App 正常退出。
- [ ] 刷新期间关闭最后窗口时，实际行为与产品需求一致，没有无窗口长期驻留。
- [ ] App 退出后检查进程列表，没有 Cellar 启动后遗留的 bash、npm、brew 或 zsh 进程。
- [ ] Homebrew/Node 查询超过 5 分钟、写操作超过 30 分钟时记录 deadline 行为；当前没有用户取消入口，且 terminate 不保证强制结束整个子进程树。

## Application Support

- [ ] 首次正常启动后存在 `~/Library/Application Support/Cellar/Managers/1c9d71b-app2/`。
- [ ] 目录包含 node-manager、homebrew-manager 和 zsh-manager。
- [ ] 重启 App 会复用完整快照，不重复创建随机 staging 目录。
- [ ] App Bundle 内 `Contents/Resources/Managers/` 没有 `.runtime`、日志或临时文件。
- [ ] npm 或 Manager 产生的运行文件只出现在 Application Support 工作副本，不写入 App Bundle。

## 页面与可读性

- [ ] 1080 × 720 下所有一级页面、Homebrew 六个和 Node 五个二级页面无明显截断、重叠或不可达控件。
- [ ] 缩小窗口后侧边栏、表格和错误文本仍可访问。
- [ ] Homebrew、Node、Shell 路径可以选择和复制。
- [ ] 空状态、部分失败和长错误文本不会把窗口撑出屏幕。
- [ ] VoiceOver 能识别侧边栏条目、刷新按钮、表格列和主要状态值。

## Release 产物

- [ ] App 与所有嵌入 Mach-O 只有 arm64 slice。
- [ ] 最低系统版本为 macOS 26.0。
- [ ] Bundle identifier 为 `com.dylanwang.Cellar`。
- [ ] 不存在 `LSUIElement`，也没有 `MenuBarExtra` 场景。
- [ ] Manager Bundle 快照与仓库 `Resources/Managers/` 一致。

## 记录结果

只把实际执行的项目标为完成。需要真实网络、不同 nvm 配置、无 Homebrew 账户或辅助功能工具但本轮没有环境时，保留未选中并在交付说明中列为剩余风险。
