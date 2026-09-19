# Cellar

Cellar 是一个原生 macOS 开发环境查看工具。它把 Homebrew、Node/npm/nvm、Zsh 和 Oh My Zsh 的状态放在同一个窗口里，适合检查当前机器实际使用的工具和 npm 全局包。

> Cellar 仍在开发，没有可下载的正式版本。当前 v1 只读，不执行安装、更新、卸载或清理。

## 当前可以查看什么

| 页面 | 内容 |
|---|---|
| 概览 | Homebrew、Node、Shell 和 Manager 快照摘要 |
| Homebrew | 安装状态、版本和可执行文件路径 |
| Node | Node/npm 版本、全局包、可更新版本和 npm 配置 |
| Shell | Zsh 版本和 Oh My Zsh 状态 |
| 操作记录 | 本次 App 会话中的刷新结果和错误 |

Cellar 启动后会自动刷新。Homebrew、Node 或 Shell 其中一项失败时，其他已经读取的状态仍会保留。npm 更新检查失败也不会清空 Node 版本和全局包列表。

## 当前限制

- 不安装、更新或卸载 Homebrew formula/cask。
- 不安装、更新或卸载 npm 全局包。
- 不修改 npm registry、nvm 默认版本、`.zshrc` 或 Oh My Zsh。
- Node 环境支持默认的 `~/.nvm` 布局和常见系统路径；自定义 NVM_DIR、asdf、fnm 与 Volta 尚未支持。
- 外部命令目前没有 timeout，长时间无响应的刷新不能在界面中取消。
- 界面文本目前只有中文。

## 数据与网络

Manager 以只读资源随 App 打包，首次运行时复制到：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

Cellar 不包含账户、遥测或自己的服务端。Node 页面会运行 npm 的只读命令；其中 `npm outdated` 会访问当前配置的 npm registry，并使用 npm 自身的 cache。App 不写入 `~/.npmrc`、`~/.zshrc` 或 `~/.nvm`，也不修改全局包。

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
