# Changelog

记录 Cellar 面向用户的重要变更。

## [1.0.0] - 2026-11-12

当前为源码实现与本地验证版本，尚未公开发布；真实环境人工验收仍按清单执行。

### Added

- Home、Library、Discover、开发环境与主窗口 Settings/About 任务导航，软件更新整合在 Library。
- Formula、Cask 与明确 Node 环境的 npm 目录、搜索和顺序批量操作，保留逐项状态、部分完成与复查结果。
- CLT/Homebrew 安全安装引导、Node runtime/项目配置、Sources/Terminal 受限配置与维护。
- 本地文件日志，可配置记录等级和保存期限，并从设置打开日志文件夹；支持英文、简体中文和繁体中文界面。
- Icon Composer 应用图标、README 图标预览及随 App 打包的彩色工具图标。

### Changed

- 开发环境按 Node.js、终端、软件源和环境检查组织；项目版本及维护操作归回对应工具，设置只保留应用语言与日志偏好，“关于”成为独立入口。
- 移除活动记录页面，以跨页面的任务进度和最近结果展示逐项完成情况；历史活动文件不再读写，也不自动迁移或删除。
- 首页各统计项使用独立小卡片，统一图标底框、阴影与更新箭头；调整侧边栏、工具栏、搜索框、表单间距及按钮样式。
- 添加 Tap 和从 GitHub 安装插件改用输入弹窗；终端插件通过分组多选面板展示已选项、未选项和来源。
- 批量安装使用与发现页一致的分类控件，并提供带行号、高亮当前行、边框及共享背景的输入框。

### Fixed

- Debug 构建使用本地临时签名，并修复嵌套框架签名，无需登录 Apple 账号或选择开发团队。
- 修复批量安装长列表无法滚动到末尾、输入无法撤销的问题；撤销与重做同步更新输入内容和行号。
- 限制任务反馈区的总高度并支持整体滚动，避免多组失败结果挤占整个页面。
- 拒绝将日志写入符号链接或特殊文件，避免异常目标阻塞写入和退出，并保留失败记录供重试。
- 修正本地化检查对数字插值的误判，补齐原有翻译目录中的缺失项。
- 修复“关于”和菜单中的检查更新按钮未随后台更新状态恢复的问题。

## [0.1.0] - 2026-09-21

### Added

- Native macOS management for Homebrew, Node/npm/nvm, Zsh, and Oh My Zsh.
- Controlled plan, confirmation, execution, and post-refresh workflows.
- Sparkle update support and release automation for arm64 macOS 26 builds.
