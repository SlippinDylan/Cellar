<div align="center">
  <img src="docs/images/readme/app-icon.png" width="160" height="160" alt="Cellar 应用图标">
  <h1>Cellar</h1>
</div>

Cellar 是面向 macOS 26+、仅支持 Apple Silicon 的原生开发环境管理工具。1.0 把 Homebrew Formula、Homebrew Cask、npm 全局包、Node/nvm 与终端配置组织为查找、安装、更新、卸载和维护等用户任务，同时保留每个 provider 的真实语义与安全边界。

> Cellar 1.0.0 已完成源码实现与本地自动验证，尚未公开发布，没有正式下载。真实工具写入、系统 Installer、网络和辅助功能等人工验收仍按清单执行。

## Cellar 1.0

| 入口 | 用途 |
|---|---|
| Home | Homebrew、Node/npm/nvm 与终端环境的关键状态、版本、数量和可更新数量 |
| Library | 查看、搜索和筛选已安装软件；单项或当前筛选范围内批量更新，以及单项卸载 |
| Discover | 搜索 Homebrew 与 npm Registry，单项或同 provider/type 批量安装 |
| 环境 | Node.js 版本与项目版本、终端主题和插件、软件源及 Zsh 文件整理 |
| 维护 | Homebrew 检查、npm 缓存校验和已有受限清理 |

主窗口侧边栏左下方依次显示 Settings 和 About，不再提供活动记录页面或菜单。Settings 使用“通用／环境信息”分类：通用提供语言、完全磁盘访问权限与日志偏好，环境信息集中展示 Cellar 识别和使用的开发工具版本、状态与路径；软件源和终端配置归入环境；About 是独立页面，显示放大的图标、名称、版本、检查更新按钮和底部 Studio 版权署名。App 菜单或 Command-Comma 会前置或重建主窗口并选择 Settings，不打开独立设置窗口；菜单“关于 Cellar”打开 About。界面支持 English、简体中文和繁体中文，默认跟随系统语言。

环境按终端、Brew Tap（Homebrew Tap）、npm 软件源、Node.js 的顺序组织。Node.js 区分 Cellar 当前使用的 Node 与 nvm 管理的已安装版本，版本安装在用户主动打开后读取官方版本；项目版本只读取或写入明确选择项目的 `.nvmrc`，不自动安装或切换终端。操作页面仅在短页面底部或长页面正文末尾以无卡片、居中紧凑的小号次要文字保留必要上下文，完整环境信息位于 Settings > 环境信息，不代表所有已打开终端的运行环境。维护独立分为检查与清理：检查保留 Homebrew 状态检查和 npm 缓存校验，清理保留 npm／构建缓存、失效 npm 链接、未使用 Node 版本与旧 Manager 日志处理；Zsh 文件整理和 Homebrew 目录数据更新仍分别位于终端和 Homebrew Tap 页。检查保留实际结果，清理保留精确范围、一次确认与实际完成结果。CLT/Homebrew 的状态与必要安装动作保留在首页，nvm 安装指引位于 Node.js。

Homebrew Tap 页右上角刷新同时更新 Homebrew/Tap 目录元数据与本机状态，不升级已安装软件；其他页面的刷新仍只读取本机环境。添加 Tap 位于分组标题右侧。

软件更新不再单独占据侧边栏入口。Library 的类型、可取消选中的待更新 Tab 和搜索条件组合筛选；刷新独立显示，只有选中待更新时显示更新全部，批量更新只影响当前筛选后的可更新项。

目录卡片左侧保留固定 48 × 48 点的图标布局空间，在整张卡片内垂直居中；没有真实图标时使用居中的 40 × 40 点占位底框；右侧软件包名称和 Formula/Cask/NPM 类型 Tag 组成标题行。简介位于图标右侧、名称和标签下方，与名称左边缘对齐，使用无独立背景的灰色文字，最多两行，超出以省略号截断；无论简介缺失、为空或只有一行，都预留两行高度，让卡片等高。名称、简介与版本行之间的两处间距均为 4 点。右侧底部版本使用大写 `V` 前缀（如 `V 8.12.44`），与简介左对齐；其后显示蓝色“网站”文字和指南针图标，文字与图标共同组成可点击的网站入口。不使用分割线。官方 Homebrew Cask 按精确 token 显示真实软件图标；加载中、缺失或失败时显示名称首字母，第三方 Tap 不借用官方同名图标。Formula 和 npm 使用通用图标。需要更新时显示“V 当前 → V 新版本”与更新箭头。Library 右上角提供 Liquid Glass 胶囊形更新／卸载按钮组，鼠标悬停时对应按钮显示浅色背景，无更新资格时只显示卸载，Discover 保留安装主动作。网站由系统浏览器打开，卡片本体不承担跳转。

## 操作与安全

- npm 只管理全局包，操作始终绑定明确的目标 Node 环境；卡片不重复显示 Node/npm 环境版本。
- 单项安装/更新从卡片开始；批量安装/更新、单项卸载、zap、清理和配置修改使用任务专用确认。
- 批量任务一次只处理一个 provider/type，逐项顺序执行；某项失败后继续。已开始的任务不提供手动停止，运行至完成。
- 写操作不是事务，不承诺回滚。Cellar 会保留成功、失败、内部中断和 post-refresh 后的真实状态。
- Formula/Cask 卸载禁止 Homebrew 自动更新和 autoremove，不执行 Homebrew cleanup。Cask 卸载前列出应用本体、可确认归属的缓存与应用数据，以及目标对应的 Homebrew 下载缓存；确认后先请求目标应用正常退出，再由 Homebrew 卸载及清理已确认的关联路径；拒绝退出、重新运行或文件身份变化时保留相应结果和数据。共享或无法确认归属的数据保留，不处理其他安装来源的软件或孤儿依赖。
- 受限 Cask 残留清理遇到权限不足时，可以请求 macOS 管理员授权；密码由系统处理，Cellar 不收集或保存密码，也不安装常驻特权服务。Homebrew 卸载钩子自身需要 sudo 的情况仍可能失败，不能保证所有受保护文件都可删除。Cellar 不修改 `.zprofile`，不运行 `chsh`。

缺少 Command Line Tools 时，Cellar 只通过 `xcode-select --install` 请求 macOS 系统安装对话框。缺少 Homebrew 时，只接受官方 latest stable Release 的 `Homebrew.pkg` 和该精确资产的有效 SHA-256；digest、package signature 与 Gatekeeper assessment 全部通过后才交给系统 Installer。任何验证缺失或失败都会阻止打开并提供原因和 Homebrew 官方链接。Cellar 不重写安装器、不执行远端安装脚本，也不处理系统许可或认证。nvm 提供官方安装指引，不在 App 内运行远端脚本。

Cask 卸载弹窗立即打开并显示扫描状态，高度不超过当前主窗口可用高度的 70%。本机图标与名称、应用大小与本次预计移除摘要及底部操作区固定，只有分类路径和各项占用明细滚动，路径可在访达中定位。确认后在原弹窗按路径显示移除进度与结果，完成后点击“好的”关闭；未移除项按原因提示手动处理或先核实共享数据的影响。可在 Settings > 通用 > 完全磁盘访问权限打开系统的完全磁盘访问权限设置，通过悬浮引导窗把当前 App 拖入权限列表并手动开启开关；返回 App 后会验证受保护 Cookies 目录的读取，通过后显示绿色“访问已验证”；这不代表所有路径均可读。如果仍拒绝访问，请退出重开后再扫描。保留项同样尝试统计大小；无法统计时区分权限不足、达到统计上限及读取失败，不计为零；不承诺无残留或自动回滚。

## 数据与网络

Cellar 没有账户、遥测或自有服务端。Homebrew、npm Registry、nvm/Node 版本、Oh My Zsh、GitHub 插件和 Sparkle 更新会按用户可见功能访问官方或用户配置的来源。Homebrew/npm 查询也可能写入各自 cache；单一网络检查失败不会清空已读取的本地状态。

Library 和 Discover 的官方 Cask 图标由 [CaskFlow](https://github.com/alielsokary/CaskFlow) 提供，通过 `cdn.jsdelivr.net` 按展示需要请求精确 Cask token 对应的 PNG；第三方 CDN 会收到所请求的 token 和通常的网络连接信息。图标缓存在 `~/Library/Caches/com.dylanwang.Cellar/CatalogIcons/`，内存上限 8 MiB、磁盘上限 64 MiB，成功缓存 7 天，失败在当前会话内缓存 5 分钟。图标失败不影响查询和软件操作。CaskFlow 使用 MIT 许可证，软件 Logo 的商标权益归各自权利人；许可文本随 App 的 `BrandIcons-LICENSE.txt` 提供。

Manager 只读资源随 App 打包，运行副本安装到：

```text
~/Library/Application Support/Cellar/Managers/<version>/
```

非刷新任务的进度和最近一次完成结果在主窗口顶部显示，切换页面后仍可查看；批量操作保留逐项结果和部分完成说明。结果可收起或关闭，不受日志等级影响，重启后不恢复。刷新进度仍只显示在工具栏刷新按钮内。

日志保存在 `~/Library/Logs/Cellar/`。可在 Settings > 通用的日志分组选择最低记录等级（Trace、Debug、Info、Warning、Error、Critical，默认 Info）、保存期限（7、14 或 30 天，默认 7 天），并在访达中打开日志文件夹。设置立即生效；文件按 UTC 日期分组，单文件最多 10 MiB，总占用最多 50 MiB，写入或调整设置时淘汰过期和最旧日志。日志只保存去敏后的任务语义、结果及必要排错信息，不保存原始命令或 stdout/stderr；技术输出仍只在显式打开的当前会话诊断区域或既有受控 Manager 日志中提供。旧版 `~/Library/Application Support/Cellar/Activity/activity.json` 不再读写，也不自动迁移或删除。

Release 构建使用 Sparkle 检查 `https://slippindylan.github.io/homebrew-tap/cellar/appcast.xml`。Debug 和普通本地构建默认关闭 updater；只有发布流水线配置密钥并显式开启时才检查更新。

## 系统要求

- macOS 26.0 或更高版本
- Apple Silicon Mac（仅 `arm64`）
- 从源码构建需要 Xcode 26 或更高版本

不支持 Intel Mac、Universal Binary、Rosetta 或 macOS 15。

## 从源码构建

打开 `Cellar.xcodeproj`，选择 `Cellar` scheme 和 My Mac，按 `⌘R` 使用 Debug 构建并运行。Debug 使用本地临时签名（Sign to Run Locally），无需登录 Apple 账号、选择开发团队或安装开发证书。详细签名与验证说明见[开发指南](docs/development.md)。

仅验证无签名编译时，也可以在仓库根目录执行：

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
| [总体架构](docs/architecture/macos-app-architecture.md) | 当前实现、数据流与进程边界 |
| [平台支持](docs/requirements/platform-support.md) | macOS、arm64 和构建门禁 |
| [研究依据](docs/research.md) | Apple、Homebrew、npm 与 nvm 官方依据 |
| [开发指南](docs/development.md) | 测试、构建、产物检查和清理 |
| [人工验收清单](docs/manual-smoke-checklist.md) | 真实机器、系统授权和 UI 检查 |
