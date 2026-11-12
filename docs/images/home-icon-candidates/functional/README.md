# 首页尚未替换图标的候选

下载日期：2026-11-12。这六类图标已接入首页剩余七张统计卡片（两处更新共用一个资源），通过 `Resources/BrandIcons.xcassets` 编译打包，已接入的六个品牌图标保持不变。除 Command Line Tools 使用 Apple 终端 App 官方图标外，其余素材来自微软 Fluent UI System Color Icons，采用彩色填充与渐变；微软图标是功能示意图，不是这些统计项的官方品牌 Logo。

| 首页用途 | 候选文件 | 固定版本来源 |
|---|---|---|
| Formula：代码块 | [formula-code.svg](formula-code.svg) | [来源](https://github.com/microsoft/fluentui-system-icons/blob/4bf6b786b16f120595efcee8911c74392fa29c14/assets/Code%20Block/SVG/ic_fluent_code_block_24_color.svg) |
| Cask：应用网格 | [cask-apps.svg](cask-apps.svg) | [来源](https://github.com/microsoft/fluentui-system-icons/blob/4bf6b786b16f120595efcee8911c74392fa29c14/assets/Apps/SVG/ic_fluent_apps_24_color.svg) |
| 更新：向上箭头 | [updates-up.svg](updates-up.svg) | [原始向上箭头](https://github.com/microsoft/fluentui-system-icons/blob/4bf6b786b16f120595efcee8911c74392fa29c14/assets/Arrow%20Up/SVG/ic_fluent_arrow_up_24_filled.svg) |
| 全局包：软件库 | [global-packages.svg](global-packages.svg) | [来源](https://github.com/microsoft/fluentui-system-icons/blob/4bf6b786b16f120595efcee8911c74392fa29c14/assets/Library/SVG/ic_fluent_library_24_color.svg) |
| nvm 默认版本：选中标记 | [nvm-default.svg](nvm-default.svg) | [来源](https://github.com/microsoft/fluentui-system-icons/blob/4bf6b786b16f120595efcee8911c74392fa29c14/assets/Checkmark%20Circle/SVG/ic_fluent_checkmark_circle_24_color.svg) |
| Command Line Tools：Apple 终端图标 | [apple-terminal.png](apple-terminal.png) | 从本机 `/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.icns` 导出；系统版本 macOS 27.0.1 |

更新图标使用 Fluent 的实心向上箭头，原文件保存为 `arrow-up-original.svg`；`updates-up.svg` 仅将其填充适配为原更新图标的青绿渐变，几何轮廓保持不变。旧循环箭头 `updates.svg` 留作来源记录，首页不再使用。Command Line Tools 按用户选择使用 Apple 终端 App 的官方图标，原图转换为 256 × 256 透明 PNG；它仅作为该安装状态卡片的图示，不改变功能或安装检测。原工具箱 SVG 留作参考，不再打包。其余四个正在使用的微软图标均保留下载原文，许可原文见 [LICENSE.txt](LICENSE.txt)，校验值见 [SHA256SUMS](SHA256SUMS)。主统计项的图标候选不涉及版本号后的更新小标、官网链接或侧边栏图标。
