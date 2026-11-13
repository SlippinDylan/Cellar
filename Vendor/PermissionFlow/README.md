# Cellar 使用的 PermissionFlow

上游：[jaywcjlove/PermissionFlow](https://github.com/jaywcjlove/PermissionFlow)。固定来源提交：`65434c9ae04dba97cf52c1dffbe3e4e62b547c82`。许可为 MIT，完整许可见同目录 `LICENSE`，App 内另打包 `Resources/PermissionFlow-LICENSE.txt`。

这里直接保留上游 `Sources/PermissionFlow` 与 `Sources/SystemSettingsKit`，只导出这两个产品，不包含其他权限扩展。沿用原版面板、翻译及原生 App 拖拽；保留单屏跟随布局，并维护下述多屏几何、字号与减少动态效果补丁。`UPSTREAM.json` 记录全部原始来源文件摘要，便于更新时复核本地补丁。

## 本地维护的补丁

- `PermissionFlowController.swift`：`authorize` 返回 `Bool`，在记录原前台应用后只打开一次系统设置，打开失败不呈现引导；本地宿主不再预先打开。关闭清空当前任务状态，回到原前台应用仍由原版流程负责。导航、前台应用及呈现边界可注入纯测试夹具，不在测试中打开系统设置或读取权限 provider。主线程回调直接消费窗口结束事件，防止旧事件延迟关闭后来重开的引导。
- `Tracking/SettingsWindowTracker.swift`：保留原版 30 Hz 跟随及 AX/Window Server 几何读取；仅当系统设置窗口曾可见、随后连续 12 次不可见时结束引导。隐藏、最小化、关闭窗口或退出进程都按同一可见性状态处理，不再只依赖进程退出。结束时停止 Timer、移除观察并清空状态，已排队回调不能重启已停止的观察。首次冷启动使用独立的 10 秒单调时钟期限，不按 12 次采样误关正常启动；始终没有可见窗口、设置进程启动后又退出等情况最多等待 10 秒便结束并回收。用户可通过原版关闭按钮提前取消，结束后可重新点击宿主授权按钮开启并获得新的启动期限。
- `Tracking/SettingsWindowTrackingState.swift`：新增纯状态，区分冷启动、短暂丢失与连续丢失，供 tracker 与隔离回归测试共同使用，启动期限与可见后丢失的采样次数分别建模。tracker 可注入单调时钟与几何探测夹具，测试真实状态接线与停止行为时不访问真实 App、Window Server 或 AX。
- `Tracking/ScreenGeometry.swift`、`Tracking/SettingsWindowTracker.swift` 与 `UI/FloatingDropPanel.swift`：坐标转换与面板定位统一按窗口和屏幕的最大相交面积选屏，避免跨屏窗口仅少量覆盖首屏时把面板拉回首屏。保留原版单屏侧栏对齐、屏幕边距及纵向补偿；面板受所选屏幕的可见区域约束，离屏时使用主屏回退，不增加权限请求。纯几何测试直接覆盖生产转换与定位函数，包含左右／上下排列、屏幕顺序、跨屏回归和离屏回退。
- `UI/AppDropArea.swift`：拖拽提示从 8 点 Light 调整为 10 点 Regular，提高可读性；原生拖拽实现不变。
- `UI/PermissionFlowPanelView.swift`：方向图标响应系统“减少动态效果”，启用时保持静止，关闭后按当前拖拽状态恢复原版重复动画。系统偏好动态切换时移除旧动画并重置阶段。
- `Package.swift`：仅保留上述两个核心产品及隔离测试 target，平台限定为当前宿主需要的 macOS。

Cellar 不调用 PermissionFlow 的完整磁盘权限状态 provider。绿色“访问已验证”继续由 Cellar 自身的受保护目录只读验证提供；`promptForAccessibilityTrust` 保持关闭，不为跟随申请辅助功能或屏幕录制权限。

## 验证

```bash
swift test --package-path Vendor/PermissionFlow --scratch-path build/PermissionFlow-Package-Tests
```

上述测试只用假的导航、前台、呈现边界及窗口可见性数据，不触真实系统设置、权限 provider、用户软件或窗口。真实面板外观、拖拽接收和多屏跟随仍由宿主的人工验收覆盖。
