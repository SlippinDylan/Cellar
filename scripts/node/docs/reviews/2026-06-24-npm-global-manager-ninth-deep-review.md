# npm-global-manager.sh 第九轮深度 Review

日期：2026-06-24

范围：

- `scripts/node/npm-global-manager.sh`
- `scripts/node/tests/npm-global-manager-test.sh`
- `scripts/node/run-quality-checks.sh`
- `scripts/node/config/global-packages.txt`
- `scripts/node/app-bundle-manifest.txt`
- `scripts/node/docs/specs/2026-06-11-node-npm-global-manager-spec.md`
- `scripts/node/docs/drafts/2026-06-11-node-npm-global-manager-requirements.md`
- `scripts/node/docs/specs/2026-06-24-app-boundary-and-packaging-contract.md`
- `scripts/node/docs/reviews/2026-06-24-npm-global-manager-eighth-deep-review.md`

结论：第八轮指出的 P1/P2 主问题大多已经修掉，当前脚本比第八轮报告中的状态更接近可交付。`nvm-install v0.40.4` 已拒绝，`node-use lts` / `node-uninstall lts` / `project-nvmrc lts` 已在 plan 阶段返回结构化错误，业务错误 envelope 也保留了原始上下文。当前我给 88/100。卡住 90 分的不是 npm 主流程，而是 app 后端契约和交互确认面的严谨性：plan 和 execute 无法稳定关联、plan/package-plan 产生空日志副作用、交互 `.nvmrc` 写入仍允许非具体版本、单包/批量安装确认页没有把目标版本展示完整、`node-install` JSON execute 仍缺业务错误分层。

## 联网核对资料

- npm package spec: https://docs.npmjs.com/cli/v11/using-npm/package-spec
- npm install: https://docs.npmjs.com/cli/v11/commands/npm-install/
- npm update: https://docs.npmjs.com/cli/v11/commands/npm-update
- npm outdated: https://docs.npmjs.com/cli/v11/commands/npm-outdated
- npm config: https://docs.npmjs.com/cli/v11/commands/npm-config/
- npmrc: https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/
- nvm README: https://github.com/nvm-sh/nvm
- nvm releases: https://github.com/nvm-sh/nvm/releases

核对结论：

- npm 官方 `<package-spec>` 可以覆盖 registry package、tag、version、range 等形态。当前脚本主动收窄为安全 registry 子集是可以接受的，但确认页必须把最终解析出的目标版本展示给用户。
- `npm install -g <package-spec>` 和 `npm update -g <pkg>` 是全局安装/升级的官方路径；脚本用 npm 自身执行 mutation 是正确方向。
- `npm outdated -g --json` 用作升级扫描是合理的，但它的退出码语义不能简单等同失败；当前代码已经做了 exit 1 有可升级项的处理。
- `npm config set/delete ... --location=user` 与 `.npmrc` 分层展示符合 npm config 模型。
- nvm 的 LTS alias 可以用于安装和使用，但本项目自己的 app boundary spec 已明确 project `.nvmrc` 应使用具体版本；JSON 路径已经修正，交互路径仍未对齐。

## 本轮复现证据

第八轮核心问题已修：

```bash
MANAGER_TEST_UNAME=Darwin bash npm-global-manager.sh --json plan node-uninstall lts
```

结果：

```json
{"ok":false,"schemaVersion":1,"command":"plan","error":{"code":"invalid-node-version-for-action","action":"node-uninstall","version":"lts"}}
```

```bash
MANAGER_TEST_UNAME=Darwin bash npm-global-manager.sh --json plan project-nvmrc . lts
```

结果：

```json
{"ok":false,"schemaVersion":1,"command":"plan","error":{"code":"invalid-node-version-for-action","action":"project-nvmrc","version":"lts"}}
```

```bash
MANAGER_TEST_UNAME=Darwin bash npm-global-manager.sh --json plan nvm-install v0.40.4
```

结果：

```json
{"ok":false,"schemaVersion":1,"command":"plan","error":{"code":"unsupported-nvm-install-version","action":"nvm-install","requestedVersion":"v0.40.4","configuredVersion":"v0.40.5"}}
```

新增复现 1：package plan 会创建空日志文件。

```bash
tmp_before=$(mktemp .runtime/tmp/log-before.XXXXXX)
tmp_after=$(mktemp .runtime/tmp/log-after.XXXXXX)
find .runtime/logs -maxdepth 1 -type f 2>/dev/null | sort > "$tmp_before"
MANAGER_TEST_UNAME=Darwin bash npm-global-manager.sh --json plan install eslint@9.0.0 >/dev/null
find .runtime/logs -maxdepth 1 -type f 2>/dev/null | sort > "$tmp_after"
comm -13 "$tmp_before" "$tmp_after"
```

结果新增：

```text
.runtime/logs/install-eslint-20260624-144446-77409.log.N8cbIJ
```

新增复现 2：plan 与 execute 的 `operationId` / `logFile` 不一致。

plan：

```json
"operationId":"20260624144543-79770-install-eslint",
"logFile":"/Users/dylanwang/Repo/Products/Apps/Cellar/scripts/node/.runtime/logs/install-eslint-20260624-144543-79770.log.rjaAjG"
```

execute mock：

```json
"operationId":"20260624144600-79999-install-eslint",
"logFile":"/Users/dylanwang/Repo/Products/Apps/Cellar/scripts/node/.runtime/logs/install-eslint-20260624-144600-79999.log.rEBaL7"
```

新增复现 3：`node-install` JSON execute 的可预期业务失败仍是泛化 failed。

```bash
NODE_MANAGER_ALLOW_JSON_EXECUTE=1 bash -lc 'source ./npm-global-manager.sh; load_nvm_into_current_shell() { return 1; }; render_execute_json node-install 20.11.1'
```

结果：

```json
{"operationId":"...","action":"node-install","subject":"20.11.1","exitCode":1,"status":"failed","logFile":"..."}
```

这里没有 `nvm-unavailable`、`node-install-failed`、`node-use-after-install-failed` 这类可展示的业务 code。

## 必须修的问题

### P1. JSON plan 和 execute 不是同一个操作，app 无法稳定关联用户确认与实际执行

位置：

- `scripts/node/npm-global-manager.sh:5824`
- `scripts/node/npm-global-manager.sh:6007-6020`
- `scripts/node/npm-global-manager.sh:6408-6420`
- `scripts/node/npm-global-manager.sh:6436-6444`
- `scripts/node/npm-global-manager.sh:6510-6570`

当前行为：

- `plan` 返回 `operationId`。
- `plan install` / `package-plan` 还返回 `logFile`。
- 但 `execute` 完全不接受 plan 的 `operationId` 或 `logFile`，而是在执行时重新生成。
- app 如果按标准流程“plan -> 用户确认 -> execute -> 展示结果”，确认页上的操作 ID 和日志路径都不是最终执行对象。

用户影响：

- macOS app 后续无法用 `operationId` 做稳定追踪、取消、重试、日志跳转或审计。
- 用户确认页显示的 `logFile` 会变成空文件，真实日志在另一个文件里。
- 出问题时 UI 很容易展示“用户确认的是 A，执行结果是 B”的割裂状态。

修复标准：

- 二选一：plan 不返回 `operationId` / `logFile`，只返回纯影响范围；execute 生成真实 operation 元数据。
- 或者建立显式 contract：execute 接收 app 传回的 plan token / operationId，并复用或验证 plan 中的关键字段。
- 不允许继续让 plan 伪装成已经预留了执行操作。

### P1. `--json plan install` 和 `package-plan` 会创建空日志文件，违反只读计划的边界

位置：

- `scripts/node/npm-global-manager.sh:1704-1717`
- `scripts/node/npm-global-manager.sh:6007-6008`
- `scripts/node/npm-global-manager.sh:6665-6680`

当前行为：

- `create_log_file()` 使用 `mktemp`，会真实创建文件。
- `render_action_plan_json install` 在 plan 阶段调用 `create_log_file`。
- `render_package_plan_json` 也在只读计划阶段调用 `create_log_file`。

用户影响：

- 用户只是打开 app 预览安装计划，日志目录就会积累空文件。
- `logs` / `logs-cleanup` 会把这些空 plan 文件当成真实执行日志。
- 这会污染未来 app 的操作历史，不符合“只读展示功能不得修改环境”的设计原则。虽然文件位于 `.runtime` 内，不是系统环境污染，但仍是 plan 副作用。

修复标准：

- plan/package-plan 不创建真实日志文件。
- 如果 UI 需要提前展示未来日志位置，应返回 `logFileHint` 或 `logFileTemplate`，不能创建文件。
- 只有 execute 开始时才创建真实 log。

### P1. 交互式 project `.nvmrc` 仍允许写入非具体版本，和 app boundary contract 不一致

位置：

- `scripts/node/npm-global-manager.sh:5071-5089`
- `scripts/node/npm-global-manager.sh:5118-5147`
- `scripts/node/docs/specs/2026-06-24-app-boundary-and-packaging-contract.md:13-18`

当前行为：

- JSON `project-nvmrc` 已使用 `validate_node_concrete_action_version()`，会拒绝 `lts` 和非具体版本。
- 交互式 `run_project_node_flow()` 仍提示“输入序号或版本号(例如 20 或 20.11.0)”。
- 校验使用 `normalize_node_version()`，允许 `20`、`20.11`。
- 最终 `atomic_write_file "$nvmrc" "$version"` 会把用户输入的非具体版本原样写入 `.nvmrc`。

用户影响：

- 同一个功能在终端和 app 路径上边界不一致。
- `.nvmrc` 写 `20` 或 `20.11` 会随时间和本地安装状态移动，不符合本项目 contract 对可复现性的要求。
- 用户如果从列表选择已安装版本没问题；但手输短版本会留下长期维护风险。

修复标准：

- 交互式 `.nvmrc` 写入也必须使用具体版本。
- 如果用户输入 `20` 或 `20.11`，应解析到已安装的唯一具体版本并在确认页展示实际写入值；无法唯一解析则拒绝。
- 最终写入 `.nvmrc` 的内容必须是 `vX.Y.Z` 或 `X.Y.Z`，不能是 major/minor alias。

### P2. 安装确认页没有完整展示目标版本，用户确认的不是完整影响范围

位置：

- `scripts/node/npm-global-manager.sh:2340-2355`
- `scripts/node/npm-global-manager.sh:2468-2506`
- `scripts/node/npm-global-manager.sh:2550-2557`

当前行为：

- 单包安装先创建日志、展示包名，然后立刻问“确认安装？”。
- `target_version="$(resolve_install_target_version "$package_name")"` 发生在用户确认之后。
- 批量安装会提前解析 target version，但列表只显示 `[待安装] packageSpec`，不展示 target version、当前已安装版本、实际 registry。

用户影响：

- 用户输入 `eslint@latest`、`eslint@next`、`eslint@9` 这类 spec 时，确认前看不到最终解析到哪个版本。
- 批量安装失败时用户无法从确认页判断是 registry 查询问题、版本解析问题，还是已经安装但版本不匹配。
- 这和需求里的“先扫描，再展示，再确认，再执行”不完全对齐。

修复标准：

- 单包安装确认前解析并展示：package spec、规范化 package name、target version、当前已安装版本、global prefix、registry、log 将在执行时创建。
- 批量列表展示每项的 package spec、target version、installed version、状态。
- 解析失败应作为计划阶段问题展示，不要在用户已经确认之后才失败。

### P2. `node-install` JSON execute 缺少业务错误分层

位置：

- `scripts/node/npm-global-manager.sh:2159-2194`
- `scripts/node/npm-global-manager.sh:6520-6531`
- `scripts/node/npm-global-manager.sh:6566-6570`

当前行为：

- `node-use`、`node-uninstall` 已有 `nvm-unavailable`、`node-version-not-installed` 等业务错误。
- `node-install` 直接调用 `install_node_lts` 或 `install_node_version`，失败后统一返回 operation result: `status:"failed"`。
- nvm 未加载、安装命令失败、安装成功但 `nvm use` 失败、安装后版本验证失败，全部无法区分。

用户影响：

- app 只能显示“安装失败”，不能告诉用户是没有 nvm、网络下载失败、版本不存在，还是安装后切换失败。
- 日志里有细节，但 UI 不能可靠做下一步引导。

修复标准：

- 为 JSON `node-install` 增加 pre-execute 检查：`nvm-unavailable`、`invalid-node-install-target`。
- 对 install 和 use 分步捕获，返回 `node-install-failed`、`node-use-after-install-failed`、`node-install-verification-failed`。
- 不可预期命令失败才落到泛化 operation failed。

## 需要继续补齐或收敛的问题

### P2. `run_json_preflight()` 对 plan/execute 没有分层，部分 plan 被执行依赖拦住

位置：

- `scripts/node/npm-global-manager.sh:5468-5508`

当前行为：

- `plan nvm-install` 和 `execute nvm-install` 共用同一组依赖：`curl bash sed mktemp`，配置 SHA 时还要求 `shasum`。
- plan 阶段本质只需要展示当前配置和目标路径，不需要 curl 或 bash 真正可用。

用户影响：

- 在缺少执行依赖的机器上，app 可能连确认页都打不开。
- 更合理的 UX 是 plan 成功，并在 plan 中标出 execute 缺少的依赖。

修复标准：

- `run_json_preflight plan <action>` 和 `run_json_preflight execute <action>` 拆开。
- plan 只要求生成计划所必需的依赖。
- execute 才要求执行依赖。

### P3. 批量安装 summary 的 `warned` 统计按尝试次数累加，不是按包累加

位置：

- `scripts/node/npm-global-manager.sh:2441-2444`
- `scripts/node/npm-global-manager.sh:2600-2621`
- `scripts/node/npm-global-manager.sh:2647-2656`

当前行为：

- 同一个包如果连续多次 `npm install` 返回 0 但验证失败，`warned` 每次尝试都会累加。
- 最终同一个包可能同时计入多次警告和一次失败。

用户影响：

- 批量安装总结不是“包级别总结”，用户会误读失败范围。
- 长期看也会影响 app 的批量结果模型。

修复标准：

- 每个包最终只落一个终态：success / skipped / failed / warning / unknown。
- attempt 级别细节写日志，summary 只统计包。

### P3. 存在未接入的 mutation wrapper，维护边界不够干净

位置：

- `scripts/node/npm-global-manager.sh:1953-1972`

当前行为：

- `install_global_package()`、`upgrade_global_package_to_latest()`、`upgrade_global_package()` 是薄 wrapper。
- 交互流和 JSON execute 基本直接调用 `run_logged_command`，没有复用这些 wrapper。

用户影响：

- 当前不直接造成功能错误。
- 但长期维护时会出现“修了 wrapper，实际路径没变”的错觉。

修复标准：

- 要么删除未使用 wrapper。
- 要么把交互流和 JSON execute 都收敛到同一 mutation helper，确保验证、日志、锁、错误码边界统一。

## 功能完成度判断

- npm 全局包安装：主体可用，但交互确认页没有完整 target version；JSON plan/execute 关联契约不稳。
- 批量安装：串行、安全子集、逐包日志、失败重试都具备；summary 统计和确认页信息还要补。
- 卸载 global package：保护包、元数据、bin、残留候选、后置验证整体完整。
- 更新与升级：`npm outdated -g --json` 语义处理、wanted 升级、latest 升级基本完整。
- registry 与 scope registry：交互和 JSON plan 边界基本完整。
- nvm 安装：固定版本和 SHA 阻断已收口；不再接受任意 subject 造成实际版本分裂。
- Node 安装/切换/卸载：交互路径完整；JSON `node-use` 和 `node-uninstall` 边界已补，`node-install` 还缺业务错误。
- project `.nvmrc`：JSON 路径符合 contract；交互路径仍需只写具体版本。
- 清理：保守策略基本符合需求，日志 cleanup 例外已写入 app boundary spec。
- app 打包边界：runtime 仍在 `scripts/node/.runtime`，manifest 白名单存在；但 plan 空日志会污染未来 app 的日志模型。

## 总评

最新代码不是“为了过测试打补丁”的水平，第八轮问题的修复方向是对的，尤其是 Node action 输入边界已经明显清晰。但要达到稳定 90 分，还必须把 app contract 和交互确认面继续收紧。

最优先要做的是统一 plan/execute 契约：plan 只能是纯计划，要么不返回 operation 元数据，要么 execute 必须复用 plan token。其次是把终端交互和 JSON 路径的 `.nvmrc` 版本边界统一到具体版本。最后补齐 `node-install` 业务错误分层和安装确认页信息。这些不是后续可选优化，而是完整交付质量的一部分。
