# Cellar 文档

Cellar 的文档按职责维护。[1.0 产品需求](requirements/product-requirements.md)是用户行为和安全边界的唯一权威来源。1.0 源码已实现，尚未公开发布；代码和工程配置说明实现事实，架构文档描述当前实现，人工清单保留未执行的真实环境验收。

## 文档导航

| 需要了解的内容 | 权威文档 |
|---|---|
| 用户行为、状态、安全边界和验收契约 | [1.0 产品需求](requirements/product-requirements.md) |
| 1.0 发布内容、非目标和门槛 | [1.0 交付范围](requirements/v1-mvp.md) |
| macOS 版本、arm64 和构建门禁 | [平台支持](requirements/platform-support.md) |
| 当前实现、数据流、快照和进程边界 | [总体架构](architecture/macos-app-architecture.md) |
| 本地开发、测试、构建和清理 | [开发指南](development.md) |
| Apple、Homebrew、npm、nvm 官方依据和项目推论 | [研究依据](research.md) |
| 真实机器、系统授权与 UI 检查 | [人工验收清单](manual-smoke-checklist.md) |

## 维护规则

- 用户可见行为变化先更新产品需求，再同步 README；交付范围只引用契约，不复制细节。
- 组件所有权、数据流或系统边界变化更新架构文档。
- 构建、测试、CI、发布或清理流程变化更新开发指南。
- 外部平台证据或推论变化更新研究依据。
- 自动测试无法证明的行为进入人工验收清单。
- `scripts/` 中的历史需求只解释对应 CLI Manager，不作为 App 当前行为来源。
- 同一事实只维护一个权威来源；代码已经能清楚表达的成员和调用细节不复制进文档。
