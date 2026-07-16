# npm-global-manager.sh 第二轮深度 Review

日期：2026-06-17
范围：`scripts/node/npm-global-manager.sh`、`scripts/node/tests/npm-global-manager-test.sh`、`scripts/node/run-quality-checks.sh`、同目录需求/规格/计划
结论：这轮修复明显推进了质量，当前约 84/100。核心架构已经接近可持续交付：runtime 边界、能力预检、package spec parser、卸载残留快照、registry effective 验证、nvm default 解析、JSON/app wrapper 雏形都补上了。但还没到 90+，原因是仍有几个真实用户路径 bug、测试未覆盖关键交互、锁模型和 JSON 契约还不够硬。

参考资料：

- npm package spec: https://docs.npmjs.com/cli/v11/using-npm/package-spec
- npm install: https://docs.npmjs.com/cli/v11/commands/npm-install/
- npm update: https://docs.npmjs.com/cli/v11/commands/npm-update/
- npm outdated: https://docs.npmjs.com/cli/v11/commands/npm-outdated/
- npm config: https://docs.npmjs.com/cli/v11/commands/npm-config/
- npmrc: https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/
- npm package name guidelines: https://docs.npmjs.com/package-name-guidelines/
- nvm README: https://github.com/nvm-sh/nvm

## 本轮已明显改善的点

- runtime 输出仍收敛在 `scripts/node/.runtime`。
- 增加了 `require_capabilities`，npm 缺失时不会让多数菜单裸跑。
- 增加了 runtime lock，但锁粒度还需要调整。
- 增加了 `parse_package_spec`，把 name、version/tag、raw spec 分开。
- 卸载残留增加了 symlink snapshot 和 directory snapshot，安全性比上一版高很多。
- `npm outdated` 升级后增加了复扫验证，不再只看版本是否变化。
- registry 写入现在区分 user layer 写入成功和 effective registry 是否生效。
- `.nvmrc` 项目写入默认禁用，符合本轮输出边界。
- 清理菜单改成循环。
- nvm default alias 已分 alias/resolved/status，无法解析时会阻断卸载/清理。
- JSON/app wrapper 入口扩展为 plan/execute/status/logs，并默认禁用 execute。

## 仍必须修的问题

1. 单包安装错误地拒绝 `package@version` / `package@tag`。
   - 位置：`npm-global-manager.sh:1981-1990`
   - 证据：提示写着“支持 package 或 @scope/package 或 package@version”，需求也要求支持指定版本；但实现用 `validate_package_name_only`，会拒绝 `eslint@9.0.0` 和 `eslint@next`。
   - 实测：`validate_package_name_only 'eslint@9.0.0'` 返回 reject。
   - 用户影响：用户无法按需求安装指定版本，这是主路径功能 bug。
   - 修复标准：单包安装应使用 `validate_package_spec`；安装用 raw spec，验证用 `extract_package_name`。提示文案同步包含 `package@tag`。

2. latest 升级仍允许 version/tag spec，可能拼出错误参数。
   - 位置：`npm-global-manager.sh:2963-3014`
   - 问题：`run_upgrade_latest_flow` 仍用 `validate_package_spec`，允许 `eslint@9.0.0`。后续执行 `npm install -g "${package_name}@latest"`，会生成 `eslint@9.0.0@latest`。
   - 用户影响：命令失败或行为不可预测。
   - 修复标准：这里必须使用 `validate_package_name_only`，或先 `extract_package_name` 后再 `@latest`。提示文案也必须改成“只接受 package / @scope/package”。

3. package name 校验接受 npm 明确不推荐/不合法的新包名。
   - 位置：`npm-global-manager.sh:1366-1411`
   - 问题：当前正则接受 `Foo`、`.bin`、`_foo`、`node_modules`。npm package name guidelines 要求名称不能含大写，不能以点或下划线开头，并有保留名称约束。
   - 实测：`validate_package_spec 'Foo'`、`validate_package_spec '.bin'`、`validate_package_spec '_foo'` 都会通过。
   - 用户影响：脚本会放过明显无效 spec，最后让 npm 报错；这不是“边界清晰”。
   - 修复标准：安全子集应更严格：lowercase、不能以 `.`/`_` 开头、拒绝保留名；如果要兼容历史包，必须在文档中明确。

4. 锁模型粒度不对，npm install/update/uninstall/cache 可以互相并发。
   - 位置：`npm-global-manager.sh:1456-1490`
   - 问题：`run_logged_command` 生成锁名为 `npm-install`、`npm-uninstall`、`npm-update`、`npm-cache`。这只能阻止同类操作并发，不能阻止 install 与 uninstall 同时改同一个 global node_modules/bin/cache。
   - 用户影响：两个终端或未来 app 并发运行时，全局包状态可能竞争。
   - 修复标准：npm 变更型操作使用同一个 `npm-mutation` 锁；nvm install/use/uninstall/default 使用清晰的 `nvm-mutation` 或按资源分层锁。

5. 锁没有 stale lock 处理，也没有 trap 清理。
   - 位置：`npm-global-manager.sh:61-83`、`1456-1490`、`1833-1866`、`4267-4274`、`4476-4483`
   - 问题：脚本被 Ctrl+C、终端关闭或进程 kill 时，`.runtime/tmp/*.lock` 会残留，后续操作永久失败。
   - 用户影响：普通用户很难知道为什么后续操作被锁住。
   - 修复标准：锁内记录 pid/time/action；获取锁时检测 pid 是否存活；执行期间设置 trap；异常退出释放自己持有的锁。

6. `nvm` 安装仍默认没有 SHA256，只是二次确认。
   - 位置：`npm-global-manager.sh:20-23`、`1750-1795`、`3470-3489`
   - 问题：这比上一版好，但 90+ 的长期稳定交付不应该默认走未校验远程脚本。`NVM_INSTALL_SHA256` 仍为空。
   - 用户影响：企业代理、网络污染、GitHub raw 异常响应下，用户仍可能执行未校验内容。
   - 修复标准：固定 `NVM_INSTALL_VERSION` 时同步固定 SHA256；如果无法固定，应把无校验安装变成显式高级路径，而不是普通默认确认。

7. `render_summary_json` 被 `run_json_preflight` 的 npm 依赖卡住。
   - 位置：`npm-global-manager.sh:4891-4909`、`4804-4835`
   - 问题：交互启动摘要可以在 npm 缺失时降级展示，但 JSON `summary` 统一要求 `ruby npm sed mktemp`。未来 macOS app 第一次引导用户安装 nvm/Node 时，正需要 summary，但此时可能没有 npm。
   - 实测：覆写 `command_exists` 让 npm 缺失时，`run_json_command summary` 输出 `missing-dependency npm`。
   - 修复标准：JSON preflight 按 command 区分。`summary/status` 不应强依赖 npm；缺失字段输出空值或 `<unavailable>`。

8. JSON execute 的 update-latest 只验证“安装后有版本”，不验证是否等于 latest。
   - 位置：`npm-global-manager.sh:5085-5099`
   - 问题：交互 latest 流程至少会先 `npm view package version`，JSON execute 直接安装后只看 `get_installed_global_package_version` 非空。
   - 用户影响：app 端会收到 `ok`，但实际可能没升级到 latest。
   - 修复标准：JSON execute 与交互路径共用同一 plan/execute/verify helper，latest 必须验证 registry latest 或复扫。

9. JSON execute 的 uninstall 没有残留扫描和保护结果摘要。
   - 位置：`npm-global-manager.sh:5065-5083`
   - 问题：交互卸载已经有 package metadata、bin、目录残留、快照复验；JSON execute 只做 `npm uninstall -g` 后查版本为空。
   - 用户影响：未来 app 使用 JSON execute 会比 CLI 交互路径更不安全，出现两个质量等级。
   - 修复标准：把卸载 plan/execute/verify 抽成共享动作层，交互和 JSON 都调用。

10. package spec parser 用 `|` 作为字段分隔，缺少统一转义策略。
    - 位置：`npm-global-manager.sh:1410`、`1651-1659`、`4984-5030`
    - 问题：当前安全子集不允许 `|`，所以短期没炸；但这是一种隐性耦合。后续一旦扩展 npm spec，所有 `awk -F'|'` 都可能破。
    - 修复标准：保持安全子集时写明 `|` 被禁止并加测试；或者改成 JSON/独立变量返回，不用文本分隔协议。

11. 源管理 scope 展示仍可能重复输出。
    - 位置：`npm-global-manager.sh:3097-3118`
    - 问题：先打印 `scope_lines`，再打印包含 `scope_lines + config_scopes` 去重后的 `combined_scope_lines`。用户级 scope 会出现两次。
    - 用户影响：源配置页噪音，用户难以判断真实唯一配置。
    - 修复标准：只打印 `combined_scope_lines`，不要先打印未去重的 user 文件解析结果。

12. Scope registry 添加只验证 user layer，不验证 effective layer。
    - 位置：`npm-global-manager.sh:1606-1613`、`3317-3321`
    - 问题：默认 registry 切换已区分 effective mismatch，但 scope registry 添加没有同等处理。如果项目级或 global 覆盖同一 scope，用户仍只看到“已添加”。
    - 用户影响：用户以为 scope 生效，安装 scoped 包时实际仍走其他源。
    - 修复标准：scope registry set 也返回 `effective-ok/effective-mismatch`，展示分层。

13. `run_node_gyp_cache_cleanup` 会对每个候选目录连续进入确认流程，用户体验较差。
    - 位置：`npm-global-manager.sh:3981-4007`
    - 问题：检测多个候选后，没有先过滤存在目录，也没有让用户多选；直接逐个调用 `remove_confirmed_cache_directory`，不存在目录也会 pause。
    - 用户影响：用户会被多个不存在目录的确认/继续打断。
    - 修复标准：先扫描存在目录和体积，展示列表，多选后逐项删除。

14. 直接删除 npm cache 目录仍没有 runtime lock。
    - 位置：`npm-global-manager.sh:3910-3979`
    - 问题：`npm cache clean` 有 `npm-cache` lock，但高级目录删除没有锁。它还提示“确认没有 npm install/update/cache”，但程序没有强制阻止本脚本内并发 mutation。
    - 用户影响：两个脚本实例并发时仍可能删除另一个实例正在使用的 cache。
    - 修复标准：直接目录删除也使用 `npm-mutation` 或 `npm-cache` 锁，并做 stale lock 处理。

15. `scan_installed_node_versions_from_dirs` 仍使用 `sort -V`。
    - 位置：`npm-global-manager.sh:480-488`、`1806-1811`
    - 问题：脚本定位 macOS/Bash 3.2。当前机器可运行不等于所有目标 macOS 都有兼容 `sort -V` 的行为。长期稳定应避免依赖不必要的 GNU 风格选项，或者预检中明确要求。
    - 用户影响：部分 macOS 环境下 Node 版本列表可能失败。
    - 修复标准：用 Ruby 排序版本，或在 preflight 检查 `sort -V`，失败时降级。

16. `run_environment_overview` 在 nvm 已安装但未加载时不展示目录扫描出的已安装版本。
    - 位置：`npm-global-manager.sh:1918-1957`
    - 问题：启动摘要已经能只读解析 default alias 文件，但环境总览只有 `is_nvm_loaded` 时才显示 `nvm ls`。未加载时反而缺少更完整只读诊断。
    - 用户影响：用户无法在未 source nvm 的 shell 中看到已安装版本，只能看到 nvm.sh 存在。
    - 修复标准：环境总览始终展示 `scan_installed_node_versions_from_dirs` 结果；nvm loaded 时再附加 `nvm ls`。

17. `manager_version` 未随功能契约变化更新。
    - 位置：`npm-global-manager.sh:4755-4757`
    - 问题：脚本从 0.2.0 增加了 JSON execute、locks、snapshot、project write gate 等明显契约变化，但版本仍是 `0.2.0`。
    - 用户影响：未来 app 或用户无法通过版本判断能力集。
    - 修复标准：至少 bump 到 `0.3.0` 或加入 capability JSON。

18. 测试仍没有覆盖真实交互主路径。
    - 位置：`scripts/node/tests/npm-global-manager-test.sh`
    - 问题：270 个测试通过，但单包安装的 `package@version` 回归没有被测出来；latest 升级错误也只测“源码里有提示”，没有驱动输入。
    - 用户影响：测试绿仍可能放过主流程 bug。
    - 修复标准：增加 hermetic 行为测试：mock npm 状态文件 + printf 输入流，跑 `run_single_install_flow`、`run_upgrade_latest_flow`、`run_uninstall_flow`，断言 npm 收到的参数和状态变化。

19. ShellCheck 仍未实际运行。
    - 位置：`scripts/node/run-quality-checks.sh`
    - 证据：本轮执行仍显示 `shellcheck not installed; skipped`。
    - 用户影响：静态问题、引用问题、bash 可维护性问题缺少工具兜底。
    - 修复标准：安装 shellcheck 或提供本目录内可执行检查路径；质量门禁不能 silent skip。

20. npm 变更型操作没有统一动作层，交互和 JSON 逻辑分叉。
    - 位置：交互 `1964-3029`，JSON `4984-5106`
    - 问题：install/uninstall/update-latest 在交互和 JSON 里各写一套。现在已经出现质量分叉：交互 uninstall 更安全，JSON uninstall 更薄；JSON update-latest 验证更弱。
    - 用户影响：后续 macOS app 调 JSON 会绕过你精心做的交互安全设计。
    - 修复标准：抽出 `plan_install_global_package`、`execute_install_global_package`、`verify_install_global_package` 等共享函数；UI 只负责输入输出。

## 当前未完成或仍不完善的功能清单

- 单独安装 global package：指定版本/tag 路径当前坏了，需要立即修。
- 指定包升级到 latest：输入约束仍错，需要立即修。
- npm package spec 安全子集：比上一版好，但仍没有完整对齐 npm 命名规则。
- 升级与卸载：交互路径已接近稳，但 JSON 路径没有共享同等验证。
- 源管理：默认 registry effective 验证已补，scope registry 还没补齐。
- nvm 安装：无 SHA256 默认路径仍达不到 90+。
- 清理：cache/node-gyp 的 UX 和锁模型仍需收敛。
- 并发控制：有锁但不是最终形态，缺 stale lock/trap。
- app wrapper：接口有雏形，但还不是稳定后端契约。
- 测试：数量多，但缺关键行为测试和 shellcheck 实跑。

## 本轮验证证据

执行：

```bash
bash scripts/node/run-quality-checks.sh
```

结果：

- `bash -n` 通过。
- 测试：270 passed, 0 failed。
- ShellCheck：未安装，已跳过。

额外针对性验证：

```bash
source scripts/node/npm-global-manager.sh
validate_package_name_only 'eslint@9.0.0'
# rejects

validate_package_spec 'Foo'
# accepts-uppercase

validate_package_spec '.bin'
# accepts-dotbin
```

这些验证说明现有测试没有覆盖到关键交互语义。

## 90+ 达标线

要进入 90+，建议至少做到：

- 修掉单包安装 `package@version/tag` 回归。
- 修掉 latest 升级接受 version/tag spec 的 bug。
- package name 安全子集严格对齐 npm 命名规则。
- npm mutation 统一锁，支持 stale lock 和 trap 清理。
- nvm installer 默认绑定 SHA256，或把未校验安装移出普通路径。
- JSON execute 与交互路径共享 plan/execute/verify，不再分叉。
- summary/status JSON 在 npm 缺失时仍可工作。
- scope registry set/delete 同样区分 user/effective layer。
- 增加真实交互行为测试，至少覆盖 install、batch install、latest update、uninstall、registry set。
- ShellCheck 进入实际质量门禁。
