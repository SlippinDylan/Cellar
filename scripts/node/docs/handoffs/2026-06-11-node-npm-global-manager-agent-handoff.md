# Node / npm 全局环境管理脚本交接说明

日期：2026-06-11
用途：交给实现 agent 的开工说明
目标脚本：`scripts/node/npm-global-manager.sh`
参考脚本：`scripts/homebrew/brew-app-manager.sh`
需求文档：`scripts/node/docs/drafts/2026-06-11-node-npm-global-manager-requirements.md`

## 1. 任务目标

实现一个运行在 macOS 终端中的交互式 shell 脚本，专门管理：

- `nvm`
- `Node.js`
- `npm` 全局包
- `npm` 源配置

这个脚本不是项目级依赖管理工具，不处理：

- 当前仓库或任意项目内的 `package.json` 依赖安装
- `npm install` 项目依赖
- `pnpm` / `yarn` / `bun`
- Homebrew 安装 Node.js

Node.js 本体必须统一走 `nvm` 管理。

## 2. 必须先看的本地文件

实现前必须先完整阅读：

- [`scripts/node/docs/drafts/2026-06-11-node-npm-global-manager-requirements.md`](</Users/dylanwang/Repo/Products/Apps/Cellar/scripts/node/docs/drafts/2026-06-11-node-npm-global-manager-requirements.md>)
- [`scripts/homebrew/brew-app-manager.sh`](</Users/dylanwang/Repo/Products/Apps/Cellar/scripts/homebrew/brew-app-manager.sh>)

阅读 `brew-app-manager.sh` 的目的不是复制业务逻辑，而是复用这些设计思路：

- 顶层菜单 + 子菜单
- 统一的标题页
- 先扫描再确认
- 多选输入
- 状态摘要
- 结果总结页
- 输入无效时的停顿与回退

不要照搬 Homebrew 的数据模型：

- 不要做 formula / cask / tap
- npm 没有 tap
- npm 对应的是 registry / scope registry / global packages / nvm-managed Node versions

## 3. 已经定死的产品边界

以下内容已经确认，不要再发散：

- 脚本运行环境是 macOS 本地交互式终端。
- Node.js 安装方式固定为 `nvm` 官方脚本，不走 Homebrew。
- `nvm` 的检测方式使用 `command -v nvm`，不要使用 `which nvm`。
- 脚本启动后，先显示当前 Node / npm 环境摘要，再进入主菜单。
- “Tap 管理”不做，正式替换成“源管理”。
- 交付必须可持续、长期稳定、可维护，不能为了“先跑起来”牺牲结构质量。
- 不允许为了过测试、过语法检查、过执行路径而打补丁式修复。
- 不允许扩散爆炸半径；如果一个任务本应只影响一个子模块，就不要顺手改动其他无关分支。
- 不允许“哪里出问题就往哪里糊一层”的面条式实现；要通过清晰边界和明确职责解决问题。
- 所有只读展示功能不得修改环境。
- 所有删除、卸载、覆盖、切换默认版本、修改 registry 的动作都必须：
  - 先展示影响范围
  - 用户确认
  - 执行
  - 执行后验证
  - 输出结构化总结
- 所有清理功能默认只处理确定性路径。
- 模糊残留只能列为候选项，由用户确认后删除。

## 4. 启动页要求

脚本一启动，先渲染“当前环境摘要”，再显示主菜单。

建议默认展示：

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

- 缺失项不能导致脚本中断。
- 缺失项显示成 `<unavailable>`、`<not-loaded>`、`<none>` 之类。
- 摘要要控制在一屏内。
- 顶层菜单返回时可以刷新摘要。

## 5. 第一版建议实现范围

第一版只要求把交互骨架和确定性流程跑通，不要求一次做完所有深清理。

第一版优先实现：

- 启动摘要
- 主菜单
- 环境总览
- 单包安装
- 批量安装
- 全局包列表扫描
- 卸载 global package 的扫描与基础执行
- 可升级包扫描
- 批量升级
- registry 只读查看
- registry 切换
- `scope registry` 查看 / 添加 / 删除
- 安装 `nvm`
- 安装 Node.js 版本
- 切换当前 / 默认 Node 版本

第一版可以暂缓：

- 并行安装
- 卸载 Node.js 版本
- 指定项目 Node 版本
- 全局 bin 孤儿软链接清理
- nvm 旧版本残留清理
- 深度残留候选项清理

## 6. 第一版推荐菜单结构

建议与需求文档保持一致：

1. 安装项目
2. 卸载项目
3. 更新与升级
4. 源管理
5. 环境与依赖
q. 退出

建议再细化为：

`安装项目`

1. 单独安装 global package
2. 批量安装内置清单
b. 返回

`卸载项目`

1. 卸载 global package
b. 返回

`更新与升级`

1. 扫描并升级已安装 global package
2. 指定包升级到 latest
b. 返回

`源管理`

1. 查看源配置
2. 切换 registry
3. 管理 scope registry
b. 返回

`环境与依赖`

1. 环境总览
2. 安装 nvm
3. 安装 Node.js 版本
4. 更改全局 Node 版本
5. 清理 npm 环境
b. 返回

## 7. 批量安装的实现约束

这部分不要做得太激进。

已经确认：

- 第一版默认串行安装。
- 并行安装不是第一版硬要求。
- 如果保留并行相关结构，也必须明确它是高级选项，默认关闭。

批量安装清单建议采用类似 Homebrew 的固定数组，例如：

- `INSTALLABLE_GLOBAL_PACKAGES=( ... )`

建议第一版支持：

- 展示内置清单
- 检查哪些已安装
- 允许跳过已安装项
- 逐包安装
- 失败重试
- 每包日志
- 最终汇总

## 8. 卸载 global package 的实现约束

必须先扫描，再确认，再卸载。

扫描建议至少包含：

- 包名
- 当前版本
- 安装目录
- `package.json`
- `bin` 字段
- global bin 目录中的相关入口
- 目录体积

确认后执行：

- `npm uninstall -g <package>`

卸载后验证：

- 包是否还在全局包列表中
- 包目录是否仍存在
- `bin` 命令或入口是否仍存在

保护包机制必须做：

- 默认不允许普通卸载 `npm`
- 默认不允许普通卸载 `corepack`

如果需要扩展保护列表，必须集中定义，不要散落在流程里。

## 9. npm 源管理的实现约束

npm 没有 Homebrew tap，对应的是源配置。

源管理必须聚焦：

- 当前 registry
- 用户级 `.npmrc`
- 项目级 `.npmrc`
- `scope registry`

建议使用的命令：

- `npm config get registry`
- `npm config set registry <url>`
- `npm config delete registry`
- `npm config get @scope:registry`
- `npm config set @scope:registry <url>`
- `npm config delete @scope:registry`
- `npm config list -l`

第一版不要做花哨的“来源推理系统”，先把配置管理做稳。

## 10. nvm / Node 环境管理的实现约束

### 安装 nvm

安装路径已经指定：

- 使用官方 install.sh

注意：

- 在脚本里直接 `source ~/.zshrc` 不可靠，不能把它当成唯一生效路径。
- 安装完成后，应在当前脚本进程内加载：

```sh
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
```

然后：

- 验证 `command -v nvm`
- 提示用户新开终端或手动 `source` shell 配置

### 安装 Node.js 版本

第一版建议支持两条路径：

- 安装 LTS
- 安装指定版本

建议用：

- `nvm install --lts`
- `nvm install <version>`
- `nvm use <version>`
- `nvm alias default <version>`

### 切换当前 / 默认 Node 版本

要能区分：

- 当前 shell 正在使用的版本
- 默认版本 alias

切换后必须验证：

- `node -v`
- 必要时也验证 `npm -v`

## 11. 清理功能的实现约束

第一版只做保守清理，不做大爆炸清理。

建议优先做：

- `npm cache verify`
- `npm cache clean --force`
- `node-gyp` 缓存扫描
- npm cache 路径扫描

注意：

- npm 用户缓存路径不能写死成 `~/.npm`
- 必须先用 `npm config get cache` 获取实际 cache 路径

`清理 npm 用户缓存目录` 的正确要求：

- 通过 `npm config get cache` 获取实际 cache 路径
- 检测 cache 路径是否存在
- 估算目录体积
- 用户确认后清理 cache 路径
- 输出清理结果

## 12. 风险点和已知坑

实现时要注意这些坑：

### 1. `nvm` 不是普通二进制

- `nvm` 常常是 shell function
- 不能假设 `which nvm` 可用
- 子 shell / 非交互 shell 中的加载行为要单独处理

### 2. npm 全局包安装位置依赖当前 Node 版本

- 当前 `node` / `npm` 所属版本不对，装包就会落到错误环境里
- 所以启动摘要和安装前展示当前版本是刚需

### 3. `npm outdated -g --json` 依赖网络

- 网络慢、registry 异常、认证问题都会影响结果
- 扫描失败时必须给出明确提示，不能假装“没有可升级项”

### 4. npm cache 路径不一定是 `~/.npm`

- 必须动态读取

### 5. 并行安装收益有限，失败排查成本高

- 第一版不要强做

### 6. 父 shell 环境不会自动被子脚本永久修改

- 安装 `nvm`、切换版本、`source` 配置，这些都要分清“当前脚本进程生效”和“用户终端永久生效”

## 13. 建议的内部实现模块

虽然最终交付可以是单脚本，但内部最好按职责分函数。

建议至少拆成这些函数层次：

- 菜单渲染
- 输入解析
- 状态摘要渲染
- nvm 加载与检查
- Node / npm 环境信息收集
- npm 全局包清单收集
- 单包安装
- 批量安装
- 包升级扫描
- 包升级执行
- 包卸载扫描
- 包卸载执行
- registry 信息读取
- registry 修改
- scope registry 管理
- 清理扫描
- 清理执行
- 结果总结输出

## 13.1 代码质量红线

实现 agent 必须把下面这些点当成红线：

- 不要为了省事把状态采集、菜单输入、业务执行、结果渲染揉成一个超长函数。
- 不要复制粘贴相近流程再做微调，应该抽成共享 helper。
- 不要把新的环境逻辑偷偷塞进已有只读函数里。
- 不要通过吞错、硬编码兜底、静默跳过来伪造“脚本可用”。
- 如果实现过程中发现设计明显不稳，应先收紧边界，再继续写代码。

## 14. 当前仍未完全定死的问题

这些点如果实现 agent 觉得会影响落地，应该先问，不要自己拍脑袋：

### A. 内置批量安装清单放什么包

目前需求只确定“要有固定清单”，但没有最终包列表。

待确认：

- 你想内置哪些 global package
- 是否需要分组
- 是否允许从配置文件读取而不是写死在脚本里

### B. 保护包列表是否只包含 `npm` / `corepack`

目前最低要求是：

- `npm`
- `corepack`

待确认：

- 是否还要保护 `npx`
- 是否还要保护某些你常用的基础 CLI

### C. 第一版的“源管理”是否允许直接写配置

当前建议是：

- 可以做只读查看
- 可以做 registry 切换
- 可以做 scope registry 增删改

但如果你想让第一版更稳，也可以先只做只读 + 官方源 / 镜像源切换。

### D. 清理功能是否允许直接删除 cache 目录

虽然需求允许这么做，但实现时最好确认：

- 你是否更倾向优先使用 `npm cache clean --force`
- 是否要把“删除目录”降级为候选动作而不是默认动作

### E. 指定项目 Node 版本要不要纳入第一版

需求文档里有，但第一版建议后置。

如果要提前做，需要进一步确认：

- 只写 `.nvmrc` 就够不够
- 是否要同时读取 / 展示 `package.json` 的 `engines.node`

## 15. 若无新增澄清，推荐的开工顺序

建议 agent 按这个顺序做：

1. 搭主菜单和启动摘要
2. 做环境信息采集和 `nvm` 加载封装
3. 做环境总览页
4. 做 npm 全局包清单读取
5. 做单包安装
6. 做批量安装
7. 做 registry 查看与切换
8. 做 scope registry 管理
9. 做可升级包扫描
10. 做批量升级
11. 做全局包卸载扫描与基础执行
12. 最后再补清理功能

## 16. 给实现 agent 的一句话总结

参考 `brew-app-manager.sh` 的交互壳，但不要复制 Homebrew 的业务模型。这个脚本的核心不是“管理前端项目”，而是“管理 nvm 模式下的 Node 版本、npm 全局包和 npm 源配置”，并且每个危险动作都必须是可扫描、可确认、可验证、可总结的。
