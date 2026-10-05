# Cellar Agent 指南

本文件是仓库导航和工作契约，不是完整手册。只读取当前任务涉及的链接；产品行为、架构、开发流程和外部依据分别维护在对应权威文档中。

## 项目概述

Cellar 是面向 macOS 26 及以上版本、仅支持 Apple Silicon 的原生开发环境管理工具。1.0 采用任务导向的 Home、Library、Discover、Updates、Tools 和 Activity，统一组织 Homebrew Formula/Cask、npm 全局包、Node/nvm 与终端配置，同时保留 provider 身份和安全边界。主 App 使用 Swift 6、SwiftUI、Foundation 和少量 AppKit；现有 CLI Manager 以快照随 App 打包，但 App 不驱动其交互菜单。

[产品需求](docs/requirements/product-requirements.md)是 1.0 用户行为和安全边界的唯一权威来源。1.0 源码已实现，尚未公开发布；未执行的真实环境与 UI 验收见人工清单。[架构文档](docs/architecture/macos-app-architecture.md)描述当前实现，构建和验证见[开发指南](docs/development.md)。

## 开始工作

1. 检查 Git 状态，保留已有未提交改动，不清理或回退无关内容。
2. 阅读本文件及任务涉及的权威文档；历史脚本资料不代表 App 当前行为。
3. 搜索现有类型、调用点和测试，确认职责、数据流及外部副作用后再修改。
4. macOS、Swift、SwiftUI、Foundation 或 AppKit 功能编码前，通过 Sosumi 核对 Apple 官方文档。
5. 需求、公共契约或架构方向存在实质歧义时，列出事实和影响，等待确认。

## 仓库地图

- `CellarApp.swift`：SwiftUI Scene、AppKit delegate 和退出策略。
- `Features/`：Home、Library、Discover、Updates、Tools、Activity 与主窗口 Settings；保留的旧 provider 页面不进入主导航。
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
- 单项安装/更新从卡片直接开始；批量、卸载、zap、清理和配置修改按产品矩阵进行一次任务专用确认。内部计划、状态指纹和 post-refresh 继续作为安全边界。写操作不是事务，界面和 Activity 必须保留部分完成结果。
- Command Line Tools 只通过 `xcode-select --install` 请求系统对话框。Homebrew 只接受官方 latest stable Release 的精确 `Homebrew.pkg` 及其有效官方 SHA-256；digest、package signature 和 Gatekeeper assessment 任一缺失或失败都必须 fail closed、不得打开，并报告原因及 Homebrew 官方链接。全部通过后才交给系统 Installer；Cellar 不执行远端安装脚本、不收集密码、不调用自己的 `sudo` 或 Helper。
- 不修改 `.zprofile`，不执行 Homebrew cleanup，不自动删除孤儿依赖，也不由 App 自行 `rm` Cask 残留。
- Formula/Cask 卸载必须显式禁止 Homebrew 自动更新和 autoremove。Cask artifact 只用于卸载前展示和执行后报告，不由 App 单独删除。
- Homebrew Manager 没有稳定 App JSON 契约，Homebrew 由 Bridge 使用绝对 `brew` 路径和受控环境调用。Zsh 原交互 Manager 同样不被驱动；App 只调用相邻的 Cellar-owned schema v1 adapter。
- Node 通过 Manager schema v1 读取状态，并仅在产品确认规则满足后启用单次 JSON execute。支持的写操作限定为 npm 全局包、nvm/Node 版本、Registry、Manager 维护和用户明确选择项目的 `.nvmrc`；npm 搜索与操作始终绑定明确 Node 环境。
- Shell 通过 App 专用 schema v1 adapter 查询和修改 Oh My Zsh、插件、主题及受限 Zsh 文件布局；不得驱动交互菜单或执行协议外的 Shell 命令。
- 主导航固定为 Home、Library、Discover、Updates、Tools；侧边栏左下方依次为 Settings 和 Activity，Activity 固定在最底部。Settings 是主窗口 detail 页面，包含 General、Sources、Terminal、About；不声明独立 Settings scene，Command-Comma 经共享导航意图前置或重建主窗口并选择 Settings。
- 卡片本体不导航，只显示关键信息、一个主动作和系统浏览器网站链接。普通 UI 不显示原始命令或内部计划术语。
- Activity 最多持久化 100 条去敏结构化摘要；原始输出只保留在当前会话诊断或既有受控日志。运行中任务不提供用户手动停止；内部取消只用于任务所有者结束、超时和生命周期回收。
- 用户可见字符串进入 String Catalog，支持 English、简体中文、繁体中文和默认 Follow System。

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
