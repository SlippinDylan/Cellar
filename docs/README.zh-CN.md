<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Cellar 应用图标">
  <h1>Cellar</h1>
  <p>在一个原生 Mac 应用里，管理你的开发工具。</p>
  <p>
    <a href="../README.md">English</a> ·
    <strong>简体中文</strong> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ko.md">한국어</a> ·
    <a href="README.de.md">Deutsch</a> ·
    <a href="README.fr.md">Français</a> ·
    <a href="README.es.md">Español</a>
  </p>
</div>

Cellar 把 Homebrew 软件、npm 全局包、Node.js 版本和终端配置集中到一个 macOS 应用中。查看已安装的软件，查找新工具，完成更新，并在卸载前了解将要移除的内容。

> [!NOTE]
> Cellar 1.0 尚未公开发布，暂时没有可下载的安装包或 Homebrew Cask。目前可以从源码构建；真实环境与界面验收仍待完成。

## 你可以做什么

| 任务 | 在 Cellar 中 |
|---|---|
| 查看环境状态 | 在首页查看 Homebrew、Node.js、npm、nvm 和终端环境状态。 |
| 管理已安装软件 | 在软件库浏览、搜索和筛选 Homebrew Formula、Cask 与 npm 全局包；单项更新、按筛选范围批量更新，以及单项卸载。 |
| 查找新工具 | 在发现页面搜索 Homebrew 和 npm，单项安装或批量安装同一类型的软件包。 |
| 配置开发环境 | 通过 nvm 管理 Node.js 版本，管理所选项目的 `.nvmrc`、Homebrew Tap、npm 软件源，以及 Oh My Zsh 主题和插件。 |
| 检查与清理 | 运行 Homebrew 诊断和 npm 缓存校验，查看并确认受支持的缓存、未使用 Node 版本及旧 Manager 日志清理任务。 |

任务进度和最近结果会在切换页面后继续显示，批量任务部分成功时也能查看逐项结果。

界面支持**英文、简体中文、繁体中文、日语、韩语、德语、法语和西班牙语**，默认选项为**跟随系统**。也可以在「设置 > 通用」中选择语言；更改后会重启 Cellar。

## 系统要求与发布状态

- **macOS 26 或更新版本**，运行于 **Apple Silicon Mac**（`arm64`）。
- 从源码构建需要 **Xcode 26 或更新版本**。
- Homebrew、Node.js、npm 和 nvm 是 Cellar 管理的工具，不随应用捆绑。

缺少 Command Line Tools 或 Homebrew 时，Cellar 可以打开系统安装流程；Homebrew 官方安装包会在打开前完成验证。nvm 提供安装指引。

应用更新已通过 Sparkle 配置到共享的 [Homebrew Tap](https://github.com/SlippinDylan/homebrew-tap)。首次对应版本发布时，流水线会创建签名更新源和 Cask。Debug 和普通本地构建关闭应用更新。

## 从源码构建

```bash
git clone https://github.com/SlippinDylan/Cellar.git
cd Cellar
open Cellar.xcodeproj
```

在 Xcode 中选择 **Cellar** scheme、**My Mac** 和 **Debug** 配置，按 **⌘R** 运行。Debug 使用本地临时签名（Sign to Run Locally），无需登录 Apple 开发者账号或安装签名证书。

也可以通过命令行构建：

```bash
xcodebuild build \
  -project Cellar.xcodeproj \
  -scheme Cellar \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData-Debug
```

应用产物位于 `build/DerivedData-Debug/Build/Products/Debug/Cellar.app`。测试、签名和 Release 构建见[开发指南](development.md)。

## 修改环境前需要了解

- npm 全局包属于具体的 Node.js 安装。搜索与操作绑定所选 Node 环境；Cellar 不管理项目内的 npm 依赖。
- npm 包搜索与修改需要受支持的 nvm 安装；其他已检测的 Node 安装仍可读取。Registry 用户设置和缓存维护按各自能力规则处理。软件源地址支持无凭证 HTTPS，以及 `localhost`、`127.0.0.1`、`[::1]` 的本机 HTTP；不支持其他 HTTP 地址。
- 切换 Cellar 当前使用的 Node 版本仅影响本次 Cellar 会话，不会切换已打开的终端。保存项目的 `.nvmrc` 只声明所需版本，不会自动安装 Node 或切换终端。
- 软件库与发现页面卡片中的单项软件包安装和更新直接开始；终端组件安装、批量操作、卸载、清理和配置修改会先确认范围。运行中的任务不能手动停止，任务进行时 Cellar 会阻止退出。
- Homebrew Cask 卸载还可移除预先确认、能够验证归属的关联数据，共享或无法核实的数据会保留。Formula 和 npm 卸载不包含这类关联数据清理。Cellar 不执行 Homebrew cleanup，也不自动删除孤儿依赖。
- 部分残留文件清理需要 macOS 管理员授权或完全磁盘访问权限。密码由系统处理，Cellar 不收集密码，也不安装常驻特权服务；授权不保证所有文件均可删除。
- 操作可能部分成功。Cellar 会报告已完成项和失败项，不承诺回滚；不修改 `.zprofile`，也不改变登录 Shell。

## 数据与网络

Cellar 没有账户、遥测或自有服务端。工具查询、搜索、安装、插件和应用更新访问官方服务或你配置的来源。Homebrew 和 npm 查询也可能写入各自的缓存。

官方 Homebrew Cask 图标由 [CaskFlow](https://github.com/alielsokary/CaskFlow) 提供，通过 `cdn.jsdelivr.net` 下载。CDN 会收到所请求的 Cask 标识和通常的连接信息。CaskFlow 的 MIT 许可随应用分发，软件 Logo 的权益归各自所有者。

| 本地数据 | 位置 |
|---|---|
| 随应用分发的 Manager 运行副本 | `~/Library/Application Support/Cellar/Managers/<version>/` |
| 日志 | `~/Library/Logs/Cellar/` |
| 下载的软件图标 | `~/Library/Caches/com.dylanwang.Cellar/CatalogIcons/` |

日志等级和保存期限可在「设置 > 通用」中调整。文件日志不保存原始命令或 stdout/stderr；任务结果仅在当前会话保留。

## 项目文档

详细项目文档目前使用中文：[文档索引](README.md)、[产品需求](requirements/product-requirements.md)、[总体架构](architecture/macos-app-architecture.md)、[开发指南](development.md)和[人工验收清单](manual-smoke-checklist.md)。
