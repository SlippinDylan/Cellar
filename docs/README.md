# Cellar 文档

Cellar 的文档按职责维护。代码和工程配置说明当前实现，文档记录稳定的产品行为、架构边界、开发流程和外部依据。

## 文档导航

| 需要了解的内容 | 权威文档 |
|---|---|
| 页面行为、状态、数据和验收契约 | [产品需求](requirements/product-requirements.md) |
| 当前 v1 范围和非目标 | [v1 MVP 范围](requirements/v1-mvp.md) |
| macOS 版本、arm64 和构建门禁 | [平台支持](requirements/platform-support.md) |
| 当前组件、数据流、快照和进程边界 | [总体架构](architecture/macos-app-architecture.md) |
| 本地开发、测试、构建和清理 | [开发指南](development.md) |
| Apple、npm 官方依据和项目推论 | [研究依据](research.md) |
| 真实机器与 UI 检查 | [人工验收清单](manual-smoke-checklist.md) |

## 维护规则

- 用户可见行为变化更新产品需求和 README。
- 组件所有权、数据流或系统边界变化更新架构文档。
- 构建、测试、CI、发布或清理流程变化更新开发指南。
- 外部平台证据或推论变化更新研究依据。
- 自动测试无法证明的行为进入人工验收清单。
- `scripts/` 中的历史需求只解释对应 CLI Manager，不作为 App 当前行为来源。
- 同一事实只维护一个权威来源；代码已经能清楚表达的成员和调用细节不复制进文档。
