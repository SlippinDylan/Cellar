# Cellar

Cellar 是一个原生 macOS 开发环境工具。它把 Homebrew、Node/npm/nvm、Zsh 和 Oh My Zsh 的状态放在同一个窗口里，并提供受控的 Homebrew 查询与管理功能。

> Cellar 仍在开发，没有可下载的正式版本。当前只有 Homebrew 模块提供写操作；Node 和 Shell 仍然只读。

## 当前能力

| 页面 | 内容 |
|---|---|
| 概览 | Homebrew、Node、Shell 和 Manager 快照摘要 |
| Homebrew | 概览、已安装项、可升级项、搜索发现、诊断、配置与 Tap |
| Node | Node/npm 版本、全局包、可更新版本和 npm 配置 |
| Shell | Zsh 版本和 Oh My Zsh 状态 |
| 操作记录 | 本次 App 会话中的刷新结果和错误 |

Cellar 启动后会自动刷新。Homebrew、Node 或 Shell 其中一项失败时，其他已经读取的状态仍会保留。npm 更新检查失败也不会清空 Node 版本和全局包列表。

Homebrew 可以安装 Formula/Cask、更新 Homebrew 元数据、选择升级、卸载单个 Formula、以 standard 或 zap 模式卸载单个 Cask，以及添加或安全移除 Tap。每项写操作都会先展示计划并等待确认，完成后重新读取状态。Homebrew 操作不是事务；命令失败时可能已经完成其中一部分，Cellar 会保留实际结果而不会显示为整体回滚。

## 当前限制

- 不安装 Command Line Tools 或 Homebrew，不修改 `.zprofile`。
- 不执行 Homebrew cleanup，不自动删除孤儿依赖，也不由 App 自行删除 Cask 残留文件。
- 不调用 `sudo`，不包含 Privileged Helper；需要更高权限的项目只报告给用户。
- 不安装、更新或卸载 npm 全局包。
- 不修改 npm registry、nvm 默认版本、`.zshrc` 或 Oh My Zsh。
- Node 环境支持默认的 `~/.nvm` 布局和常见系统路径；自定义 NVM_DIR、asdf、fnm 与 Volta 尚未支持。
- Homebrew 查询和写操作分别设置 5 分钟和 30 分钟 deadline；Node/Shell 仍未配置 deadline，界面也没有用户取消入口。
- 界面文本目前只有中文。

## 数据与网络

Manager 以只读资源随 App 打包，首次运行时复制到：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

Cellar 不包含账户、遥测或自己的服务端。Node 页面会运行 npm 的只读命令；其中 `npm outdated` 会访问当前配置的 npm registry，并使用 npm 自身的 cache。Homebrew 搜索、详情、过期检查、更新、安装和升级等命令可能访问 Homebrew 或第三方 Tap 的服务，并写入 Homebrew 自己管理的 API cache。App 不写入 `~/.npmrc`、`~/.zshrc`、`~/.nvm` 或 `.zprofile`。

## 系统要求

- macOS 26.0 或更高版本
- Apple Silicon Mac（仅 `arm64`）
- 从源码构建需要 Xcode 26 或更高版本

不支持 Intel Mac、Universal Binary、Rosetta 或 macOS 15。

## 从源码构建

打开 `Cellar.xcodeproj` 并运行 `Cellar` scheme，或者在仓库根目录执行：

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

测试命令、Release 构建、产物检查和安全清理见[开发指南](docs/development.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [产品需求](docs/requirements/product-requirements.md) | 页面行为、状态、数据边界和验收契约 |
| [v1 MVP 范围](docs/requirements/v1-mvp.md) | 当前阶段范围和非目标 |
| [总体架构](docs/architecture/macos-app-architecture.md) | 组件、数据流、Manager 与进程边界 |
| [平台支持](docs/requirements/platform-support.md) | macOS、arm64 和构建门禁 |
| [开发指南](docs/development.md) | 测试、构建、产物检查和清理 |
| [人工验收清单](docs/manual-smoke-checklist.md) | 真实机器和 UI 检查 |
