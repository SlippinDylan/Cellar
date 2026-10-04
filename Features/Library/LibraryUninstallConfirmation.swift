import SwiftUI

struct LibraryUninstallConfirmation: View {
    let plan: BatchPlan
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Uninstall Software").font(.title2.bold())
            Text(plan.intent.scope.libraryTitle).font(.headline)
            if let environment = plan.intent.scope.nodeEnvironment {
                Text("Node Environment: \(environment.nodeVersion) · npm \(environment.npmVersion)")
            }
            Text("These items will be removed. This cannot be rolled back. Items run in order; a failure does not undo completed items.")
            if plan.intent.scope == .homebrew(.cask) {
                Text("Standard Cask Uninstall").font(.headline)
                Text("Homebrew removes the listed app artifacts. Preferences and support files may remain.")
            }
            if case .nodeRuntime = plan.intent.scope {
                Text("Each selected Node installation and its global npm packages will be removed. Current and default Node versions are protected.")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.intent.items, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayIdentifier).font(.body.monospaced()).textSelection(.enabled)
                            ForEach(artifacts(for: item), id: \.self) { Text($0).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive, action: confirm)
            }
        }
        .padding(24).frame(width: 520)
    }

    private func artifacts(for item: BatchItem) -> [String] {
        guard case .homebrew(let identity) = item else { return [] }
        return plan.homebrewImpacts.first { $0.targets == [identity] }?.artifacts
            .filter { $0.category == .installed }.flatMap(\.values) ?? []
    }
}

struct LibraryResultView: View {
    let result: BatchExecutionResult

    var body: some View {
        GroupBox("Uninstall Results") {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.outcome.status.libraryTitle).font(.headline)
                if result.refreshStatus == .failed {
                    Label("Uninstall finished, but the environment could not be refreshed. Use Refresh to check the current state.", systemImage: "exclamationmark.circle")
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(result.outcome.itemOutcomes, id: \.item) { outcome in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(outcome.item.displayIdentifier).textSelection(.enabled)
                                    Spacer()
                                    Text(outcome.status.libraryTitle)
                                }
                                let paths = residualPaths(for: outcome.item)
                                if !paths.isEmpty {
                                    Text("Remaining Artifacts").foregroundStyle(.secondary)
                                    ForEach(paths, id: \.self) { Text($0).textSelection(.enabled) }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }.frame(maxHeight: 160)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func residualPaths(for item: BatchItem) -> [String] {
        guard let index = result.outcome.intent.items.firstIndex(of: item),
              case .homebrew(let providerResult) = result.providerResults[index]
        else { return [] }
        return providerResult.remainingResidualPaths.map(\.path)
    }
}

extension BatchScope {
    var libraryTitle: LocalizedStringResource {
        switch self {
        case .homebrew(.formula): LocalizedStringResource("Homebrew · Formula")
        case .homebrew(.cask): LocalizedStringResource("Homebrew · Cask")
        case .npm: LocalizedStringResource("npm Global Packages")
        case .nodeRuntime: LocalizedStringResource("Node Runtime")
        }
    }

    var nodeEnvironment: NodeEnvironmentContext? {
        switch self {
        case .npm(let environment), .nodeRuntime(let environment): environment
        case .homebrew: nil
        }
    }
}

extension BatchItemStatus {
    var libraryTitle: LocalizedStringResource {
        switch self {
        case .succeeded: LocalizedStringResource("Uninstalled")
        case .partiallySucceeded: LocalizedStringResource("Partially Completed")
        case .failed: LocalizedStringResource("Failed")
        case .cancelled: LocalizedStringResource("Cancelled")
        case .unknown: LocalizedStringResource("Result Unknown")
        }
    }
}

extension ActivityStatus {
    var libraryTitle: LocalizedStringResource {
        switch self {
        case .running: LocalizedStringResource("Running")
        case .succeeded: LocalizedStringResource("Uninstall Completed")
        case .partiallySucceeded: LocalizedStringResource("Partially Completed")
        case .failed: LocalizedStringResource("Uninstall Failed")
        case .cancelled: LocalizedStringResource("Cancelled")
        }
    }
}
