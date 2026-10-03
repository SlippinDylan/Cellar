# Cellar 1.0 交付范围

状态：已确认范围；实现中

更新日期：2026-10-04

文件名为兼容既有链接保留。本文只概括 1.0 的发布边界，不建立第二套产品定义；任何用户行为、确认规则或安全边界以[产品需求](product-requirements.md)为准。

## 1.0 必须交付

| 范围 | 交付结果 |
|---|---|
| App shell | Home、Library、Discover、Updates、Tools；底部 Activity；标准 Settings scene |
| 目录体验 | Formula、Cask、npm 卡片；本地库、官方搜索、网站链接、语义版本状态 |
| Home | Homebrew 与 Node/npm/nvm 的本地状态、线上版本、数量、具体更新摘要和内联 setup |
| Library | 已安装软件的统一查看、搜索、scope、单项与同类型批量卸载 |
| Discover | 有界的 Homebrew/npm 搜索，以及单项和单 provider/type 批量安装 |
| Updates | scope 决定影响范围；单项和 typed batch 更新；npm ahead/unknown 不降级 |
| Tools | CLT/Homebrew/nvm setup，Node runtime，项目 `.nvmrc`，诊断，受限维护与 Zsh tidy |
| Settings | General、Sources、Terminal、About；Tap、Registry、插件、本机主题和语言 |
| Operations | 全局写任务互斥、顺序批量、取消、部分完成、post-refresh 和退出保护 |
| Activity | 最多 100 条可筛选、可复制、隐私处理后的持久摘要；原始输出不持久化到摘要 |
| Localization | English、简体中文、繁体中文；默认 Follow System |
| Quality | 键盘、VoiceOver、系统外观、对比度/动态效果设置、响应式窗口和低空闲资源占用 |
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
5. README、产品、架构、开发和人工清单与最终实现一致；未验证行为不写成已交付。
6. `scripts/` 保持冻结，release 开关保持关闭，除非用户另行明确授权。

真实环境步骤见[人工验收清单](../manual-smoke-checklist.md)，工程验证见[开发指南](../development.md)。
