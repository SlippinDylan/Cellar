# Cellar 平台支持范围

状态：已确认
更新日期：2026-09-19

## 支持范围

| 项目 | 已确认要求 |
|---|---|
| 操作系统 | macOS 26.0 及以上 |
| 最低部署版本 | `MACOSX_DEPLOYMENT_TARGET = 26.0` |
| CPU 架构 | 仅 Apple silicon `arm64` |
| Intel Mac | 不支持 `x86_64`，不提供 Universal Binary |
| Rosetta | 不作为运行或兼容方案 |
| App 形态 | 原生 macOS App，不使用 Mac Catalyst |

不为 macOS 15 及更早版本增加兼容分支、降级实现或测试矩阵。业务代码可以直接以 macOS 26 SDK 和 macOS 26 可用 API 为基线。

构建工具至少使用包含 macOS 26 SDK 的 Xcode 26。Apple 的 macOS Tahoe 26 Release Notes 明确说明，macOS 26 SDK 随 Xcode 26 提供。

## Xcode 构建约束

Apple 官方说明，Xcode 的标准 macOS Release 架构默认会生成同时包含 `arm64` 与 `x86_64` 的 Universal Binary。因此 Cellar 不能只保留默认配置，必须显式排除 Intel 架构。

项目与所有可执行 Target 遵循：

```text
SDKROOT = macosx
SUPPORTED_PLATFORMS = macosx
MACOSX_DEPLOYMENT_TARGET = 26.0
ARCHS = $(ARCHS_STANDARD)
EXCLUDED_ARCHS[sdk=macosx*] = x86_64
```

约束说明：

- 不设置已废弃的 `VALID_ARCHS`。
- 按 Apple TN3117 的建议，通过 `EXCLUDED_ARCHS` 表达有意排除的架构，不用自定义 `VALID_ARCHS`。
- App、Framework、Helper、命令行工具和其他 Mach-O 产物都必须满足相同的 `arm64` 要求。
- 第三方二进制依赖必须包含原生 `arm64` slice，不接受只能通过 Rosetta 运行的依赖。
- 不编写 `x86_64` 专用实现，不加入 `arch -x86_64` 或 Rosetta fallback。

## 发布验收

Release 产物必须同时通过以下检查：

```text
最低系统版本 = macOS 26.0
主程序架构 = arm64
所有嵌入 Mach-O 架构 = arm64
不存在 x86_64 slice
```

架构使用 `lipo -archs <binary>` 或 `file <binary>` 验证。主程序、Framework、Helper、Plug-in 和其他嵌入式可执行文件都要逐项检查，不能只检查 `.app` 主二进制。

## 开发与测试约束

- 开发、构建和验收机器使用 Apple silicon Mac。
- CI 或发布任务只选择 Apple silicon 环境。
- SwiftUI Preview、单元测试、集成测试和 UI 测试以 macOS 26 为最低系统环境。
- 不为 Intel Mac 建立构建目标、测试任务或发布产物。
- 如果依赖不支持 `arm64` 或要求低于 macOS 26 的兼容实现，优先替换依赖，不扩大平台范围。

## 标准目录

App 持久支持文件通过 Foundation 的 `URL.applicationSupportDirectory` 或等价 `FileManager` API 获取，不硬编码用户主目录。非沙盒 macOS App 中，该目录对应当前用户的 `~/Library/Application Support`。

缓存与日志同样使用 Foundation 提供的标准目录能力，并在其下创建 Cellar 专属子目录。

## Apple 官方依据

依据的分类、适用结论和 npm 资料统一维护在[研究文档](../research.md)。平台直接来源包括：

- [TN3117: Resolving architecture build errors on Apple silicon](https://developer.apple.com/documentation/technotes/tn3117-resolving-build-errors-for-apple-silicon)
- [Building a universal macOS binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)
- [URL.applicationSupportDirectory](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory)
- [macOS Tahoe 26 Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)
- [Xcode 26 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
