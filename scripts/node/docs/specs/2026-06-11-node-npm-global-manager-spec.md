# Node / npm 全局环境管理脚本规格

日期：2026-06-11
状态：Ready for implementation planning
目标脚本：`scripts/node/npm-global-manager.sh`
参考脚本：`scripts/homebrew/brew-app-manager.sh`

## 目标

实现一个运行在 macOS 本地交互式终端中的 shell 脚本，统一管理：

- `nvm`
- `Node.js`
- `npm` 全局包
- `npm` 源配置

脚本要参考 `brew-app-manager.sh` 的交互方式，而不是复制 Homebrew 的业务模型。

## 非目标

以下内容不在当前脚本范围内：

- 任意项目目录中的 `npm install`
- 项目级 `package.json` 依赖管理
- `pnpm`、`yarn`、`bun`
- 用 Homebrew 安装 Node.js
- GUI 界面

## 核心约束

- 脚本运行环境固定为 macOS 本地交互式终端。
- Node.js 本体统一由 `nvm` 管理，不走 Homebrew。
- `nvm` 的验证方式使用 `command -v nvm`，不要使用 `which nvm`。
- 实现目标必须是可持续、长期稳定、可维护的完整交付，不接受只为“先跑通”而做的短期拼接。
- 绝不允许为了过语法检查、过测试或过编译而打补丁式修复。
- 绝不允许扩散爆炸半径；新增逻辑必须收敛在清晰边界内，不得把无关模块一起拖进修改范围。
- 绝不允许“哪里报错就在哪里临时糊一层”的面条式实现。
- 代码必须保持设计感：函数职责单一、边界清晰、输入输出明确、可读性优先于投机取巧。
- 所有只读展示功能不得修改环境。
- 所有删除、卸载、覆盖、修改默认版本、修改 registry 的动作必须遵循：
  - 先展示影响范围
  - 用户确认
  - 执行
  - 执行后验证
  - 输出结构化总结
- 所有清理功能默认只处理确定性路径。
- 模糊残留只能列为候选项，由用户确认后删除。

## 启动体验

脚本启动后，先显示“当前环境摘要”，再进入主菜单。

默认展示项：

- `node` 路径
- `npm` 路径
- `node` 版本
- `npm` 版本
- `nvm` 是否已加载
- 当前使用的 Node 版本
- 默认 Node 版本
- `npm global prefix`
- `npm global root`
- 当前 registry
- 当前 Node 是否由 `nvm` 管理

要求：

- 缺失项不得导致脚本中断。
- 缺失项显示为 `<unavailable>`、`<not-loaded>`、`<none>` 等明确状态。
- 摘要控制在一屏内。
- 回到顶层菜单时可刷新摘要。

## 顶层菜单

脚本提供五个主入口：

1. 安装项目
2. 卸载项目
3. 更新与升级
4. 源管理
5. 环境与依赖
q. 退出

只有顶层菜单可以退出。
所有子菜单都必须支持返回上一级。

## 功能范围

### 安装项目

管理当前 Node 版本下的 `npm` 全局包安装。

包括：

- 单独安装 `global package`
- 批量安装内置清单
- 显示当前 Node 版本和 `npm global prefix`
- 失败重试
- 安装后验证包是否存在
- 安装后提取 `bin` 命令
- 输出安装结果

批量安装约束：

- 第一版默认串行安装
- 并行安装不是第一版硬要求
- 如果保留并行结构，必须作为高级选项并明确风险

### 卸载项目

只做 `global package` 卸载，不区分 formula / cask。

包括：

- 扫描已安装全局包
- 展示包名、版本、安装路径
- 支持多选
- 卸载前读取 `package.json`
- 卸载前提取 `bin`
- 卸载前扫描全局 `bin` 入口
- 估算包目录体积
- 执行 `npm uninstall -g`
- 卸载后检查包目录与 `bin` 是否仍存在
- 输出卸载总结

保护包约束：

- 默认不允许普通卸载 `npm`
- 默认不允许普通卸载 `corepack`

### 更新与升级

管理当前 Node 版本下已安装全局包的升级。

包括：

- 扫描 `npm outdated -g --json`
- 展示当前版本、目标版本、latest 版本
- 多选升级
- 指定包升级到 `latest`
- 升级后验证版本
- 输出升级总结

### 源管理

npm 没有 Homebrew `tap`，这一层正式替换为源管理。

包括：

- 查看当前 registry
- 查看用户级 `.npmrc`
- 查看项目级 `.npmrc`
- 查看 `scope registry`
- 切换官方源 / `npmmirror` / 自定义 registry
- 添加 / 删除 / 查看指定 `scope registry`

### 环境与依赖

管理 `nvm`、Node 版本与本地缓存。

包括：

- 环境总览
- 安装 `nvm`
- 安装 Node.js 版本
- 更改全局 Node 版本
- 清理 npm 环境

第一版不强制实现但后续会需要：

- 卸载 Node.js 版本
- 指定项目 Node 版本
- 清理全局 `bin` 孤儿软链接
- 清理 `nvm` 旧版本残留

## `nvm` 安装规则

必须使用官方安装脚本。

安装完成后：

- 在当前脚本进程内加载 `nvm.sh`
- 验证 `command -v nvm`
- 提示用户新开终端或手动 `source` shell 配置

不能把 `source ~/.zshrc` 当成唯一生效方式。

## 清理规则

第一版清理要保守，不要做大范围删除。

允许的优先项：

- `npm cache verify`
- `npm cache clean --force`
- `node-gyp` 缓存扫描
- npm cache 路径扫描

关键约束：

- npm cache 路径不能写死成 `~/.npm`
- 必须先通过 `npm config get cache` 获取实际 cache 路径

## 测试期望

实现时至少需要具备：

- shell 级解析与流程测试
- 对 `npm outdated`、全局包列表、registry 输出等解析逻辑的夹具测试
- 关键只读函数的稳定性验证
- 对关键危险动作的前置校验与后置验证

## 工程质量要求

实现 agent 必须把下面这些要求当成硬约束，而不是建议：

- 优先做结构化设计，再做功能堆砌。
- 优先新增小而清晰的辅助函数，不要在一个超长函数里堆菜单、状态采集、执行逻辑和输出逻辑。
- 能放在只读信息收集层的逻辑，不要混进执行层。
- 能放在单一动作函数里的逻辑，不要散落到多个菜单分支里重复实现。
- 如果某个功能第一版做不稳，应明确后置，而不是塞一个半成品入口。
- 如果某个实现会明显扩大修改半径，应回退到更小、更可控的设计。
- 不允许以牺牲长期维护性为代价换取短期“可以跑”。
- 不允许静默吞掉关键失败；失败必须可见、可定位、可验证。

建议把 shell 测试与夹具放在 `scripts/node/tests/` 下。

## 第一版交付标准

满足以下条件即可认为第一版可交付：

- 启动摘要可用
- 主菜单与子菜单完整
- 环境总览可用
- 单包安装可用
- 批量安装可用
- 全局包清单读取可用
- 升级扫描与升级执行可用
- registry 查看与切换可用
- `scope registry` 管理可用
- `nvm` 安装可用
- Node 版本安装与切换可用
- 基础卸载扫描与卸载可用
- 基础清理入口可用

## 参考文档

- 需求草稿：[`scripts/node/docs/drafts/2026-06-11-node-npm-global-manager-requirements.md`](</Users/dylanwang/Repo/Products/Apps/Cellar/scripts/node/docs/drafts/2026-06-11-node-npm-global-manager-requirements.md>)
- 交接说明：[`scripts/node/docs/handoffs/2026-06-11-node-npm-global-manager-agent-handoff.md`](</Users/dylanwang/Repo/Products/Apps/Cellar/scripts/node/docs/handoffs/2026-06-11-node-npm-global-manager-agent-handoff.md>)
