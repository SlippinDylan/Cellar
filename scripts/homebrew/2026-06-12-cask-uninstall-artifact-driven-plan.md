# Cask 卸载能力升级方案

## 目标

把当前 `cask` 卸载从“模糊路径扫描 + 通用残留删除”升级为“基于 Homebrew 安装元数据和 artifact 类型的结构化卸载与校验”。

这份方案的目标不是给 `wireshark-app` 打补丁，而是建立一套对复杂 `cask` 同样成立的通用模型。

重点解决：

- `brew uninstall --zap` 成功后，脚本如何按实际 artifact 做残留校验
- `brew uninstall --zap` 失败后，脚本如何 fail-closed，不做错误深删
- `binary` / `manpage` / `launchctl` / `pkgutil` 这类当前扫描不到的项目，如何按类型处理
- 模糊扫描如何退化为 fallback，而不是主流程

## 当前问题

当前脚本对 `cask` 卸载的主流程是：

1. 读取部分 cask 元数据
2. 扫描 app 本体和常见用户目录残留
3. 执行 `brew uninstall --zap`
4. 再删除扫描到的路径

这个模型对普通 `app` 类 cask 够用，但对复杂 cask 不够：

- `wireshark-app` 这种 cask 还会安装：
  - `binary` 链接
  - `manpage` 链接
  - `launchctl` 组件
  - `pkgutil` receipt
  - `early_script`
- 当前脚本的候选列表没有把这些结构化 artifact 单独列出来
- 结果是：
  - 如果 `brew uninstall --zap` 成功，用户看不到完整清理范围
  - 如果 `brew uninstall --zap` 失败，脚本自己的深删也不能代替 Homebrew 完整卸载

## 设计原则

- 先读结构化元数据，再决定怎么删
- 不模拟 Homebrew 自己的 uninstall 逻辑
- 对高风险 artifact，优先“校验 + 报告”，而不是直接自己删
- 元数据缺失时才退化到模糊扫描
- 所有复杂 cask 统一走同一模型，不做单个 cask 特判

## 数据来源

### 一级来源

- `brew info --cask --json=v2 <cask>`
- `INSTALL_RECEIPT.json`

### 二级来源

- `Caskroom/<cask>/...`
- App bundle 本体
- Homebrew prefix 下符号链接和 manpage 链接

### 三级来源

- 按 `bundle_id` / `app_name` 做模糊路径扫描

这个顺序不能反过来。

## artifact 模型

建议把 `cask` 卸载涉及的对象统一抽象成 artifact 记录：

```text
type
source
installed_path
expected_removal_owner
risk_level
post_uninstall_check_mode
```

### 建议支持的 artifact 类型

- `app`
- `binary`
- `manpage`
- `zap_trash`
- `pkg`
- `launchctl`
- `early_script`
- `caskroom`
- `fallback_path`

## 每种 artifact 的处理策略

### `app`

来源：

- `uninstall_artifacts.app`
- `brew info --json=v2` 的 app artifact

处理：

- 主要由 `brew uninstall --zap` 处理
- 卸载后校验 app 本体是否仍存在
- 若仍存在，可纳入手工残留候选

### `binary`

来源：

- `uninstall_artifacts.binary`

处理：

- 不自己推导命令名，直接按 artifact 记录解析目标
- 卸载后检查 `/opt/homebrew/bin/...` 链接是否仍存在
- 若仍存在：
  - 先确认是否仍指向该 cask app
  - 只有明确指向当前 cask 时，才允许纳入残留候选

### `manpage`

来源：

- `uninstall_artifacts.manpage`

处理：

- 卸载后检查对应 manpage 链接是否仍在
- 若仍存在且明确指向当前 cask 内容，纳入残留报告

### `zap_trash`

来源：

- cask 元数据中的 `zap.trash`
- receipt 中可恢复出的 zap 路径

处理：

- 这是脚本当前最适合自己删的一类
- 可保留现有候选展示与可选提权删除逻辑

### `pkg`

来源：

- `uninstall_artifacts.uninstall.pkgutil`

处理：

- 不尝试自己删 pkg receipt 或反向执行 pkg uninstall
- 卸载后只做校验和报告：
  - `pkgutil --pkgs | grep ...`
- 报告为：
  - 已清除
  - 仍残留
  - 需人工处理

### `launchctl`

来源：

- `uninstall_artifacts.uninstall.launchctl`

处理：

- 不默认由脚本自己直接 `bootout`
- 依赖 `brew uninstall --zap` 处理
- 卸载后做状态校验：
  - plist 文件是否存在
  - 对应服务标签是否仍可见

### `early_script`

来源：

- `uninstall_artifacts.uninstall.early_script`

处理：

- 绝不自己重放
- 只在总结里明确说明：
  - 该 cask 含有 Homebrew uninstall script
  - 是否成功依赖 `brew uninstall --zap` 执行

### `caskroom`

来源：

- `brew --prefix` + `Caskroom/<cask>`

处理：

- 保留当前逻辑
- 作为补充清理对象，不作为主逻辑依据

### `fallback_path`

来源：

- bundle id
- app name
- 目录规则扫描

处理：

- 仅在结构化元数据不足时使用
- 在结果页中明确标记：
  - 结构化 artifact
  - fallback 路径

## 新的卸载执行顺序

建议改成下面这条链路：

1. 读取 cask 结构化元数据
2. 构建 artifact 清单
3. 根据 artifact 清单展示“预计处理范围”
4. 用户确认
5. 执行 `brew uninstall --zap`
6. 若失败，停止脚本侧深删
7. 若成功，进入 post-uninstall 校验
8. 对允许脚本处理的残留类型执行删除
9. 输出按 artifact 分类的总结

## 结果页结构建议

不要只打印一个“候选项列表”，建议拆成几组：

### Homebrew 负责卸载的 artifact

- app
- binary
- manpage
- launchctl
- pkgutil
- uninstall script

### 脚本负责补充清理的路径

- zap 路径
- fallback 路径
- Caskroom 残留

### 卸载后校验结果

- 已清除 artifact
- 仍残留 artifact
- 需要人工处理 artifact
- 因权限跳过的 artifact

## fail-closed 边界

以下情况必须停止脚本侧深删，只做报告：

- `brew uninstall --zap` 失败
- 结构化 artifact 里含 `pkgutil` / `launchctl` / `early_script`，且 Homebrew 卸载失败
- receipt 元数据明显不完整，无法判断关键 artifact

不要在这些场景下靠模糊扫描继续“尽量删一点”。

## 分阶段实施

### 第 1 阶段

目标：

- 先把 `INSTALL_RECEIPT.json` 里的 `binary`、`manpage`、`launchctl`、`pkgutil` 解析出来
- 只做展示和卸载后校验

不做：

- 对 `pkgutil`
- 对 `launchctl`
- 对 `early_script`

执行任何脚本侧自动删除

### 第 2 阶段

目标：

- 把 `binary`、`manpage` 的残留校验结果接入总结页
- 若 Homebrew 卸载成功但对应链接仍残留，允许脚本在“明确指向当前 cask”前提下补删

### 第 3 阶段

目标：

- 给候选项区分来源标签：
  - `artifact:binary`
  - `artifact:manpage`
  - `artifact:app`
  - `fallback`

### 第 4 阶段

目标：

- 把 `pkgutil` / `launchctl` 的状态检查纳入总结
- 形成“自动已处理 / 需人工处理”的完整输出

## 测试策略

### 必测普通 cask

- 只有 `.app` 和 `zap` 残留的轻量 cask

目的：

- 确认普通 case 不被复杂模型带坏

### 必测复杂 cask

- `wireshark-app`

目的：

- 覆盖：
  - `binary`
  - `manpage`
  - `launchctl`
  - `pkgutil`
  - `early_script`

### 必测失败路径

- `brew uninstall --zap` 失败时：
  - 不应继续深删复杂 artifact
  - 只允许保守报告

## 这次方案的核心收益

- 不再依赖“猜这个 cask 安装了什么”
- 不再把复杂 cask 误当普通 app 类 cask 处理
- 不需要给 `wireshark-app` 写专门特判
- 用户能看到“Homebrew 负责什么，脚本补什么，剩下什么要人工处理”

这才是长期稳定、边界清晰的 cask 卸载设计。
