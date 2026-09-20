# Manager Snapshot

- Source commit: `1c9d71b3fbec98034b397d76babe47e459ad83f6`
- Snapshot version: `1c9d71b-app2`
- Generated: 2026-09-14

`node-manager` follows `scripts/node-manager/app-bundle-manifest.txt`.
`homebrew-manager` contains `main.sh` and production `lib/*.sh` files.
`zsh-manager/omz-manager.sh` is copied unchanged from `scripts/zsh/omz-manager.sh`.
The adjacent `app-json.sh` and `lib/app_json_*.sh` files are Cellar-owned schema v1
adapters layered on the frozen interactive manager for App query/plan/execute calls.

Frozen source copies must not be patched in place. App-owned adapters are maintained
in this resource tree and must keep the interactive source file byte-identical.
