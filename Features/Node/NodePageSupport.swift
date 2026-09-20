import SwiftUI

struct NodePageContainer<Content: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder let content: (NodeSnapshot) -> Content

    var body: some View {
        if let node = model.node {
            content(node)
        } else if model.isRefreshing {
            PageLoadingView(message: "正在读取 Node 环境…")
        } else {
            ContentUnavailableView(
                "无法读取 Node",
                systemImage: "shippingbox",
                description: Text(model.errorMessages.first(where: { $0.hasPrefix("Node") }) ?? "请刷新后重试")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension NodeAction {
    var title: String {
        switch self {
        case .installPackage: "安装全局包"
        case .uninstallPackage: "卸载全局包"
        case .updatePackage: "更新全局包"
        case .setRegistry: "设置默认 Registry"
        case .deleteRegistry: "删除用户 Registry"
        case .setScopeRegistry: "设置 Scope Registry"
        case .deleteScopeRegistry: "删除 Scope Registry"
        case .installNVM: "安装 nvm"
        case .installNode: "安装 Node"
        case .useNode: "用于本次 Cellar 会话"
        case .setDefaultNode: "设为默认 Node"
        case .uninstallNode: "卸载 Node"
        case .cleanup: "维护 Node 环境"
        case .writeProjectNVMRC: "写入项目 .nvmrc"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .uninstallPackage, .deleteRegistry, .deleteScopeRegistry, .uninstallNode, .cleanup: true
        default: false
        }
    }
}

extension NodeActionPlan {
    var displayTarget: String {
        payload.packageSpec ?? payload.packageName ?? payload.normalizedVersion
            ?? payload.nvmrcPath ?? payload.subject ?? request.subject
    }
}
