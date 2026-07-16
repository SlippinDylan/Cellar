# npm-global-manager.sh 第七轮深度 Review

日期：2026-06-24

范围：

- `scripts/node/npm-global-manager.sh`
- `scripts/node/tests/npm-global-manager-test.sh`
- `scripts/node/run-quality-checks.sh`
- `scripts/node/config/global-packages.txt`
- `scripts/node/docs/specs/*`
- `scripts/node/docs/drafts/*`
- `scripts/node/docs/handoffs/*`
- `scripts/node/docs/plans/*`
- `scripts/node/docs/reviews/2026-06-24-npm-global-manager-sixth-deep-review.md`

结论：第六轮指出的两个 P1 已经修复：JSON uninstall 不存在包会失败，裸包安装会解析 latest target，JSON 错误 envelope 也已经明显收敛。当前脚本比第六轮报告中的 88/100 有进步，我给最新代码约 89/100。它已经接近 90 分，但还没有稳稳站上去，主要卡在三个会影响真实用户或 macOS app 后端契约的点：npm semver/range 版本 spec 处理错误、JSON bootstrap 入口错误依赖 npm、JSON execute 对若干危险动作只返回泛化失败而不是结构化业务错误。

## 联网核对资料

- npm package spec: https://docs.npmjs.com/cli/v11/using-npm/package-spec
- npm install: https://docs.npmjs.com/cli/v11/commands/npm-install/
- npm uninstall: https://docs.npmjs.com/cli/v11/commands/npm-uninstall/
- npm outdated: https://docs.npmjs.com/cli/v11/commands/npm-outdated/
- npm update: https://docs.npmjs.com/cli/v11/commands/npm-update/
- npm config: https://docs.npmjs.com/cli/v11/commands/npm-config/
- npmrc: https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/
- nvm README: https://github.com/nvm-sh/nvm
- nvm releases: https://github.com/nvm-sh/nvm/releases
- Node Corepack: https://nodejs.org/api/corepack.html

核对结论：

- npm package spec 不只是 `package@1.2.3` 和 dist-tag。npm 文档把 `package@version` 归到 semver 语义；用户输入 `eslint@9`、`typescript@5.5` 属于常见 npm 用法，不能被脚本当作安装后版本字符串直接比较。
- `npm install -g <package>` 默认使用 npm 的 tag 配置，通常是 `latest`。脚本现在对裸包 latest 的修复方向正确。
- `npm update -g` 的 wanted/latest 语义和 `npm install -g package@latest` 不等价。交互里的“扫描并升级 wanted”和“指定升级 latest”分开是合理的。
- npm config 的 user/project/global 分层用 `--location=user|project|global` 方向是对的。修改 user 层后继续提示 effective 是否被覆盖是必要行为。
- nvm 是 shell function，检测 `command -v nvm`、加载 `nvm.sh`、不用 `which nvm` 是正确方向。
- `nvm` 安装脚本下载后校验 SHA256 是正确方向；但 JSON execute 不能绕过终端 flow 的未校验阻断逻辑。

## 本轮验证证据

质量门禁：

```bash
bash scripts/node/run-quality-checks.sh
```

结果：

- `bash -n` 通过。
- 测试：`377 passed, 0 failed`。
- ShellCheck：已执行，无报错输出。

额外复现 1：`package@9` 被误当成精确安装版本。

```bash
source scripts/node/npm-global-manager.sh
npm() {
  if [ "$1" = view ]; then printf '9.0.0\n'; return 0; fi
  if [ "$1" = ls ]; then printf '{"dependencies":{"eslint":{"version":"9.2.0"}}}\n'; return 0; fi
  return 0
}
printf 'target='
resolve_install_target_version eslint@9
printf '\nverify='
verify_install_result_for_spec eslint@9 9.2.0 "$(resolve_install_target_version eslint@9)" || true
```

结果：

```text
target=9
verify=failed|安装版本不符合请求|9
```

额外复现 2：无 npm 的机器无法通过 JSON 规划 nvm 安装。

```bash
source scripts/node/npm-global-manager.sh
command_exists() { [ "$1" != npm ]; }
run_json_command plan nvm-install
```

结果：

```json
{"ok":false,"schemaVersion":1,"command":"plan","error":{"code":"missing-dependency","dependencies":["npm"]}}
```

额外复现 3：JSON execute project `.nvmrc` 默认禁用时，业务错误被写进 log，app 只能看到泛化 failed。

```bash
MANAGER_TEST_UNAME=Darwin NODE_MANAGER_ALLOW_JSON_EXECUTE=1 NODE_MANAGER_ALLOW_PROJECT_WRITE=0 \
  bash scripts/node/npm-global-manager.sh --json execute project-nvmrc /tmp/demo 20.11.1
```

结果：

```json
{"ok":false,"schemaVersion":1,"command":"execute","error":{"operationId":"...","action":"project-nvmrc","subject":"/tmp/demo","exitCode":1,"status":"failed","logFile":"..."}}
```

额外复现 4：JSON nvm-install execute 可绕过终端 flow 的未校验安装阻断。

```bash
MANAGER_TEST_UNAME=Darwin NODE_MANAGER_ALLOW_JSON_EXECUTE=1 NVM_INSTALL_SHA256= NVM_ALLOW_UNVERIFIED_INSTALL=0 \
  bash -lc 'source scripts/node/npm-global-manager.sh; install_nvm_official() { printf "INSTALL_CALLED\n"; return 0; }; run_json_command execute nvm-install'
```

结果：返回 `ok:true` / `status:"ok"`。这个复现用 mock 避免真实下载，但证明 `render_execute_json nvm-install` 没有执行 `run_install_nvm_flow()` 里的 SHA256 gate。

## 已经闭环的问题

- JSON uninstall 现在会拒绝不存在包：`package-not-installed`。
- 裸包 `eslint` 现在会解析 registry latest，并用 targetVersion 判断 alreadyInstalled。
- JSON 错误 envelope 已从双层 `error.ok:false` 收敛成单层 `code` payload。
- 非 package 类动作已有 JSON plan/execute 入口：registry、scope registry、nvm install、Node install/use/uninstall、cleanup、project-nvmrc。
- registry HTTP 策略和提示已对齐：默认 HTTPS，本机调试允许 `localhost` / `127.0.0.1` HTTP。
- 运行时目录、日志、tmp、lock 都收在 `scripts/node/.runtime`。
- app 打包边界已有 `app-bundle-manifest.txt` 和独立 spec。

## 必须修的问题

### P1. npm semver/range spec 被误当成精确版本，合法安装会被误判失败

位置：

- `scripts/node/npm-global-manager.sh:1543-1575`
- `scripts/node/npm-global-manager.sh:1577-1599`
- `scripts/node/npm-global-manager.sh:1606-1617`
- `scripts/node/npm-global-manager.sh:2227-2346`
- `scripts/node/npm-global-manager.sh:2352-2588`
- `scripts/node/npm-global-manager.sh:5577-5639`
- `scripts/node/npm-global-manager.sh:5966-6009`

当前行为：

- `requested_package_version_is_exact()` 把 `9`、`9.0` 这类 semver shorthand 视作 exact。
- `resolve_install_target_version eslint@9` 直接返回 `9`，不查 registry。
- 安装后实际版本只可能是类似 `9.2.0`，于是 `verify_install_result_for_spec()` 判失败。

用户影响：

- 真实用户常会输入 `eslint@9`、`typescript@5`、`vite@5.4`。
- 这些 npm 合法输入在脚本中会出现“npm 安装成功，但脚本说失败”的反直觉结果。
- JSON plan 会给 app 错误的 `targetVersion:"9"`，确认页不可信。
- 批量清单里写 `package@9` 会导致批量安装反复失败或跳过判断不准。

修复标准：

- 只把完整精确版本视为 exact，例如 `1.2.3`、`1.2.3-beta.1`、`1.2.3+build.1`。
- 对 `1`、`1.2`、`1.x` 等 semver range/shorthand，要么明确拒绝并提示仅支持完整版本或 tag，要么通过 `npm view <spec> version` 解析成具体目标版本。
- 如果选择支持 range，不能用 `sed -n '1p'` 随便取第一行；需要稳定取 npm 将安装的目标版本，否则确认页仍可能错。
- 补测试：`eslint@9` 不能得到 `targetVersion:"9"`；安装后 `9.2.0` 不应因目标字符串 `9` 被误判。

### P1. JSON bootstrap 入口错误要求 npm，导致无 Node/npm 机器无法从 app 安装 nvm

位置：

- `scripts/node/npm-global-manager.sh:5330-5364`
- `scripts/node/npm-global-manager.sh:5366-5427`
- `scripts/node/npm-global-manager.sh:5487-5575`
- `scripts/node/npm-global-manager.sh:5966-6138`

当前行为：

- `run_json_preflight()` 只按 JSON command 名称判断依赖。
- `plan` / `execute` 除 summary/status/logs 外统一要求 `ruby npm sed mktemp`。
- `--json plan nvm-install` 和 `--json execute nvm-install` 在没有 npm 时直接失败。

用户影响：

- 新机器最需要的路径是：安装 nvm -> 安装 Node -> 才有 npm。
- 后续 macOS app 如果通过 JSON contract 驱动脚本，在干净机器上无法展示 nvm 安装确认页。
- 这和终端交互层不一致：终端启动预检只把 `node/npm/curl/ruby/shasum` 作为 warn，不阻断环境安装入口。

修复标准：

- JSON preflight 必须按 action 细分，而不是只看 `plan` / `execute`。
- `nvm-install` plan/execute 只要求 `curl bash shasum sed mktemp` 等真实依赖，不能要求 npm。
- `node-install` / `node-use` / `node-uninstall` 应要求 nvm 可加载或返回结构化 `nvm-unavailable`，不应被 npm preflight 抢先阻断。
- package 类动作才要求 npm；需要解析 npm JSON 的动作才要求 Ruby，或者提供无 Ruby 的明确降级策略。

### P1. JSON nvm-install execute 绕过未校验安装脚本阻断

位置：

- `scripts/node/npm-global-manager.sh:19-22`
- `scripts/node/npm-global-manager.sh:1993-2038`
- `scripts/node/npm-global-manager.sh:3787-3905`
- `scripts/node/npm-global-manager.sh:6086-6092`

当前行为：

- 终端 flow 在 `run_install_nvm_flow()` 中阻断 `NVM_INSTALL_SHA256=""` 且 `NVM_ALLOW_UNVERIFIED_INSTALL!=1`。
- JSON execute 直接调用 `install_nvm_official`，而 `install_nvm_official` 本身不检查 `NVM_ALLOW_UNVERIFIED_INSTALL`。
- 因此 JSON 路径和交互路径的供应链安全边界不一致。

用户影响：

- macOS app 后端可能在环境变量配置错误时执行未校验远程脚本。
- 这类问题不是普通功能缺陷，是供应链边界缺陷。

修复标准：

- SHA256 gate 必须下沉到 `install_nvm_official()` 或共享动作层，不能只放在交互函数。
- JSON nvm-install plan 应明确返回 `sha256Configured:true/false`、`allowUnverified:false`、`installUrl`、`version`。
- execute 如果无 SHA 且未显式允许，必须返回结构化错误，例如 `nvm-install-unverified-blocked`。

## 需要继续补齐或收敛的问题

### P2. JSON execute 失败丢失业务错误，只返回泛化 operation result

位置：

- `scripts/node/npm-global-manager.sh:5802-5845`
- `scripts/node/npm-global-manager.sh:5847-5895`
- `scripts/node/npm-global-manager.sh:5935-5954`
- `scripts/node/npm-global-manager.sh:6086-6131`

当前行为：

- `project-nvmrc` 默认禁用时，`write_project_nvmrc_json_action()` 输出 `project-write-disabled`，但调用方把它重定向进 log。
- JSON envelope 返回的是 `status:"failed"` 和 `logFile`，没有 `code`。
- `node-uninstall`、`cleanup` 等动作也存在类似问题：业务失败原因容易进入 log，而不是机器可读 error payload。

用户影响：

- app 不能可靠区分“用户未授权外部写入”“nvm 不可用”“默认版本不能卸载”“锁冲突”“路径不安全”。
- UI 只能展示泛化失败，再让用户打开 log。对危险动作来说这不符合“执行后结构化总结”的要求。

修复标准：

- 动作层返回结构化结果，而不是把业务错误 print 到 stdout 后再整体重定向到 log。
- 失败 envelope 应保留 `code`、`action`、`subject`、必要上下文和 `logFile`。
- log 只保存命令输出和诊断细节，不能成为 app 判断业务失败的唯一来源。

### P2. JSON plan 对危险动作的影响范围仍过薄

位置：

- `scripts/node/npm-global-manager.sh:5487-5575`
- `scripts/node/npm-global-manager.sh:5577-5639`

当前行为：

- `registry-delete` plan 只返回 `targetType:"npm-registry"` 和 `subject:"registry"`，不展示当前 user/effective registry。
- `scope-registry-delete` plan 不展示当前 user/effective scope registry。
- `node-uninstall` plan 不展示 current/default 保护判断、版本目录、体积、该版本下全局包摘要。
- `cleanup` plan 不列出将处理的 cache 路径、node-gyp 候选、orphan bins、nvm old versions 候选。
- `project-nvmrc` plan 不检查路径是否存在，也不展示现有 `.nvmrc` / `package.json engines.node`。

用户影响：

- 终端交互层基本做到了“先展示影响范围”，但 app JSON plan 还没有做到同等安全水位。
- 后续 app 如果只看 JSON plan，会把很多危险动作做成“确认按钮 + 泛化标题”，没有足够上下文。

修复标准：

- 每个危险动作的 plan 都应复用交互层的扫描/计划逻辑，至少返回当前值、目标值、受影响路径、保护判断、是否 externalWrite。
- execute 前必须重新校验关键前置条件，不能只信 plan。
- plan 的结构应按 action 细分，不要只用 `subject/value` 两个泛化字段承载所有语义。

### P2. `nvm-install` plan/execute subject 不一致

位置：

- `scripts/node/npm-global-manager.sh:5526-5529`
- `scripts/node/npm-global-manager.sh:6086-6092`

当前行为：

- `--json plan nvm-install` 返回 `subject:"v0.40.5"`。
- `--json execute nvm-install` 无参数时返回 `subject:""`，log subject 为 `default`。

用户影响：

- app 确认页展示的 subject 和执行结果 subject 对不上。
- operation history 难以按版本聚合。

修复标准：

- execute 也应规范化 subject：无参数时使用 `$NVM_INSTALL_VERSION`。
- log 文件名、operationId、result subject 都使用同一个规范化值。

### P2. `install_nvm_official()` 单元测试鼓励不安全直调

位置：

- `scripts/node/tests/npm-global-manager-test.sh:1313-1327`
- `scripts/node/npm-global-manager.sh:1993-2038`

当前行为：

- 测试直接设置 `NVM_INSTALL_SHA256=''` 后调用 `install_nvm_official`，并断言 mocked 下载脚本会执行。
- 这和后面新增的 `run_install_nvm_flow` 安全阻断测试相互矛盾。

用户影响：

- 测试会保护一个不应被保护的行为：共享动作函数可以未校验执行下载脚本。
- 这也是 JSON nvm-install execute 漏洞能留下来的原因之一。

修复标准：

- 改测试语义：`install_nvm_official` 本身必须阻断未校验路径。
- 如确实需要测试 mock 成功路径，应给出 mock SHA 或显式设置 `NVM_ALLOW_UNVERIFIED_INSTALL=1`，并测试默认不允许。

### P2. 交互层和 JSON 层仍存在双实现，修复容易漏一边

位置：

- `scripts/node/npm-global-manager.sh:2227-2588`
- `scripts/node/npm-global-manager.sh:2632-3037`
- `scripts/node/npm-global-manager.sh:3073-3357`
- `scripts/node/npm-global-manager.sh:3481-3739`
- `scripts/node/npm-global-manager.sh:3787-5098`
- `scripts/node/npm-global-manager.sh:5487-6138`

当前行为：

- install/update/uninstall/registry/node/cleanup 交互层和 JSON 层有大量平行业务逻辑。
- 第六轮的 uninstall 和 latest 修复已经补了部分 JSON 漏口，但整体动作层还没有真正收口。

用户影响：

- 后续修复某个危险动作时，仍可能只修交互或只修 JSON。
- app 交付后，终端行为和 app 行为可能长期漂移。

修复标准：

- 抽出共享动作层：build plan、execute、verify、summarize。
- 交互层只做人类输入和文本渲染。
- JSON 层只做 envelope 和机器可读渲染。
- 优先收口供应链动作、Node 版本动作、cleanup 动作。

### P3. 内部 renderer 在 `set -u` 下缺省参数会崩溃

位置：

- `scripts/node/npm-global-manager.sh:5577-5580`
- `scripts/node/npm-global-manager.sh:5966-5969`

当前行为：

- `render_action_plan_json()` 和 `render_execute_json()` 用 `$1` / `$2` 读取必填参数。
- CLI 入口 `run_json_command` 传了 `"${2:-}"`，所以正常 CLI 不触发。
- 但测试、未来 app wrapper 或维护脚本直接 source 后调用这些函数时，会因 `set -u` 报 `unbound variable`。

用户影响：

- 当前用户从 CLI 不容易触发，但维护者写测试或复用函数时容易踩。
- 这类内部 API 边界不清，会拖慢后续拆动作层。

修复标准：

- renderer 入参统一写成 `local action="${1:-}"`、`local subject="${2:-}"`。
- 缺必填参数返回结构化 `missing-argument`，不要 shell 崩溃。

### P3. cleanup JSON 的 `logs` target 不应走 execute gate

位置：

- `scripts/node/npm-global-manager.sh:5476-5485`
- `scripts/node/npm-global-manager.sh:5847-5895`
- `scripts/node/npm-global-manager.sh:6196-6206`

当前行为：

- 已有专门的 `--json logs-cleanup [keep-count]`。
- 同时 `cleanup` target 也允许 `logs`，并要求 `NODE_MANAGER_ALLOW_JSON_EXECUTE=1`。

用户影响：

- app 侧会出现两个清理日志的入口，一个需要 execute 确认，一个不需要。
- 语义重复会增加 wrapper 复杂度。

修复标准：

- 二选一：保留 `logs-cleanup` 作为唯一日志清理 JSON 命令；或让 `cleanup logs` 成为它的薄代理并文档说明。
- 如果保留两个入口，plan/execute 的确认策略要一致。

## 当前功能完成度判断

已达到较高完成度：

- 启动摘要、主菜单、子菜单。
- 环境总览和 nvm 诊断。
- 单包安装、批量安装、失败重试、安装后验证。
- 全局包扫描、卸载前元数据、bin 快照、残留候选与清理。
- outdated 扫描、wanted 升级、latest 升级。
- registry / scope registry 查看、切换、删除、分层提示。
- nvm 安装、Node 安装、切换、卸载。
- npm cache、node-gyp、orphan bin、nvm old versions 清理。
- JSON 基础查询、package plan/execute、非 package plan/execute 初版。
- 运行时目录边界、日志、锁、ShellCheck 安装校验、质量检查。

仍未达到“完整 90+ 交付”的部分：

- npm semver/range package spec 的 target 解析和验证。
- JSON bootstrap actions 的按 action 依赖预检。
- JSON nvm-install 的 SHA256 gate 下沉到动作层。
- JSON execute 失败业务 code 的保留。
- JSON plan 对危险动作影响范围的完整表达。
- 交互层和 JSON 层共享动作层的结构收口。
- `nvm-install` execute subject 规范化。
- 内部 renderer 缺省参数边界。
- cleanup logs JSON 入口去重或语义统一。

## 总评

最新脚本已经有相当多工程化基础：测试数量足、危险删除路径有快照校验、运行产物收在 `scripts/node/.runtime`、供应链校验也比早期强很多。它的问题不是“功能没堆完”，而是几个边界还没有按同一个动作层模型闭合。

要达到 90 分以上，不建议继续加菜单分支。优先修三个点：

1. 修 npm semver/range target 解析，避免合法 `package@9` 被误判。
2. 修 JSON preflight，确保 nvm/Node bootstrap 不依赖 npm。
3. 把 nvm-install SHA256 gate 下沉到共享动作函数，并让 JSON execute 保留业务错误 code。

这三项修完并补行为测试后，我认为可以达到 90 分；再把危险动作 JSON plan 的影响范围补齐并收口共享动作层，质量可以进入 92 分以上。
