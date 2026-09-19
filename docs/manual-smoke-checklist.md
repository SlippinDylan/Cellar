# Cellar 人工验收清单

本清单用于验证自动测试无法证明的真实 macOS、窗口和本机工具行为。检查会读取用户的 Homebrew、Node/npm/nvm 和 Shell 状态；执行前确认当前机器适合测试。

除“Application Support”一节外，检查过程中不应产生持久写入。不要使用有价值的生产环境验证未来写操作。

## 启动与窗口

- [ ] 从 Finder 启动 App，主窗口立即出现。
- [ ] 首次创建且没有窗口恢复状态时，内容尺寸为 1080 × 720 点。
- [ ] 窗口可以使用系统控件调整大小。
- [ ] Dock 显示 Cellar，菜单栏没有 Cellar 常驻图标。
- [ ] 侧边栏包含概览、Homebrew、Node、Shell 和操作记录，默认选择概览。
- [ ] 关闭最后一个窗口后 App 退出。

## 启动刷新

- [ ] 正常启动自动执行一次刷新。
- [ ] 刷新期间工具栏按钮禁用，没有启动第二轮并发刷新。
- [ ] 概览在首次刷新时显示进度，结束后显示刷新时间。
- [ ] 操作记录先出现进行中状态，结束后只保留完成状态。
- [ ] 一项读取失败时，其他已成功模块仍显示真实值。

## Homebrew

- [ ] Apple Silicon 默认安装显示 `/opt/homebrew/bin/brew` 和正确版本。
- [ ] 没有安装 Homebrew 的测试账户显示“未安装”，而不是崩溃或假版本。
- [ ] Homebrew 页面只执行版本读取，不运行 update、install、uninstall 或 cleanup。
- [ ] Homebrew Manager 快照显示可用，但页面不打开或驱动其交互菜单。

## Node 与 nvm

- [ ] `~/.nvm/alias/default` 指向具体已安装版本时，页面显示对应 Node/npm 路径和版本。
- [ ] default 使用主版本前缀时，选择该主版本中已安装的最高三段式版本。
- [ ] default 使用 `node`、`stable` 或 alias 链时，解析结果与 nvm 已安装目录一致。
- [ ] default 缺失、循环或无法匹配时，Cellar 不擅自选择最新 nvm 版本。
- [ ] Node 页面显示的是当前受控 Node 的全局包，不把其他 Node 版本的包混入列表。
- [ ] 包表按名称排列，显示当前、wanted 和 latest。
- [ ] npm registry、cache 和 prefix 与当前有效配置一致。
- [ ] 刷新前后比较全局包、`~/.npmrc`、nvm alias 和 Node 目录，确认没有修改。

## Node 网络失败

- [ ] 临时断网或使用不可达测试 registry 时，summary、包列表和配置仍可显示。
- [ ] 页面明确显示更新检查失败，不把空 latest 列解释为没有更新。
- [ ] 恢复网络并刷新后，错误消失并显示新的更新数据。
- [ ] 网络失败不会触发自动重试循环或包操作。

## Shell

- [ ] Shell 页面显示与 `/bin/zsh --version` 一致的结果。
- [ ] `~/.oh-my-zsh` 是目录时显示已安装，不存在时显示未安装。
- [ ] 刷新不会读取、修改或生成 `.zshrc`。
- [ ] Zsh Manager 快照显示可用，但页面不驱动交互菜单。

## 退出与子进程

- [ ] 没有任务时按 `Command-Q` 立即退出。
- [ ] 刷新进行中按 `Command-Q`，本次退出被拒绝。
- [ ] 刷新结束后再次按 `Command-Q`，App 正常退出。
- [ ] 刷新期间关闭最后窗口时，实际行为与产品需求一致，没有无窗口长期驻留。
- [ ] App 退出后检查进程列表，没有 Cellar 启动后遗留的 bash、npm、brew 或 zsh 进程。
- [ ] 外部命令长时间无响应时记录实际表现；当前版本没有用户取消和 deadline，不能把该场景标记为已支持。

## Application Support

- [ ] 首次正常启动后存在 `~/Library/Application Support/Cellar/Managers/1c9d71b/`。
- [ ] 目录包含 node-manager、homebrew-manager 和 zsh-manager。
- [ ] 重启 App 会复用完整快照，不重复创建随机 staging 目录。
- [ ] App Bundle 内 `Contents/Resources/Managers/` 没有 `.runtime`、日志或临时文件。
- [ ] npm 或 Manager 产生的运行文件只出现在 Application Support 工作副本，不写入 App Bundle。

## 页面与可读性

- [ ] 1080 × 720 下五个页面无明显截断、重叠或不可达控件。
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
