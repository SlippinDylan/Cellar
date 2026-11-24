# Cellar 1.0 交付范围

状态：1.0 源码已实现，未公开发布；人工验收门槛保留

更新日期：2026-11-13

文件名为兼容既有链接保留。本文只概括 1.0 的发布边界，不建立第二套产品定义；任何用户行为、确认规则或安全边界以[产品需求](product-requirements.md)为准。

## 1.0 实现范围

| 范围 | 交付结果 |
|---|---|
| App shell | Home、Library、Discover、环境、维护；左下方依次显示 Settings 和 About；两者位于主窗口内 |
| 目录体验 | Formula、Cask、npm 卡片；本地库、官方搜索、网站链接、语义版本状态 |
| Home | Homebrew 与 Node/npm/nvm 的本地状态、线上版本、数量、具体更新摘要和内联 setup |
| Library | 已安装软件的统一查看、搜索、类型及待更新筛选、单项／批量更新与单项卸载 |
| Discover | 有界的 Homebrew/npm 搜索，以及单项和单 provider/type 批量安装 |
| 软件更新 | 位于 Library；当前类型、状态和搜索共同决定批量范围；npm ahead/unknown 不降级 |
| 环境 | 终端、Brew Tap（Homebrew Tap）、npm 软件源、Node.js 四个独立页面；全局 Node/nvm 管理与 Zsh tidy，操作附近只保留必要上下文 |
| 维护 | Homebrew 状态检查、npm 缓存校验与五类已有受限清理；保留确认、复验和实际结果 |
| Settings | 通用提供语言与日志偏好；环境信息集中展示 Cellar 识别和使用的已有环境详情 |
| About | 独立侧栏入口；128 点图标、名称、版本、检查更新与 Studio 版权署名 |
| Operations | 全局写任务互斥、顺序批量、取消、部分完成、post-refresh 和退出保护 |
| 任务反馈与日志 | 跨页面任务进度与可关闭的最近结果；本地去敏文件日志、等级与保存期限设置；原始输出只在显式会话诊断中展示 |
| Localization | English、简体中文、繁体中文、日本語、한국어、Deutsch、Français、Español；默认 Follow System |
| Quality | 键盘、VoiceOver 和系统外观支持、响应式窗口、无空闲轮询；真实辅助功能、外观和性能仍需人工验收 |
| Distribution | macOS 26+、仅 arm64、普通前台 App、现有 Sparkle 发布边界 |

## 延续的实现基础

当前仓库已经实现并在 1.0 中继续沿用：受控 `ProcessRunner`、绝对 executable 与参数数组、Manager 快照、Homebrew Bridge、Node schema v1、Shell schema v1 adapter、状态指纹、部分失败保留、操作锁和 post-refresh。1.0 重组用户界面和编排，不用通用命令执行器覆盖这些边界。

## 明确不包含

- Homebrew cleanup、自动删除孤儿依赖、Cellar 自行删除 Cask artifact 或残留。
- Cellar 自有 `sudo`、Privileged Helper、密码收集或绕过系统 Installer/授权。
- npm 项目依赖、混合 Node 环境的“全局包”视图、自定义 `NVM_DIR`、asdf、fnm 或 Volta。
- 修改 `.zprofile` 正文、`chsh`、删除 Oh My Zsh、任意 Shell 命令或任意 Git URL。
- 自动驾驶 Homebrew/Zsh 交互菜单、后台驻留、退出后继续运行或包自动更新守护进程。
- Intel、Universal Binary、Rosetta、macOS 15、App Sandbox 或 Mac App Store。
- Cellar 账户、遥测、自有目录服务、团队同步或远程环境管理。

## 发布门槛

1. 所有产品需求均由实现、直接测试或明确人工验收覆盖。
2. 自动测试只使用 fake executable、fixture 和临时根目录，不触发用户真实环境写入或系统 Installer。
3. 完整 XCTest、Debug/Release build、localization coverage、release manifest/version checks 通过。
4. Release App 内每个 Mach-O 的最低系统版本为 macOS 26.0，且只有 `arm64`。
5. README、产品、架构、开发和人工清单与最终实现一致；未执行的人工验收不写成已验证。
6. `scripts/` 保持冻结，release 开关保持关闭，除非用户另行明确授权。

真实环境步骤见[人工验收清单](../manual-smoke-checklist.md)，工程验证见[开发指南](../development.md)。
