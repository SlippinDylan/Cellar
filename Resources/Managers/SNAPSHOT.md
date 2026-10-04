# Manager Snapshot

- Source commit: `1c9d71b3fbec98034b397d76babe47e459ad83f6`
- Snapshot version: `1c9d71b-app3`
- Generated: 2026-09-14

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
