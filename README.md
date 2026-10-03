# Cellar

Cellar 是面向 macOS 26+、仅支持 Apple Silicon 的原生开发环境管理工具。1.0 把 Homebrew Formula、Homebrew Cask、npm 全局包、Node/nvm 与终端配置组织为查找、安装、更新、卸载和维护等用户任务，同时保留每个 provider 的真实语义与安全边界。

> Cellar 仍在开发，没有可下载的正式版本。以下内容是已确认的 1.0 产品范围；当前源码会随实现任务逐步达到该契约。

## Cellar 1.0

| 入口 | 用途 |
|---|---|
| Home | Homebrew 与 Node/npm/nvm 的本地状态、线上版本、数量和具体更新摘要 |
| Library | 统一查看、搜索和管理已安装的 Formula、Cask 与 npm 全局包 |
| Discover | 搜索 Homebrew 与 npm Registry，单项或同 provider/type 批量安装 |
| Updates | 按 All、Homebrew、npm、Formula 或 Cask scope 查看和执行更新 |
| Tools | CLT/Homebrew/nvm setup、Node runtime、项目 `.nvmrc`、诊断与受限维护 |
| Activity | 当前任务、取消、最近最多 100 条持久摘要、筛选与复制 |

Activity 固定在主窗口侧边栏底部。Settings 使用标准 macOS 窗口，包含 General、Sources、Terminal 和 About。界面支持 English、简体中文和繁体中文，默认跟随系统语言。

目录使用简洁卡片：名称、Formula/Cask/npm 类型、当前/可用版本、语义更新状态、最多两行说明、一个主动作和系统浏览器网站链接。卡片本体不承担跳转。

## 操作与安全

- npm 只管理全局包，并始终标明目标 Node 环境。
- 单项安装/更新从卡片开始；批量、卸载、zap、清理和配置修改使用任务专用确认。
- 批量任务一次只处理一个 provider/type，逐项顺序执行；某项失败后继续，用户取消则停止未开始项。
- 写操作不是事务，不承诺回滚。Cellar 会保留成功、失败、已取消和 post-refresh 后的真实状态。
- Formula/Cask 卸载禁止 Homebrew 自动更新和 autoremove。Cellar 不执行 Homebrew cleanup，不自行删除 Cask artifact 或孤儿依赖。
- Cellar 不运行自己的 `sudo` 或 Privileged Helper，不收集管理员密码，不修改 `.zprofile`，不运行 `chsh`。

缺少 Command Line Tools 时，Cellar 只通过 `xcode-select --install` 请求 macOS 系统安装对话框。缺少 Homebrew 时，只接受官方 latest stable Release 的 `Homebrew.pkg` 和该精确资产的有效 SHA-256；digest、package signature 与 Gatekeeper assessment 全部通过后才交给系统 Installer。任何验证缺失或失败都会阻止打开并提供原因和 Homebrew 官方链接。Cellar 不重写安装器、不执行远端安装脚本，也不处理系统许可或认证。nvm 提供官方安装指引，不在 App 内运行远端脚本。

## 数据与网络

Cellar 没有账户、遥测或自有服务端。Homebrew、npm Registry、nvm/Node 版本、Oh My Zsh、GitHub 插件和 Sparkle 更新会按用户可见功能访问官方或用户配置的来源。Homebrew/npm 查询也可能写入各自 cache；单一网络检查失败不会清空已读取的本地状态。

Manager 只读资源随 App 打包，运行副本安装到：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

Activity 最多持久化 100 条去敏后的结构化摘要。原始命令输出不进入持久摘要，只在当前会话诊断区域或既有受控日志中提供。

Release 构建使用 Sparkle 检查 `https://slippindylan.github.io/homebrew-tap/cellar/appcast.xml`。Debug 和普通本地构建默认关闭 updater；只有发布流水线配置密钥并显式开启时才检查更新。

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
| [1.0 产品需求](docs/requirements/product-requirements.md) | 唯一的用户行为、安全边界与验收契约 |
| [1.0 交付范围](docs/requirements/v1-mvp.md) | 发布内容、非目标和门槛 |
| [总体架构](docs/architecture/macos-app-architecture.md) | 目标架构、当前基线、数据流与进程边界 |
| [平台支持](docs/requirements/platform-support.md) | macOS、arm64 和构建门禁 |
| [研究依据](docs/research.md) | Apple、Homebrew、npm 与 nvm 官方依据 |
| [开发指南](docs/development.md) | 测试、构建、产物检查和清理 |
| [人工验收清单](docs/manual-smoke-checklist.md) | 真实机器、系统授权和 UI 检查 |
