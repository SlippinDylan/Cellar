# npm-global-manager.sh 深度 Review

日期：2026-06-17
范围：`scripts/node/npm-global-manager.sh`、同目录需求/规格/计划/测试
结论：当前脚本功能覆盖面已经接近完整，但还没有达到 90/100 的交付质量。按长期稳定、可维护、安全边界、真实用户场景评估，当前约为 72/100。主要差距不是菜单缺失，而是若干危险路径的验证不够硬、部分 npm/nvm 语义理解不准、测试对真实行为保护不足。

参考资料：

- npm package spec: https://docs.npmjs.com/cli/v11/using-npm/package-spec
- npm install: https://docs.npmjs.com/cli/v11/commands/npm-install/
- npm update: https://docs.npmjs.com/cli/v11/commands/npm-update/
- npm outdated: https://docs.npmjs.com/cli/v11/commands/npm-outdated/
- npm config: https://docs.npmjs.com/cli/v11/commands/npm-config/
- npmrc: https://docs.npmjs.com/cli/v11/configuring-npm/npmrc/
- nvm README: https://github.com/nvm-sh/nvm

## 必须修的问题

1. `npm outdated -g` 的升级目标语义不够可靠。
   - 位置：`npm-global-manager.sh:2251-2446`
   - 问题：脚本把 `wanted` 当成批量升级目标，并用 `npm update -g package` 执行。但 npm 官方文档说明 `wanted` 与 semver 范围相关；全局包没有项目 `package.json` 约束时，`wanted/latest` 语义和用户直觉可能不一致。当前验证只判断版本是否变化，不验证是否等于 `wanted` 或是否仍 outdated。
   - 用户影响：用户看到计划是 `current -> wanted`，实际升级后可能不是展示的版本；也可能 npm 返回 0 但版本未达预期，只被归为 warn，流程仍继续。
   - 需要达到 90 分的状态：展示必须明确“npm update 目标为 npm 自身解析结果”，执行后必须复扫该包并验证不再出现在 outdated 列表，或验证版本达到展示目标；失败要进入失败而不是普通 warning。

2. 包名校验过窄，会误拒 npm 官方支持的合法包名。
   - 位置：`npm-global-manager.sh:1065-1079`
   - 问题：当前正则只允许字母数字、点、下划线、短横线和简单版本后缀。npm package spec 支持更完整的 `<package-spec>`；即使按当前需求只支持 registry 包，也应至少支持现代 npm 合法名称和常见 dist-tag，例如 `package@next`、`package@beta`，并明确拒绝 alias/git/file/tarball 是“产品边界”而不是误认为非法包名。
   - 用户影响：用户安装 `foo@next`、`@scope/foo@beta` 这类正常全局 CLI 时可能失败；错误信息会让用户以为包名不合法。
   - 需要达到 90 分的状态：把“允许的安全子集”独立成产品决策；校验函数、提示文案、测试夹具一致。

3. `extract_package_name` 对 `@` 的解析过于简单。
   - 位置：`npm-global-manager.sh:1265-1287`
   - 问题：通过统计 `@` 决定是否有版本。这个对当前狭窄正则大多可用，但和 npm package spec 的扩展能力不兼容，也没有统一“spec -> name/tag/version”的结构化解析。
   - 用户影响：后续一旦放宽包名或 dist-tag，安装验证、升级 latest、卸载验证会出现包名提取错误。
   - 需要达到 90 分的状态：新增单一 parser，输出 `name`、`requested_version_or_tag`、`raw_spec`，所有安装/验证路径共用。

4. `nvm` 安装脚本默认没有完整性校验。
   - 位置：`npm-global-manager.sh:20-22`、`1320-1365`
   - 问题：脚本下载官方 install.sh 后执行。虽然没有 `curl | bash`，比直接管道执行好，但 `NVM_INSTALL_SHA256` 默认为空，默认路径没有校验下载内容。
   - 用户影响：企业网络代理、被污染的网络、GitHub raw 异常返回等场景下，用户可能执行未校验脚本。
   - 需要达到 90 分的状态：默认固定版本必须绑定已知 SHA256，或者在安装前展示版本、URL、校验策略，并把“未配置 SHA256”作为强警告二次确认。

5. `run_project_node_flow` 会写入任意项目目录，和本次“输出不能跑出 scripts/node”约束冲突。
   - 位置：`npm-global-manager.sh:3872-4062`
   - 问题：这是功能需求里提到的能力，但用户本轮明确要求后续输出均在 `scripts/node` 文件夹内。当前功能会写 `项目路径/.nvmrc`，即使有确认，也属于目录外输出。
   - 用户影响：如果本轮继续实现或测试该功能，可能违反工作边界；未来 app 化也需要明确沙盒授权和文件写入提示。
   - 需要达到 90 分的状态：本轮内不执行该功能的真实写入；脚本层面应加清晰模式开关或运行边界说明。作为工具能力保留可以，但报告/实现阶段要单独标注。

6. 卸载残留 bin 判断依赖卸载后的包目录归属，可能漏报。
   - 位置：`npm-global-manager.sh:1977-2000`、`2074-2085`
   - 问题：脚本预先保存 bin command 名，但没有保存每个 bin 入口卸载前的 symlink target。卸载后再用 `is_owned_symlink "$bin_path" "$pkg_dir"` 判断归属；如果包目录已经不存在，`is_path_within_dir` 会失败，导致本该清理的残留 symlink 可能不会进入候选。
   - 用户影响：卸载后全局 bin 残留不能稳定识别。
   - 需要达到 90 分的状态：卸载前保存 `bin_path -> resolved_target -> package_dir` 快照；卸载后只在 target 快照归属明确且当前路径仍是同一个 symlink 时列为候选。

7. 卸载目录残留清理使用 `rm -rf`，边界不错但仍缺少“目录快照一致性”。
   - 位置：`npm-global-manager.sh:2147-2165`
   - 问题：删除前只验证残留目录在 `global_root` 下，没有验证它仍是卸载前同一个包目录，或者没有被用户/其他进程替换。
   - 用户影响：并发 npm 操作或用户手动改动时，可能删除新创建的同名目录。
   - 需要达到 90 分的状态：卸载前记录 inode/realpath/mtime 或至少记录目录是否存在；清理前复验目录未被替换，并要求逐项确认。

8. 清理 npm cache 目录直接 `rm -rf` 实际 cache 路径，和 npm 官方 cache 管理路径重叠。
   - 位置：`npm-global-manager.sh:3411-3423`、`3360-3409`
   - 问题：脚本已经提供 `npm cache verify` 和 `npm cache clean --force`，但又允许直接删除 `npm config get cache` 返回目录。这个能力风险明显更高，且没有说明为什么要绕过 npm 官方命令。
   - 用户影响：用户可能删除正在被 npm 使用的缓存目录；失败或部分删除后状态不清晰。
   - 需要达到 90 分的状态：默认只走 `npm cache verify/clean`；直接删除 cache 目录应降级为高级修复入口，并必须先停止相关 npm 进程或给出强提示。

9. `node-gyp` 缓存路径检测不够准确。
   - 位置：`npm-global-manager.sh:1037-1053`
   - 问题：`npm config get devdir` 不是所有 npm/node-gyp 场景的稳定配置项；默认回退 `~/.node-gyp` 只覆盖旧路径。现代 node-gyp 常见缓存也可能在 `~/Library/Caches/node-gyp` 或 npm cache 派生位置。
   - 用户影响：清理入口可能显示不存在，用户以为没有缓存；或者只清一部分。
   - 需要达到 90 分的状态：明确支持路径列表，逐项只读扫描、展示来源、用户逐项确认。

10. `run_cleanup_flow` 不是循环菜单。
    - 位置：`npm-global-manager.sh:3687-3709`
    - 问题：进入清理菜单后只能执行一次动作，然后返回环境菜单；其他子菜单多为循环。交互不一致。
    - 用户影响：用户连续做 verify -> clean -> verify，需要反复进入菜单。
    - 需要达到 90 分的状态：清理菜单改成循环，所有动作完成后回到清理子菜单。

11. Node 版本安装指定版本后没有显式 `nvm use`。
    - 位置：`npm-global-manager.sh:1418-1422`、`3138-3172`
    - 问题：需求要求安装指定版本后执行 `nvm use`。脚本的 `install_node_version` 只执行 `nvm install "$version"`，后续用 `node -v` 验证当前版本。nvm install 在部分场景可能不会切换当前 shell，验证可能失败或行为依赖 nvm 版本。
    - 用户影响：用户安装成功但当前 Node 未切换，后续全局包装错版本。
    - 需要达到 90 分的状态：`nvm install "$version"` 后必须显式 `nvm use "$version"`，并验证当前 `node -v`。

12. `install_node_lts` 使用 `nvm use --lts` 后设置 default 使用 `node -v`，但 default alias 最好绑定解析后的具体版本。
    - 位置：`npm-global-manager.sh:1413-1416`、`3069-3087`
    - 问题：当前把 `node -v` 作为 default 目标，通常可以，但没有记录 LTS alias 到具体版本的解析过程，也没有复扫已安装版本确认。
    - 用户影响：如果 `nvm use --lts` 成功但 PATH 异常，default 设置可能不可靠。
    - 需要达到 90 分的状态：安装后用 nvm current 和 node -v 双重验证，并以解析出的具体版本设置 default。

13. `get_installed_node_versions` 解析 `nvm ls` 依赖文本 grep。
    - 位置：`npm-global-manager.sh:1367-1385`
    - 问题：nvm 输出格式不是机器接口。当前正则已规避一部分 alias 行，但仍可能受 nvm 本地化、颜色、系统 alias 输出变化影响。
    - 用户影响：Node 卸载、切换、清理都依赖这个函数；解析错会影响危险操作对象。
    - 需要达到 90 分的状态：尽可能基于 `$(detect_nvm_dir)/versions/node/v*` 目录扫描作为主数据源，再用 nvm current/default 叠加状态。

14. `get_nvm_default_version` 解析 alias 输出不够严格。
    - 位置：`npm-global-manager.sh:1397-1411`
    - 问题：如果 default 是 `node`、`stable`、`lts/*` 或不存在，返回原始 alias 输出；后续和 `vX.Y.Z` 比较可能失败。
    - 用户影响：可能允许清理/卸载实际 default 指向的版本，或者错误显示默认版本。
    - 需要达到 90 分的状态：把 default alias、resolved version、resolution status 分开返回；无法解析时禁止 default 相关危险操作。

15. `run_nvm_old_versions_cleanup` 把“没有用户全局包”作为可清理条件，但没有展示 npm/corepack 等基础包是否存在。
    - 位置：`npm-global-manager.sh:3526-3685`
    - 问题：`count_user_global_packages_from_json` 排除 `npm`、`corepack`。这个作为保护逻辑可以，但清理计划里没有展示完整包列表。
    - 用户影响：用户不知道卸载旧版本仍会删除该版本内的 npm/corepack 和其他内置文件。
    - 需要达到 90 分的状态：清理计划展示完整版本目录内容摘要、用户包数量、保护包数量和目录大小。

16. registry 切换验证只验证 user layer，不验证 effective layer 一致。
    - 位置：`npm-global-manager.sh:1206-1211`、`2643-2711`
    - 问题：`set_registry_value` 成功条件是 user registry 写入成功；如果项目级 `.npmrc` 覆盖 effective registry，用户看到“切换成功”后实际当前目录仍不是该源。脚本后来会打印 actual，但仍先报 ok。
    - 用户影响：用户以为已切换源，安装时仍走项目源或企业源。
    - 需要达到 90 分的状态：结果状态区分“user 写入成功”和“effective 生效成功”；若 effective 被项目/global 覆盖，应显示 warning 而不是纯 ok。

17. scope registry 展示来源会重复且解析不完整。
    - 位置：`npm-global-manager.sh:2587-2620`、`2744-2876`
    - 问题：同时解析用户 `.npmrc` 和 `npm config list -l`，可能重复输出；`parse_scope_registry_lines` 只支持非常窄的格式。
    - 用户影响：scope 源列表可能重复或漏报，尤其企业 npmrc 中有注释、环境变量、不同空格格式时。
    - 需要达到 90 分的状态：统一从 npm config 查询 effective/user/project/global，并对每个 scope 去重展示。

18. `npm config get ... --location=project` 在没有项目 npmrc 时可能返回默认值，脚本没有区分“未设置”和“继承/默认”。
    - 位置：`npm-global-manager.sh:1177-1185`、`2624-2633`
    - 问题：配置分层摘要把 npm CLI 输出直接展示，不解释 `undefined/null/default`。
    - 用户影响：用户可能误判某层配置真实存在。
    - 需要达到 90 分的状态：规范化空值，并展示“unset/default/effective”。

19. 启动摘要在 nvm 已安装但未加载时不解析 current/default。
    - 位置：`npm-global-manager.sh:531-541`
    - 问题：这是为了只读不 source nvm，方向对。但用户实际启动脚本时最关心“nvm 已安装但当前 shell 没加载”与“默认版本是什么”。目前都显示 `<not-loaded>`，信息不足。
    - 用户影响：用户看到摘要不知道是没安装、没加载还是当前 shell 问题。
    - 需要达到 90 分的状态：只读检测 `nvm.sh` 存在、NVM_DIR、当前 node 是否 nvm-managed；default 可以通过只读解析 alias 文件或在环境总览中提供“加载后诊断”按钮。

20. `run_dependency_preflight` 把 `node/npm/curl/shasum` 设为 warn，但后续很多入口会直接调用。
    - 位置：`npm-global-manager.sh:69-87`
    - 问题：主菜单仍允许进入安装包、升级、registry 等 npm 必需功能，失败会分散在各函数里。
    - 用户影响：没有 Node/npm 的用户第一次使用时，会遇到多个子功能失败，而不是被引导先安装 nvm/Node。
    - 需要达到 90 分的状态：每个菜单入口声明所需能力；缺 npm 的入口给出明确跳转建议，只允许 nvm 安装等可用入口。

21. `run_batch_install_flow` 的“all”会选择已安装包，再执行时 skip，交互语义不够干净。
    - 位置：`npm-global-manager.sh:1668-1720`
    - 问题：提示写的是 `all 全部待安装`，实现是选全部清单，包括已安装。
    - 用户影响：统计中的“选中”数量和用户理解不一致。
    - 需要达到 90 分的状态：`all` 只选待安装项；如需全选清单，另设显式选项。

22. 批量安装验证对带版本 spec 处理错误。
    - 位置：`npm-global-manager.sh:1740-1783`
    - 问题：`npm ls -g "$package_name"` 和 `get_installed_global_package_version "$package_name"` 直接使用可能包含版本的 spec，例如 `eslint@9.0.0`。单包安装里有 `extract_package_name`，批量安装没有统一使用。
    - 用户影响：安装成功后验证失败，或版本读取为空。
    - 需要达到 90 分的状态：所有路径先解析 spec，安装使用 raw spec，验证使用 package name。

23. `run_upgrade_latest_flow` 允许输入 `package@version`，但语义上只应输入包名。
    - 位置：`npm-global-manager.sh:2455-2506`
    - 问题：提示“请输入包名”，校验却允许 `package@version`。然后执行 `npm install -g "${package_name}@latest"`，如果输入 `foo@1.0.0` 会变成 `foo@1.0.0@latest`。
    - 用户影响：命令错误或安装非预期包。
    - 需要达到 90 分的状态：latest 升级只接受 package name，不接受 version/tag spec；或先 extract name。

24. JSON CLI 与交互逻辑覆盖不一致。
    - 位置：`npm-global-manager.sh:4115-4333`
    - 问题：提供 `--json summary/packages/outdated/config/package-plan`，但没有 JSON 版 install/uninstall/update plan 的完整 dry-run，也没有统一错误码模型。
    - 用户影响：后续 macOS app 包装会发现交互脚本难以稳定驱动，只能解析人类文本。
    - 需要达到 90 分的状态：app 面向命令必须是稳定契约：plan、execute、status、logs，且输出 JSON schema 固定。

25. `--dry-run` 只打印目录与支持命令，不是真正 dry-run。
    - 位置：`npm-global-manager.sh:4335-4347`
    - 问题：文案说 no mutation commands will be executed，但没有支持任意动作的 dry-run plan。
    - 用户影响：用户可能以为能预演安装/卸载/升级，实际不能。
    - 需要达到 90 分的状态：要么改名为 `--info`，要么实现具体动作 dry-run。

26. 测试通过不能证明主要功能可靠。
    - 位置：`scripts/node/tests/npm-global-manager-test.sh`
    - 问题：235 个测试通过，但大量测试是 `type function` 或源码字符串包含断言，不执行真实流程；mock npm/nvm 也没有覆盖安装、卸载、registry、node 切换的状态迁移。
    - 用户影响：后续重构时很容易“测试绿但脚本坏”。
    - 需要达到 90 分的状态：引入行为测试：给定 mock HOME/NVM_DIR/PATH，驱动交互输入，断言文件、日志、mock 状态和输出。

27. ShellCheck 未实际运行。
    - 位置：`scripts/node/run-quality-checks.sh`
    - 证据：本次执行显示 `shellcheck not installed; skipped`。
    - 用户影响：当前没有静态检查覆盖；缩进异常、未引用变量、不可移植写法等问题可能漏过。
    - 需要达到 90 分的状态：在本机或 CI 安装 shellcheck；至少对 `npm-global-manager.sh` 和测试脚本跑通。

28. 多处缩进异常显示代码维护状态不稳定。
    - 位置：例如 `npm-global-manager.sh:2044-2047`、`2167-2182`、`2751`、`2827-2837`、`3147`、`3271`、`3962-4035`、`4043`
    - 问题：虽然 bash 语法通过，但这些缩进明显不是统一风格。
    - 用户影响：后续改动时很容易误读控制流，尤其危险操作附近。
    - 需要达到 90 分的状态：格式统一，危险路径缩进必须清楚。

29. 日志记录没有统一结果模型。
    - 位置：`npm-global-manager.sh:1099-1124` 及各流程
    - 问题：每个流程自由写日志，有的有 summary，有的只记录 command，有的清理动作不入日志。
    - 用户影响：用户排查问题时日志不一致；app 化后难以展示。
    - 需要达到 90 分的状态：统一 operation id、command、exit code、stdout/stderr 摘要、result JSON。

30. 没有锁机制防止并发运行。
    - 位置：全局缺失
    - 问题：脚本可能同时被两个终端或未来 app 调起，npm global install/uninstall、cache clean、nvm install/use 并发会互相影响。
    - 用户影响：产生 package/bin/cache 状态竞争。
    - 需要达到 90 分的状态：对变更型操作加 runtime lock，读操作不锁或共享锁。

## 功能缺失或半完成清单

这些入口已经出现，但还没有达到需求里的完整交付质量：

- 单包安装：缺少 tag/spec 结构化解析；没有对当前 Node 是否 nvm-managed 做阻断或强提示；失败重试交互可用但无法区分网络失败、权限失败、registry 认证失败。
- 批量安装：清单为空是合理默认，但没有示例可执行配置；带版本 spec 验证问题；`all` 语义不准确；没有逐包最终 bin 摘要。
- 卸载 global package：有基础计划、确认、验证和残留候选，但 bin 残留归属快照不足；目录残留清理缺少替换复验；没有记录卸载前完整 package metadata 到日志。
- 更新与升级：扫描有处理 `npm outdated` exit 1 的意识，但升级目标和验证不够硬；latest 流程输入允许 version spec 是 bug。
- 源管理：user layer 修改已实现，但 effective layer 验证和分层解释不够；scope registry 去重、删除后有效配置解释还不够清楚。
- 环境总览：只读安全做得对，但 nvm 未加载时信息太少；没有 Homebrew/系统 Node 混用风险诊断。
- 安装 nvm：安装流程基本可用，但默认无 SHA256 校验；profile 修改检测依赖 md5 diff，不是强保证。
- 安装 Node.js 版本：LTS 路径较完整；指定版本路径缺显式 `nvm use`；远程版本只列 LTS 后 20 个，不支持 Current/全部稳定版本。
- 更改全局 Node 版本：基础可用；default alias 解析失败时没有硬阻断。
- 卸载 Node.js 版本：实现存在，但不是第一版硬要求；当前缺少“先切 default”的引导操作，只是阻断。
- 指定项目 Node 版本：功能存在，但会写 scripts/node 之外；本轮边界下应视为受限功能。
- 清理 npm 环境：入口丰富，但风险分层不足；cache 目录直接删除、node-gyp 路径识别、nvm old cleanup 信息展示都需要加强。
- JSON/app wrapper：只是雏形。未来 macOS app 需要稳定机器接口，现在还不足以作为可靠后端。

## 优点

- 运行产物默认收敛在 `scripts/node/.runtime`，符合当前目录边界。
- 主菜单、子菜单、启动摘要、环境总览的整体交互框架已经成型。
- 保护包 `npm/corepack` 已有普通卸载保护。
- 重要变更大多有确认步骤，不是裸执行。
- nvm 加载使用 `command -v nvm` 方向正确，也避免了启动摘要静默 source nvm。
- 需求文档、规格、计划和测试都放在同一目录，后续收敛成本不高。

## 测试与验证证据

本次执行：

```bash
bash scripts/node/run-quality-checks.sh
```

结果：

- `bash -n` 通过。
- 测试：235 passed, 0 failed。
- ShellCheck：未安装，已跳过。

这说明当前脚本语法和现有测试通过，但不能证明高风险交互功能达到 90 分质量线。

## 建议的 90 分验收线

脚本要达到你要求的 90/100，至少需要满足：

- 所有 npm package spec 在产品边界内被结构化解析，安装、验证、升级共用同一解析结果。
- 所有变更型操作都有 plan -> confirm -> execute -> verify -> structured summary，同一套结果模型。
- 卸载和清理的删除动作必须有卸载前快照和删除前复验，不能只靠路径字符串。
- nvm 安装默认有完整性校验或强警告确认。
- Node 版本安装/切换/default/卸载全部基于解析后的具体版本，不依赖模糊 alias 输出。
- registry 修改明确区分 user layer 成功和 effective 生效成功。
- JSON/app wrapper 接口有稳定 schema，不能让未来 app 解析人类菜单文本。
- 行为测试覆盖真实交互路径和 mock 状态迁移，而不是主要靠源码字符串断言。
- ShellCheck 实际运行并通过。
