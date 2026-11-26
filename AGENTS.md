# Cellar Agent 指南

本文件是仓库导航和工作契约，不是完整手册。只读取当前任务涉及的链接；产品行为、架构、开发流程和外部依据分别维护在对应权威文档中。

## 项目概述

Cellar 是面向 macOS 26 及以上版本、仅支持 Apple Silicon 的原生开发环境管理工具。1.0 采用任务导向的 Home、Library、Discover、环境和维护，统一组织 Homebrew Formula/Cask、npm 全局包、Node/nvm 与终端配置，软件更新整合在 Library 内，同时保留 provider 身份和安全边界。主 App 使用 Swift 6、SwiftUI、Foundation 和少量 AppKit；现有 CLI Manager 以快照随 App 打包，但 App 不驱动其交互菜单。

[产品需求](docs/requirements/product-requirements.md)是 1.0 用户行为和安全边界的唯一权威来源。1.0 源码已实现，尚未公开发布；未执行的真实环境与 UI 验收见人工清单。[架构文档](docs/architecture/macos-app-architecture.md)描述当前实现，构建和验证见[开发指南](docs/development.md)。

## 开始工作

1. 检查 Git 状态，保留已有未提交改动，不清理或回退无关内容。
2. 阅读本文件及任务涉及的权威文档；历史脚本资料不代表 App 当前行为。
3. 搜索现有类型、调用点和测试，确认职责、数据流及外部副作用后再修改。
4. macOS、Swift、SwiftUI、Foundation 或 AppKit 功能编码前，通过 Sosumi 核对 Apple 官方文档。
5. 需求、公共契约或架构方向存在实质歧义时，列出事实和影响，等待确认。

## 仓库地图

- `CellarApp.swift`：SwiftUI Scene、AppKit delegate 和退出策略。
- `Features/`：Home、Library（包含软件更新）、Discover、环境、维护与主窗口 Settings；保留的旧 provider 页面不进入主导航。
- `Services/`：App 状态、刷新编排、任务登记和系统探测。
- `Models/`：页面状态、Manager JSON DTO、操作计划与结果模型。
- `Bridge/`：`Process`、受控环境、Manager 快照安装和 JSON 解码。
- `Resources/Managers/`：从冻结脚本复制的只读生产快照。
- `CellarTests/`：契约、环境解析、进程、生命周期和快照测试。
- `Config/Release/`、`Config/Generated/`：发布请求与生成的 Xcode 版本配置。
- `.github/`、`tools/`：CI、Release、Discord、DMG、Sparkle 和分发元数据自动化。
- `scripts/`：既有 CLI Manager；App 开发期间冻结。
- `docs/`：产品、架构、开发、研究和人工验收文档。

依赖方向是 `Features → Services → Bridge → Manager/系统 CLI`，共享数据由 `Models` 表达。View 不直接运行命令；Bridge 不依赖具体页面。

## 不可破坏的边界

### 能力边界

- Homebrew 可以查询、搜索和管理 Formula/Cask、诊断、配置和 Tap；支持 typed batch install/update 和单项 uninstall。批量一次只处理一个 provider/type，顺序执行并保留逐项结果。
- 单项安装/更新从卡片直接开始；批量、卸载、zap、清理和配置修改按产品矩阵进行一次任务专用确认。内部计划、状态指纹和 post-refresh 继续作为安全边界。写操作不是事务，界面与本地日志必须保留部分完成语义；界面结果不受日志等级过滤。
- Command Line Tools 只通过 `xcode-select --install` 请求系统对话框。Homebrew 只接受官方 latest stable Release 的精确 `Homebrew.pkg` 及其有效官方 SHA-256；digest 或 `pkgutil` Apple Developer ID 签名链校验任一缺失或失败都必须 fail closed、不得执行，并报告原因及 Homebrew 官方链接。全部通过后通过 macOS 一次系统管理员授权静默执行 `/usr/sbin/installer -pkg ... -target /`；该安装流程不执行远端安装脚本、不收集密码、不安装常驻特权服务。
- 仅在通过 Cellar 成功安装 Homebrew 后自动幂等追加 `brew shellenv` 到 `~/.zprofile`（拒绝符号链接，不覆盖原有内容），其他场景不修改 `.zprofile`；不执行 Homebrew cleanup，不自动删除孤儿依赖。Library 的增强 Cask 卸载只在 Homebrew 卸载成功且复查确认目标已移除后，删除确认清单内可验证归属的关联数据和目标下载缓存；共享、归属未知或复验失败的路径保留。不得按名称模糊搜索后删除，也不得清空整个 Homebrew 缓存。
- Formula/Cask 卸载必须显式禁止 Homebrew 自动更新和 autoremove。增强 Cask 卸载使用 standard，不把整个 zap stanza 静默交给 Homebrew；应用本体仍由 Homebrew 处理，额外删除限于强类型确认计划。删除前复验文件身份，拒绝符号链接祖先和任意路径输入。
- 受限 Cask 残留删除可通过 macOS 系统管理员授权执行一次性清理模式；只接受真实用户主目录下的允许路径、精确文件身份和有界请求，遵守任务取消及生命周期约束。Cellar 不收集密码、不安装常驻特权服务、不把整条 brew 命令提权。Homebrew 自身需 sudo 的卸载钩子仍按实际失败或部分完成报告。
- Homebrew Manager 没有稳定 App JSON 契约，Homebrew 由 Bridge 使用绝对 `brew` 路径和受控环境调用。Zsh 原交互 Manager 同样不被驱动；App 只调用相邻的 Cellar-owned schema v1 adapter。
- Node 通过 Manager schema v1 读取状态，并仅在产品确认规则满足后启用单次 JSON execute。支持的写操作限定为全局 npm 包、nvm/Node 版本、Registry 和 Manager 维护（不管理单个项目的 `.nvmrc`）；npm 搜索与操作始终绑定明确 Node 环境。
- Shell 通过 App 专用 schema v1 adapter 查询和修改 Oh My Zsh、插件、主题及受限 Zsh 文件布局；不得驱动交互菜单或执行协议外的 Shell 命令。
- 主导航固定为 Home、Library、Discover、环境（内部路由仍为 tools）、维护；软件更新与待更新筛选位于 Library；侧边栏左下方依次显示 Settings 和 About，不提供活动记录页面或菜单。环境按顺序包含 Terminal、Brew Tap、npm Registry、Node.js，操作页仅在短页面底部或长页面正文末尾以无卡片、居中紧凑的小号次要文字保留必要上下文；维护包含检查与清理，分别保留 Homebrew 检查／npm 缓存校验和既有受限清理；Zsh 文件整理仍在终端，Homebrew 目录更新仍在 Homebrew Tap 页。Settings 使用通用／环境信息分类，前者提供语言与日志偏好，后者集中展示 Cellar 识别和使用的完整环境信息，不冒充已打开终端的环境；About 是独立页面，显示放大的图标、名称、版本、检查更新和底部 Studio 版权署名。不声明独立 Settings scene，Command-Comma 经共享导航意图前置或重建主窗口并选择 Settings。
- 卡片本体不导航，只显示关键信息和系统浏览器网站链接。Library 卡片提供单项更新与卸载，Discover 卡片保留状态相关主动作。普通 UI 不显示原始命令或内部计划术语。
- 安装、配置与维护等任务进度与最近完成结果在主窗口顶部跨页面显示，批量结果保留逐项状态；刷新进度只在工具栏显示。文件日志位于 `~/Library/Logs/Cellar/`，由 Settings 配置等级与保存期限；原始命令和 stdout/stderr 不进入文件日志，只在显式当前会话诊断或既有受控 Manager 日志中提供。旧 `activity.json` 不再读写、迁移或删除。运行中任务不提供用户手动停止；内部取消只用于任务所有者结束、超时和生命周期回收。
- 用户可见字符串进入 String Catalog，支持 English、简体中文、繁体中文、日本語、한국어、Deutsch、Français、Español，默认 Follow System。

### Node 环境

- npm 全局包属于具体 Node 安装，不能表示为整台机器唯一的一组包。
- App 优先使用 `~/.nvm/alias/default` 能明确解析到的已安装版本；解析失败时不得猜测最新版。
- Finder/Xcode 启动环境不读取 `.zshrc`。受控 PATH 只包含解析出的默认 nvm `bin` 和项目批准的系统路径。
- `npm outdated` 失败是独立的部分失败，不得抹掉已经读取的 Node、npm、包列表和配置。

### Manager 快照

- 未经用户再次明确授权，不修改 `scripts/` 下的代码、配置、测试或文档。
- `Resources/Managers/` 必须来自生产白名单或明确的生产文件集合，并记录来源 commit。冻结 Manager 原文件保持逐字节一致。
- App 专属 adapter 必须与冻结来源分文件维护并记录性质；不得直接修补复制的交互 Manager。
- App Bundle Resources 只读。运行副本位于 `~/Library/Application Support/Cellar/Managers/<version>/`。

### 进程与生命周期

- 使用绝对 executable URL 和参数数组；禁止用 `bash -c` 拼接命令。
- 启动前显式设置环境、工作目录、stdin、stdout 和 stderr，并分别保留输出及退出状态。
- 进程取消时终止对应子进程；退出后不得遗留 App 启动的任务。
- App 是普通前台窗口，默认尺寸为 1080 × 720 点；不使用 `MenuBarExtra`，不后台驻留。
- 无活动任务时 `Command-Q` 和关闭最后窗口退出；有活动任务时拒绝本次退出。

### 测试隔离

- 自动测试不得调用用户真实的 brew、node、npm、nvm 或 Zsh 环境。
- Manager 集成测试使用临时目录和假入口；Application Support 测试必须注入临时根目录。
- Hosted tests 必须保持启动自动刷新关闭，不能创建真实 Cellar 运行目录或访问 npm registry。
- 不把 Preview、fixture 或测试结果当作真实本机环境证据。

## 常用命令

优先使用 XcodeBuildMCP；首次构建或测试前先读取 session defaults。Shell 等价命令、按改动选择验证、产物位置和清理规则见 [开发指南](docs/development.md)。常用入口：

```bash
xcodebuild -project Cellar.xcodeproj -list
xcodebuild test -project Cellar.xcodeproj -scheme Cellar -destination 'platform=macOS,arch=arm64'
xcodebuild build -project Cellar.xcodeproj -scheme Cellar -configuration Debug -destination 'platform=macOS,arch=arm64'
git diff --check
git diff -- scripts
```

仓库没有 Makefile、SwiftLint、SwiftFormat、开发服务器或 watch 流程。自动化检查入口还包括 `node .github/scripts/release-manifest.mjs validate`、`node .github/scripts/sync-version.mjs --check` 和 `node --test .github/scripts/*.test.mjs`。

## 验证与完成标准

- 先运行覆盖改动的最小检查，再根据失败或风险扩大范围。
- Models、Bridge、Services 或生命周期变化应补直接回归测试；应用级修改至少完成相关测试和一次 macOS 构建。
- Release 验收检查 App 内每个 Mach-O，确认最低系统版本为 macOS 26.0 且只有 `arm64`。
- 发布开关只来自 `Config/Release/manifest.json`；未经明确发版请求不得改为 `true`、推送、创建 Release 或更新 tap/appcast。
- 真实 Homebrew、Node/nvm、网络、窗口尺寸和退出行为按 [人工验收清单](docs/manual-smoke-checklist.md) 验证；未经用户要求不主动运行 App。
- 完成前检查 diff、引用、临时输出和 `scripts/` 状态。无法执行的验证要说明原因和剩余风险。

## 文档与清理

- README 只记录用户可见能力、限制、数据位置、网络行为和源码构建入口。
- README 默认入口为英文 `README.md`；简体中文、繁体中文、日本語、한국어、Deutsch、Français、Español 分别为 `docs/README.zh-CN.md`、`docs/README.zh-TW.md`、`docs/README.ja.md`、`docs/README.ko.md`、`docs/README.de.md`、`docs/README.fr.md`、`docs/README.es.md`。各版本顶部提供全部八种语言的切换链接，并突出当前语言。App 默认跟随系统，README 默认入口为英文，两者不可混淆。App 新增或移除语言时，同步调整对应 README 和语言导航。
- 修改任一 README 语言版本时，必须在同一变更中同步其他语言版本，保持功能、发布状态、系统要求、操作边界、命令、数据位置和链接的语义一致；不得只更新默认英文版。路径按文件所在目录调整，提交前检查各版本的链接、图片和代码块。README 不复制界面尺寸、内部实现或验收细节，这些内容维护在既有权威文档中。
- 架构文档描述当前实现和已知风险；产品需求描述稳定行为；开发指南描述命令、测试和构建；研究文档保存外部依据。
- 只有用户明确要求时才执行清理；执行前必须读取并遵循 [开发产物清理规则](docs/development-cleanup.md)。
- 不删除源码、Git 数据、工程配置、Manager 源文件和快照、用户环境、Agent 对话和状态，或用途不明的文件。

## 文档导航与权威顺序

- [1.0 产品需求](docs/requirements/product-requirements.md)：唯一的用户行为、安全边界和验收契约。
- [1.0 交付范围](docs/requirements/v1-mvp.md)：发布内容、非目标和门槛；不重复定义行为。
- [总体架构](docs/architecture/macos-app-architecture.md)：当前实现、数据流、快照与进程边界。
- [平台支持](docs/requirements/platform-support.md)：macOS、arm64 和构建门禁。
- [开发指南](docs/development.md)：环境、测试、构建和产物检查。
- [开发产物清理规则](docs/development-cleanup.md)：清理语义、范围、安全边界与结果报告。
- [研究依据](docs/research.md)：Apple、Homebrew、npm、nvm 官方依据与项目推论。
- [人工验收清单](docs/manual-smoke-checklist.md)：真实机器、系统授权和 UI 检查。

发生冲突时，先以当前工程配置、源码和测试确认实现事实，再核对产品需求与架构文档。冲突会改变用户行为、公共契约或安全边界时，不自行选择，说明影响后等待确认。
