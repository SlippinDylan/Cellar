import SwiftUI

struct LibraryResultView: View {
    let result: BatchExecutionResult
    var dismiss: (() -> Void)? = nil

    var body: some View {
        GroupBox {
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
                                if let reason = outcome.reason { Text(reason.message).foregroundStyle(.secondary) }
                                ForEach(Array(removalFailures(for: outcome.item).enumerated()), id: \.offset) { _, failure in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(failure.path).textSelection(.enabled)
                                        Text(failure.recoveryReason.message).font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                                let paths = residualPaths(for: outcome.item)
                                if !paths.isEmpty {
                                    if case .npm = outcome.item {
                                        Text("Remaining npm Files").foregroundStyle(.secondary)
                                        if outcome.status == .partiallySucceeded {
                                            Text("The package was removed. These paths remain.").foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text("Remaining Artifacts").foregroundStyle(.secondary)
                                    }
                                    ForEach(paths, id: \.self) { Text($0).textSelection(.enabled) }
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }.frame(maxHeight: 160)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            HStack {
                Text("Uninstall Results")
                Spacer()
                if let dismiss {
                    Button("Dismiss Feedback", systemImage: "xmark", action: dismiss)
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                        .help("Dismiss Feedback")
                }
            }
        }
    }

    private func removalFailures(for item: BatchItem) -> [CaskRemovalFailure] {
        guard let index = result.outcome.intent.items.firstIndex(of: item),
              case .homebrew(let providerResult) = result.providerResults[index] else { return [] }
        return providerResult.caskRemovalFailures
    }

    func residualPaths(for item: BatchItem) -> [String] {
        guard let index = result.outcome.intent.items.firstIndex(of: item) else { return [] }
        switch result.providerResults[index] {
        case .homebrew(let providerResult): return providerResult.remainingResidualPaths.map(\.path)
        case .npm(let providerResult):
            guard let residues = providerResult.residues else { return [] }
            return residues.directories + residues.bins
        case .nodeRuntime, nil: return []
        }
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
        case .skipped: LocalizedStringResource("Skipped")
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
        case .unknown: LocalizedStringResource("Result Unknown")
        }
    }
}
