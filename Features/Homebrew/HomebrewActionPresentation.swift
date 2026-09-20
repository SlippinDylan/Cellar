import Foundation

extension HomebrewActionPlan {
    var title: String {
        switch action {
        case .install: "安装软件包"
        case .upgrade: "升级软件包"
        case .update: "更新 Homebrew 元数据"
        case .addTap: "添加 Tap"
        case .removeTap: "移除 Tap"
        case .uninstallFormula: "卸载 Formula"
        case .uninstallCask: "普通卸载 Cask"
        case .zapCask: "Zap 卸载 Cask"
        }
    }

    var confirmationTitle: String {
        switch action {
        case .install: "确认安装"
        case .upgrade: "确认升级"
        case .update: "确认更新"
        case .addTap: "确认添加"
        case .removeTap: "确认移除"
        case .uninstallFormula, .uninstallCask: "确认卸载"
        case .zapCask: "确认 Zap 卸载"
        }
    }

    var isDestructive: Bool {
        switch action {
        case .removeTap, .uninstallFormula, .uninstallCask, .zapCask: true
        case .install, .upgrade, .update, .addTap: false
        }
    }
}

func formattedByteCount(_ byteCount: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
}
