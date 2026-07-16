# Node / npm 全局环境管理脚本未决问题

日期：2026-06-11
状态：Open but non-blocking if defaults are accepted
相关规格：[`2026-06-11-node-npm-global-manager-spec.md`](</Users/dylanwang/Repo/Products/Apps/Cellar/scripts/node/docs/specs/2026-06-11-node-npm-global-manager-spec.md>)

## 使用方式

这份文档列的是“实现前最好确认”的问题。
如果实现 agent 需要尽快开工，可以直接采用每项后面的“推荐默认值”。

## 1. 内置批量安装清单放哪些 global package

问题：

- 第一版的 `INSTALLABLE_GLOBAL_PACKAGES` 到底包含哪些包
- 是否按类别分组

推荐默认值：

- 第一版先放空数组，保留结构，不内置任何真实包
- 等你后续给出个人常用清单后再补

原因：

- 结构先落地更重要
- 避免实现 agent 替你猜测个人工具偏好

## 2. 保护包列表是否只包含 `npm` 和 `corepack`

问题：

- 是否还要保护 `npx`
- 是否还要保护其他你常用的基础 CLI

推荐默认值：

- 第一版只保护 `npm` 和 `corepack`

原因：

- 这是最低安全基线
- 其余工具是否应保护具有明显个人偏好色彩

## 3. 第一版源管理是否开放全部写操作

问题：

- 第一版是否允许完整执行：
  - `npm config set registry`
  - `npm config set @scope:registry`
  - `npm config delete @scope:registry`

推荐默认值：

- 第一版允许这些写操作
- 但必须逐步确认，并在写入后验证读取结果

原因：

- 这是“源管理”存在的核心价值
- 只读模式对第一版来说过于保守

## 4. 清理 cache 时是否允许直接删除 cache 目录

问题：

- 除了 `npm cache clean --force`，是否允许脚本直接删除 cache 路径

推荐默认值：

- 第一版优先执行 `npm cache verify` 和 `npm cache clean --force`
- 直接删除目录仅作为候选动作，不作为默认动作

原因：

- 更接近 npm 自身的支持路径
- 误删风险更低

## 5. `指定项目 Node 版本` 是否进入第一版

问题：

- 这个功能是否要提前到第一版

推荐默认值：

- 后置到第二阶段

原因：

- 第一版重点应放在全局环境管理
- 这个功能涉及项目路径输入、`.nvmrc` 写入、`engines.node` 读取，复杂度偏高

## 6. 第一版是否实现并行安装

问题：

- 批量安装是否要支持并行

推荐默认值：

- 第一版不实现并行安装
- 最多保留一个未启用的结构位

原因：

- npm 全局安装并行收益有限
- 失败排查和环境竞争问题更复杂

## 7. Node 版本卸载是否纳入第一版

问题：

- 是否在第一版就支持 `nvm uninstall`

推荐默认值：

- 不纳入第一版

原因：

- 这属于高风险破坏性动作
- 先把安装、切换、扫描和提示做稳更合理

## 8. Shell 兼容范围是否只做 zsh

问题：

- 第一版是否只针对 macOS 默认 `zsh`
- 还是同时兼容 `bash`

推荐默认值：

- 第一版优先兼容 `zsh`
- 代码中保留 `bash` 检测分支，但不承诺全面验证

原因：

- 你的主要使用场景已经明确是 macOS 默认 shell

## 当前结论

如果没有新的明确指示，实现 agent 可以直接采用上述推荐默认值继续开发，不需要阻塞。
