# Manager Snapshot

- Node source commit: `075464ed72f8d3ce01c0316e17a23c6cb8c3652c`（25 个生产白名单文件）
- Homebrew / frozen Zsh source commit: `1c9d71b3fbec98034b397d76babe47e459ad83f6`（19 个冻结生产文件）
- Snapshot version: `075464e-app4`
- Generated: 2026-11-14

`node-manager` follows `scripts/node-manager/app-bundle-manifest.txt`.
`homebrew-manager` contains `main.sh` and production `lib/*.sh` files.
`zsh-manager/omz-manager.sh` is copied unchanged from `scripts/zsh/omz-manager.sh`.
The adjacent `app-json.sh` and `lib/app_json_*.sh` files are Cellar-owned schema v1
adapters layered on the frozen interactive manager for App query/plan/execute calls.

Frozen source copies must not be patched in place. App-owned adapters are maintained
in this resource tree and must keep the interactive source file byte-identical.

`app3`（2026-10-04）只更新 Cellar-owned `lib/app_json_execute.sh`：插件克隆改为
写入 App 提供且经 owner marker/device/inode 核验的私有 staging。adapter 不再写入或
删除插件最终目录；Swift Bridge 以 `renameatx_np(RENAME_EXCL)` 在同一父目录原子发布，
已有目的地会失败并保留。发布后的插件不因配置失败而删除。没有复制后删除或覆盖路径。
运行快照版本随此次 App-owned 协议更新递增，已有 App 运行副本会使用新目录。
44 个冻结生产文件的来源 commit 与逐字节内容保持不变。

`app4`（2026-11-14）按生产白名单从已审查 Node source commit
`075464ed72f8d3ce01c0316e17a23c6cb8c3652c` 同步全部 25 项，实际变化只涉及
`lib/inventory.sh`、`lib/json_common.sh`、`lib/json_execute.sh`、`lib/json_plan.sh`
和 `lib/json_read.sh`。此次同步收紧当前 npm 断链归属和逐项身份复验，规范候选顺序，
并保留清理的部分完成、未知及未开始事实和稳定失败 code。旧来源的 Homebrew、
交互式 Zsh 文件及现有 Cellar-owned Zsh adapters 均未变更。新 runtime 目录防止复用
旧 `1c9d71b-app3` 运行副本；不迁移或删除旧版本目录。
