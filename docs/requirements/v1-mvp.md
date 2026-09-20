# Cellar v1 MVP 范围

状态：Homebrew 功能扩展中，完成后仍需人工验收

更新日期：2026-09-20

本文只定义当前阶段边界。页面和错误行为以[产品需求](product-requirements.md)为准，当前实现以[架构文档](../architecture/macos-app-architecture.md)为准。

## 目标

交付一个可构建的原生 macOS App，通过真实数据验证 SwiftUI 页面、Swift 服务、受控进程和冻结 Manager 快照之间的链路，并为 Homebrew 提供经过计划与确认的常用管理操作。Node 与 Shell 仍保持只读。

## 当前范围

| 模块 | v1 能力 |
|---|---|
| App Shell | 普通前台窗口、两栏导航、五个一级页面 |
| 概览 | 聚合 Homebrew、Node、Shell 和 Manager 状态 |
| Homebrew | 概览、已安装、可升级、发现、诊断、配置与 Tap；安装、update、选择升级、单目标卸载和 Tap 变更 |
| Node | 读取 summary、全局包、npm 配置和可更新版本 |
| Shell | 读取 Zsh 版本和 Oh My Zsh 目录状态 |
| 操作记录 | 保存当前 App 会话中的刷新结果 |
| Bridge | 受控环境、参数数组、stdout/stderr、退出码和 JSON schema |
| Manager 快照 | 从 Bundle 安装到版本化 Application Support 目录 |
| 生命周期 | 1080 × 720 默认尺寸，无菜单栏驻留；活动任务期间拒绝退出 |

Homebrew 写操作统一先计划和确认，执行后 post-refresh。Formula/Cask 卸载显式禁止自动更新和 autoremove；Cask standard 与 zap 分开选择，artifact 只展示和报告。Homebrew 命令不是事务，失败可能留下部分完成状态。

## 明确不包含

- 安装 Command Line Tools 或 Homebrew，修改 `.zprofile`。
- Homebrew cleanup、自动孤儿依赖删除、批量卸载或 App 自行删除 Cask 残留。
- `sudo`、Privileged Helper 或其他 root 操作。
- npm、nvm 或 Zsh 的写操作。
- 解析或自动驾驶 Homebrew/Zsh 交互菜单。
- 后台常驻、菜单栏图标或退出后继续运行。
- App Sandbox 或 Mac App Store。
- Intel、Universal Binary、Rosetta、macOS 15 或更早系统。
- 自定义 NVM_DIR、asdf、fnm 和 Volta。
- 持久操作历史、任务队列、进度百分比或用户取消入口。
- CI、签名发布、DMG、自动更新和 Homebrew Cask。

## 自动验收

- App 和测试 Target 的 deployment target 为 macOS 26.0。
- Debug、Release 和单元测试可以无签名完成。
- Release App 内每个 Mach-O 只有 arm64 slice。
- Node JSON schema、环境解析、部分失败、进程输出、快照安装和退出策略有直接测试。
- Homebrew 查询解析、计划生成、确认边界、受控命令、操作锁、部分完成和 post-refresh 有直接测试。
- 自动测试使用假 brew 和临时目录，不调用用户真实 Homebrew 或访问网络。
- Hosted tests 不自动刷新真实环境，不访问用户 Application Support 或 npm registry。
- App Swift 代码不使用 `bash -c`，不读取 `.zshrc`。
- `Resources/Managers` 与来源生产文件一致，不包含 runtime cache。
- `scripts/` 保持冻结。

## 人工验收

以下行为不能仅由自动测试关闭：

- Finder 启动后的 Homebrew 与 nvm 发现。
- Homebrew 六页的真实查询、联网行为与 cache 变化。
- 在专用测试环境中验证安装、update、升级、Formula 卸载、Cask standard/zap 和 Tap 变更。
- Homebrew 命令部分完成、取消退出与执行后状态复查。
- 真实 npm registry 正常、离线和失败状态。
- 首次窗口尺寸与不同窗口宽度下的可读性。
- `Command-Q`、关闭最后窗口和活动任务组合。
- App 退出后的子进程状态。

检查步骤见[人工验收清单](../manual-smoke-checklist.md)。未执行的项目保持为剩余风险，不写成已验证能力。

## Homebrew 写操作边界

Homebrew 写操作不复用或自动驾驶交互式 Manager。App 通过 Bridge 调用绝对 `brew`，并遵循 query、plan、confirm、execute、result、post-refresh 流程。一次只允许一个写操作；取消后再次操作必须重新生成计划。执行结果保留 stdout、stderr、退出码和部分完成语义，不承诺事务回滚。

本轮授权只覆盖产品需求中列出的 Homebrew 动作。环境引导、提权、cleanup、自动孤儿清理和 App 自行删除文件需要新的产品与安全决策。
