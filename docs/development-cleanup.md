# Cellar 开发产物清理规则

本文是 Cellar 开发产物清理的唯一规则来源。只有用户明确要求时才执行清理。

目标是让仓库回到接近“尚未构建”的状态：保留项目输入、用户开发环境、App 运行数据和 Agent 对话记录，移除能够可靠归属于 Cellar、由开发和验证过程产生且可以重新生成的全部输出。

## 请求语义

### 清理仓库内开发产物

仅审计当前 Cellar Git 工作树内部、本文件明确列出的可再生产物，不扩展到仓库外目录。

### 清理当前项目所有开发产物

“清理当前项目所有开发产物”“全面清理当前项目”或含义等价的明确请求，表示：

- 审计当前工作树及本文列出的仓库外位置；
- 覆盖本次和历史 Agent 会话执行编译、构建、测试、预览、签名、打包及验证留下的 Cellar 产物；
- 删除能够可靠归属的本地 App、DMG、dSYM、`.xcarchive` 和其他可再生交付物，无论它们是否已经签名或通过验证；
- 授权删除审计范围内满足本文全部删除条件的内容，无需对同一范围再次请求许可。

授权审计不等于删除所有命中项。无法证明项目归属、安全再生性或数据性质的内容必须保留并报告。

如果当前目录不是 Cellar 的单一 Git 工作树，或者请求可能同时指向其他 clone 或 worktree，必须先明确目标。

### 清理当前项目所有开发和验证残留

该请求包含前述全部范围，并进一步检查为了本地验证而安装的 Cellar App 和测试运行状态。

Cellar 能管理用户真实的 Homebrew 环境。普通清理和验证环境恢复都不得撤销用户的 Homebrew、Node/npm/nvm 或 Shell 状态，不得删除用户安装的软件包，也不得把 App 展示或管理的外部环境误认为 Cellar 自己的开发产物。

## 当前项目定义

| 项目属性 | Cellar 定义 |
|---|---|
| Git 仓库 | 当前工作树根目录 |
| Xcode project | `Cellar.xcodeproj` |
| Scheme | `Cellar` |
| Targets | `Cellar`、`CellarTests` |
| App bundle identifier | `com.dylanwang.Cellar` |
| Test bundle identifier | `com.dylanwang.CellarTests` |
| Node 测试临时前缀 | `node-manager-tests.` |
| Homebrew 测试临时前缀 | `brew-app-manager-*`，仅限能够与当前测试执行建立关联的目标 |
| Zsh 测试临时前缀 | `omz-manager-test-home.`，仅限能够与当前测试执行建立关联的目标 |
| App 运行数据 | `~/Library/Application Support/Cellar/` |
| 用户开发环境 | Homebrew 安装与缓存、`~/.nvm`、npm cache/配置、Shell 配置和用户项目 |

这些标识来自工程配置、源码和受版本控制的脚本。名称相似但工程路径、测试上下文或标识不匹配的内容不属于 Cellar。

## 仓库内审计范围

本文构建命令产生：

```text
build/DerivedData-Tests/
build/DerivedData-Debug/
build/DerivedData-Release/
```

其他可再生产物包括：

```text
DerivedData/
.build/
.swiftpm/
*.xcresult
*.dSYM
*.dSYM.zip
*.app
*.dmg
*.xcarchive
```

还应审计由当前任务明确指定在仓库内的测试结果、覆盖率输出、构建日志、Archive、打包输出和临时导出目录。

候选项必须位于当前工作树内，并能由工程设置、构建命令或项目脚本证明为生成物。`.gitignore` 只能作为线索；不得使用 `git clean` 代替逐项判断，未跟踪文件也不能自动视为垃圾文件。

`scripts/`、`Resources/Managers/` 及其中的源码、快照、测试夹具和设计资料是项目输入，不是构建垃圾。

## 仓库外审计范围

只有用户明确要求清理当前项目所有开发产物时，才审计本节范围。

### Xcode DerivedData 与 Archives

审计以下位置中能够通过工程路径、构建或归档元数据确认属于当前 Cellar 工作树的内容：

- `~/Library/Developer/Xcode/DerivedData/`
- `~/Library/Developer/Xcode/Archives/`

不能只根据 `Cellar-` 前缀判断。属于其他 clone、worktree 或无法解析来源的目录必须保留。符合归属条件的 `.xcarchive` 属于可再生本地输出，即使已经签名或用于验证，也在全面清理范围内。

### 系统临时目录

审计 `/tmp`、`/private/tmp` 和当前用户 `$TMPDIR` 解析后的 `/private/var/folders/.../T/`。`/tmp` 通常对应 `/private/tmp`，统计和删除前必须规范化并去重，也不得遍历其他用户的临时目录。

Cellar 的测试和 Manager 脚本使用多个通用临时前缀。只有路径、测试沙箱、内容元数据或当前工作树绝对路径能够证明目标由本仓库开发验证产生时才删除。前缀相同、最近修改或位于临时目录都不是充分证据。

尤其不能把真实 Homebrew、npm、nvm 或 Shell 操作创建的临时文件仅凭 Manager 前缀认定为 Cellar 开发残留；相关进程仍在运行时必须保留。

### 项目专属缓存

只有完整 bundle identifier 对应、且确认不承载用户或 Manager 状态的纯缓存可以纳入。下列内容始终保护：

- `~/Library/Application Support/Cellar/` 中的版本化 Manager 运行副本、`.runtime` 和未来用户状态；
- Homebrew 安装、Cellar、下载缓存、日志、服务和用户安装记录；
- `~/.nvm`、npm cache、npm 配置、Node 版本和全局包；
- Shell 配置、Oh My Zsh、插件、主题和历史；
- 用户项目、registry 设置以及 App 读取或管理的其他外部工具数据。

### 历史 Agent 开发残留

文件系统通常不能证明某个文件由哪次 Codex、ChatGPT 或其他 Agent 对话创建。历史残留不受本次会话时间限制，但仍必须依赖工程路径、构建元数据、测试沙箱或项目脚本等客观证据。

不得按 `Codex`、`ChatGPT`、`Agent`、`Cellar` 或时间范围进行宽泛匹配删除。

## Agent 对话和工作状态

清理不得扫描、删除或修改：

- Codex、ChatGPT 或其他 Agent 的 conversation、thread 和 session 数据；
- `~/.codex/`、`~/.agents/` 以及 ChatGPT/Codex 的 Application Support 数据；
- Agent 配置、Skill、认证状态和工具配置；
- 仓库内 `.engramory-memory/` 及其他项目决策记录。

这些记录只能作为调查线索，不能成为清理目标。

## 可删除内容

满足项目归属和安全条件后，全面清理应删除：

- 仓库内外属于当前工作树的 DerivedData 和 SwiftPM 构建产物；
- 测试结果、覆盖率输出、构建日志和预览产物；
- 本地生成的 Cellar `.app`、`.dSYM`、`.xcarchive`、DMG 和其他打包输出；
- 签名、导出和验证产生的可再生副本、响应文件、staging、挂载和临时目录；
- 能与当前仓库开发测试建立可靠关联的测试沙箱和临时文件；
- 完整 bundle identifier 对应且不承载用户状态的纯缓存。

删除符号链接时只处理链接本身，不跟随链接递归删除其目标。候选目录包含未知挂载点、路径逃逸、权限异常或所有权异常时，停止处理并报告。

## 禁止删除内容

默认不得删除：

- 源码、测试源码、文档、Git 数据和任务开始前的工作区变更；
- `Cellar.xcodeproj/`、plist、entitlements、受版本控制的配置和依赖声明；
- `scripts/`、`Resources/Managers/` 及其源码、快照和测试资料；
- 证书、私钥、真实钥匙串、provisioning profile、Token、公证凭据和签名配置；
- `xcuserdata`、断点、个人 scheme 和编辑器状态；
- Application Support、用户配置、外部开发环境、真实运行日志和用户项目；
- Agent 对话、session、配置、Skill、认证状态、Memory 和项目决策记录；
- 已安装 App 和其他机器长期状态，除非用户明确要求恢复开发验证环境且存在精确卸载流程；
- Xcode ModuleCache、SDK 缓存、SwiftPM 下载/仓库缓存及其他跨项目共享缓存；
- 其他仓库、clone 或 worktree 的产物；
- 用途、所有权、项目归属或可再生性无法确认的文件。

普通清理不得停止 Cellar、Xcode、Homebrew 服务或其他进程。相关进程仍在运行时，应说明产物可能立即重新生成。

## 输出集中规则

本地自动验证应继续把 DerivedData 放在仓库内 `build/`。新增测试、Archive 或打包流程时，优先使用：

```text
build/
├── DerivedData-Tests/
├── DerivedData-Debug/
├── DerivedData-Release/
├── TestResults/
├── Archives/
├── Products/
├── Packages/
└── Temp/
```

在命令支持的前提下显式设置 `-derivedDataPath`、`-resultBundlePath` 和 `-archivePath`。测试脚本需要系统临时目录时，应使用精确测试前缀、隔离 HOME 和工具环境，并为正常及异常退出设置清理。

## 执行流程

1. 确认当前 Git 根目录、实际工作树和本文件中的项目定义。
2. 检查工作树状态；已有修改和未跟踪文件属于用户内容，除非与明确列出的生成物完全匹配，否则不得处理。
3. 根据请求语义确定仅审计仓库内、同时审计仓库外，还是进一步恢复开发安装和验证状态。
4. 收集候选项，解析绝对路径和符号链接，去除重复、嵌套和互相覆盖的目标。
5. 为每项记录项目归属证据、安全分类以及保留或删除理由。
6. 使用一致口径统计删除前大小；父目录已计入时，不重复计算子目录。
7. 只删除同时满足项目归属、可再生性和非用户数据要求的精确目标。
8. 使用同一口径重新统计，并计算每项实际释放空间。
9. 再次扫描相同范围，记录残留和保留原因。
10. 检查 Git 状态，确认没有影响受版本控制文件或任务开始前的工作区变更。
11. 确认 Agent 对话、配置、Skill、认证状态和 Memory 未被扫描或修改。

不得为了扩大范围使用 `sudo`，不得修改权限或所有权。

## 结果报告

| 项目 | 路径 | 归属证据 | 清理前 | 清理后 | 实际释放 | 结果 |
|---|---|---|---:|---:|---:|---|
| `<artifact>` | `<absolute-path>` | `<evidence>` | `<size>` | `<size>` | `<size>` | `<deleted/retained/failed>` |

随后汇总删除的主要目录、每项和总实际释放空间、保留项及原因、未处理范围和可能重新生成产物的相关进程。

总数只能对规范化、去重后的非重叠目标求和。APFS clone、稀疏文件或文件系统记账可能使逻辑大小与实际磁盘回收量不同，必须说明统计口径。

完成结论应表述为：所有能够可靠归属于当前 Cellar 工作树、可安全重新生成的开发产物均已清除；共享缓存、Agent 对话和状态、用户环境、App 数据、机器长期状态以及无法可靠归属的系统记录未处理。
