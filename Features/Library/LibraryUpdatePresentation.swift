import SwiftUI

struct UpdatesConfirmationSheet: View {
    let confirmation: UpdatesConfirmation
    @ObservedObject var updates: PackageUpdatesModel
    @Environment(\.dismiss) private var dismiss
    private var eligibleCount: String { String(confirmation.plan.executableCount) }
    private var totalCount: String { String(confirmation.plan.groups.reduce(0) { $0 + $1.items.count }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update All in This Scope").font(.title2.bold())
            Text(confirmation.scope == .homebrew && confirmation.subtype != .all ? (confirmation.subtype == .formula ? LocalizedStringResource("Homebrew · Formula") : LocalizedStringResource("Homebrew · Cask")) : confirmation.scope.libraryTitle)
            Text("\(eligibleCount) of \(totalCount) Items Can Be Updated")
            Text("Updates run one item at a time. A failure does not stop other items. Completed updates cannot be rolled back.")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(confirmation.plan.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.intent.scope.updatesTitle).font(.headline)
                            if let binding = group.npmBindings.first {
                                Text("Node Environment: \(binding.environment.nodeVersion) · npm \(binding.environment.npmVersion)")
                                DiscoverNPMDestinationView(destination: binding.destination)
                            }
                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.item.displayIdentifier).textSelection(.enabled)
                                    Text(item.status.updatesTitle).foregroundStyle(.secondary)
                                    if let binding = group.npmBindings.first(where: { $0.item == item.item }) {
                                        if let target = binding.targetVersion { Text("Available: \(target)") }
                                        Text("Registry: \(binding.registryURL.absoluteString)").foregroundStyle(.secondary)
                                    }
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { updates.dismissConfirmation(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Update All") { Task { await updates.confirmUpdateAll() } }
                    .keyboardShortcut(.defaultAction).disabled(confirmation.plan.executableCount == 0)
            }
        }.padding(24).frame(width: 520)
    }
}

struct UpdatesResultView: View {
    let result: BatchUpdateExecutionResult
    var body: some View {
        GroupBox("Update Results") {
            VStack(alignment: .leading, spacing: 12) {
                if result.groups.contains(where: { $0.refreshStatus == .failed }) {
                    Label("Updates finished, but an environment could not be refreshed. Item results are retained. Use Refresh to check the current state.", systemImage: "exclamationmark.circle")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(result.groups.enumerated()), id: \.offset) { _, group in
                            Text(group.outcome.intent.scope.updatesTitle).font(.headline)
                            ForEach(group.outcome.itemOutcomes, id: \.item) { outcome in
                                ViewThatFits(in: .horizontal) {
                                    HStack { Text(outcome.item.displayIdentifier); Spacer(); Text(outcome.status.updatesTitle) }
                                    VStack(alignment: .leading) { Text(outcome.item.displayIdentifier); Text(outcome.status.updatesTitle) }
                                }.accessibilityElement(children: .combine)
                                if let reason = outcome.reason { Text(reason.message).foregroundStyle(.secondary) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 200)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
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
