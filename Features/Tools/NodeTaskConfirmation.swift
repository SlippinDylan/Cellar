import SwiftUI

struct NodeTaskConfirmation: View {
    let plan: NodeActionPlan
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if plan.request.action == .cleanup, let action = NodeMaintenanceAction(rawValue: plan.request.subject) {
                        Text(action.detail)
                        ForEach(plan.payload.paths ?? [], id: \.self) { Text($0).textSelection(.enabled) }
                        if action == .logs {
                            Text("The current maintenance task counts as one of the 100 retained logs.")
                            if plan.maintenanceCandidates.isEmpty { Text("No Older Logs to Remove") }
                            ForEach(plan.maintenanceCandidates, id: \.self) { Text($0).textSelection(.enabled) }
                        }
                    } else if plan.request.action.isRegistryConfiguration {
                        Text("Change the user npm configuration for this Node environment. Higher priority project settings can still override it.")
                        if let effective = plan.payload.effectiveRegistry { LabeledContent("Effective Registry", value: DiagnosticText.sanitized(effective)) }
                        if !plan.request.subject.isEmpty { Text(plan.request.subject).textSelection(.enabled) }
                        if let value = plan.request.value { Text(value).textSelection(.enabled) }
                        if [.deleteRegistry, .deleteScopeRegistry].contains(plan.request.action) { Text("Removing the user setting reveals the next applicable Registry configuration.") }
                    } else {
                        Text(plan.request.subject).font(.body.monospaced())
                        if plan.request.action == .uninstallNode {
                            Text("This Node installation and its global npm packages will be removed. This cannot be rolled back.")
                            if let path = plan.payload.versionDir { Text(path).textSelection(.enabled) }
                            if let packages = plan.payload.globalPackageSummary { Text(packages).textSelection(.enabled) }
                        } else { Text("Future nvm sessions will use this version. Existing terminals are not changed.") }
                    }
                    if !plan.canExecute { Label { Text(plan.blockingMessage) } icon: { Image(systemName: "exclamationmark.triangle") } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(role: isDestructive ? .destructive : nil) { confirm() } label: { Text(isDestructive ? LocalizedStringResource("Remove") : LocalizedStringResource("Save Changes")) }
                    .disabled(!plan.canExecute)
            }
        }.padding(24).constrainedSheetWidth(540)
    }
    private var isDestructive: Bool { plan.request.action == .uninstallNode || plan.request.action == .cleanup || [.deleteRegistry, .deleteScopeRegistry].contains(plan.request.action) }
    private var title: LocalizedStringResource {
        switch plan.request.action {
        case .uninstallNode: LocalizedStringResource("Uninstall Node Version")
        case .setDefaultNode: LocalizedStringResource("Set nvm Default")
        case .setRegistry: LocalizedStringResource("Set Default npm Registry")
        case .deleteRegistry: LocalizedStringResource("Remove Default npm Registry Setting")
        case .setScopeRegistry: LocalizedStringResource("Set Scope npm Registry")
        case .deleteScopeRegistry: LocalizedStringResource("Remove Scope npm Registry Setting")
        case .cleanup: NodeMaintenanceAction(rawValue: plan.request.subject)?.title ?? LocalizedStringResource("Node Maintenance")
        default: LocalizedStringResource("Node Configuration")
        }
    }
}
