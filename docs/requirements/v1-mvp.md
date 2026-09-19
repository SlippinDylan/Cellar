# Cellar v1 MVP 范围

状态：已实现代码基线，仍需人工验收

更新日期：2026-09-19

本文只定义当前阶段边界。页面和错误行为以[产品需求](product-requirements.md)为准，当前实现以[架构文档](../architecture/macos-app-architecture.md)为准。

## 目标

交付一个可构建的原生 macOS App，通过真实只读数据验证 SwiftUI 页面、Swift 服务、受控进程和冻结 Manager 快照之间的链路。

## 当前范围

| 模块 | v1 能力 |
|---|---|
| App Shell | 普通前台窗口、两栏导航、五个一级页面 |
| 概览 | 聚合 Homebrew、Node、Shell 和 Manager 状态 |
| Homebrew | 读取安装状态、版本和路径 |
| Node | 读取 summary、全局包、npm 配置和可更新版本 |
| Shell | 读取 Zsh 版本和 Oh My Zsh 目录状态 |
| 操作记录 | 保存当前 App 会话中的刷新结果 |
| Bridge | 受控环境、参数数组、stdout/stderr、退出码和 JSON schema |
| Manager 快照 | 从 Bundle 安装到版本化 Application Support 目录 |
| 生命周期 | 1080 × 720 默认尺寸，无菜单栏驻留；活动任务期间拒绝退出 |

## 明确不包含

- Homebrew、npm、nvm 或 Zsh 的写操作。
- 解析或自动驾驶 Homebrew/Zsh 交互菜单。
- 后台常驻、菜单栏图标或退出后继续运行。
- App Sandbox、Mac App Store、Privileged Helper、root 或 `sudo`。
- Intel、Universal Binary、Rosetta、macOS 15 或更早系统。
- 自定义 NVM_DIR、asdf、fnm 和 Volta。
- 持久操作历史、任务队列、进度百分比或用户取消入口。
- CI、签名发布、DMG、自动更新和 Homebrew Cask。

## 自动验收

- App 和测试 Target 的 deployment target 为 macOS 26.0。
- Debug、Release 和单元测试可以无签名完成。
- Release App 内每个 Mach-O 只有 arm64 slice。
- Node JSON schema、环境解析、部分失败、进程输出、快照安装和退出策略有直接测试。
- Hosted tests 不自动刷新真实环境，不访问用户 Application Support 或 npm registry。
- App Swift 代码不使用 `bash -c`，不读取 `.zshrc`。
- `Resources/Managers` 与来源生产文件一致，不包含 runtime cache。
- `scripts/` 保持冻结。

## 人工验收

以下行为不能仅由自动测试关闭：

- Finder 启动后的 Homebrew 与 nvm 发现。
- 真实 npm registry 正常、离线和失败状态。
- 首次窗口尺寸与不同窗口宽度下的可读性。
- `Command-Q`、关闭最后窗口和活动任务组合。
- App 退出后的子进程状态。

检查步骤见[人工验收清单](../manual-smoke-checklist.md)。未执行的项目保持为剩余风险，不写成已验证能力。

## 进入写操作阶段的门槛

写操作不直接复用交互式脚本。开始实现前必须先确定：

1. Manager 的稳定机器协议和 schema 兼容策略。
2. query、plan、用户确认、execute 和 result 的完整流程。
3. 锁、状态复验、取消、deadline、日志和部分完成语义。
4. 删除边界、恢复方式和测试隔离。
5. Homebrew、Node 和 Shell 是否共享协议，哪些能力继续由 Swift 直接实现。

这些问题没有形成需求和架构决策前，v1 保持只读。
