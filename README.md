# Cellar

Cellar 是一个原生 macOS 开发环境工具。它把 Homebrew、Node/npm/nvm、Zsh 和 Oh My Zsh 的状态放在同一个窗口里，并提供受控的 Homebrew 查询与管理功能。

> Cellar 仍在开发，没有可下载的正式版本。Homebrew、Node 和 Shell 的写操作都会先展示计划并等待确认。

## 当前能力

| 页面 | 内容 |
|---|---|
| 概览 | Homebrew、Node、Shell 和 Manager 快照摘要 |
| Homebrew | 概览、已安装项、可升级项、搜索发现、诊断、配置与 Tap |
| Node | Node/npm 版本、全局包、Registry、nvm 版本和受控维护操作 |
| Shell | Zsh、Oh My Zsh、插件、主题和受控配置整理 |
| 操作记录 | 本次 App 会话中的刷新结果和错误 |

Cellar 启动后会自动刷新。Homebrew、Node 或 Shell 其中一项失败时，其他已经读取的状态仍会保留。npm 更新检查失败也不会清空 Node 版本和全局包列表。

Homebrew 可以安装 Formula/Cask、更新 Homebrew 元数据、选择升级、卸载单个 Formula、以 standard 或 zap 模式卸载单个 Cask，以及添加或安全移除 Tap。每项写操作都会先展示计划并等待确认，完成后重新读取状态。Homebrew 操作不是事务；命令失败时可能已经完成其中一部分，Cellar 会保留实际结果而不会显示为整体回滚。

Node 可以在当前受控 Node 环境中安装、更新和卸载 npm 全局包，管理 nvm/Node 版本、默认与 scope Registry，执行受限维护操作，并为用户明确选择的项目写入 `.nvmrc`。写操作同样先生成计划并确认；“用于本次 Cellar 会话”只改变 App 后续命令的受控 PATH，不改变已经打开的终端。

Shell 可以安装 Oh My Zsh、从 GitHub HTTPS 地址安装插件、更新受管理的插件与主题配置，并把 zcompdump 和历史备份整理到 `~/.zsh`。修改 `.zshrc` 前会创建备份；符号链接、非普通文件和计划后状态变化会阻止执行。

## 当前限制

- 不安装 Command Line Tools 或 Homebrew，不修改 `.zprofile`。
- 不执行 Homebrew cleanup，不自动删除孤儿依赖，也不由 App 自行删除 Cask 残留文件。
- 不调用 `sudo`，不包含 Privileged Helper；需要更高权限的项目只报告给用户。
- 不切换默认登录 Shell，不运行 `chsh`，也不删除 Oh My Zsh 或用户插件目录。
- Node 环境支持默认的 `~/.nvm` 布局和常见系统路径；自定义 NVM_DIR、asdf、fnm 与 Volta 尚未支持。
- Homebrew 与 Node 查询和写操作分别设置 5 分钟和 30 分钟 deadline；Shell 尚未配置 deadline，界面也没有用户取消入口。
- 界面文本目前只有中文。

## 数据与网络

Manager 以只读资源随 App 打包，首次运行时复制到：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

Cellar 不包含账户、遥测或自己的服务端。`npm outdated`、包安装和更新会访问当前配置的 npm registry；Node/nvm 写操作可能修改 `~/.npmrc`、`~/.nvm`、npm cache，以及用户明确选择项目中的 `.nvmrc`。Homebrew 查询和操作可能访问 Homebrew 或第三方 Tap 的服务。Oh My Zsh 和插件安装会访问固定官方脚本或用户确认的 GitHub 地址；Shell 配置操作会备份并更新 `.zshrc` 的受管理 block。Cellar 不修改 `.zprofile` 正文，也不调用 `chsh`。

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
