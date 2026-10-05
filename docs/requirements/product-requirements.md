# Cellar 1.0 产品需求

状态：1.0 产品契约；源码已实现，未公开发布

更新日期：2026-10-04

本文是 Cellar 1.0 用户行为、范围和验收的唯一权威来源。源码实现与自动验证不代替真实环境人工验收。组件边界见[总体架构](../architecture/macos-app-architecture.md)，发布范围见[1.0 交付范围](v1-mvp.md)，外部依据见[研究文档](../research.md)。

## 1. 摘要

Cellar 是面向 Apple Silicon Mac 的原生开发环境管理工具。它把 Homebrew Formula、Homebrew Cask、npm 全局包、Node/nvm 与终端配置组织为“查看、发现、安装、更新、卸载和维护”等用户任务，而不是要求用户先理解不同命令行工具的页面结构。

统一界面不抹平 provider 差异。每项操作始终保留 Formula、Cask 或 npm 身份、明确的 Node 环境、真实副作用和失败边界；批量操作不是事务，也不承诺回滚。

## 2. 背景与用户

目标用户是在 macOS 上维护本机开发工具、但不希望反复记忆多套 CLI 语法的开发者。他们需要快速回答三个问题：本机有什么、有什么可更新、一个操作会影响哪里。

1.0 在受控进程、Homebrew 查询和 mutation、Node Manager schema v1、Shell adapter、部分失败保留与 Manager 快照的基础上，已实现任务信息架构、官方目录、环境安装引导、批量编排、持久 Activity、本地化和可访问性支持。

## 3. 目标与成功标准

| ID | 目标 | 1.0 验收信号 |
|---|---|---|
| G-01 | 任务导向 | 用户从 Home、Library、Discover、Updates 或 Tools 完成任务，无需先选择技术模块 |
| G-02 | 真实且清楚 | 卡片显示 provider/type、版本、状态和目标环境；未知状态不伪装为最新 |
| G-03 | 安全写入 | 写操作有明确范围、适当确认和 post-refresh，并保留部分完成结果 |
| G-04 | 可恢复读取 | 一个 provider 或线上检查失败时，其他本地数据继续可用 |
| G-05 | 原生体验 | 支持键盘、VoiceOver、系统外观、窄窗口和标准 macOS 菜单快捷键 |
| G-06 | 国际化 | 英文、简体中文和繁体中文覆盖所有用户可见字符串，默认跟随系统 |
| G-07 | 低资源占用 | 空闲时无轮询；独立 IO 只使用有界并发；大列表和状态更新无持续高频工作 |

## 4. 信息架构

主窗口使用两栏 `NavigationSplitView`。窗口默认及最小内容尺寸均为 1080 × 720 点，可由用户放大并由系统恢复尺寸。

侧边栏主导航顺序固定为：

1. Home
2. Library
3. Discover
4. Updates
5. Tools

侧边栏左下方依次为 Settings 和 Activity，Activity 固定在最底部。Settings 是主窗口内的真实导航页面，选择后在 detail 区域显示设置内容，不打开独立设置窗口。App 菜单和 Command-Comma 通过共享导航意图前置或重建主窗口并选择 Settings；重复调用复用同一主窗口。App 是普通前台应用，不提供 `MenuBarExtra`，不在关闭最后窗口后后台驻留。

无活动任务时，关闭最后窗口和 `Command-Q` 退出 App。有活动任务时，本次退出请求被拒绝；运行中只显示进度、不提供手动停止，任务结束后用户可再次退出。

所有登记为 refresh 的任务统一在主窗口右上角的刷新按钮中显示系统进度动画；页面内容区不重复显示刷新动画或刷新中说明。

所有主页面采用统一的原生窗口工具栏：不显示重复页面标题，分类或范围入口位于左侧，刷新与页面动作靠右；工具栏背景、悬停反馈和滚动边缘由系统自动管理，不强制固定背景或硬边界。正文容器铺满内容栏，留白只作用于内容；表单、表格和滚动视图保留各自的原生滚动，不在外层再套第二个滚动容器。

全部网站链接统一使用白色 `arrow.turn.right.up` 箭头和小号蓝色实心圆角矩形底，通过系统浏览器打开。首页与软件卡片只显示图标，安装指引和开源入口保留说明文字并使用同一图标。

### 4.1 Home

Home 依次显示 Homebrew、Node/npm/nvm 与终端环境摘要，不显示路径、配置文件或 Manager 技术信息。

- Homebrew：安装状态、Homebrew 版本、Formula/Cask 数量和软件更新数量；官网入口紧随卡片内的 Homebrew 字段标题，使用统一的小号填充式网站图标打开系统浏览器。
- Node：当前受控 Node/npm 版本、当前 Node 环境的 npm 全局包数量、软件更新数量、nvm 状态和 nvm default。
- 终端环境：Command Line Tools 安装状态、Zsh 版本和 Oh My Zsh 安装状态；插件、主题和路径等配置详情仍只在 Settings > Terminal 展示。
- 三个摘要区直接使用单层数据卡片，进入页面时完整结构立即显示；尚未读取的值显示 `—`。已有成功结果在刷新期间继续保留，并在新结果到达时原位更新，不把卡片清空为 loading 页面。
- 本机版本与线上版本只有在能够可靠判断本机落后时才显示“当前版本 → 最新版本”，并在最新版本后显示圆形向上箭头；相同、领先、检查中、检查失败或无法比较时只显示本机版本。Home 不显示检查时间、刷新时间、重复的最新状态或具体更新名称。
- 本地状态先显示，线上版本和更新检查随后异步完成；线上失败不能清空本地状态。
- 缺少 Command Line Tools 或 Homebrew 时，Home 在终端环境或 Homebrew 对应区域提供必要的安装动作；缺少 nvm 时只在摘要中显示状态，安装指引保留在 Tools > Environment setup，不在 Home 重复入口。

### 4.2 Library

Library 展示已安装软件，提供 All、Homebrew、npm scope；Homebrew 下提供 Formula 与 Cask subtype scope。

- 软件库不显示页面标题；窗口 toolbar 左上角使用系统自动样式的原生 `NSSegmentedControl`，只承载 Tab 而不创建空内容容器。默认单行显示 All、Brew、NPM；选择 Brew 时切换 toolbar item identity，在同一行于 Brew 后显示 All、Formula、Cask，并按标题内容重新计算整体宽度；离开 Brew 时收起，并保留上次 Brew subtype。右侧搜索框使用固定宽度的原生 `NSSearchField`，与刷新按钮保持独立，Tab 展开或收起时宽度和可见性不变。
- 使用卡片和本地搜索/筛选。
- 默认 1080 点窗口且侧边栏可见时，软件库卡片每行两列；窗口变宽后自动增加列数，卡片宽度随可用空间调整。
- 工具栏下方由单个主滚动区域占满内容栏，卡片、提示和卸载结果一起滚动；内容保留边距，滚动条位于内容栏右缘。页面顶部不重复显示 Node 环境，npm 卡片继续标明所属环境。
- Tab 靠左，刷新按钮与固定宽度搜索框一起靠右；展开或收起 Brew 不改变这两个控件的右侧对齐。
- npm 卡片始终显示所属 Node 环境，不把多个 Node 安装的全局包合并成整机唯一集合。
- 单项卸载使用一次任务专用确认；Library 不提供管理模式、批量选择或批量卸载。
- Cask 单项卸载默认 standard；zap 必须由用户对明确目标主动选择，不能静默升级为 zap。

### 4.3 Discover

Discover 是 Homebrew Formula、Homebrew Cask 和 npm Registry 的统一搜索入口。scope 必须清楚可见，结果保留 provider/type 身份。

- 窗口工具栏不显示页面标题；左侧使用与软件库相同的原生系统分段样式，显示 Formula、Cask、NPM，紧跟固定 360 点搜索框；范围 Tab 与搜索框分别使用独立外观，中间留出间隔，不共享连体背景。刷新与批量安装靠右。搜索通过回车提交，Command-F 聚焦当前搜索框。
- 页面由单个主滚动区域覆盖内容栏，滚动条位于右缘；默认空状态在可见内容区水平、垂直居中，搜索结果从顶部排列。内容区不显示默认 Registry、整页 Node 环境说明、结果数量提示或搜索按钮。
- 空查询不请求完整远端目录；搜索结果有界。新查询或页面生命周期变化会在内部结束旧查询，界面不提供手动停止。
- 结果卡显示名称、类型、可用版本、最多两行说明、网站链接和一个状态相关主动作。
- npm 结果卡保留目标 Node 环境；搜索与安装绑定实际有效 Registry，批量安装确认继续显示来源和目标，不因移除页面摘要而改变环境绑定。
- Formula/Cask 同名时不能依靠名称猜测类型。
- 批量安装一次只接受一个明确 provider/type，一行一项，去空、去重，最多 100 项；预览目标后统一确认，逐项保留结果。

### 4.4 Updates

Updates 提供 All、Homebrew、npm scope；Homebrew 下提供 Formula 与 Cask subtype scope。

- 工具栏不显示页面标题；左侧复用软件库的原生 Tab，默认 All/Brew/NPM，选择 Brew 后在同一行展开 All/Formula/Cask，离开 Brew 收起并保留上次子范围。刷新和 Update All 靠右。
- 主滚动区域铺满内容栏，滚动条位于右缘；无结果时空状态水平、垂直居中，有结果时卡片从顶部排列。内容区不重复显示范围标题、更新数量、Node 环境摘要或检查按钮；失败、未知状态、执行进度和逐项结果仍保留，刷新与菜单继续提供检查入口。
- 卡片显示当前版本、可用版本和 `behind`、`current`、`ahead` 或 `unknown` 语义状态。
- 只有 `behind` 提供更新动作；npm 的 `ahead` 或 `unknown` 不产生更新或降级动作。
- “Update All”只影响当前可见 scope。跨 provider 的 All 视图仍拆成 provider/type 明确的顺序任务，不生成混合命令。
- 单项更新从卡片直接开始；批量更新使用一次任务专用确认。
- `brew update` 只更新 Homebrew/Tap 元数据，是 Tools 中的独立动作，不与包更新、查看或卸载隐式绑定。

### 4.5 Tools

Tools 按任务组织，而不是暴露 Manager 菜单：

分类使用工具栏左侧的原生分段控件，所选分类保留在 App 状态中；正文直接显示对应原生表单，不在正文重复放置分类条与分隔线。

- Environment setup：Command Line Tools、Homebrew 与 nvm 状态和安全引导。
- Runtime：安装、切换本次 Cellar 会话使用的 Node、设置 nvm default、安全卸载 Node。
- Project：为用户通过系统目录选择器明确选择的项目读取或写入 `.nvmrc`。
- Diagnostics：`brew doctor`、受控 PATH 和关键路径。
- Maintenance：Homebrew 元数据更新、npm/node-gyp/Manager 日志等现有受限维护动作，以及 Zsh tidy。

Homebrew `cleanup`、自动删除孤儿依赖和任意路径清理不在 Tools 范围内。普通界面不展示原始命令或“生成计划/执行计划”等内部术语。

### 4.6 Activity

Activity 展示当前任务与最近最多 100 条结构化摘要，并跨 App 启动持久化。

正文保留原生历史表格与详情的上下分区，分别滚动；搜索使用独立的 360 点工具栏搜索框，Command-F 聚焦且输入实时筛选。

- 摘要包含用户可理解的动作、scope、时间、进行中/成功/部分完成/失败/已取消状态和逐项目结果。
- 支持按状态或 provider 筛选，支持复制用户摘要和显式诊断详情。
- 默认界面不显示原始命令。stdout/stderr 和原始技术输出只在当前会话的诊断区域或现有受控日志中提供，不写入持久摘要。
- 持久数据在写入前去除凭证、环境变量秘密和不必要的用户路径。
- 运行中显示真实进度但不提供手动停止；任务所有者结束、超时或 App 生命周期回收导致内部取消时，仍 post-refresh 已经可能改变的状态，并显示实际完成项。

### 4.7 Settings

Settings 在主窗口内使用原生控件和四个 pane：

四个 pane 的切换入口位于窗口工具栏左侧，与其他页面使用相同的原生分段样式；正文铺满内容栏，不为整个设置容器设置外侧留白。最近选择仍持久保存，菜单“关于”继续导航到当前主窗口的 About；表单原生滚动，About 在空间足够时居中并支持滚动。

- General：语言，默认 Follow System，可显式选择 English、简体中文或繁体中文。
- Sources：Homebrew Tap 与 npm 默认/scope Registry。
- Terminal：Oh My Zsh、插件和主题。
- About：版本、更新通道、开源与 Sparkle 检查更新入口。

Terminal 插件可从 Oh My Zsh 内置插件、已安装自定义插件或用户确认的 `https://github.com/<owner>/<repository>` 添加；不提供“推荐插件”目录。主题只选择本机已安装的 `.zsh-theme`。插件和主题使用一次 Apply 提交；Cellar 永不运行 `chsh`。

## 5. 卡片与交互契约

目录型页面共享自适应卡片网格。卡片本体没有导航或点击动作；只有明确控件可触发操作。

每张卡片按数据可用性展示：

- 名称后紧跟不可点击的 Formula、Cask 或 NPM 文字 Tag，不在名称前显示 App 图标或类型符号，不在第二行重复类型；长名称优先截断，保留类型与网站入口；
- 已安装软件通常只显示当前版本数值；只有明确 `behind` 且有可用版本时显示“当前版本 → 新版本”，后接圆形向上箭头。不单列“已安装版本”“可用版本”或“已是最新版本”等状态行；检查中、失败、领先或无法比较时保留当前版本，不显示更新箭头。未安装的发现结果显示待安装版本；
- 语义版本状态继续用于更新资格与辅助功能读取，刷新失败由页面提示，不将未知状态伪装成最新；
- 最多两行、尾部截断的说明；
- 一个主动作；
- 类型 Tag 后的小号填充式网站箭头通过系统默认浏览器打开网站，不使用底部网站按钮；没有有效 URL 时不显示入口；
- 执行中的真实阶段或不定进度。

软件库、发现与更新共用上述卡片样式，不读取或下载软件 App 图标。界面使用系统字体、颜色、material 和标准控件，类型 Tag 为低对比度静态标识，不以装饰性玻璃覆盖内容卡片。

键盘必须能到达所有动作，并显示焦点。状态不能只靠颜色表达。支持 VoiceOver 名称/值/顺序、Light/Dark、Increased Contrast、Reduce Motion、Reduce Transparency，以及窄/宽窗口。菜单命令和快捷键覆盖可达的刷新、搜索及常用 toolbar 动作。

## 6. 数据与版本语义

### 6.1 Homebrew

- Formula 与 Cask 是不同身份；查询、安装、更新、卸载和批量操作都保留类型。
- 本机信息以受控绝对 `brew` 返回的结构化数据为准；线上 Homebrew 版本与安装器元数据来自官方来源。
- Cask artifact 只用于卸载前说明和执行后报告。Cellar 不自行 `rm` artifact，也不做名称或 bundle identifier 模糊扫描。
- 卸载显式禁止 Homebrew 自动更新和 autoremove。

### 6.2 Node、npm 与 nvm

- npm 1.0 只管理全局包，不管理项目依赖。
- 全局包属于明确 Node 安装。默认启动环境优先解析 `~/.nvm/alias/default`；缺失、循环或无法匹配时不猜测最新版。
- Finder/Xcode 启动不读取 `.zshrc`。受控 PATH 只加入明确解析的默认或本次会话 Node `bin` 和批准的系统路径。
- npm Registry 搜索与 Node runtime 管理是不同职责。
- `npm outdated` 或线上元数据失败是独立部分失败，不能抹掉 Node/npm 版本、包列表和配置。

### 6.3 版本状态

在可以可靠比较时，版本状态为：

- `behind`：可用版本高于当前版本；允许更新。
- `current`：当前与可用版本相同。
- `ahead`：当前版本高于线上/Registry 版本；只展示，不自动降级。
- `unknown`：缺失、非可比较版本或检查失败；不声称已是最新，也不提供更新。

## 7. 写操作与安全边界

### 7.1 确认规则

| 动作 | 用户确认 |
|---|---|
| 单项安装、单项更新 | 从卡片直接开始，不显示通用计划页 |
| 批量安装、批量更新 | 预览明确 scope 和目标后一次确认 |
| 单项卸载、Cask zap | 一次任务专用确认，说明不可回滚与影响范围 |
| Tap、Registry、Terminal、`.nvmrc` 等配置修改 | 一次任务专用确认 |
| cleanup 类受限维护 | 一次任务专用确认并列出精确候选；Homebrew cleanup 不支持 |

内部仍使用强类型计划、时效和状态指纹保护高风险操作。确认后的目标或状态变化必须拒绝执行并要求用户重新开始。所有 mutation 在有能力处理结果的层保存退出状态和逐项目结果，完成、失败或内部中断后读取真实状态。

### 7.2 批量与并发

- 同一时间只执行一个全局写任务；重复提交不启动第二项。
- 每次提交只包含一个 provider/type；跨 scope 的用户动作拆为清楚的 typed operation。
- 批量 install/update 顺序执行；单项失败后继续未执行项。uninstall 只接受单个目标，已开始的任务不提供手动停止。
- 不做事务承诺或自动回滚。成功、失败、内部取消和无法确认的项目分别呈现。
- 退出保护覆盖仍在运行的任务；任务所有者结束、超时或 App 生命周期回收时，通过既有进程组生命周期终止对应子进程。

### 7.3 环境安装

- Command Line Tools：只调用 `xcode-select --install` 请求 Apple 文档定义的系统安装对话框。Cellar 不下载、不打包、不模拟 CLT 安装器，也不代替系统处理许可或安装。
- Homebrew：只接受 Homebrew 官方仓库 latest stable Release 中适用于当前平台的精确 `Homebrew.pkg`，并要求同一官方 Release 提供该资产的有效 SHA-256。Cellar 必须依次验证官方来源、SHA-256 完整匹配、package signature 和 Gatekeeper assessment；任一验证缺失、无效、不匹配或失败时都不得打开安装包，而是显示具体原因和 Homebrew 官方网站链接。
- 通过全部验证后，Cellar 只把 package 交给 macOS 系统 Installer 打开。Cellar 不保证 Installer 将显示哪一种提示；后续可能出现的权限说明、许可、认证和安装均由系统界面处理。Cellar 不重写 Homebrew 安装逻辑、不运行网络脚本、不收集管理员密码，也不提供自己的 `sudo` 或 Privileged Helper。
- 已有但损坏或来源不明的 Homebrew 不被覆盖、删除或“自动修复”；界面说明检测结果并引导用户采用 Homebrew 官方恢复方式。
- nvm：1.0 提供状态、官方安装指引和已有 nvm 环境管理；不在 App 内执行远端安装脚本。

release metadata、下载、SHA-256、package signature、Gatekeeper assessment 和打开 Installer 必须是可替换边界，以便自动测试覆盖每一种 fail-closed 结果，只使用本地 fixture，绝不打开真实 Installer。

### 7.4 明确禁止

Cellar 1.0 不会：

- 执行 Homebrew cleanup、自动删除孤儿依赖，或自行删除 Cask 残留；
- 运行 `sudo`、内置 Privileged Helper、保存密码或绕过 macOS 授权界面；
- 修改 `.zprofile` 正文、运行 `chsh`、删除 Oh My Zsh 或接受任意 Git URL/任意 Shell 命令；
- 驱动 Homebrew 或 Zsh 的交互菜单；
- 管理 npm 项目依赖，或把不同 Node 环境的全局包合并；
- 在未确认的 provider/type 之间混合批量命令；
- 后台驻留、退出后继续任务、收集遥测或使用 Cellar 账户服务。

## 8. 文件、网络与隐私

Cellar 没有账户、遥测或自有服务端。网络请求只服务于用户可见的版本、目录、包管理、插件或更新任务，并使用官方服务或用户明确配置的 Tap/Registry/GitHub 地址。

Manager 只读资源从 App Bundle 安装到：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

App Bundle Resources 不写入运行数据。Activity 的结构化摘要持久化在 Cellar 自有 Application Support 范围，最多 100 条；原始输出不进入该摘要存储。

Homebrew 和 npm 查询也可能访问网络并写入各自 cache。拒绝网络或单一来源失败时，本地已知状态尽量继续展示。任何真实安装、更新、卸载或配置操作只在用户动作和上述确认边界内发生。

## 9. 性能与可靠性

- 启动先读取本地状态；线上版本检查不阻塞首屏。
- 相互独立的只读 IO 使用有界并发；不使用轮询循环、高频动画或投机 cache。
- 进程使用绝对 executable、参数数组、受控 environment、明确工作目录/stdin/stdout/stderr、deadline、输出上限、取消和进程组回收；禁止 `bash -c`。
- 读取、线上版本、搜索和单项 mutation 的失败分开建模；一个错误不清空无关成功数据。
- View 不直接运行命令；Models 不执行 IO；自动测试不接触用户真实环境。

## 10. 发布范围与非目标

1.0 支持 macOS 26.0 及以上、仅 Apple Silicon `arm64`，使用 Swift 6、SwiftUI、Foundation 和必要的 AppKit/Sparkle。不支持 Intel、Universal Binary、Rosetta、macOS 15、App Sandbox 或 Mac App Store。

1.0 不保证自定义 `NVM_DIR`、asdf、fnm、Volta、远程主机、团队同步、后台自动更新包、自动修复开发环境或任意 CLI 执行。新的删除、提权、持久化或外部协议能力必须先更新本文的产品与安全契约。

## 11. 验收边界

自动测试和无签名构建验证类型、状态、解码、进程、取消、持久化、测试隔离、localization coverage、最低系统和 arm64 产物。所有外部写操作使用 fake executable、fixture 和临时目录。

真实 Finder 启动、系统授权、官方 Installer、真实 Homebrew/npm/nvm、网络、窗口、键盘、VoiceOver 和视觉质量按[人工验收清单](../manual-smoke-checklist.md)验证。未执行的项目不得描述为已验证或已发布。
