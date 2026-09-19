# Cellar macOS App 架构

状态：当前实现

更新日期：2026-09-19

本文描述 Cellar v1 的组件、数据流和长期边界。页面行为见[产品需求](../requirements/product-requirements.md)，构建和测试见[开发指南](../development.md)，平台依据见[研究文档](../research.md)。

## 系统定位

Cellar 是单进程、非沙盒的原生 macOS 前台应用。它读取 Homebrew、Node/npm/nvm、Zsh 和 Oh My Zsh 状态，不包含后台守护进程、菜单栏入口或 Privileged Helper。

App 使用 SwiftUI 构建窗口和页面，Foundation 负责文件与进程边界，AppKit delegate 处理退出请求。Node 的结构化数据来自随 App 打包的 Manager 快照；Homebrew 与 Shell 使用 Swift 组织只读探测。

## 仓库与组件

```text
Cellar/
├── CellarApp.swift             Scene、AppDelegate、退出策略
├── Features/                   页面、导航和展示
│   ├── Overview/
│   ├── Homebrew/
│   ├── Node/
│   ├── Shell/
│   └── Activity/
├── Services/                   App 状态、任务登记和探测编排
├── Models/                     页面状态与 JSON DTO
├── Bridge/                     Process、环境、快照和 Node Manager
├── Resources/Managers/         只读 Manager 快照
├── CellarTests/                单元与边界测试
├── scripts/                    冻结的 CLI Manager 来源
└── docs/                       产品与工程文档
```

依赖方向：

```text
Features → Services → Bridge → Manager / 系统 CLI
                ↓
              Models
```

- `Features` 展示状态并发送用户意图，不构造命令。
- `Services` 负责刷新流程和跨模块组合。
- `Bridge` 封装 IO、进程、环境和机器协议。
- `Models` 不执行 IO。
- `Resources/Managers` 是来源快照，不承载 App 专属适配。

## 应用生命周期

`CellarApp` 使用 `WindowGroup` 创建普通前台窗口，并通过 `defaultSize(width:height:)` 设置 1080 × 720 点的首次默认尺寸。App 不设置 `LSUIElement`，也不声明 `MenuBarExtra`。

`AppDelegate` 通过 `NSApplicationDelegateAdaptor` 接入 AppKit：

- 关闭最后一个窗口会请求终止应用。
- `OperationStore` 没有活动任务时返回 `.terminateNow`。
- 有活动任务时返回 `.terminateCancel`，任务完成后用户可再次退出。

退出保护只描述当前终止决策。关闭窗口、任务持续时间和真实 `Command-Q` 交互仍需人工验证。

## App 状态与刷新

`AppModel` 是 `@MainActor` 的页面状态所有者。它持有当前页面、各模块状态、错误、刷新时间、操作记录和刷新标志。

正常启动时 `AppRootView.task` 发起一次刷新。刷新流程：

```text
OperationStore.begin
        ↓
安装或复用 Manager 运行快照
        ↓
并行读取 Homebrew / Node / Shell
        ↓
分别写入成功值和错误
        ↓
更新本次会话的 ActivityEntry
        ↓
OperationStore.end
```

`isRefreshing` 保证同一 `AppModel` 不会同时运行两次刷新。Hosted XCTest 通过 `XCTestConfigurationFilePath` 跳过启动自动刷新，避免测试访问真实开发环境。

当前操作记录只在内存中存在。没有持久化、独立任务队列、进度百分比或用户取消入口。

## Manager 快照

仓库中的 `Resources/Managers/` 包含：

- `node-manager`：按 `scripts/node-manager/app-bundle-manifest.txt` 复制。
- `homebrew-manager`：`main.sh` 和生产 `lib/*.sh`。
- `zsh-manager`：`omz-manager.sh`。
- `SNAPSHOT.md`：来源 commit 和生成说明。

当前快照版本是 `1c9d71b`。`ManagerSnapshotInstaller` 从 `Bundle.main.resourceURL/Managers` 读取资源，并安装到：

```text
~/Library/Application Support/Cellar/Managers/1c9d71b/
```

安装过程先验证三套入口文件，再复制到同级随机 staging 目录，最后移动到版本目录。已有完整版本直接复用；缺少入口文件的版本目录会被删除并重新安装。安装后再次验证入口可读性。

Bundle Resources 不产生运行时写入。Node Manager 的 `.runtime` 位于 Application Support 工作副本内；v1 调用的只读命令不会执行 JSON write actions。

当前完整性检查验证入口文件存在和可读，不在运行时计算整套快照的哈希。仓库和发布验收通过逐文件比较保证来源一致。

## 进程边界

`ProcessRunner` 是 actor，保存当前运行的 `Process` 对象。每个请求明确提供：

- executable URL；
- arguments；
- 完整 environment；
- 可选 current directory；
- 空 stdin；
- 分离的 stdout 和 stderr pipe。

stdout 与 stderr 在独立任务中读取，进程结束后返回 `ProcessResult` 和退出码。调用任务取消时向对应进程发送 terminate。App 代码不使用 `bash -c`，Node Manager 通过固定 `/bin/bash` 加脚本路径和参数数组启动。

当前 runner 没有 deadline、强制终止升级或输出大小上限。长时间无响应的外部命令可能让刷新持续较久，并在此期间阻止退出。这是当前已知风险。

## 受控环境与 Node 选择

`NodeEnvironmentResolver` 不继承用户完整 Shell 环境。它构造包含 HOME、PATH、TMPDIR、locale、NVM_DIR、USER 和 LOGNAME 的明确环境，并把 `NODE_MANAGER_ALLOW_JSON_EXECUTE` 固定为 `0`。

PATH 顺序：

1. 能明确解析的 `~/.nvm/alias/default` 对应版本 `bin`；
2. `/opt/homebrew/bin`、`/opt/homebrew/sbin`；
3. `/usr/local/bin`；
4. `/usr/bin`、`/bin`、`/usr/sbin`、`/sbin`。

alias 解析支持三段式版本、数字前缀、`node`、`stable` 和 alias 链，并检测循环。没有明确匹配时不选择任意已安装版本。

当前实现只检查 `~/.nvm`，没有读取自定义 `NVM_DIR`、XDG nvm 目录、asdf、fnm 或 Volta。这些环境不在当前支持保证内。

## Node Manager 协议

`NodeManagerClient` 只使用 schema v1：

```text
main.sh --json summary
main.sh --json packages
main.sh --json config
main.sh --json outdated
```

每次响应必须同时满足：

- 进程退出状态符合命令结果；
- JSON 可以解码为 `ManagerEnvelope<Payload>`；
- `schemaVersion == 1`；
- `ok == true` 且 `data` 存在。

前三项核心命令失败会终止 Node 页面加载。`outdated` 单独捕获错误；失败时保留核心数据，并把错误写入 `NodeSnapshot.outdatedError`。

Node Manager 入口会加载自己的模块，但 App 不直接调用 `lib/*.sh`，也不驱动交互菜单。

## Homebrew 与 Shell

Homebrew 探测在受控 PATH 中寻找可执行的 `brew`。找不到时返回“未安装”；找到后执行 `brew --version` 并读取首行。v1 不调用 Homebrew Manager 的交互入口。

Shell 探测固定执行 `/bin/zsh --version`，再通过 `FileManager` 检查 `~/.oh-my-zsh` 是否是目录。它不读取 `.zshrc`，也不调用 Zsh Manager。

两页仍显示相应 Manager 快照是否存在，用于说明 App Bundle 和运行副本的准备状态，不代表该交互 Manager 已接入 UI。

## 数据、网络与权限

Cellar 不使用 App Sandbox。v1 不要求管理员权限，不调用 `sudo`，也没有 Helper 或 XPC。

持久写入只有版本化 Manager 运行副本：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

操作记录、页面状态和刷新时间不持久化。App 没有自己的账户、遥测或服务端。`npm outdated` 会访问用户当前配置的 npm registry，并使用 npm 自身的 cache 行为；其他当前探测是本机读取。

## 测试边界

`CellarTests` 覆盖：

- Manager envelope 和 payload 解码；
- nvm default alias 与版本匹配；
- executable PATH 查找；
- stdout、stderr 和退出码分离；
- Node 部分失败；
- 快照安装到临时 Application Support；
- 活动任务对应的退出策略。

测试通过依赖注入、临时目录和假 Manager 隔离副作用，不读取用户真实包管理状态。真实 Finder 启动环境、brew/npm/nvm 组合、registry 网络和窗口交互由人工清单验证。

## 平台与构建

工程包含 `Cellar` App Target 和 `CellarTests` Target。两者最低部署版本为 macOS 26.0，显式排除 `x86_64`，发布产物只允许 arm64。App Sandbox 关闭。

当前仓库没有 CI、签名发布、DMG、Sparkle 或 Homebrew Cask。发布模型尚未确定，不能把本地无签名构建描述为正式版本。

## 稳定不变量

- v1 不修改包、registry、Node 版本、Shell 配置或 Homebrew 状态。
- 不把某个 Node 的 npm 全局包描述为整台机器唯一集合。
- 不因更新检查失败丢弃已经读取的 Node 数据。
- 不加载用户 `.zshrc`，不猜测无法解析的 nvm 默认版本。
- 不从 View 直接执行命令，不从 Models 执行 IO。
- 不修改冻结的 `scripts/`，不手工修补 Manager 快照。
- 不在 App Bundle Resources 中写运行数据。
- 不让自动测试访问真实用户环境或 Application Support。

## 当前已知限制

- 外部进程没有 timeout 和输出上限。
- 刷新没有用户取消入口；活动任务期间退出被拒绝。
- 自定义 nvm 目录和其他 Node 版本管理器未支持。
- Homebrew 与 Shell 只有只读探测，交互 Manager 尚未接入。
- 快照运行时验证入口完整性，不验证全部文件摘要。
- UI 文本当前直接写在 Swift 源码中，没有 String Catalog 和多语言支持。
- 普通 `WindowGroup`、最后窗口关闭和任务期间退出的组合仍需真实窗口验收。
