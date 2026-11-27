import SwiftUI

struct NodeTaskConfirmation: View {
    let plan: NodeActionPlan
    let cancel: () -> Void
    let confirm: () async -> String?

    @State private var isRunning = false
    @State private var hasFinished = false
    @State private var errorMessage: String?

    var body: some View {
        MaintenanceModalFrame(
            title: title,
            systemImage: isDestructive ? "trash.fill" : "slider.horizontal.3",
            tint: isDestructive ? .red : .green
        ) {
            if isRunning {
                Text("Running").foregroundStyle(.secondary)
            } else if hasFinished {
                Text(errorMessage == nil ? LocalizedStringResource("Completed") : LocalizedStringResource("Operation Failed"))
                    .foregroundStyle(errorMessage == nil ? .green : .orange)
            } else {
                Text("Node.js").foregroundStyle(.secondary)
            }
        } content: {
            if isRunning {
                MaintenanceLoadingState(title: LocalizedStringResource("Running"))
            } else if hasFinished {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(errorMessage == nil ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(errorMessage == nil ? LocalizedStringResource("Completed") : LocalizedStringResource("Operation Failed"))
                            .font(.headline)
                        if let errorMessage {
                            Text(verbatim: errorMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                MaintenanceDetailWell(maxHeight: 240) {
                    VStack(alignment: .leading, spacing: 10) {
                        if plan.request.action == .cleanup, let action = NodeMaintenanceAction(rawValue: plan.request.subject) {
                            Text(action.detail).font(.callout).foregroundStyle(.secondary)
                            ForEach(plan.payload.paths ?? [], id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                            if action == .logs {
                                Text("The current maintenance task counts as one of the 100 retained logs.").font(.callout).foregroundStyle(.secondary)
                                if plan.maintenanceCandidates.isEmpty { Text("No Older Logs to Remove").foregroundStyle(.secondary) }
                                ForEach(plan.maintenanceCandidates, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                            }
                        } else if plan.request.action.isRegistryConfiguration {
                            Text("Change the user npm configuration for this Node environment. Higher priority project settings can still override it.")
                                .font(.callout).foregroundStyle(.secondary)
                            if let effective = plan.payload.effectiveRegistry { LabeledContent("Effective Registry", value: DiagnosticText.sanitized(effective)) }
                            if !plan.request.subject.isEmpty { Text(plan.request.subject).font(.callout.monospaced()).textSelection(.enabled) }
                            if let value = plan.request.value { Text(value).font(.callout.monospaced()).textSelection(.enabled) }
                            if [.deleteRegistry, .deleteScopeRegistry].contains(plan.request.action) {
                                Text("Removing the user setting reveals the next applicable Registry configuration.").font(.callout).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(plan.request.subject).font(.body.monospaced())
                            if plan.request.action == .uninstallNode {
                                Text("This Node installation and its global npm packages will be removed. This cannot be rolled back.").font(.callout).foregroundStyle(.secondary)
                                if let path = plan.payload.versionDir { Text(path).font(.callout.monospaced()).textSelection(.enabled) }
                                if let packages = plan.payload.globalPackageSummary { Text(packages).font(.callout).textSelection(.enabled) }
                            } else {
                                Text("Future nvm sessions will use this version. Existing terminals are not changed.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if !plan.canExecute {
                            Label { Text(plan.blockingMessage) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            if isRunning {
                Text("Running").foregroundStyle(.secondary)
            } else if hasFinished {
                Button("OK", action: cancel)
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(role: isDestructive ? .destructive : nil) {
                    guard !isRunning else { return }
                    isRunning = true
                    Task {
                        errorMessage = await confirm()
                        isRunning = false
                        hasFinished = true
                    }
                } label: { Text(isDestructive ? LocalizedStringResource("Remove") : LocalizedStringResource("Save Changes")) }
                    .buttonStyle(.glassProminent)
                    .tint(isDestructive ? .red : .blue)
                    .disabled(!plan.canExecute)
            }
        }
        .interactiveDismissDisabled(isRunning)
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
