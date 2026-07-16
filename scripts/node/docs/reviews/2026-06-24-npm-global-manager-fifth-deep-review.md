# npm-global-manager.sh 第五轮深度 Review

日期：2026-06-24

范围：

- `scripts/node/npm-global-manager.sh`
- `scripts/node/tests/npm-global-manager-test.sh`
- `scripts/node/run-quality-checks.sh`
- `scripts/node/tools/install-shellcheck.sh`
- `scripts/node/docs/specs/*`
- `scripts/node/docs/drafts/*`
- `scripts/node/docs/reviews/2026-06-18-npm-global-manager-fourth-deep-review.md`

结论：第四轮指出的主流程问题基本已经收敛，当前脚本主体质量已经接近 90+。但我不建议现在打 90+，原因很明确：`--json` 失败路径会输出非法 JSON，这是未来 macOS app 直接调用时的契约级 bug。按 100 分算，我给当前产物约 89/100；修掉 JSON 失败 envelope 并补 parser 级测试后，可以进入 91/100 左右。

## 联网核对资料

- npm package spec: https://docs.npmjs.com/cli/v11/using-npm/package-spec
- npm install: https://docs.npmjs.com/cli/v11/commands/npm-install/
- npm ls: https://docs.npmjs.com/cli/v11/commands/npm-ls/
- npm outdated: https://docs.npmjs.com/cli/v11/commands/npm-outdated/
- npm update: https://docs.npmjs.com/cli/v11/commands/npm-update/
- npm config: https://docs.npmjs.com/cli/v11/commands/npm-config/
- npmrc: https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/
- nvm README: https://github.com/nvm-sh/nvm
- ShellCheck release: https://github.com/koalaman/shellcheck/releases/tag/v0.11.0

核对结论：

- npm 官方 package spec 支持的形态远多于本脚本允许的安全子集。本脚本拒绝 git、file、tarball、alias、URL spec 是合理的产品边界，但 JSON plan/execute 必须稳定报告拒绝原因。
- `npm ls -g --depth=0 --json`、`npm outdated -g --json` 是正确的数据源方向；当前代码对 stdout、空输出、stderr、非法 JSON 的处理比前几轮明显更稳。
- nvm 安装路径现在避免 `curl | bash`，并对 `v0.40.5` install.sh 做 SHA256 校验，方向正确。
- ShellCheck 已经通过本地 bundled 版本执行；但 bundled installer 本身还缺下载完整性校验。

## 本轮验证证据

执行：

```bash
bash scripts/node/run-quality-checks.sh
```

结果：

- `bash -n` 通过。
- 测试：`335 passed, 0 failed`。
- ShellCheck：已执行 `scripts/node/.runtime/tools/shellcheck/shellcheck`，版本 `0.11.0`，无输出错误。

额外 JSON parser 级验证：

```bash
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json summary | ruby -rjson -e 'JSON.parse(STDIN.read)'
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json status | ruby -rjson -e 'JSON.parse(STDIN.read)'
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json logs 5 | ruby -rjson -e 'JSON.parse(STDIN.read)'
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json logs-cleanup 999999 | ruby -rjson -e 'JSON.parse(STDIN.read)'
```

结果：以上 4 个只读/低风险 JSON 命令均可被 `JSON.parse` 接受。

失败路径验证：

```bash
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json package-plan 'eslint@' | ruby -rjson -e 'JSON.parse(STDIN.read)'
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json execute install eslint | ruby -rjson -e 'JSON.parse(STDIN.read)'
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json plan nope eslint | ruby -rjson -e 'JSON.parse(STDIN.read)'
```

结果：以上失败路径均解析失败，Ruby 报 `JSON::ParserError: unexpected token at '}'`。

## 已经明显闭环的问题

- `npm_package_is_installed()` 已统一丢弃 `npm ls` stdout，解决真实 `npm ls` 输出污染布尔判断的问题。
- `is_install_spec_satisfied()` 已把裸包、精确版本、dist-tag 解析目标版本纳入同一判断。
- 批量安装现在会预解析目标版本；`all` 选择的是待安装项，而不是全量清单。
- `render_package_plan_json` 已输出 `targetVersion`，并按请求版本判断 `alreadyInstalled`。
- JSON preflight 已改成单个错误对象，不再输出多段 JSON。
- unsupported JSON command 已有稳定 envelope。
- 交互 install/update/uninstall 菜单入口已经补了 Ruby 能力检查。
- `logs-cleanup` JSON 命令已暴露。
- `run-quality-checks.sh` 现在会优先使用本目录 bundled ShellCheck，实际质量门禁比第四轮强。
- nvm 官方安装脚本已有默认 SHA256，未配置校验时默认阻断。

## 必须修的问题

### P1. `run_json_command` 失败包装会输出非法 JSON

位置：

- `scripts/node/npm-global-manager.sh:5326-5328`
- `scripts/node/npm-global-manager.sh:5376-5377`

当前输出例子：

```json
{"ok":false,"schemaVersion":1,"command":"package-plan","error":{"ok":false,"error":"invalid-safe-package","packageSpec":"eslint@","allowed":"registry package safe subset: package, @scope/package, package@version, @scope/package@tag"}}}
```

末尾多了一个 `}`，不是合法 JSON。

已复现的坏路径：

- `--json package-plan eslint@`
- `--json execute install eslint` 默认禁用路径
- `--json plan nope eslint`
- mocked 缺依赖 preflight：`command_exists() { return 1; }; run_json_command packages`

根因不是业务逻辑，而是 Bash 参数展开写法：

```bash
"${output:-{\"error\":\"command-failed\"}}"
```

`${...}` 的默认值里包含未转义的 `}`，Bash 会把它当成参数展开结束符，导致多出来的 `}` 变成字面量。即使 `output` 非空，这个字面量也会被拼进参数。

用户影响：

- macOS app 端只要调用失败路径，就会直接 JSON parse 失败。
- 错误不是结构化错误，而是协议损坏；app 无法稳定展示“包名非法”“execute 未启用”“缺依赖”等原因。
- 当前测试全绿不能代表 app contract 可靠，因为测试只做 substring 和行数断言，没有 parser 级断言。

修复标准：

- 不要在 `${var:-...}` 里内联 JSON 字面量。
- 用局部变量保存 fallback，例如 `fallback_error='{"error":"command-failed"}'`，再传 `"${output:-$fallback_error}"`。
- preflight fallback 同理。
- 对所有 `run_json_command` 成功和失败路径补 `JSON.parse` 断言。

### P1. JSON execute uninstall 仍未完成 app 后端能力

位置：

- `scripts/node/npm-global-manager.sh:5471-5474`
- `scripts/node/npm-global-manager.sh:5523-5526`
- `scripts/node/npm-global-manager.sh:5176-5177`

当前状态：

- `plan uninstall` 会明确标记 `executeSupported:false`。
- `execute uninstall` 返回 `json-uninstall-execute-disabled`。

这个选择比写一个危险薄实现更好，但从“后面做 macOS app”的目标看，功能仍缺口明显。交互卸载已经有较完整的安全链路：扫描、保护包、metadata、bin 快照、目录快照、执行、后置验证、残留候选、复验删除。JSON execute uninstall 没有复用这套能力。

修复标准：

- 把交互卸载中的 plan/capture/execute/verify/residue cleanup 拆成共享动作层。
- 交互层只负责读输入和渲染。
- JSON 层调用同一套动作层，而不是另写一条弱路径。

### P1. `tools/install-shellcheck.sh` 下载二进制没有校验

位置：

- `scripts/node/tools/install-shellcheck.sh:31-39`

当前实现：

```bash
curl -fL "$download_url" -o "$archive_path"
tar -xJf "$archive_path" -C "$DOWNLOAD_DIR"
cp "$DOWNLOAD_DIR/$release_name/shellcheck" "$SHELLCHECK_DIR/shellcheck"
chmod +x "$SHELLCHECK_DIR/shellcheck"
```

问题：

- 下载 release asset 后直接解压复制，没有 SHA256 或签名校验。
- 主脚本的 nvm installer 已经要求 `NVM_INSTALL_SHA256`，但 ShellCheck 工具链 installer 没有同等级供应链边界。
- 这不是 npm manager 运行时高危 bug，但它会影响质量门禁可复现性和长期可信度。

修复标准：

- 至少为 `v0.11.0` 的四个平台 asset 内置 SHA256。
- 允许显式 override，但默认必须校验。
- 下载后先校验 archive，再解压。

## 需要继续补齐或收敛的问题

### P2. JSON 测试仍没有覆盖 parser 级失败路径

位置：

- `scripts/node/tests/npm-global-manager-test.sh:1885-1903`
- `scripts/node/tests/npm-global-manager-test.sh:1921-1929`

当前测试能验证：

- 单行输出。
- 包含 `command`。
- 包含 `dependencies`。
- unsupported command 有 envelope。

但它没有验证输出能被 JSON parser 接受，所以 P1 这种多一个 `}` 的 bug 直接漏掉了。

修复标准：

- 增加测试 helper，例如 `assert_valid_json_document`。
- 对以下命令全部做 `JSON.parse`：
  - `summary`
  - `status`
  - `logs`
  - `logs-cleanup`
  - `packages`
  - `outdated`
  - `config`
  - `package-plan` 成功与失败
  - `plan` 成功与失败
  - `execute` disabled、install/update 成功失败、uninstall disabled
  - preflight missing dependency
  - unsupported command

### P2. JSON 错误对象模型还不够干净

位置：

- `scripts/node/npm-global-manager.sh:5229-5239`
- `scripts/node/npm-global-manager.sh:5420-5451`
- `scripts/node/npm-global-manager.sh:5480-5553`
- `scripts/node/npm-global-manager.sh:5623-5657`

现状：renderer 失败时经常输出 `{"ok":false,"error":"..."}`，外层 `run_json_command` 再包成：

```json
{"ok":false,"schemaVersion":1,"command":"...","error":{"ok":false,"error":"..."}}
```

即使修掉多余 `}`，这个模型也不够优雅。`error` 里再放一个 `ok:false` 没有信息增益，app 侧要多处理一层历史包袱。

修复标准：

- renderer 失败时输出纯 error payload，例如 `{"code":"invalid-package-spec","packageSpec":"eslint@"}`。
- `run_json_command` 是唯一 envelope 生成点。
- 所有错误至少有稳定 `code` 字段。

### P2. 动作层边界仍然偏厚，长期维护压力集中在几个超长函数

位置：

- `run_uninstall_flow`: `scripts/node/npm-global-manager.sh:2620-3026`，约 407 行
- `run_batch_install_flow`: `scripts/node/npm-global-manager.sh:2340-2581`，约 242 行
- `run_upgrade_scan_flow`: `scripts/node/npm-global-manager.sh:3061-3267`，约 207 行
- `run_project_node_flow`: `scripts/node/npm-global-manager.sh:4890-5091`，约 202 行

评价：这些函数已经不是随手堆出来的面条代码，内部有安全快照、验证、锁、摘要，工程方向是对的。但 UI、plan、execute、verify、summary 仍混在同一个函数里。继续加 JSON app 能力时，维护者会很自然地复制交互逻辑或绕过交互逻辑。

修复标准：

- install/update/uninstall 至少拆出共享 helper：
  - build plan
  - capture metadata/snapshot
  - execute mutation
  - verify result
  - render human summary / render JSON result
- 交互层不直接操作 npm 业务细节。

### P2. `scripts/node` 工作区卫生仍需要收口

位置：

- `scripts/node/.runtime/`
- `scripts/node/.DS_Store`
- `scripts/node/docs/.DS_Store`
- `scripts/node/tests/.DS_Store`
- `scripts/node/.gitignore`

现状：

- `.gitignore` 已忽略 `.runtime/` 和 `.DS_Store`，所以不会被正常提交。
- 但本地目录里确实已经积累大量 runtime logs/tmp/tooling artifacts。

影响：

- 对 git 影响不大。
- 对“后续打包成 macOS app”有影响：如果打包脚本粗暴复制整个 `scripts/node`，会把 runtime 垃圾、临时日志、工具链下载缓存带进 app。

修复标准：

- app 打包时只白名单复制脚本、配置、docs/tests 是否按需选择。
- 不要把 `.runtime` 当源码资产。

### P2. 项目 `.nvmrc` 写入是有意越界入口，需要 app 权限模型

位置：

- `scripts/node/npm-global-manager.sh:4894-4900`
- `scripts/node/npm-global-manager.sh:4999-5001`
- `scripts/node/npm-global-manager.sh:5051-5059`

当前状态：默认禁用，必须设置 `NODE_MANAGER_ALLOW_PROJECT_WRITE=1` 才会写项目目录。这已经符合“所有输出默认限制在 scripts/node 内”的约束。

需要注意：未来 app 化时，这个入口不能和普通 runtime 输出混在一起。它是明确的用户授权写入项目动作，需要单独权限提示、路径确认和回滚策略。

## 当前未完成或仍不完善的功能清单

- JSON 失败响应：目前存在非法 JSON，必须修。
- JSON execute uninstall：仍禁用，app 后端还不完整。
- JSON 错误模型：`error` payload 里嵌 `ok:false`，需要统一成 `code` 风格。
- JSON parser 测试：缺少覆盖失败路径的 `JSON.parse` 断言。
- ShellCheck installer：缺二进制下载校验。
- 动作层抽象：交互主流程已经可用，但 install/update/uninstall 仍需拆出共享动作层，避免 app 路径复制逻辑。
- app 打包卫生：`.runtime` 和 `.DS_Store` 虽已忽略，但打包时必须白名单。

## 最终判断

这个版本已经不是“为了过测试打补丁”的状态。安装、批量安装、卸载、升级、源管理、nvm/Node 环境管理这些主线都有真实安全设计，测试数量和质量门禁也明显超过普通 shell 脚本水平。

但 90+ 的前提是 app-facing JSON contract 不能坏。当前 `run_json_command` 失败路径输出非法 JSON，这一项必须先修。修复它、补 parser 级测试、给 ShellCheck installer 加 checksum 后，我会把这个脚本评到 91/100 左右；如果再把卸载 JSON execute 接到共享安全动作层，可以继续往 93-94 靠。
