# Cellar 产品需求

状态：当前 v1 行为契约

更新日期：2026-09-19

## 产品定位

Cellar 是一个原生 macOS 开发环境查看工具。它在一个窗口中汇总 Homebrew、Node/npm/nvm、Zsh 和 Oh My Zsh 的本机状态，并显示本次会话的刷新记录。

当前 v1 只读。它不安装、更新、卸载或清理软件包，不修改 npm registry、nvm 默认版本、Shell 配置或 Homebrew 状态。现有 Manager 快照用于建立 App 与 CLI 工具之间的受控读取边界，为后续经过单独设计的写操作做准备。

## 目标

| ID | 目标 |
|---|---|
| G-01 | 从 Finder 或 Xcode 启动时仍能读取常见 Apple Silicon Homebrew 和默认 nvm Node 环境 |
| G-02 | 在同一界面展示 Homebrew、Node/npm 和 Shell 的真实状态，不使用假数据 |
| G-03 | 保持外部命令参数、环境、输出和错误边界明确 |
| G-04 | 单项读取失败时保留其他已经成功取得的状态 |
| G-05 | 不修改用户的全局包、registry、Shell 配置或 Homebrew 安装 |

## v1 非目标

| ID | 非目标 | 原因 |
|---|---|---|
| NG-01 | 安装、更新或卸载 Homebrew formula/cask | Homebrew Manager 目前没有稳定 App JSON 契约 |
| NG-02 | 安装、更新、卸载 npm 全局包 | 写操作需要独立的计划、确认、执行和结果设计 |
| NG-03 | 修改 npm registry 或 scope registry | v1 只展示配置 |
| NG-04 | 安装、切换、设为默认或卸载 Node 版本 | App 当前只解析默认 nvm 环境 |
| NG-05 | 修改 Zsh 或 Oh My Zsh | Zsh Manager 目前是交互式脚本 |
| NG-06 | root 操作、Privileged Helper 或 `sudo` | v1 能力不需要提权 |
| NG-07 | 后台驻留或菜单栏入口 | Cellar 是普通前台窗口应用 |
| NG-08 | Intel、Universal Binary、Rosetta 或 macOS 15 | 平台只支持 macOS 26+、arm64 |

## 导航与窗口

Cellar 使用两栏 `NavigationSplitView`。侧边栏固定包含：概览、Homebrew、Node、Shell 和操作记录。启动时默认选择概览。

| ID | 行为 |
|---|---|
| UI-01 | 首次创建窗口时默认内容尺寸为 1080 × 720 点，用户可以调整窗口大小 |
| UI-02 | App 启动后直接显示普通前台窗口，不创建 `MenuBarExtra` |
| UI-03 | 关闭最后一个窗口时请求退出 App |
| UI-04 | 没有活动任务时 `Command-Q` 立即退出 |
| UI-05 | 有活动任务时拒绝当前退出请求；任务结束后用户可以再次退出 |
| UI-06 | 工具栏刷新按钮在刷新期间禁用，重复刷新请求不启动第二轮任务 |

## 启动与刷新

正常启动后，根视图自动发起一次刷新。Hosted XCTest 进程不执行自动刷新，防止测试访问用户真实环境。

一次刷新按以下顺序执行：

1. 验证 App Bundle 中的 Manager 快照。
2. 将当前版本快照安装到 Application Support；已有完整副本直接复用，不完整副本重新安装。
3. 并行读取 Homebrew、Node 和 Shell 状态。
4. 分别保存成功结果和错误。
5. 用一条完成记录替换操作记录中的“进行中”条目。

如果快照安装失败，本轮不启动后续三项读取。Homebrew、Node 或 Shell 单项失败不影响另外两项结果。

## 页面行为

### 概览

概览显示四张状态卡：

- Homebrew：版本和可执行文件路径；未读取时显示不可用。
- Node：Node 版本和全局包数量；未读取时显示不可用。
- Shell：Zsh 版本和 Oh My Zsh 安装状态。
- Manager 快照：版本和 Application Support 路径。

首次刷新期间显示进度。刷新完成后如有错误，在“部分状态读取失败”区域逐项列出，并显示最后刷新时间。

### Homebrew

| ID | 展示内容 |
|---|---|
| HB-01 | 是否在受控 PATH 中找到 `brew` |
| HB-02 | `brew --version` 输出的首行 |
| HB-03 | brew 可执行文件绝对路径 |
| HB-04 | Homebrew Manager 快照是否存在 |

找不到 brew 是正常的“未安装”状态，不是命令失败。找到 brew 但版本命令非零退出时，页面显示读取失败。

### Node

Node 页面使用 Node Manager schema v1 的只读 JSON 命令。

| ID | 命令 | 用途 |
|---|---|---|
| ND-01 | `summary` | Node/npm 路径、版本、全局 prefix/root 和有效 registry |
| ND-02 | `packages` | 当前 Node 环境的顶层 npm 全局包 |
| ND-03 | `config` | registry、cache、prefix 及 user/project/global registry 层 |
| ND-04 | `outdated` | 当前、wanted 和 latest 版本 |

`summary`、`packages` 和 `config` 是页面核心数据，按顺序读取。`outdated` 最后执行；它访问当前配置的 npm registry，失败时页面仍显示核心数据，并单独显示更新检查错误。

包表按本地化名称顺序排列，列出包名、当前版本、wanted 和 latest。没有更新数据时使用占位符，不把网络失败解释为“全部已是最新”。

### Shell

| ID | 展示内容 |
|---|---|
| SH-01 | `/bin/zsh --version` 的完整单行结果 |
| SH-02 | `~/.oh-my-zsh` 是否是目录 |
| SH-03 | Oh My Zsh 检查路径 |
| SH-04 | Zsh Manager 快照是否存在 |

v1 不读取、解析或修改 `.zshrc`。

### 操作记录

操作记录只存在于当前 App 进程内，不持久化。刷新开始时加入“进行中”记录，结束后替换为成功或失败记录。失败详情包含本轮各模块的可读错误。

关闭并重新打开 App 后，旧记录不会恢复。

## 状态与错误契约

| 状态 | 用户看到的行为 |
|---|---|
| 尚未刷新 | 页面没有业务数据；正常启动会立即进入刷新 |
| 首次刷新 | 相关页面显示 `ProgressView`，刷新按钮禁用 |
| 全部成功 | 页面展示真实状态，操作记录标记成功 |
| 部分失败 | 成功模块继续展示；概览和对应页面显示失败原因 |
| Node 更新检查失败 | Node 核心数据和包表保留，更新列没有可用值，并显示独立错误 |
| 快照失败 | 后续探测不运行，概览显示 Manager 快照错误 |
| JSON 无效 | 不解析文本作为替代数据，显示无法识别的输出错误 |
| schema 不是 v1 | 显式报告不支持的 schema，不尝试宽泛兼容 |

外部工具的 stderr、非零退出状态和 Manager 业务错误必须保留。界面不能把失败显示成成功或空数据。

## Node 环境选择

nvm 的每个 Node 版本有独立的 npm 全局包目录。Cellar 页面展示的是本轮受控环境选择到的 Node，不代表用户所有终端，也不代表整台机器只有这一套全局包。

环境解析规则：

1. 检查 `~/.nvm/versions/node/` 下可执行的三段式版本目录。
2. 解析 `~/.nvm/alias/default`，支持具体版本、版本前缀、`node`、`stable` 和可继续解析的 alias 文件。
3. alias 明确匹配已安装版本时，把对应 `bin` 放在 PATH 首位。
4. alias 缺失、循环、无法解析或没有匹配版本时，不猜测最新版本。
5. 之后依次使用 `/opt/homebrew/bin`、`/opt/homebrew/sbin`、`/usr/local/bin` 和系统路径。

Cellar 不加载 `.zshrc`，也不会改变已经打开的终端所使用的 Node 版本。

## 文件、网络与隐私

Cellar 不包含遥测、账户系统或项目自己的网络服务。

App 启动后可能产生以下外部行为：

- 把 Bundle 中的 Manager 快照复制到 `~/Library/Application Support/Cellar/Managers/<version>/`。
- 运行 `brew --version` 和 `/bin/zsh --version`。
- 通过 Node Manager 运行 npm 只读命令。
- `npm outdated` 访问用户当前配置的 npm registry，并遵守 npm 自身的网络和 cache 行为。

Cellar v1 不写入 `~/.npmrc`、`~/.zshrc`、`~/.nvm`，不改变全局包，不调用 `sudo`。拒绝网络请求或 npm registry 不可用时，只影响更新检查。

## 功能需求

| ID | 需求 | 阶段 |
|---|---|---|
| FR-01 | 提供五个固定一级页面和侧边栏导航 | v1 |
| FR-02 | 启动后自动刷新真实环境状态 | v1 |
| FR-03 | Homebrew 页面显示安装、版本、路径和快照状态 | v1 |
| FR-04 | Node 页面显示 summary、全局包、配置和可更新版本 | v1 |
| FR-05 | Shell 页面显示 Zsh 与 Oh My Zsh 状态 | v1 |
| FR-06 | 操作记录保存当前会话的刷新结果 | v1 |
| FR-07 | 单模块失败不清除其他模块结果 | v1 |
| FR-08 | Node 更新检查失败时保留核心 Node 数据 | v1 |
| FR-09 | 活动任务期间拒绝退出 | v1 |
| FR-10 | Manager 快照从 Bundle 安装到版本化 Application Support 目录 | v1 |

## 非功能需求

| ID | 需求 |
|---|---|
| NFR-01 | 最低 macOS 26.0，仅构建 arm64 |
| NFR-02 | 外部命令使用绝对 executable 和参数数组，不使用 `bash -c` |
| NFR-03 | 明确设置子进程环境、目录和标准 IO |
| NFR-04 | App Bundle Resources 不产生运行时写入 |
| NFR-05 | 自动测试不访问用户真实包管理环境和 Application Support |
| NFR-06 | `scripts/` 在 App 开发期间保持冻结 |
| NFR-07 | View 不直接执行外部命令，Models 不执行 IO |

## 验收边界

自动测试和无签名构建可以验证 JSON、环境解析、进程输出、快照复制、退出策略、macOS 版本和 arm64 产物。它们不能证明真实 brew/npm/nvm 配置、registry 网络、窗口视觉或 macOS 退出交互。

真实机器验收使用[人工验收清单](../manual-smoke-checklist.md)。没有执行的项目不得描述为已经验证。

## 后续阶段

写操作不属于当前 v1。后续如要接入，必须先定义稳定的 query、plan、confirm、execute 和 result 契约，并分别处理操作锁、状态复验、取消、超时、日志、部分完成和恢复。Homebrew 与 Zsh 需要先拥有面向 App 的稳定机器协议；不能自动驾驶现有交互式菜单。
