# npm-global-manager.sh 第八轮深度 Review

日期：2026-06-24

范围：

- `scripts/node/npm-global-manager.sh`
- `scripts/node/tests/npm-global-manager-test.sh`
- `scripts/node/run-quality-checks.sh`
- `scripts/node/tools/install-shellcheck.sh`
- `scripts/node/config/global-packages.txt`
- `scripts/node/app-bundle-manifest.txt`
- `scripts/node/docs/specs/*`
- `scripts/node/docs/reviews/2026-06-24-npm-global-manager-seventh-deep-review.md`

结论：第七轮指出的核心 P1 已经收口，当前质量我给 91/100。脚本已经进入可交付边缘：npm package spec、无 npm bootstrap、nvm 未校验安装阻断、JSON missing argument、危险动作 plan 信息补全都有实质修复。但还没有到“长期稳定的 app 后端契约”级别，主要卡在 Node/nvm JSON 动作的边界：`lts` alias 被错误放进所有 Node 动作、`nvm-install [version]` 的入参和实际安装版本不一致、JSON plan 仍会触发 nvm 副作用输出。

## 联网核对资料

- npm package spec: https://docs.npmjs.com/cli/v11/using-npm/package-spec
- npm install: https://docs.npmjs.com/cli/v11/commands/npm-install/
- npm config: https://docs.npmjs.com/cli/v11/commands/npm-config/
- npmrc: https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/
- nvm README: https://github.com/nvm-sh/nvm
- nvm releases: https://github.com/nvm-sh/nvm/releases

核对结论：

- npm 官方 package spec 覆盖 `<pkg>@<version>`、tag、range 等形式。第七轮后的实现已经不再把 `eslint@9` 当作精确版本，这个方向是对的。
- npm install 的 `<package-spec>` 语义由 npm 解析，脚本在 plan 阶段提前解析目标版本是合理的，但必须保证 plan 里的 `targetVersion` 和实际 npm install 后验证一致。
- nvm 的 LTS 入口不是一个可以任意复用的普通版本字符串。官方 README 使用 `--lts`、`--lts=<line>`、`lts/*`、`lts/<line>` 等语义；卸载和项目 `.nvmrc` 写入应使用明确版本，不能把裸 `lts` 当成稳定版本。
- nvm 是 shell function，加载 `nvm.sh` 后调用是正确路径；但 JSON plan 属于只读展示，不应向 stderr 输出 nvm 内部诊断，也不应让 plan 的字段看起来像已确认的可执行版本。

## 本轮验证证据

质量门禁：

```bash
bash scripts/node/run-quality-checks.sh
```

结果：

- `bash -n` 通过。
- 测试：`422 passed, 0 failed`。
- ShellCheck：已执行，无报错输出。

额外复现 1：`node-uninstall lts` 被 plan 接受，并且 stderr 出现 nvm 噪声。

```bash
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json plan node-uninstall lts
```

合并输出中出现：

```text
unknown version dir
{"ok":true,"schemaVersion":1,"command":"plan","data":{"ok":true,...,"action":"node-uninstall","subject":"lts","normalizedVersion":"lts","versionDir":"","versionDirExists":false,...}}
```

stdout 单独解析仍是合法 JSON，但 stderr 噪声对 app 桥接层和日志收集是不稳定因素。

额外复现 2：`node-use lts` 被 plan 接受，但 execute 只返回泛化失败。

```bash
MANAGER_TEST_UNAME=Darwin NODE_MANAGER_ALLOW_JSON_EXECUTE=1 \
  bash scripts/node/npm-global-manager.sh --json execute node-use lts
```

结果：

```json
{"ok":false,"schemaVersion":1,"command":"execute","error":{"operationId":"...","action":"node-use","subject":"lts","exitCode":3,"status":"failed","logFile":"..."}}
```

额外复现 3：`project-nvmrc` 接受 `lts`，会允许 app 写入不稳定 alias。

```bash
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json plan project-nvmrc scripts/node lts
```

结果中 `value` 是 `lts`，没有被拒绝，也没有被解析成明确 Node 版本。

额外复现 4：`nvm-install [version]` 的参数和真实安装版本不一致。

```bash
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json plan nvm-install v0.40.4
```

结果：

```json
{"subject":"v0.40.4","version":"v0.40.5","installUrl":"https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh"}
```

再用 mock 验证 execute：

```bash
NODE_MANAGER_ALLOW_JSON_EXECUTE=1 bash -c 'source scripts/node/npm-global-manager.sh; install_nvm_official() { printf "version=%s url=%s\n" "$NVM_INSTALL_VERSION" "$NVM_INSTALL_URL"; return 0; }; render_execute_json nvm-install v0.40.4'
```

对应 log 中实际执行仍是：

```text
version=v0.40.5 url=https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.5/install.sh
```

## 第七轮已闭环项

- `requested_package_version_is_exact()` 现在只把完整 semver 当 exact：`scripts/node/npm-global-manager.sh:1594-1597`。
- `resolve_install_target_version()` 对裸包、tag、range 会走 npm view 解析目标版本：`scripts/node/npm-global-manager.sh:1599-1624`。
- `install_nvm_official()` 已经下沉未校验安装阻断：`scripts/node/npm-global-manager.sh:2042-2069`。
- JSON preflight 已按 action 分支，不再让 `nvm-install` 强依赖 npm：`scripts/node/npm-global-manager.sh:5428-5494`。
- `render_action_plan_json` / `render_execute_json` 已处理缺失参数：`scripts/node/npm-global-manager.sh:5827-5845`、`scripts/node/npm-global-manager.sh:6221-6242`。
- JSON dangerous plan 已补充 registry、scope registry、node uninstall、cleanup、project-nvmrc 的影响范围。
- 新增测试覆盖了 semver range、bootstrap preflight、nvm install gate、业务错误 code、危险 plan、missing argument、cleanup logs proxy。

## 必须修的问题

### P1. Node action 的版本校验边界错误，`lts` 被误用到 uninstall/use/project-nvmrc

位置：

- `scripts/node/npm-global-manager.sh:5603-5608`
- `scripts/node/npm-global-manager.sh:5664-5689`
- `scripts/node/npm-global-manager.sh:5737-5773`
- `scripts/node/npm-global-manager.sh:6068-6099`
- `scripts/node/npm-global-manager.sh:6190-6208`
- `scripts/node/npm-global-manager.sh:6360-6387`

当前行为：

- `validate_node_action_version()` 把 `lts` 和 `--lts` 作为全局合法 Node version。
- `node-install`、`node-use`、`node-uninstall`、`project-nvmrc` 共用这一个校验函数。
- `node-uninstall lts` plan 返回成功，`normalizedVersion:"lts"`、`versionDir:""`，还会产生 `unknown version dir` stderr。
- `node-use lts` execute 失败时只返回 `exitCode:3` 的泛化 operation result，app 不知道这是非法输入、未安装版本，还是 nvm 自身错误。
- `project-nvmrc lts` plan 返回成功；在 `NODE_MANAGER_ALLOW_PROJECT_WRITE=1` 时会把 `lts` 写进项目 `.nvmrc`。

用户影响：

- 卸载 Node 的确认页会展示一个无法定位目录、无法判断 current/default 保护的目标。
- app 如果把 stdout/stderr 合并读取，会拿到非纯 JSON 输出。
- `node-use lts` 这类输入本应在 plan 阶段被阻断或解析成明确版本，现在会拖到 execute 后失败。
- 项目 `.nvmrc` 的目标应该偏稳定和可复现；写入裸 `lts` 会让同一个项目在不同时间解析到不同 Node 版本，不符合“长期稳定、可维护”的要求。

修复标准：

- 拆分校验函数，不要用一个 `validate_node_action_version()` 覆盖所有动作。
- `node-install` 可支持官方 LTS 语义，但应明确支持 `--lts`、`--lts=<line>`、`lts/*`、`lts/<line>`；如果保留裸 `lts`，必须在内部规范化成官方语义或明确拒绝。
- `node-use` 应只接受已安装的明确版本，或者先把 alias 解析成明确 installed version 后再 plan/execute。
- `node-uninstall` 必须只接受明确版本，并且在 plan 阶段判断 current/default/installed 状态。
- `project-nvmrc` 建议只接受明确版本，至少默认不写裸 `lts`；如果支持 alias，plan 必须明确标出 `nonReproducible:true` 并要求更强确认。
- 所有非法 alias 都应返回结构化业务错误，例如 `invalid-node-version-for-action`，不能落到泛化 failed。

### P1. `nvm-install [version]` 的 subject 和实际安装版本不一致

位置：

- `scripts/node/npm-global-manager.sh:19-21`
- `scripts/node/npm-global-manager.sh:5259-5260`
- `scripts/node/npm-global-manager.sh:5660-5663`
- `scripts/node/npm-global-manager.sh:5730-5735`
- `scripts/node/npm-global-manager.sh:6346-6358`

当前行为：

- help 暴露 `--json plan nvm-install [version]` 和 `--json execute nvm-install [version]`。
- plan 会把用户传入的版本放进 `subject` 和 `operationId`。
- 但 `version` 与 `installUrl` 仍来自全局 `NVM_INSTALL_VERSION` / `NVM_INSTALL_URL`。
- execute 也没有把 subject 转成 install URL，最终仍安装全局版本。

用户影响：

- app 确认页可能显示“将安装 v0.40.4”，实际执行安装 `v0.40.5`。
- SHA256 也绑定在全局默认版本上；一旦参数版本和校验值不一致，供应链校验语义会变得不可信。
- 这是确认页和执行层不一致的问题，不能只靠文案解释。

修复标准：

- 二选一：要么删除 `[version]` 入参，`nvm-install` 永远只安装脚本内固定版本；要么把 subject 变成真实配置源，派生 `installUrl` 和对应 SHA256。
- 如果支持多版本，必须有版本白名单或 checksum 表，不能允许任意版本拼 URL 后执行。
- plan 和 execute 使用同一个解析结果对象：`requestedVersion`、`resolvedVersion`、`installUrl`、`sha256`、`sha256Configured` 必须完全一致。
- 测试必须覆盖 `nvm-install v0.40.4` 不能出现 subject/version 分裂。

## 需要继续补齐或收敛的问题

### P2. JSON plan 仍会加载 nvm，违反只读展示不应修改环境/污染输出的边界

位置：

- `scripts/node/npm-global-manager.sh:522-529`
- `scripts/node/npm-global-manager.sh:5737-5756`

当前行为：

- `render_non_package_action_plan_json()` 在 Node plan 分支里调用 `load_nvm_into_current_shell`。
- 同一段 plan 内还调用两次加载逻辑：一次采集 current/default，一次打印 `nvmAvailable`。
- 对 alias 输入会出现 nvm stderr：`unknown version dir`。

用户影响：

- 需求明确写了“所有只读展示功能不得修改环境”。source `nvm.sh` 会改变当前进程环境和函数表，虽然不写磁盘，但它不是纯只读采集。
- macOS app 的 JSON bridge 通常会分别处理 stdout/stderr，但也常见合并输出或把 stderr 当错误提示；plan 阶段的 nvm 噪声会导致 UI 误判。
- plan 的字段依赖当前 shell 状态，重复加载也让行为更难测试。

修复标准：

- 把 Node plan 信息采集收敛成一个只读 helper，只加载一次，stderr 全部捕获进字段或忽略。
- 如果 nvm 不可用，plan 应返回 `nvmAvailable:false` 和可解释的 unavailable reason，而不是让下游函数打印诊断。
- 对 alias 输入先做 action-specific validation，避免后续路径计算触发 nvm 的 unknown version 输出。

### P2. 业务错误 envelope 仍丢失原始错误上下文字段

位置：

- `scripts/node/npm-global-manager.sh:5319-5339`
- `scripts/node/npm-global-manager.sh:6380-6387`
- `scripts/node/npm-global-manager.sh:6396-6402`

当前行为：

- `json_print_business_error_with_operation()` 只用 `sed` 从原始 JSON 中提取 `code`。
- 原始错误里的 `path`、`version`、`lock`、`registry` 等字段会被丢弃。
- 第七轮修复后 code 能保住，但上下文还不完整。

用户影响：

- app 可以知道 `project-write-disabled`，但拿不到原始错误的 path/version 等细节，只能再去 log 里查。
- 这会降低用户提示质量，也让自动化调用者难以判断下一步动作。

修复标准：

- 不要用正则抽 JSON 后重组半截字段。
- 如果有 Ruby，解析原始错误对象后合并 operation 元数据；没有 Ruby 时保留原始 `error` 为字符串或返回明确降级字段。
- 最终错误至少要保留 `code`、`action`、`subject`、原始错误上下文、`operationId`、`logFile`。

### P2. `node-use lts` / `node-uninstall lts` 失败没有业务错误分层

位置：

- `scripts/node/npm-global-manager.sh:6372-6378`
- `scripts/node/npm-global-manager.sh:6380-6387`
- `scripts/node/npm-global-manager.sh:6404-6410`

当前行为：

- `node-use` 直接调用 `switch_node_version "$subject"`。
- 失败后统一落到 `render_simple_execute_result_json(..., "failed", exit_code)`。
- `node-uninstall lts` 在 `normalize_node_version "$version"` 失败后没有结构化错误输出，最终也可能落到泛化 failed。

用户影响：

- app 无法区分非法版本、nvm 不可用、版本未安装、当前版本不能卸载、默认版本不能卸载。
- 这会让 UI 只能展示“操作失败”，不符合脚本现在已经建立的 JSON contract 水平。

修复标准：

- `node-use` 增加结构化 pre-execute 检查：invalid version、nvm unavailable、version not installed。
- `node-uninstall` 对 normalize 失败必须返回 `invalid-node-version`，不能继续执行后续逻辑。
- execute 的最终失败只应该覆盖不可预期的命令失败；可预期业务失败必须有 code。

### P3. help 与实际 execute gate 有例外，文档契约不够精确

位置：

- `scripts/node/npm-global-manager.sh:5284-5287`
- `scripts/node/npm-global-manager.sh:5530-5534`

当前行为：

- help 写着所有 JSON execute 都需要 `NODE_MANAGER_ALLOW_JSON_EXECUTE=1`。
- 但 `execute cleanup logs` 被实现成 `logs-cleanup` proxy，不需要 execute gate。
- 测试也确认这是当前预期。

用户影响：

- 对 app 开发者来说，文档会误导权限模型：到底是所有 execute 都要确认，还是只读清理日志可以直接走？
- 这类例外应该写进 contract，否则后续封装容易产生不一致。

修复标准：

- help 和 app boundary spec 明确：`execute cleanup logs` 是兼容别名，不执行外部危险动作，可不需要 execute gate。
- 或者取消这个例外，统一让所有 `execute` 都走 gate，把 `logs-cleanup` 作为唯一无 gate 命令。

## 功能完成度判断

- npm 全局包安装/卸载/升级：主体完整，range/tag 解析已明显补强。
- registry 与 scope registry：交互和 JSON 计划基本完整，影响范围字段可用。
- nvm 安装：安全阻断已经补上，但 `[version]` 入参和实际执行仍有严重契约分裂。
- Node 安装/切换/卸载：终端交互路径可用，JSON app 路径还需要按 action 拆分 alias/version 语义。
- project `.nvmrc`：权限 gate 正确，但版本输入应更保守，不能默认允许裸 `lts`。
- 清理：保守策略基本符合需求，`cleanup logs` 的 gate 例外需要文档化或收敛。
- app 打包边界：manifest 和 runtime 边界方向正确，没有发现输出跑出 `scripts/node` 的新问题。

## 总评

第七轮修复质量是明显往正确方向走的，不是补丁式糊测试：npm package spec、nvm 安全 gate、JSON preflight 都有共享边界上的改动。现在剩下的问题集中在 Node/nvm JSON contract，而不是 npm 主流程。

如果要达到稳定 90+，下一轮不应该继续在单个 case 上补判断，而应该把 Node 动作的输入模型拆清楚：`node-install` 支持 install target，`node-use` 支持 installed target，`node-uninstall` 支持 uninstallable concrete version，`project-nvmrc` 支持 reproducible project version。每个动作都有自己的 plan/execute 校验和错误码，`nvm-install` 则必须消除 subject/version/installUrl 的分裂。这样脚本才适合作为未来 macOS app 的后端，而不是只能靠终端人工理解失败原因。
