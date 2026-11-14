# App 边界与打包契约

日期：2026-06-24
更新：2026-09-13

规范实现位于 `scripts/node-manager`，由 `main.sh` 加载 `lib/` 中按职责拆分的模块。旧路径 `scripts/node/npm-global-manager.sh` 仅作为兼容入口，不包含业务实现。

管理器的运行产物位于 `scripts/node-manager/.runtime`。未来 macOS App 打包必须以 `scripts/node-manager/app-bundle-manifest.txt` 作为生产文件白名单，不能直接复制任一源码目录。

## 打包规则

- 只包含 `app-bundle-manifest.txt` 列出的文件。
- 排除 `.runtime`、`.DS_Store`、下载的工具、日志、临时文件和本地 shell 输出。
- 测试与文档保留在 `scripts/node` 中作为开发资源，不进入生产包。

## 项目 `.nvmrc`

项目 `.nvmrc` 写入按设计位于 `scripts/node-manager` 运行目录之外。交互终端通过展示目标、要求复述完整项目路径以及覆盖确认来取得写入授权，不要求额外环境变量。

JSON 契约通过 `plan project-nvmrc <project-path> <version>` 暴露该能力，并返回 `externalWrite:true`。版本必须是 `20.11.1` 或 `v20.11.1` 这类具体版本；为保证可复现性，不接受 `lts` 等浮动别名。无交互的 `execute project-nvmrc` 同时要求 `NODE_MANAGER_ALLOW_JSON_EXECUTE=1` 和 `NODE_MANAGER_ALLOW_PROJECT_WRITE=1`，因此 App 调用方必须在写入管理器目录之外的路径前单独展示路径并确认授权。

当前 `externalWrite` 只标识 `project-nvmrc` 这类任意项目路径写入，不是所有环境变更的完整 effects 模型。App 不得仅依据该字段判断动作是否会修改 Node/npm/nvm 环境；是否确认仍以 `requiresConfirmation` 和具体 action 为准。

## Node 版本选择

- `node-use` 只改变当前 `execute` 子进程，计划结果返回 `processOnly:true`、`persistent:false`。App 进程结束后，该选择不会自动影响用户后续打开的终端。
- `node-default` 持久修改 nvm 的 default alias，计划结果返回 `processOnly:false`、`persistent:true`。需要持久选择默认 Node 版本时使用该 action。
- Node 与项目计划返回 `executable` 和 `blockedReason`。App 应在 `executable:false` 时禁用执行入口，并展示或映射 `blockedReason`；执行端仍会重新校验状态，计划结果不能替代执行期校验。

## 清理计划令牌

`plan cleanup <target>` 对 `npm-cache-clean`、`node-gyp-cache`、`orphan-bins`、`nvm-old-versions` 返回 `planToken`，它绑定计划时看到的清理候选状态。App 应把该值原样传给 `execute cleanup <target> <plan-token>`；如果候选状态已经变化，执行返回 `plan-stale`，且不会开始清理。

只读的 `npm-cache-verify` 不需要令牌。`execute cleanup logs` 走标准确认执行契约并返回真实 operation 结果，创建本次执行日志后保留最近 100 份日志；独立的 `logs-cleanup [keep-count]` 保留原有响应与自定义保留数量。

为兼容既有调用方，当前仍允许不带令牌的 `execute cleanup <target>`。是否在未来版本强制 App 必须传令牌，属于尚未裁决的公共契约变更。

## 卸载残留

`execute uninstall <package>` 只执行 npm 卸载并报告 `residues`，不会在同一次调用中自动删除卸载后才发现的目录或 bin 残留。App 必须先展示返回的候选项，再通过后续显式确认流程处理；卸载前的确认不能替代残留候选生成后的确认。

## JSON execute 开关

所有 `--json execute` 命令（包括 `execute cleanup logs`）都要求 App 在完成确认后设置 `NODE_MANAGER_ALLOW_JSON_EXECUTE=1`。独立的兼容命令 `logs-cleanup [keep-count]` 只处理 Manager 自身的 `.runtime/logs`，继续保留原有无 gate 契约。

## 测试隔离

Shell 测试必须在 `${TMPDIR:-/tmp}/node-manager-tests.*` 创建独立沙箱，并覆盖 `HOME`、`NVM_DIR`、`XDG_CONFIG_HOME`、npm userconfig、`PATH` 和运行目录。测试 shell 使用 `--noprofile --norc`，同时禁用 `BASH_ENV` 与 `ENV`；Node、npm、nvm 和 curl 的变更路径必须由 mock 接管。测试不得读取、安装、卸载、切换或清理用户真实的 Node/npm/nvm 环境。
