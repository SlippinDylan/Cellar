# npm-global-manager.sh 第三轮深度 Review

日期：2026-06-18
范围：`scripts/node/npm-global-manager.sh`、`scripts/node/tests/npm-global-manager-test.sh`、`scripts/node/run-quality-checks.sh`、`scripts/node/docs/specs/*`、`scripts/node/docs/drafts/*`
结论：这一轮相比第二轮收敛明显，当前约 87/100。主干功能已经比较完整，很多上一轮高风险项已修掉；但还没有稳定到 90+。剩余问题集中在锁所有权、少数交互分支真实崩溃、指定版本安装的后置验证、nvm 变更动作一致性、JSON/app 后端契约和默认 nvm installer 校验策略。

对照资料：

- npm package spec: https://docs.npmjs.com/cli/v11/using-npm/package-spec
- npm install: https://docs.npmjs.com/cli/v11/commands/npm-install/
- npm update: https://docs.npmjs.com/cli/v11/commands/npm-update/
- npm outdated: https://docs.npmjs.com/cli/v11/commands/npm-outdated/
- npm config: https://docs.npmjs.com/cli/v11/commands/npm-config/
- npmrc: https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/
- npm package name guidelines: https://docs.npmjs.com/package-name-guidelines/
- nvm README: https://github.com/nvm-sh/nvm

## 本轮已修复或明显改善

- 单包安装已经改用 `validate_package_spec`，支持 `package@version` / `package@tag`。
- latest 升级已经改用 `validate_package_name_only`，不再接受 version/tag spec。
- package name component 校验已拒绝大写、前导点、前导下划线、`node_modules`、`favicon.ico`。
- npm 变更命令在 `run_logged_command` 中统一到 `npm-mutation` 锁。
- runtime lock 增加 metadata、pid、stale pid 恢复和全局 trap。
- `sort -V` 已替换为 Ruby 版本排序 fallback。
- scope registry set 已返回 effective 状态。
- 源配置页 scope registry 重复输出已修。
- cache 目录直接删除使用 `npm-mutation` 锁。
- node-gyp 清理已先过滤存在目录并展示选择。
- JSON preflight 已按命令区分，`summary/status/logs` 不再硬依赖 npm/ruby。
- JSON uninstall execute 默认禁用，避免走比交互卸载更薄的危险路径。
- JSON update-latest 会对照 registry latest 验证。
- 版本已升到 `0.3.0`。
- `run-quality-checks.sh` 不再 silent skip shellcheck；缺少 shellcheck 时会执行 fallback static checks。

## 必须修的问题

### P0. runtime lock 释放没有所有权校验，且已释放的锁仍留在 HELD_RUNTIME_LOCKS

- 位置：`npm-global-manager.sh:62-119`、`1520-1561`
- 问题：`release_runtime_lock` 只按目录名删除 lock，不检查 `pid`/`metadata` 是否属于当前进程；`run_logged_command` 显式释放锁后，`HELD_RUNTIME_LOCKS` 仍保留该 lock name，进程退出时 trap 会再次释放。
- 真实风险：进程 A 执行一次 npm install 后释放 `npm-mutation`，随后进程 B 获取同名锁；进程 A 退出时 `release_all_runtime_locks` 可能删除进程 B 的锁。这个问题会破坏锁模型本身。
- 修复标准：释放锁前必须校验 lock owner 是 `$$`；显式释放后要从 `HELD_RUNTIME_LOCKS` 中移除；重复释放必须是 no-op，不能删除其他进程锁。

### P0. node-gyp 清理的返回/全选分支会崩溃或不可用

- 位置：`npm-global-manager.sh:372-455`、`4094-4168`
- 问题 1：`parse_multi_numeric_choice` 返回 `back`，但 `run_node_gyp_cache_cleanup` 检查的是旧值 `__BACK__`。
- 问题 2：界面提示 `a 全选`，解析器实际只支持 `all`。
- 证据：
  - `parse_multi_numeric_choice b 3` 输出 `back`。
  - `set -u; selected_index=back; i=$((selected_index - 1))` 会触发 `bash: back: unbound variable`。
  - `parse_multi_numeric_choice a 3` 输出 `invalid`。
- 用户影响：用户在 node-gyp 清理页面输入 `b` 返回，可能触发 Bash 算术展开错误；输入界面提示的 `a` 也无法全选。
- 修复标准：该分支和其它多选分支统一处理 `back/all/invalid`；提示文案与解析器一致；测试必须断言 `b` 不崩溃、`all` 能全选、提示中不能出现未支持的 `a`。

### P1. 指定版本安装没有验证最终版本是否等于用户请求

- 位置：`npm-global-manager.sh:2057-2157`、`2163-2367`、`5204-5268`
- 问题：单包安装、批量安装、JSON execute install 都支持 `eslint@9.0.0` 这类 spec，但安装后只验证“包存在且能读到版本”，没有验证确切版本。
- 用户影响：npm 返回 0 但实际安装到其它版本时，脚本会显示成功。对未来 macOS app 来说，这是错误状态回传。
- 修复标准：`package@<semver>` 应验证 installed version 等于 requested version；`package@<dist-tag>` 至少应在安装前用 `npm view package dist-tags.<tag>` 或 `npm view package@tag version` 解析目标版本，再验证 installed version。

### P1. package spec 接受末尾裸 `@`

- 位置：`npm-global-manager.sh:1410-1455`
- 问题：`eslint@`、`@scope/pkg@` 会被解析为无 requested 的普通包并通过。
- 证据：
  - `validate_package_spec eslint@` 返回 0。
  - `parse_package_spec eslint@` 输出 `eslint||eslint@`。
  - `validate_package_spec @scope/pkg@` 返回 0。
- 用户影响：用户输入明显不完整的 spec，脚本仍继续执行，命令行为和用户意图不一致。
- 修复标准：只要原始 spec 含 version/tag 分隔符 `@`，requested 部分不能为空。scoped 包需要区分开头 scope 的 `@` 和版本分隔符。

### P1. nvm mutation 锁没有覆盖所有 nvm 变更动作

- 位置：`npm-global-manager.sh:1916-1961`、`3834-3945`、`4700-4859`
- 问题：`install_node_lts` / `install_node_version` 对 `nvm install` 和 `nvm use` 分段加锁；`switch_node_version` 和 `set_node_default_alias` 直接执行 `nvm use` / `nvm alias default`，没有锁。
- 用户影响：两个脚本实例或未来 app 同时执行安装、切换、设置默认版本时，current/default 状态可能交错。
- 修复标准：所有 `nvm install/use/uninstall/alias` 写动作统一经过同一个 `nvm-mutation` 动作层；安装并切换应尽量在同一锁生命周期内完成。

### P1. nvm 安装默认没有内置 SHA256，普通路径开箱不可执行

- 位置：`npm-global-manager.sh:20-23`、`1833-1878`、`3555-3673`
- 当前行为：默认 `NVM_INSTALL_SHA256` 为空，脚本会阻断安装，并要求用户显式设置 `NVM_ALLOW_UNVERIFIED_INSTALL=1` 才能执行未校验下载脚本。
- 评价：安全性比上一轮好，但交付完整度仍不足。固定了 `NVM_INSTALL_VERSION=v0.40.5`，却没有同步固定该 install script 的校验值，导致默认安装 nvm 这条主路径不可用。
- 修复标准：提供固定版本对应的校验策略，例如内置 release/install script 校验值、签名/commit pin 校验，或把“下载安装 nvm”明确拆成需要用户提供 checksum 的高级功能。

### P1. 卸载后的残留清理没有持有 npm mutation 锁

- 位置：`npm-global-manager.sh:2616-2777`
- 问题：`npm uninstall -g` 本身通过 `run_logged_command` 持有 `npm-mutation`，但卸载后的包目录/bin 残留删除发生在命令锁释放之后。
- 用户影响：另一个脚本实例可能在残留扫描和删除之间执行 npm install/update/uninstall，残留删除有机会误碰正在变化的 global root/bin。
- 修复标准：卸载执行、后置验证、确定归属的残留删除应属于同一个全局包 mutation 临界区，或残留删除前重新获取同一把锁并做快照复验。

### P1. JSON/app 后端契约还不是完整共享动作层

- 位置：`npm-global-manager.sh:4916-5324`
- 问题：交互路径和 JSON 路径仍分叉。JSON uninstall execute 被禁用是正确的止血，但也说明 app 后端能力没有完成；JSON install 和交互 install 的验证语义也不完全一致。
- 用户影响：后续 macOS app 如果直接使用 JSON execute，会遇到能力不完整、结果模型不统一、部分路径比交互路径弱的问题。
- 修复标准：抽出共享动作层，例如 `plan_install_global_package`、`execute_install_global_package`、`verify_install_global_package`、`plan_uninstall_global_package` 等；交互层只负责输入/展示，JSON 层只负责序列化同一结果。

## 需要继续补齐的问题

1. `render_operation_result_json` 没校验 `exit_code` 是否为数字，外部传入非数字会输出非法 JSON。
   - 位置：`npm-global-manager.sh:5121-5137`
   - 修复标准：exit code 先走 `is_nonnegative_integer` 或有符号整数校验，非法时返回 JSON error。

2. JSON 输出结构不统一。
   - 位置：`npm-global-manager.sh:4965-5324`
   - 现状：有的命令返回原始 npm JSON，有的返回 `{ok:false}`，`summary` 没有 `ok/schemaVersion`。
   - 修复标准：面向 app 的命令至少要有稳定 envelope：`ok`、`schemaVersion`、`command`、`data/error`。

3. `validate_scope_name` 比 package name 安全子集更宽。
   - 位置：`npm-global-manager.sh:1483-1486`
   - 现状：scope 允许大写、前导点、前导下划线。
   - 修复标准：如果 scope registry 用于 npm package scope，应复用 package component 的安全规则，只在前面加 `@`。

4. 自定义 registry 允许 `http://`。
   - 位置：`npm-global-manager.sh:1488-1491`、`3249-3331`、`3364-3507`
   - 评价：npm 支持 registry URL，但长期安全交付默认应偏向 HTTPS。HTTP 可以作为显式高级路径，而不是普通路径。

5. `run_dependency_preflight` 仍把 Ruby 作为整个交互脚本的硬依赖。
   - 位置：`npm-global-manager.sh:135-153`
   - 影响：如果未来 macOS 环境不带 Ruby，用户连安装 nvm / 环境总览这类可降级功能都进不去。
   - 修复标准：预检按菜单能力分层；只读摘要和 nvm 安装不应被 JSON 解析依赖阻断。

6. 存在未被主流程调用的动作 helper。
   - 位置：`npm-global-manager.sh:1745-1758`、`1821-1827`
   - 现状：`install_global_package`、`upgrade_global_package_to_latest`、`upgrade_global_package`、`uninstall_global_package` 只定义未使用。
   - 影响：这些 helper 不走日志和锁，后续维护者误用会绕过当前安全设计。
   - 修复标准：要么删除，要么改造成唯一共享动作入口并让交互/JSON 都调用。

7. ShellCheck 仍没有实际进入质量门禁。
   - 位置：`scripts/node/run-quality-checks.sh:17-32`
   - 本轮结果：当前环境没有 shellcheck，runner 走 fallback static checks。
   - 修复标准：项目需要能在目标开发环境稳定运行 ShellCheck；fallback 只能兜底，不应替代最终门禁。

8. 测试对崩溃型交互分支覆盖不足。
   - 位置：`scripts/node/tests/npm-global-manager-test.sh:1660-1679`
   - 例子：node-gyp cleanup 输入 `b` 的测试没有检查退出码，所以真实 Bash 崩溃没有被测出来。
   - 修复标准：交互流测试必须断言 exit code、关键输出和副作用，而不只是 `|| true` 后检查片段。

9. 关键函数仍偏长，动作层边界不够清晰。
   - 位置：`run_batch_install_flow`、`run_uninstall_flow`、`run_upgrade_scan_flow`、`run_scope_registry_flow`、`run_project_node_flow`
   - 评价：还不是面条代码，但 UI、计划、执行、验证、摘要混在同一个函数里。后续做 macOS app 时会被迫复制或绕过逻辑。
   - 修复标准：保留 shell 交互外观，但把动作拆成可测试的 plan/execute/verify helper。

10. runtime 日志没有清理策略。
    - 位置：`npm-global-manager.sh:1501-1514`、`5280-5298`
    - 影响：长期使用后 `scripts/node/.runtime/logs` 会持续增长。
    - 修复标准：提供日志列表、查看、保留最近 N 条、按日期清理，且只处理 `scripts/node/.runtime/logs` 内的确定性路径。

## 当前未完成或仍不完善的功能清单

- nvm 安装：安全策略有了，但默认缺少内置 checksum，主路径不可直接完成。
- Node 版本切换/默认版本设置：功能可用，但并发锁没有统一。
- 单包/批量/JSON install：功能可用，但指定确切版本的成功验证不够硬。
- node-gyp 清理：候选过滤已改善，但返回/全选分支仍有真实 bug。
- 卸载残留清理：快照安全性不错，但锁生命周期不完整。
- JSON/app wrapper：已有雏形，尚未达到可作为 macOS app 稳定后端的契约水平。
- 测试：293 个测试通过，但仍漏掉 node-gyp 返回崩溃、裸 `@` spec、锁 owner 等关键边界。
- 质量门禁：fallback static checks 通过，但 ShellCheck 未实跑。

## 本轮验证证据

执行：

```bash
bash scripts/node/run-quality-checks.sh
```

结果：

- `bash -n` 通过。
- 测试：293 passed, 0 failed。
- ShellCheck：当前环境未安装，输出 `shellcheck not installed; running fallback static checks`。
- fallback static checks 通过。

针对性验证：

```bash
source scripts/node/npm-global-manager.sh
validate_package_spec Foo                 # reject
validate_package_spec .bin                # reject
validate_package_spec _foo                # reject
validate_package_spec node_modules        # reject
validate_package_spec eslint@9.0.0        # accept
validate_package_spec eslint@next         # accept
validate_package_name_only eslint@9.0.0   # reject
parse_multi_numeric_choice b 3            # back
parse_multi_numeric_choice all 3          # all
parse_multi_numeric_choice a 3            # invalid
validate_package_spec eslint@             # accept: bug
validate_package_spec @scope/pkg@         # accept: bug
```

Bash 崩溃验证：

```bash
set -u
selected_index=back
i=$((selected_index - 1))
# bash: back: unbound variable
```

JSON summary preflight 验证：

```bash
source scripts/node/npm-global-manager.sh
command_exists() { [ "$1" = sed ] || [ "$1" = mktemp ]; }
run_json_preflight summary
# exit 0
```

## 90+ 达标线

要达到 90+，至少先完成这些硬项：

1. 修 runtime lock owner 校验和 `HELD_RUNTIME_LOCKS` 生命周期。
2. 修 node-gyp cleanup 的 `back/all/a` 分支，并补真实交互测试。
3. 修 `eslint@` / `@scope/pkg@` 这种 dangling `@` spec。
4. install exact version/tag 做真实目标版本验证。
5. 所有 nvm 写动作统一进入 `nvm-mutation`。
6. 卸载残留清理纳入 npm mutation 临界区。
7. 给 nvm installer 一个默认可验证的安装路径，不能只靠用户手填 checksum。
8. 抽出共享动作层，让交互和 JSON/app wrapper 不再分叉。
9. ShellCheck 实跑进入门禁。
10. 给新增修复补针对性测试，尤其是失败路径和退出码。

这些做完后，脚本可以接近 92/100；再处理 JSON envelope、日志清理、函数拆分和 Ruby 分层依赖，才适合作为 macOS app 后端长期维护。
