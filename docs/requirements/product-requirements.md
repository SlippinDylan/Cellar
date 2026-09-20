# Cellar 产品需求

状态：Homebrew 本轮目标行为契约

更新日期：2026-09-20

## 产品定位

Cellar 是一个原生 macOS 开发环境工具。它在一个窗口中汇总 Homebrew、Node/npm/nvm、Zsh 和 Oh My Zsh 的本机状态，并显示本次会话的操作记录。

Homebrew 与 Node 模块提供写操作；Shell 当前保持只读。Homebrew 能力通过 Bridge 受控调用已发现的绝对 `brew` 路径，Node 通过 Manager schema v1 的机器协议执行；App 不驱动交互菜单。每项写操作先展示计划并要求确认，执行后重新读取真实状态。

## 目标

| ID | 目标 |
|---|---|
| G-01 | 从 Finder 或 Xcode 启动时仍能读取常见 Apple Silicon Homebrew 和默认 nvm Node 环境 |
| G-02 | 在同一界面展示 Homebrew、Node/npm 和 Shell 的真实状态，并完成受控的 Homebrew 常用操作 |
| G-03 | 保持外部命令参数、环境、输出和错误边界明确 |
| G-04 | 单项读取失败时保留其他已经成功取得的状态 |
| G-05 | Homebrew 与 Node 写操作保持范围明确；Shell 不产生状态变更 |

## v1 非目标

| ID | 非目标 | 原因 |
|---|---|---|
| NG-01 | 安装 Command Line Tools 或 Homebrew、修改 `.zprofile` | 环境引导与系统配置不属于本轮范围 |
| NG-05 | 修改 Zsh 或 Oh My Zsh | Zsh Manager 目前是交互式脚本 |
| NG-06 | root 操作、Privileged Helper 或 `sudo` | v1 能力不需要提权 |
| NG-07 | 后台驻留或菜单栏入口 | Cellar 是普通前台窗口应用 |
| NG-08 | Intel、Universal Binary、Rosetta 或 macOS 15 | 平台只支持 macOS 26+、arm64 |
| NG-09 | Homebrew cleanup 或自动删除孤儿依赖 | 删除范围必须由用户明确选择，不做隐式扩张 |
| NG-10 | App 自行删除 Cask 残留文件 | artifact 仅展示和报告，删除交由 Homebrew standard/zap 语义 |
| NG-11 | 批量卸载 Formula/Cask | 本轮卸载限定单个目标，降低误操作和部分完成风险 |

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
| UI-07 | 每个一级页面在系统 titlebar 显示标题和一句用途说明，详情区顶部使用统一分割线 |
| UI-08 | 页面内容使用一致的水平边距；概览采用两列状态卡片，模块页的状态总览卡占满内容宽度 |
| UI-09 | Homebrew、Node 和 Shell 在左侧 Sidebar 中作为可折叠一级分类，具体功能作为第二级选择项；Homebrew 与 Node 页面提供真实功能，Shell 当前只有“概览”接入真实数据 |
| UI-10 | 左侧 Sidebar 保留垂直滚动，但不显示滚动条 |

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

概览以两列布局显示四张状态卡，每张卡占满所在列：

- Homebrew：版本和可执行文件路径；未读取时显示不可用。
- Node：Node 版本和全局包数量；未读取时显示不可用。
- Shell：Zsh 版本和 Oh My Zsh 安装状态。
- Manager 快照：版本和 Application Support 路径。

首次刷新期间显示进度。刷新完成后如有错误，在“部分状态读取失败”区域逐项列出，并显示最后刷新时间。

### Homebrew

Homebrew 使用现有六个二级页面。安装入口位于“发现”，卸载入口位于“已安装”，升级入口位于“可升级”，Tap 管理位于“配置”；不新增只承载单个动作的侧边栏页面。

#### 概览

| ID | 展示内容 |
|---|---|
| HB-01 | 是否在受控 PATH 中找到 `brew` |
| HB-02 | Homebrew 版本和 brew 可执行文件绝对路径 |
| HB-03 | prefix、repository 和 cache 路径 |
| HB-04 | 已安装 Formula、Cask、Tap 与可升级项数量 |
| HB-05 | 最近一次读取时间和各数据分区错误 |

找不到 brew 是正常的“未安装”状态，不是命令失败。找到 brew 但基础命令非零退出时，页面显示读取失败。Homebrew Manager 快照存在不代表 App 会调用它。

#### 已安装

| ID | 行为 |
|---|---|
| HB-10 | Formula 与 Cask 分组显示，支持名称搜索和类型筛选 |
| HB-11 | 每项显示名称、显示名称、已安装版本、描述和可用的来源信息 |
| HB-12 | Formula 详情展示依赖、被依赖关系和安装信息；缺失字段明确显示不可用 |
| HB-13 | Cask 详情展示 Homebrew 报告的 artifact；计划只检查其中无 glob 的精确绝对路径、`~/` 路径和明确 App bundle，显示当前存在项与预计占用空间 |
| HB-14 | Formula 只允许单目标卸载；确认计划明确声明不执行 autoremove |
| HB-15 | Cask 单目标卸载必须由用户分别选择 standard 或 zap；两者不使用模糊的统一“卸载”动作，postflight 报告仍存在的已声明路径 |
| HB-16 | Formula/Cask 卸载显式禁止自动更新；App 不自行 `rm` artifact 或其他残留 |

#### 可升级

| ID | 行为 |
|---|---|
| HB-20 | 分组列出可升级 Formula/Cask，显示当前版本和可用版本 |
| HB-21 | 用户可以选择一项或多项进行升级；确认计划列出精确目标和类型 |
| HB-22 | `brew update` 是独立动作，不与查看或卸载隐式绑定 |
| HB-23 | 升级执行后重新查询可升级与已安装状态；部分目标失败时逐项保留结果 |

#### 发现

| ID | 行为 |
|---|---|
| HB-30 | 用户输入非空查询后分别搜索 Formula 与 Cask，不在空查询时请求全部远端目录 |
| HB-31 | 搜索结果可以继续读取详情；详情加载失败不抹掉已有搜索结果 |
| HB-32 | 安装前展示目标名称、类型、版本/描述等可用信息和将执行的命令语义 |
| HB-33 | Formula/Cask 安装使用明确类型，禁止依靠同名解析猜测目标 |

#### 诊断

| ID | 行为 |
|---|---|
| HB-40 | 显示 Command Line Tools 是否可用，但不提供安装入口 |
| HB-41 | 用户主动运行 `brew doctor`；保留退出状态、stdout 和 stderr，不把非零结果显示为“无问题” |
| HB-42 | 展示受控 PATH、brew 路径以及 App 能识别的环境问题 |

#### 配置与 Tap

| ID | 行为 |
|---|---|
| HB-50 | 显示 prefix、repository、cache、Cellar 及 Homebrew 配置信息 |
| HB-51 | 列出当前 Tap，并支持添加合法的 Tap 名称 |
| HB-52 | 移除 Tap 前扫描该 Tap 提供且当前已安装的 Formula/Cask；存在关联安装项时拒绝执行并列出阻塞项 |
| HB-53 | 安全检查通过后仍需展示计划并确认；执行后重新读取 Tap 与包状态 |

#### 写操作通用契约

所有 Homebrew mutation 使用同一流程：

1. 根据当前读取结果生成只包含一个明确意图的计划。
2. 在确认界面展示动作、目标、类型、模式、预期副作用和不包含的动作。
3. 用户确认后取得 Homebrew 操作锁。
4. Bridge 使用已发现的绝对 `brew` 路径、参数数组、受控环境和空 stdin 执行。
5. 保留退出码、stdout、stderr 与逐项目结果。
6. 无论成功或失败，都在命令结束后重新读取受影响页面的真实状态。

写操作不是事务，也不承诺回滚。Homebrew 或 Tap 执行过程中可能已经修改部分目标、依赖或 cache；界面必须把这种情况显示为部分完成，不能只用单个成功布尔值覆盖实际结果。计划只在当前确认流程中有效，取消后再次操作需要重新生成。

卸载 Formula/Cask 时必须同时禁止隐式 `brew update` 和自动 `autoremove`。Cask zap 可能由 Homebrew 删除其定义的关联文件，但 Cellar 不自行删除 artifact，也不在失败后补做文件删除；postflight 只报告 Homebrew 输出和重新查询到的状态。

### Node

Node 页面使用 Node Manager schema v1。查询环境固定关闭 JSON execute；只有确认后的单次写操作才在对应子进程环境中设置 `NODE_MANAGER_ALLOW_JSON_EXECUTE=1`，项目 `.nvmrc` 还必须设置独立的 project-write 开关。

左侧 Node 分类包含概览、全局包、Node 版本、Registry 和维护。每个页面只承载对应职责。

| ID | 命令 | 用途 |
|---|---|---|
| ND-01 | `summary` | Node/npm 路径、版本、全局 prefix/root 和有效 registry |
| ND-02 | `packages` | 当前 Node 环境的顶层 npm 全局包 |
| ND-03 | `config` | registry、cache、prefix 及 user/project/global registry 层 |
| ND-04 | `outdated` | 当前、wanted 和 latest 版本 |

`summary`、`packages` 和 `config` 是页面核心数据，按顺序读取。`outdated` 最后执行；它访问当前配置的 npm registry，失败时页面仍显示核心数据，并单独显示更新检查错误。

包表按本地化名称顺序排列，列出包名、当前版本、wanted 和 latest。没有更新数据时使用占位符，不把网络失败解释为“全部已是最新”。

#### Node 写操作

- 全局包安装接受 Manager 校验过的安全 package spec；更新和卸载只作用于当前受控 Node 环境中的明确包名。
- Node 版本支持安装、用于本次 Cellar 会话、设置 nvm default 和安全卸载。“会话使用”不修改用户终端；default 是独立持久操作。
- Registry 支持设置或删除用户默认 Registry，以及设置或删除明确 scope 的 Registry。
- 维护操作限定为 Manager 声明的 npm cache 校验/清理、node-gyp cache、孤立 bin、无用户包旧 Node 和 Manager 日志；候选删除使用 plan token 并在执行前复验。
- 项目 `.nvmrc` 只允许写入用户通过系统目录选择器明确选择的目录；符号链接或计划后状态变化必须拒绝执行。
- 所有 mutation 经过 plan、确认、execute 和 post-refresh；计划五分钟过期，同一 App 状态下不并发执行第二项 Node 操作。

### Shell

左侧 Shell 分类预留概览、Oh My Zsh、插件与主题和维护。当前只有概览接入真实数据；其他页面不启动命令。

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
| 首次刷新 | 相关页面在完整详情区域水平、垂直居中显示 `ProgressView`，刷新按钮禁用 |
| 全部成功 | 页面展示真实状态，操作记录标记成功 |
| 部分失败 | 成功模块继续展示；概览和对应页面显示失败原因 |
| Homebrew 分区失败 | 已成功读取的 Homebrew 分区继续展示；失败分区提供重试，不把缺失数据解释为空集合 |
| Homebrew 操作等待确认 | 确认界面列出精确动作、目标、模式和明确排除项；取消不执行命令 |
| Homebrew 操作部分完成 | 展示实际完成、失败和无法确认的项目；post-refresh 结果优先于执行前快照 |
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
- 运行 Homebrew 查询命令和 `/bin/zsh --version`。
- 通过 Node Manager 运行 npm/nvm 查询，以及用户确认的受控写操作。
- `npm outdated` 访问用户当前配置的 npm registry，并遵守 npm 自身的网络和 cache 行为。
- Homebrew 的搜索、详情、过期检查、Tap、`update`、安装和升级可能访问 Homebrew 服务或第三方 Tap，并写入 Homebrew 自己管理的 API cache、下载 cache 和安装目录。
- 用户确认的 Homebrew 安装、更新、升级、卸载与 Tap 变更会修改 Homebrew 管理的本机状态；命令不是事务，失败时可能已经部分完成。

Cellar 只在用户确认对应计划后修改 npm 全局包、`~/.npmrc`、`~/.nvm`、npm/node-gyp cache 或用户选择项目的 `.nvmrc`。它不写入 `.zshrc` 或 `.zprofile`，不改变 Shell 状态，不调用 `sudo`。拒绝网络请求会影响 npm 更新检查、Node/nvm 安装以及依赖网络的 Homebrew 查询或操作；本机已有状态应尽量继续展示。

## 功能需求

| ID | 需求 | 阶段 |
|---|---|---|
| FR-01 | 提供五个固定一级页面和侧边栏导航 | v1 |
| FR-02 | 启动后自动刷新真实环境状态 | v1 |
| FR-03 | Homebrew 六个页面提供概览、已安装、可升级、发现、诊断、配置与 Tap | Homebrew 阶段 |
| FR-04 | Node 页面显示 summary、全局包、配置和可更新版本 | v1 |
| FR-05 | Shell 页面显示 Zsh 与 Oh My Zsh 状态 | v1 |
| FR-06 | 操作记录保存当前会话的刷新结果 | v1 |
| FR-07 | 单模块失败不清除其他模块结果 | v1 |
| FR-08 | Node 更新检查失败时保留核心 Node 数据 | v1 |
| FR-09 | 活动任务期间拒绝退出 | v1 |
| FR-10 | Manager 快照从 Bundle 安装到版本化 Application Support 目录 | v1 |
| FR-11 | Formula/Cask 安装、`brew update` 与选择升级经过计划、确认、执行和 post-refresh | Homebrew 阶段 |
| FR-12 | Formula 单目标卸载禁止自动更新和 autoremove | Homebrew 阶段 |
| FR-13 | Cask standard/zap 作为两个明确模式执行，App 不自行删除 artifact | Homebrew 阶段 |
| FR-14 | Tap 添加与安全移除经过关联安装项检查和用户确认 | Homebrew 阶段 |
| FR-15 | Homebrew 部分完成、stdout、stderr 和退出状态进入当前会话操作记录 | Homebrew 阶段 |

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
| NFR-08 | Homebrew Bridge 只调用已发现的绝对 `brew` URL，参数按数组传递，stdin 为空 |
| NFR-09 | 同一时间最多执行一个包管理写操作；写操作期间拒绝重复提交和 App 退出 |

## 验收边界

自动测试和无签名构建可以验证 JSON、环境解析、进程输出、快照复制、退出策略、macOS 版本和 arm64 产物。它们不能证明真实 brew/npm/nvm 配置、registry 网络、窗口视觉或 macOS 退出交互。

真实机器验收使用[人工验收清单](../manual-smoke-checklist.md)。没有执行的项目不得描述为已经验证。

## 后续阶段

当前仍不包含安装 Command Line Tools 或 Homebrew、修改 `.zprofile`、Homebrew cleanup、自动孤儿依赖删除、App 自行清理 Cask 残留、`sudo`、Privileged Helper 和 Shell 写操作。未来增加这些能力时必须重新定义权限、删除范围、恢复与测试契约，不能从当前包管理权限中推导授权。
