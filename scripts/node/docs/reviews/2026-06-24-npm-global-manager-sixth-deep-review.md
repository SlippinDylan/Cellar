# npm-global-manager.sh 第六轮深度 Review

日期：2026-06-24

范围：

- `scripts/node/npm-global-manager.sh`
- `scripts/node/tests/npm-global-manager-test.sh`
- `scripts/node/run-quality-checks.sh`
- `scripts/node/tools/install-shellcheck.sh`
- `scripts/node/docs/specs/*`
- `scripts/node/docs/drafts/*`
- `scripts/node/docs/plans/*`
- `scripts/node/docs/reviews/2026-06-24-npm-global-manager-fifth-deep-review.md`

结论：第五轮指出的 JSON 非法输出、JSON uninstall execute 禁用、ShellCheck 下载无校验等主问题已经修掉，当前质量门禁是绿的。按 100 分算，我现在给当前脚本约 88/100。不是因为脚本不可用，而是因为仍有两个会影响 macOS app 后端契约的 P1：JSON 卸载不存在的包会误报成功；裸包安装计划不解析 latest 目标版本，导致确认页和已安装判断不可信。这两个不修，不建议标成 90 分交付。

## 联网核对资料

- npm package spec: https://docs.npmjs.com/cli/v11/using-npm/package-spec
- npm install: https://docs.npmjs.com/cli/v11/commands/npm-install/
- npm uninstall: https://docs.npmjs.com/cli/v11/commands/npm-uninstall/
- npm outdated: https://docs.npmjs.com/cli/v11/commands/npm-outdated/
- npm update: https://docs.npmjs.com/cli/v11/commands/npm-update/
- npm config: https://docs.npmjs.com/cli/v11/commands/npm-config/
- npmrc: https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/
- nvm README: https://github.com/nvm-sh/nvm
- nvm latest release API: https://api.github.com/repos/nvm-sh/nvm/releases/latest
- Node Corepack: https://nodejs.org/api/corepack.html

核对结论：

- 脚本把 npm package spec 收窄成 registry 安全子集是合理的，不需要支持 git/file/tarball/alias/URL spec。
- `npm install -g <package>` 的裸包语义应按 registry 默认 tag/latest 处理；app 计划层不能把裸包目标版本留空。
- `npm uninstall -g <package>` 是删除动作，但 npm 对“本来就未安装”的情况不一定给出业务失败；脚本必须自己用全局清单建立“卸载对象存在”的前置条件。
- npm registry、scope registry 和 `.npmrc` 分层使用 `npm config` / `--location` 的方向是对的。
- nvm 安装使用官方安装脚本、下载后校验 SHA256、当前进程加载 `nvm.sh` 的方向是对的。
- `corepack` 作为保护包符合当前需求文档，但后续 app 里要注意 Node 版本差异和用户手动安装的 corepack 场景。

## 本轮验证证据

执行：

```bash
bash scripts/node/run-quality-checks.sh
```

结果：

- `bash -n` 通过。
- 测试：`354 passed, 0 failed`。
- ShellCheck：已执行且无报错输出。

额外复现：

```bash
MANAGER_TEST_UNAME=Darwin bash scripts/node/npm-global-manager.sh --json plan uninstall definitely-not-installed-package-xyz
```

结果：返回 `ok:true`，`installedVersion:""`，`executeSupported:true`。

```bash
MANAGER_TEST_UNAME=Darwin NODE_MANAGER_ALLOW_JSON_EXECUTE=1 bash scripts/node/npm-global-manager.sh --json execute uninstall definitely-not-installed-package-xyz
```

结果：返回 `ok:true`，内部 `status:"ok"`，但 `installedVersion:""`。

```bash
source scripts/node/npm-global-manager.sh
npm() {
  if [ "$1" = ls ]; then printf '{"dependencies":{"eslint":{"version":"8.0.0"}}}\n'; return 0; fi
  if [ "$1" = view ]; then printf '9.0.0\n'; return 0; fi
  if [ "$1" = root ]; then printf '/tmp/root\n'; return 0; fi
  if [ "$1" = prefix ]; then printf '/tmp/prefix\n'; return 0; fi
  return 0
}
render_package_plan_json eslint
```

结果：`targetVersion:""` 且 `alreadyInstalled:true`，即使 registry latest 可解析为 `9.0.0`。

## 已经明显闭环的问题

- 第五轮的非法 JSON 问题已修：失败路径现在能被 JSON parser 接受。
- `--json execute uninstall` 已经实现，不再是禁用占位。
- `tools/install-shellcheck.sh` 已内置 `v0.11.0` 多平台 SHA256 并做校验。
- JSON parser 级测试已补上，覆盖了多条成功和失败路径。
- `run_logged_command()` 已集中识别 `npm install/uninstall/update/cache` 和 `nvm install/uninstall/use/alias`，自动持有 mutation lock。
- `run-quality-checks.sh` 没有静默跳过 ShellCheck。

## 必须修的问题

### P1. JSON 卸载不存在的包会误报成功

位置：

- `scripts/node/npm-global-manager.sh:5435-5474`
- `scripts/node/npm-global-manager.sh:5542-5558`
- `scripts/node/npm-global-manager.sh:5560-5565`

当前行为：

- `render_action_plan_json uninstall <pkg>` 只校验包名格式和保护包，没有要求包已安装。
- `render_uninstall_execute_json()` 读取 `installed_version` 后没有前置阻断。
- 如果 npm 对未安装包返回 exit 0，脚本会输出 `status:"ok"`。

用户影响：

- macOS app 的确认页会允许用户执行一个不存在的卸载计划。
- 执行页会把“什么都没删”展示成成功。
- 这会破坏用户对危险动作总结页的信任。

修复标准：

- `plan uninstall` 如果 `get_installed_global_package_version` 为空，返回 `ok:false`，稳定 code 例如 `package-not-installed`。
- `execute uninstall` 必须再次做同样的存在性前置校验，不能只依赖 plan。
- 对 JSON plan 和 execute 都补测试：未安装包必须失败且 JSON parseable。
- 交互卸载当前通过列表选择规避了这个问题；JSON 层必须补同等前置条件。

### P1. 裸包安装不解析 latest 目标版本，导致 plan/verify 语义过弱

位置：

- `scripts/node/npm-global-manager.sh:1548-1557`
- `scripts/node/npm-global-manager.sh:5799-5822`
- `scripts/node/npm-global-manager.sh:5435-5455`

当前行为：

```bash
[ -n "$requested" ] || return 0
```

裸包 `eslint` 没有 requested tag/version 时，`resolve_install_target_version` 直接成功但输出空字符串。后果：

- `targetVersion` 为空。
- `package-plan eslint` 无法告诉 app 将安装哪个版本。
- 如果本地已有旧版本，`is_install_spec_satisfied` 会把任意已安装版本视为满足裸包 spec。
- `execute install eslint` 的安装后验证只确认能读到版本，不确认是否达到 registry 默认目标。

用户影响：

- app 确认页不完整：用户看不到将安装/升级到哪个版本。
- 批量清单如果写裸包名，旧版本可能被跳过，和用户“安装默认最新 registry 包”的直觉不一致。
- 验证层弱化，npm 命令 exit 0 后更容易误判成功。

修复标准：

- 裸包 spec 应解析 `npm view <package> version` 作为 target。
- `package@tag` 继续解析 tag 到具体版本。
- `package@1.2.3` 继续直接使用精确版本。
- 如果无法解析 target，应明确失败或标记为 `target-version-unavailable`，不要用空 target 表示成功。
- 明确批量安装策略：如果裸包已安装但不是 latest，是跳过还是升级。若产品目标是“安装清单工具”，建议默认把裸包视为 latest 目标，旧版本不应显示“已安装满足”。

## 需要继续补齐或收敛的问题

### P2. JSON 错误对象仍是双层 envelope

位置：

- `scripts/node/npm-global-manager.sh:5391`
- `scripts/node/npm-global-manager.sh:5799-5801`
- `scripts/node/npm-global-manager.sh:5447-5454`
- `scripts/node/npm-global-manager.sh:5523-5529`

当前输出例子：

```json
{
  "ok": false,
  "schemaVersion": 1,
  "command": "package-plan",
  "error": {
    "ok": false,
    "error": "invalid-safe-package"
  }
}
```

这已经是合法 JSON，但模型不干净。`error.ok:false` 没有信息增益，app 侧会被迫兼容历史形态。

修复标准：

- `run_json_command()` 是唯一 envelope 生成点。
- renderer 失败时输出纯 payload：`{"code":"invalid-package-spec","packageSpec":"eslint@"}`。
- 所有错误都稳定使用 `code`，不要混用 `error` 字符串和 `code`。

### P2. app JSON 后端能力仍只覆盖 npm package 子集

位置：

- `scripts/node/npm-global-manager.sh:5332-5383`
- `scripts/node/npm-global-manager.sh:5838`

当前 JSON 命令集中在：

- summary
- packages
- outdated
- config
- package-plan
- plan
- execute
- status
- logs
- logs-cleanup
- operation-result

缺口：

- registry 切换、删除用户级 registry、scope registry 添加/删除没有 JSON plan/execute。
- nvm 安装、Node 安装、Node 切换、Node 卸载没有 JSON plan/execute。
- npm cache/node-gyp/orphan bin/nvm old versions 清理没有 JSON plan/execute。
- project `.nvmrc` 功能没有 JSON plan/execute。

如果目标只是交互式终端脚本，这不是 P1；但目标已经明确是后续做 macOS app，这就是后端契约缺口。app 不应该通过伪造交互输入来驱动危险动作。

修复标准：

- 每类变更动作都有同一套契约：plan -> app 确认 -> execute -> verify -> structured result。
- 交互层和 JSON 层调用同一动作层，避免两套业务逻辑。
- 不需要一次性做 GUI，但脚本层必须把 app 可调用的安全边界打出来。

### P2. registry URL 策略和提示不一致

位置：

- `scripts/node/npm-global-manager.sh:1623-1625`
- `scripts/node/npm-global-manager.sh:3505-3508`

当前实现只接受：

```bash
^https://[^[:space:]]+/$
```

但用户提示写的是：

```text
registry URL 必须以 http:// 或 https:// 开头，并以 / 结尾。
```

复现：

```bash
validate_registry_url http://localhost:4873/
```

结果：返回失败。

用户影响：

- 企业内网 Verdaccio、localhost 测试 registry、离线镜像等常见场景可能使用 HTTP。
- 当前用户会按提示输入 `http://.../`，然后被拒绝。

修复标准：

- 如果策略是安全优先只允许 HTTPS，提示必须改成只允许 HTTPS，并给出 HTTP 不支持原因。
- 如果要满足“自定义 registry”的真实用户场景，至少允许 `http://localhost:*` / `http://127.0.0.1:*`，或通过显式环境变量启用 HTTP。
- registry set 后继续保留 effective mismatch 检测，这部分当前设计是对的。

### P2. 动作层仍没有完全收口，JSON 和交互存在双实现风险

位置：

- `scripts/node/npm-global-manager.sh:2620-3026`
- `scripts/node/npm-global-manager.sh:5494-5648`
- `scripts/node/npm-global-manager.sh:2215-2581`
- `scripts/node/npm-global-manager.sh:3061-3345`

当前 `run_uninstall_flow()` 和 `render_uninstall_execute_json()` 分别实现卸载计划、快照、执行、复验、残留处理。第五轮后 JSON 卸载确实可用了，但本轮的“未安装包误报成功”就是双实现带来的漏口。

修复标准：

- 拆出共享动作层：build uninstall plan、capture uninstall snapshots、execute uninstall、verify uninstall、collect residues、cleanup residues。
- 交互层只负责菜单输入和人类可读渲染。
- JSON 层只负责 envelope 和机器可读渲染。
- install/update/registry/node/cleanup 后续也按同一模式收口。

### P3. project `.nvmrc` 功能默认禁用，需求状态需要重新对齐

位置：

- `scripts/node/npm-global-manager.sh:4890-4898`

当前行为：功能入口存在，但默认提示：

```text
该功能会写入所选项目目录，默认已禁用以保持 scripts/node 输出边界
```

这符合本轮“输出不能跑出 scripts/node”的约束。但从完整需求看，`指定项目 Node 版本` 是功能树中的一项真实能力。

修复标准：

- 如果继续坚持脚本运行产物边界，则文档中要明确：该功能是外部项目写入动作，默认禁用，只能在用户显式授权后启用。
- 如果要交付完整终端功能，则需要保留当前强确认机制，同时把该功能从“默认不可用”调整为“默认可用但危险动作强确认”。
- macOS app 版本必须用 JSON plan/execute 暴露这个能力，不能靠交互输入。

### P3. 本地工作区卫生仍要防止打包污染

位置：

- `scripts/node/.runtime/`
- `scripts/node/.DS_Store`
- `scripts/node/docs/.DS_Store`
- `scripts/node/tests/.DS_Store`

`.gitignore` 已覆盖这些路径，源码提交风险不大。但如果后续 macOS app 打包脚本直接复制 `scripts/node`，会把日志、tmp、downloaded tools、`.DS_Store` 一起带进包。

修复标准：

- app 打包必须使用白名单：主脚本、config、必要 docs/tests 或测试产物按需选择。
- `.runtime` 只能作为运行时目录，不能进入 app bundle 源资源。

## 当前功能完成度判断

已达到可用或基本完整：

- 启动摘要
- 主菜单和子菜单
- 单包安装
- 批量安装
- 全局包清单读取
- 卸载交互流程
- 升级扫描和升级执行
- 指定包升级 latest
- registry 查看与切换
- scope registry 交互管理
- nvm 安装
- Node 安装、切换、卸载
- npm cache、node-gyp、orphan bin、nvm old versions 清理
- JSON 基础查询和 npm package install/update/uninstall mutation
- 日志、运行时目录、质量检查

仍未达到完整交付：

- JSON uninstall 对不存在对象的前置校验。
- 裸包安装 target/latest 解析和验证。
- JSON 错误对象模型统一。
- 非 package 类危险动作的 JSON plan/execute。
- project `.nvmrc` 功能的默认交付策略和 app 契约。
- registry HTTP/HTTPS 策略与用户提示一致性。
- 交互层和 JSON 层共享动作层的结构收口。

## 总评

这份脚本已经不是临时拼接，安全快照、运行目录边界、锁、测试夹具、JSON parser 验证、下载校验都在正确方向上。它距离 90 分不是差“大功能堆砌”，而是差几个会让 app 契约不可信的边界条件。

下一次修复不应继续加菜单分支。优先顺序应是：

1. 修 JSON uninstall 未安装包误报成功。
2. 修裸包 target/latest 解析和验证。
3. 统一 JSON error payload。
4. 把 uninstall 的交互和 JSON 拆到共享动作层。
5. 再扩展 registry/node/cleanup 的 JSON plan/execute。

前两项修完并补上 parser/behavior 测试后，我认为可以接近或达到 90 分；如果同时完成共享动作层和 JSON error 统一，可以进入 92 分以上。
