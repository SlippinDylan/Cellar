# Homebrew 虚拟机测试流程

## 脚本功能树

```text
Homebrew 管理脚本
├── 安装项目
│   ├── 批量安装内置 cask 清单
│   ├── 串行安装
│   ├── 并行安装
│   ├── 失败重试
│   └── 安装结果汇总
├── 卸载项目
│   ├── Formula 卸载
│   │   ├── 扫描直接依赖
│   │   ├── 规划可一并移除的孤儿依赖
│   │   ├── 停止相关 services
│   │   ├── 卸载主 formula
│   │   ├── 按计划卸载孤儿依赖
│   │   └── 执行 brew autoremove
│   └── Cask 卸载
│       ├── 读取 cask 元数据
│       ├── 降级读取 INSTALL_RECEIPT.json
│       ├── 扫描本地残留候选项
│       ├── 执行 brew uninstall --zap
│       ├── 失败时停止深删
│       ├── 可选 sudo 删除残留
│       └── 输出卸载总结
├── 更新与升级
│   ├── brew update
│   ├── 扫描可升级 formula
│   ├── 扫描可升级 cask
│   ├── 批量选择升级目标
│   ├── brew upgrade
│   └── 输出升级总结
├── Tap 管理
│   ├── 添加 tap
│   ├── 枚举已安装 tap
│   ├── 扫描 tap 关联的 formula / cask
│   ├── 关联项目未清空时阻止 untap
│   └── 删除 tap
└── 环境与依赖
    ├── 安装 Xcode Command Line Tools
    ├── 安装 Homebrew
    │   ├── 下载官方安装脚本
    │   ├── 初始化当前 shell 的 shellenv
    │   ├── 可选写入 ~/.zprofile
    │   └── 输出安装总结
    └── 清理 Homebrew 环境
        ├── brew cleanup --prune=all
        ├── brew cleanup
        ├── brew autoremove
        ├── brew services cleanup
        ├── 清理本地 cache / log / tmp 候选路径
        ├── 可选 sudo 删除权限受限路径
        └── 输出清理统计与命令状态
```

## 目标

这份流程用于在一台干净的 macOS 虚拟机里验证 `scripts/homebrew/brew-app-manager.sh` 与 `scripts/homebrew/brew-app-manager-paged.sh` 的核心能力，重点覆盖：

- `formula` 卸载
- `formula` 依赖规划
- `cask` 卸载与残留清理
- `tap -> install -> uninstall -> untap`
- `cleanup`

不覆盖：

- Xcode Command Line Tools 安装
- Homebrew 本体安装

## 测试原则

- 虚拟机内先完成 Homebrew 与 Xcode Command Line Tools 的基础准备。
- 测试样本尽量小，避免大体积下载。
- `formula` 安装样本优先用原生 `brew` 预装，再用脚本验证卸载、依赖处理、清理逻辑。
- `cask` 选择轻量 GUI 应用，重点观察 `brew uninstall --zap`、本地残留扫描、权限提示与总结输出。
- 每一大步开始前建议创建虚拟机快照。

## 推荐样本

### Formula

- `dos2unix`
  作用：无依赖样本，验证最基础的安装/卸载。
- `ripgrep`
  作用：依赖 `pcre2`，验证共享依赖不应被误删。
- `jq`
  作用：依赖 `oniguruma`，验证新引入孤儿依赖可随主包一起回收。
- `wget`
  作用：依赖更多，验证更复杂的依赖链。

### Cask

- `hiddenbar`
- `keepingyouawake`
- `itsycal`
- `maccy`
  说明：`maccy` 需要较新的 macOS 版本；如果虚拟机系统版本不满足，就跳过。

### Tap

- `farion1231/ccswitch`
- `cc-switch`

这组适合验证：

- 新增 tap
- 通过该 tap 安装 cask
- 卸载该 cask
- 删除该 tap

## 环境准备

先确认 Homebrew 可用：

```bash
brew --version
brew doctor
```

记录初始状态：

```bash
brew list --formula
brew list --cask
brew tap
```

建议此时创建一个虚拟机快照：

- `snapshot-1-homebrew-ready`

## 预装测试样本

### 安装 formula

```bash
brew install dos2unix ripgrep jq wget
```

预期：

- `dos2unix` 安装成功。
- `ripgrep` 安装成功，并带上 `pcre2`。
- `jq` 安装成功，并带上 `oniguruma`。
- `wget` 安装成功，并带上 `libidn2`、`openssl@3`、`gettext`、`libunistring` 等依赖。

### 安装 cask

```bash
brew install --cask hiddenbar keepingyouawake itsycal
brew install --cask maccy
```

如果 `maccy` 因系统版本不满足失败，直接跳过，不影响其余测试。

### 安装 tap 样本

```bash
brew tap farion1231/ccswitch
brew install --cask cc-switch
```

建议此时创建第二个快照：

- `snapshot-2-test-samples-installed`

## 脚本测试入口

如果测试分页交互版：

```bash
bash scripts/homebrew/brew-app-manager-paged.sh
```

如果测试原版：

```bash
bash scripts/homebrew/brew-app-manager.sh
```

下文默认以分页版脚本为例。

## 测试项 1：Formula 卸载

### 1.1 卸载无依赖 formula

目标：

- `dos2unix`

操作：

1. 进入 `卸载项目 -> Formula`
2. 选择 `dos2unix`
3. 确认卸载

预期：

- 卸载计划里没有孤儿依赖，或孤儿依赖为空。
- 卸载总结显示主包已移除。
- `brew list --formula | grep -Fx dos2unix` 无输出。

### 1.2 卸载依赖共享已有库的 formula

目标：

- `ripgrep`

操作：

1. 进入 `卸载项目 -> Formula`
2. 选择 `ripgrep`
3. 确认卸载

预期：

- `ripgrep` 被卸载。
- 如果 `pcre2` 仍被其他包需要，脚本不应把它当作孤儿删除。
- `brew list --formula | grep -Fx pcre2` 仍应存在。

### 1.3 卸载会留下新孤儿依赖的 formula

目标：

- `jq`

操作：

1. 进入 `卸载项目 -> Formula`
2. 选择 `jq`
3. 观察扫描结果与孤儿依赖列表
4. 确认卸载

预期：

- 脚本能识别 `oniguruma` 是否成为孤儿。
- 如果 `oniguruma` 仅因 `jq` 引入且无其他使用者，应被一起清掉。
- `brew list --formula | grep -Fx jq` 无输出。
- `brew list --formula | grep -Fx oniguruma` 也应无输出。

### 1.4 卸载依赖链更复杂的 formula

目标：

- `wget`

操作：

1. 进入 `卸载项目 -> Formula`
2. 选择 `wget`
3. 观察脚本输出的依赖规划
4. 确认卸载

预期：

- 若某些依赖仍被其他包使用，不应被误删。
- 若某些依赖是本次测试独占引入且已成孤儿，可被一并移除。

## 测试项 2：Cask 卸载与残留清理

### 2.1 单个轻量 cask

目标：

- `hiddenbar`

操作：

1. 进入 `卸载项目 -> Cask`
2. 选择 `hiddenbar`
3. 查看扫描结果
4. 确认卸载

预期：

- 脚本能列出候选残留路径。
- 卸载总结中能看到 `Homebrew 卸载状态`、候选项数量、删除结果。
- `brew list --cask | grep -Fx hiddenbar` 无输出。

### 2.2 菜单栏类 cask

目标：

- `keepingyouawake`
- `itsycal`

操作：

1. 重复上面的卸载流程。
2. 观察是否出现 `~/Library` 下的偏好、缓存、容器、日志等候选路径。

预期：

- 脚本扫描结果应可读。
- 若遇到权限路径，应提示是否 `sudo` 继续。
- 总结中删除成功、提权删除、权限跳过、其他失败数量应合理。

### 2.3 带系统版本差异的 cask

目标：

- `maccy`

说明：

- 如果虚拟机系统版本不支持，跳过此项。
- 如果安装成功，再按普通 cask 卸载流程测试。

## 测试项 3：Tap 生命周期

目标：

- `farion1231/ccswitch`
- `cc-switch`

### 3.1 验证 tap 已存在时的关联扫描

操作：

1. 进入 `Tap 管理 -> 删除 Tap`
2. 选择 `farion1231/ccswitch`

预期：

- 脚本不应直接 untap。
- 应先扫描并列出仍安装的关联项目，例如 `cc-switch [cask]`。

### 3.2 先卸载 tap 关联 cask

操作：

1. 按脚本提示先处理关联项目。
2. 卸载 `cc-switch`

预期：

- `cc-switch` 卸载完成后，不应再留在 tap 关联项目列表中。

### 3.3 删除 tap

操作：

1. 返回 `Tap 管理 -> 删除 Tap`
2. 再次选择 `farion1231/ccswitch`
3. 确认 untap

预期：

- 关联项目为空后，脚本才允许继续 untap。
- `brew tap | grep -Fx farion1231/ccswitch` 无输出。

## 测试项 4：Cleanup

操作：

1. 进入 `环境与依赖 -> 清理 Homebrew 环境`
2. 确认执行

预期：

- 页面展示清理计划。
- 总结页显示：
  - 清理前空间
  - 清理后空间
  - 本地路径统计释放空间
  - Homebrew 命令执行状态
  - 普通删除 / 提权删除 / 权限跳过 / 失败数量
- 若某步失败，应有明确警告，而不是静默吞掉。

## 测试后验证

执行：

```bash
brew list --formula
brew list --cask
brew tap
```

重点检查：

- `dos2unix`、`ripgrep`、`jq`、`wget` 是否已按预期卸载。
- `hiddenbar`、`keepingyouawake`、`itsycal`、`maccy`、`cc-switch` 是否已按预期卸载。
- `farion1231/ccswitch` 是否已按预期删除。
- 共享依赖没有被误删。
- 本次测试独占引入的孤儿依赖已被回收。

## 失败回滚建议

如果某一轮测试把状态搞乱了，直接回滚到虚拟机快照，不要在污染状态上继续追。

推荐快照点：

- `snapshot-1-homebrew-ready`
- `snapshot-2-test-samples-installed`

## 建议记录

每次执行后建议保存这些信息：

- 脚本版本
- 虚拟机 macOS 版本
- Homebrew 版本
- 本轮选择的测试样本
- 实际输出截图
- 与预期不一致的点

这样后面回归时，能快速对比是不是交互层、依赖规划、残留扫描或权限逻辑出了回归。
