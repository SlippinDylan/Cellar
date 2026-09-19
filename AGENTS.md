# Cellar Agent 指南

本文件是仓库导航和工作契约，不是完整手册。只读取当前任务涉及的链接；产品行为、架构、开发流程和外部依据分别维护在对应权威文档中。

## 项目概述

Cellar 是面向 macOS 26 及以上版本、仅支持 Apple Silicon 的原生开发环境查看工具。主 App 使用 Swift 6、SwiftUI、Foundation 和少量 AppKit，读取 Homebrew、Node/npm/nvm 与 Shell 的本机状态。现有 Shell Manager 以只读快照随 App 打包。

v1 是只读版本，不安装、更新、卸载包，也不修改 registry、Shell 配置或 Homebrew 状态。产品行为见 [产品需求](docs/requirements/product-requirements.md)，当前实现见 [架构文档](docs/architecture/macos-app-architecture.md)，构建和验证见 [开发指南](docs/development.md)。

## 开始工作

1. 检查 Git 状态，保留已有未提交改动，不清理或回退无关内容。
2. 阅读本文件及任务涉及的权威文档；历史脚本资料不代表 App 当前行为。
3. 搜索现有类型、调用点和测试，确认职责、数据流及外部副作用后再修改。
4. macOS、Swift、SwiftUI、Foundation 或 AppKit 功能编码前，通过 Sosumi 核对 Apple 官方文档。
5. 需求、公共契约或架构方向存在实质歧义时，列出事实和影响，等待确认。

## 仓库地图

- `CellarApp.swift`：SwiftUI Scene、AppKit delegate 和退出策略。
- `Features/`：概览、Homebrew、Node、Shell、操作记录及主导航。
- `Services/`：App 状态、刷新编排、任务登记和系统探测。
- `Models/`：页面状态、Manager JSON DTO 和只读业务模型。
- `Bridge/`：`Process`、受控环境、Manager 快照安装和 JSON 解码。
- `Resources/Managers/`：从冻结脚本复制的只读生产快照。
- `CellarTests/`：契约、环境解析、进程、生命周期和快照测试。
- `scripts/`：既有 CLI Manager；App 开发期间冻结。
- `docs/`：产品、架构、开发、研究和人工验收文档。

依赖方向是 `Features → Services → Bridge → Manager/系统 CLI`，共享数据由 `Models` 表达。View 不直接运行命令；Bridge 不依赖具体页面。

## 不可破坏的边界

### 只读 v1

- App 当前只读取状态。不得在 UI 中接入 install、update、uninstall、cleanup、registry 写入或 nvm 状态变更。
- Homebrew 与 Zsh Manager 没有稳定 App JSON 契约；不要通过管道输入驱动交互菜单，也不要解析人类可读菜单文本。
- Node 只调用 Manager 的 `summary`、`packages`、`config` 和 `outdated` JSON 命令。

### Node 环境

- npm 全局包属于具体 Node 安装，不能表示为整台机器唯一的一组包。
- App 优先使用 `~/.nvm/alias/default` 能明确解析到的已安装版本；解析失败时不得猜测最新版。
- Finder/Xcode 启动环境不读取 `.zshrc`。受控 PATH 只包含解析出的默认 nvm `bin` 和项目批准的系统路径。
- `npm outdated` 失败是独立的部分失败，不得抹掉已经读取的 Node、npm、包列表和配置。

### Manager 快照

- 未经用户再次明确授权，不修改 `scripts/` 下的代码、配置、测试或文档。
- `Resources/Managers/` 必须来自生产白名单或明确的生产文件集合，并记录来源 commit。
- 不在快照副本中手工修补业务逻辑；App 专属适配写在 `Bridge/`。
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

仓库没有 Makefile、SwiftLint、SwiftFormat、开发服务器或 watch 流程，不要声称运行过不存在的检查。

## 验证与完成标准

- 先运行覆盖改动的最小检查，再根据失败或风险扩大范围。
- Models、Bridge、Services 或生命周期变化应补直接回归测试；应用级修改至少完成相关测试和一次 macOS 构建。
- Release 验收检查 App 内每个 Mach-O，确认最低系统版本为 macOS 26.0 且只有 `arm64`。
- 真实 Homebrew、Node/nvm、网络、窗口尺寸和退出行为按 [人工验收清单](docs/manual-smoke-checklist.md) 验证；未经用户要求不主动运行 App。
- 完成前检查 diff、引用、临时输出和 `scripts/` 状态。无法执行的验证要说明原因和剩余风险。

## 文档与清理

- README 只记录用户可见能力、限制、数据位置、网络行为和源码构建入口。
- 架构文档描述当前实现和已知风险；产品需求描述稳定行为；开发指南描述命令、测试、构建和清理；研究文档保存外部依据。
- 仓库内 `build/`、`DerivedData/`、`.build/` 和 `.xcresult` 只有在用户明确要求时才能清理。先确认归属并统计空间。
- `~/Library/Application Support/Cellar/` 是 App 运行数据，不是普通构建缓存。不得在开发清理中删除。
- 不删除源码、Git 数据、Xcode 工程、Manager 源文件、快照、用户配置或用途不明的系统文件。

## 文档导航与权威顺序

- [产品需求](docs/requirements/product-requirements.md)：页面行为、状态、数据边界和验收契约。
- [v1 MVP 范围](docs/requirements/v1-mvp.md)：当前阶段范围与非目标。
- [总体架构](docs/architecture/macos-app-architecture.md)：当前组件、数据流、快照与进程边界。
- [平台支持](docs/requirements/platform-support.md)：macOS、arm64 和构建门禁。
- [开发指南](docs/development.md)：环境、测试、构建、产物检查和安全清理。
- [研究依据](docs/research.md)：Apple、npm 与项目推论。
- [人工验收清单](docs/manual-smoke-checklist.md)：真实机器和 UI 检查。

发生冲突时，先以当前工程配置、源码和测试确认实现事实，再核对产品需求与架构文档。冲突会改变用户行为、公共契约或安全边界时，不自行选择，说明影响后等待确认。
