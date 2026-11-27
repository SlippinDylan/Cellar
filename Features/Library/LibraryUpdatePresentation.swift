import SwiftUI

struct UpdatesConfirmationSheet: View {
    let confirmation: UpdatesConfirmation
    @ObservedObject var updates: PackageUpdatesModel
    @Environment(\.dismiss) private var dismiss
    private var eligibleCount: String { String(confirmation.plan.executableCount) }
    private var totalCount: String { String(confirmation.plan.groups.reduce(0) { $0 + $1.items.count }) }
    private var hasFinished: Bool { !updates.isSubmitting && (updates.result != nil || updates.error != nil) }

    var body: some View {
        MaintenanceModalFrame(
            title: LocalizedStringResource("Update All in This Scope"),
            systemImage: "arrow.up.circle.fill",
            tint: .green,
            width: 540
        ) {
            if updates.isSubmitting {
                Text("Running").foregroundStyle(.secondary)
            } else if hasFinished {
                Text("Update Results").foregroundStyle(.secondary)
            } else {
                Text("\(eligibleCount) of \(totalCount) Items Can Be Updated").foregroundStyle(.secondary)
            }
        } content: {
            if updates.isSubmitting {
                MaintenanceLoadingState(title: LocalizedStringResource("Updating…"))
            } else if let result = updates.result {
                UpdatesResultView(result: result)
            } else if let error = updates.error {
                Label { Text(error.updatesMessage) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Updates run one item at a time. A failure does not stop other items. Completed updates cannot be rolled back.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    MaintenanceDetailWell(maxHeight: 280) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(confirmation.plan.groups) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.intent.scope.updatesTitle).font(.headline)
                                    if let binding = group.npmBindings.first {
                                        Text("Node Environment: \(binding.environment.nodeVersion) · npm \(binding.environment.npmVersion)")
                                            .font(.callout).foregroundStyle(.secondary)
                                        DiscoverNPMDestinationView(destination: binding.destination)
                                    }
                                    ForEach(group.items) { item in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.item.displayIdentifier).textSelection(.enabled)
                                            Text(item.status.updatesTitle).font(.callout).foregroundStyle(.secondary)
                                            if let binding = group.npmBindings.first(where: { $0.item == item.item }) {
                                                if let target = binding.targetVersion { Text("Available: \(target)").font(.callout) }
                                                Text("Registry: \(binding.registryURL.absoluteString)").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }.accessibilityElement(children: .combine)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            if updates.isSubmitting {
                Button {} label: { Text("Updating") }
                    .buttonStyle(.glassProminent)
                    .tint(.green)
                    .disabled(true)
            } else if hasFinished {
                Button("OK") { updates.dismissConfirmation(); dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(.green)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { updates.dismissConfirmation(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Update All") { Task { await updates.confirmUpdateAll() } }
                    .buttonStyle(.glassProminent)
                    .tint(.green)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmation.plan.executableCount == 0)
            }
        }
        .interactiveDismissDisabled(updates.isSubmitting)
    }
}

struct UpdatesResultView: View {
    let result: BatchUpdateExecutionResult
    var dismiss: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.groups.contains(where: { $0.refreshStatus == .failed }) {
                Label("Updates finished, but an environment could not be refreshed. Item results are retained. Use Refresh to check the current state.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            MaintenanceDetailWell(maxHeight: 240) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(result.groups.enumerated()), id: \.offset) { _, group in
                        Text(group.outcome.intent.scope.updatesTitle).font(.headline)
                        ForEach(group.outcome.itemOutcomes, id: \.item) { outcome in
                            ViewThatFits(in: .horizontal) {
                                HStack { Text(outcome.item.displayIdentifier); Spacer(); Text(outcome.status.updatesTitle).foregroundStyle(.secondary) }
                                VStack(alignment: .leading) { Text(outcome.item.displayIdentifier); Text(outcome.status.updatesTitle).foregroundStyle(.secondary) }
                            }.accessibilityElement(children: .combine)
                            if let reason = outcome.reason { Text(reason.message).font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension BatchScope {
    var updatesTitle: LocalizedStringResource {
        switch self {
        case .homebrew(.formula): LocalizedStringResource("Homebrew · Formula")
        case .homebrew(.cask): LocalizedStringResource("Homebrew · Cask")
        case .npm: LocalizedStringResource("npm")
        case .nodeRuntime: LocalizedStringResource("Node Runtime")
        }
    }
}

extension BatchPreparationStatus {
    var updatesTitle: LocalizedStringResource { self == .ready ? LocalizedStringResource("Ready to Update") : LocalizedStringResource("Unavailable · Will Not Update") }
}

extension BatchItemStatus {
    var updatesTitle: LocalizedStringResource { self == .succeeded ? LocalizedStringResource("Updated") : libraryTitle }
}

extension PackageUpdateError {
    var updatesMessage: LocalizedStringResource {
        switch self {
        case .unavailable: LocalizedStringResource("Update could not start. Refresh and check the selected packages, then try again.")
        case .staleContext: LocalizedStringResource("The update state or target Node environment changed. Refresh and review the updates again.")
        }
    }
}

struct PackageUpdateActions {
    let canUpdateAll: Bool
    let updateAll: () -> Void
    let checkUpdates: () -> Void
}
private struct PackageUpdateActionsKey: FocusedValueKey { typealias Value = PackageUpdateActions }
extension FocusedValues {
    var packageUpdateActions: PackageUpdateActions? {
        get { self[PackageUpdateActionsKey.self] }
        set { self[PackageUpdateActionsKey.self] = newValue }
    }
}
