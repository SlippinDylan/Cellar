# npm-global-manager.sh 第四轮深度 Review

日期：2026-06-18
范围：`scripts/node/npm-global-manager.sh`、`scripts/node/tests/npm-global-manager-test.sh`、`scripts/node/run-quality-checks.sh`、`scripts/node/docs/specs/*`、`scripts/node/docs/drafts/*`
结论：第三轮的大部分硬问题已经修掉，当前约 89/100。代码已经接近 90+，但我不建议现在判定达标，因为仍有一个真实主路径判断 bug、JSON 错误契约不统一、ShellCheck 未实跑，以及 app 后端动作层仍未完成。

对照资料：

- npm package spec: https://docs.npmjs.com/cli/v11/using-npm/package-spec
- npm install: https://docs.npmjs.com/cli/v11/commands/npm-install/
- npm update: https://docs.npmjs.com/cli/v11/commands/npm-update/
- npm outdated: https://docs.npmjs.com/cli/v11/commands/npm-outdated/
- npm config: https://docs.npmjs.com/cli/v11/commands/npm-config/
- npmrc: https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/
- npm package name guidelines: https://docs.npmjs.com/package-name-guidelines/
- nvm README: https://github.com/nvm-sh/nvm

## 已闭环的第三轮问题

- runtime lock 现在有 owner 校验，`release_runtime_lock` 不会删除其它进程持有的 lock。
- 显式释放 lock 后会从 `HELD_RUNTIME_LOCKS` 移除。
- `node-gyp` 清理的 `back/all` 分支已修，提示不再写未支持的 `a 全选`。
- `eslint@`、`@scope/pkg@` 这种 dangling `@` spec 已拒绝。
- 单包安装、批量安装、JSON install 都开始调用 `verify_install_result_for_spec` 验证请求版本。
- nvm install/use/alias 写动作都进入 `nvm-mutation` 锁。
- nvm installer 已内置 `v0.40.5` install.sh SHA256。
- 卸载执行、后置验证、残留清理被纳入同一个 `npm-mutation` 锁生命周期。
- `validate_scope_name` 已复用 package component 规则，拒绝大写和前导下划线。
- registry URL 默认只接受 HTTPS。
- `render_operation_result_json` 已拒绝非法 exit code。
- JSON 正常响应已经有 `ok/schemaVersion/command/data` envelope。
- 增加了 runtime log 保留最近 N 条的清理 helper。
- legacy package helper 已改为走 `run_logged_command`。

## 必须修的问题

### P1. `npm ls && echo yes` 没有丢弃 stdout，安装状态判断会失真

- 位置：`npm-global-manager.sh:2355`、`2431`、`2786`
- 问题：代码写法是：

```bash
already_installed="$(npm ls -g "$bare_package_name" --depth=0 2>/dev/null && echo "yes" || echo "no")"
```

真实 `npm ls` 成功时会输出包树或 JSON，所以变量会变成多行内容加 `yes`，而不是精确的 `yes`。后续 `[ "$already_installed" = "yes" ]` 会失败。

- 用户影响：
  - 批量安装页会把真实已安装包显示为 `[待安装]`。
  - `all 全部待安装` 的语义会变差，可能重复安装本该跳过的包。
  - 卸载后验证 `still_installed` 也可能漏报“npm 返回成功但包仍在列表中”。
- 复现证据：mock `npm ls` 输出依赖 JSON 且返回 0 时，批量安装仍显示 `[待安装] eslint@9.0.0`，并继续执行 install。
- 修复标准：所有这类布尔判断必须把 `npm ls` stdout 重定向掉，例如：

```bash
if npm ls -g "$bare_package_name" --depth=0 >/dev/null 2>&1; then
    already_installed="yes"
else
    already_installed="no"
fi
```

并补行为测试：mock npm ls 输出真实 stdout 也必须判定为已安装。

### P1. 批量安装和 JSON plan 的 `alreadyInstalled` 没有按请求版本判断

- 位置：`npm-global-manager.sh:2338-2363`、`2428-2437`、`5513-5537`
- 问题：清单支持 `eslint@9.0.0`，但已安装判断只看裸包 `eslint` 是否存在，不判断当前版本是否满足 `9.0.0` 或 dist-tag 解析目标版本。
- 当前行为：`render_package_plan_json eslint@9.0.0` 在已装 `eslint@8.0.0` 时输出：

```json
{"alreadyInstalled":true,"installedVersion":"8.0.0"}
```

- 用户影响：
  - app 侧 plan 会误以为目标版本已满足。
  - 批量安装未来修掉 stdout bug 后，如果只看裸包存在，仍会跳过应该升级/重装到指定版本的清单项。
- 修复标准：引入 `is_install_spec_satisfied(package_spec, installed_version)` 这样的共享判断；裸包只要求存在，exact version 要等值，tag 要解析目标版本后等值。

### P1. JSON preflight / unsupported command 错误没有统一 envelope，且可能输出多段 JSON

- 位置：`npm-global-manager.sh:5220-5297`
- 问题：
  - `run_json_preflight` 缺多个依赖时会连续打印多个 JSON 对象，不是单个合法 JSON 文档。
  - unsupported command 直接输出 `{"ok":false,"error":"unsupported-json-command"}`，没有 `schemaVersion/command`。
- 复现证据：

```bash
source scripts/node/npm-global-manager.sh
command_exists() { return 1; }
run_json_command packages
```

输出是多行 JSON：

```json
{"ok":false,"error":"missing-dependency","dependency":"ruby"}
{"ok":false,"error":"missing-dependency","dependency":"npm"}
{"ok":false,"error":"missing-dependency","dependency":"sed"}
{"ok":false,"error":"missing-dependency","dependency":"mktemp"}
```

- 用户影响：macOS app 端如果按单个 JSON 响应解析，会直接解析失败。
- 修复标准：`run_json_command` 必须保证任何路径只输出一个 envelope，例如：

```json
{"ok":false,"schemaVersion":1,"command":"packages","error":{"code":"missing-dependency","dependencies":["ruby","npm"]}}
```

### P1. JSON uninstall execute 仍未实现共享安全动作层

- 位置：`npm-global-manager.sh:5387-5455`
- 当前行为：`render_execute_json uninstall` 仍返回 `json-uninstall-execute-disabled`。
- 评价：禁用危险薄路径是正确的，但从“后续做 macOS app”的目标看，这表示 app 后端还没完整交付。
- 修复标准：把交互卸载里的 plan、metadata、bin 快照、目录快照、执行、后置验证、残留候选清理拆成共享 helper，JSON execute 调同一套动作层，而不是另写薄版本。

### P1. ShellCheck 仍未实跑

- 位置：`scripts/node/run-quality-checks.sh:17-32`
- 本轮质量检查结果：316 passed / 0 failed，但输出 `shellcheck not installed; running fallback static checks`。
- 影响：fallback 只检查 `sort -V` 和 tab，不能替代 ShellCheck 对 quoting、local、管道、未定义变量、可移植性等问题的覆盖。
- 修复标准：在本项目的质量门禁环境中实际安装并运行 ShellCheck，或者提供一个可复现的本目录工具链入口。fallback 只能作为缺工具时的降级提示。

## 需要继续补齐的问题

1. Ruby 依赖仍然是“预检警告、流程内失败”的体验。
   - 位置：`npm-global-manager.sh:191-209`、`978-1037`、`1366-1384`
   - 现状：交互启动允许缺 Ruby，但卸载、升级扫描、包清单解析等路径实际依赖 Ruby。菜单入口多处只 `require_capabilities npm`。
   - 影响：缺 Ruby 时用户会进入流程后看到 JSON 解析失败，而不是明确“此功能需要 Ruby 解析 npm JSON”。
   - 修复标准：增加 `require_capabilities ruby` 或更细的 `require_json_parser`，只在确实需要 JSON 解析的功能入口阻断。

2. 动作层边界仍不够完整。
   - 位置：`run_single_install_flow`、`run_batch_install_flow`、`run_uninstall_flow`、`run_upgrade_scan_flow`、`render_execute_json`
   - 现状：验证 helper 已开始抽出，但 UI、计划、执行、验证、摘要仍大量混在长函数里。
   - 影响：后续 app 化会继续逼迫 JSON 路径和交互路径分叉。
   - 修复标准：至少把 install/update/uninstall 的 plan/execute/verify/result 统一成共享函数，交互层只负责读输入和渲染。

3. `resolve_install_target_version` 对 dist-tag 是安装后再查 registry。
   - 位置：`npm-global-manager.sh:1540-1557`
   - 影响：`package@tag` 安装可能已经成功，但安装后 registry 查询失败会被判定为安装验证失败并触发重试。
   - 修复标准：对 tag 在执行前解析目标版本并放入 plan；执行后只对照 plan 中目标版本，避免验证阶段再引入一次网络不确定性。

4. `cleanup_runtime_logs_keep_recent` 有 helper，但还没有交互入口或 JSON 命令。
   - 位置：`npm-global-manager.sh:5487-5511`
   - 影响：长期使用日志增长问题有底层函数，但用户和 app 还不能直接触达。
   - 修复标准：加入环境清理菜单或 JSON logs cleanup 命令，带 dry-run/plan/confirm。

5. 测试仍有较多静态字符串断言。
   - 位置：`scripts/node/tests/npm-global-manager-test.sh`
   - 评价：这轮行为测试明显增加了，但仍有不少关键测试只检查源码包含某段字符串。
   - 修复标准：对主路径补 hermetic 行为测试，尤其是真实 `npm ls` stdout、批量版本满足判断、JSON 单文档错误输出、Ruby 缺失提示。

## 当前未完成或仍不完善的功能清单

- 批量安装：已支持版本 spec 的安装验证，但“已安装/跳过”判断仍不可靠。
- JSON package plan：能输出 envelope，但 `alreadyInstalled` 对 version/tag spec 语义不准确。
- JSON execute uninstall：仍禁用，还不是 app 后端完整能力。
- JSON 错误响应：正常路径有 envelope，preflight 和 unsupported command 仍不统一。
- Ruby 能力诊断：缺 Ruby 时的用户提示还不够明确。
- ShellCheck：质量门禁仍未实际跑。
- 日志清理：有 helper，但还没暴露为可用流程。

## 本轮验证证据

执行：

```bash
bash scripts/node/run-quality-checks.sh
```

结果：

- `bash -n` 通过。
- 测试：316 passed, 0 failed。
- ShellCheck：当前环境未安装，输出 `shellcheck not installed; running fallback static checks`。

联网核对 nvm installer SHA：

```bash
set -o pipefail
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh | shasum -a 256
```

结果：

```text
582070e4c44452c1d8d68e16fc786c2216ecba6bc6bf18dc280a03fdba6ed1a9
```

与 `npm-global-manager.sh:22` 内置值一致。

针对性验证：

```bash
validate_package_spec eslint@          # reject
validate_package_spec @scope/pkg@      # reject
validate_package_spec eslint@9.0.0     # accept
validate_scope_name @Company           # reject
validate_registry_url http://registry.npmjs.org/  # reject
render_operation_result_json ... nope ...          # invalid-exit-code
```

JSON plan 版本误判验证：

```bash
render_package_plan_json eslint@9.0.0
# alreadyInstalled=true, installedVersion=8.0.0
```

JSON preflight 多文档验证：

```bash
command_exists() { return 1; }
run_json_command packages
# 输出多个独立 JSON 对象
```

## 90+ 达标线

要进入 90+，最低还需要：

1. 修掉所有 `npm ls && echo yes` 判断，stdout 必须重定向。
2. `alreadyInstalled` 必须按 package spec 判断，而不是只看裸包存在。
3. JSON 任意错误路径只输出一个稳定 envelope。
4. JSON uninstall execute 要么接入共享安全动作层，要么从 help/plan 中明确标成未交付能力。
5. ShellCheck 在质量门禁中实跑。
6. Ruby 缺失要在具体功能入口给出明确能力错误。

完成这 6 项后，我认为脚本可以进入 91-92/100；再继续拆共享动作层和补 app 行为测试，才是更稳的长期维护形态。
