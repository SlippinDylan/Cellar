import SwiftUI

struct DiscoverBatchInstallSheet: View {
    @ObservedObject var installation: DiscoverInstallationModel
    let context: DiscoverContext
    @State private var scope: CatalogProviderScope
    @State private var input = ""
    @Environment(\.dismiss) private var dismiss

    init(installation: DiscoverInstallationModel, context: DiscoverContext, initialScope: CatalogProviderScope) {
        self.installation = installation
        self.context = context
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install Software").font(.title2.bold())
            if let preview = installation.preview {
                Text(preview.intent.scope.libraryTitle).font(.headline)
                if let npm = preview.npm { DiscoverNPMContextView(context: npm) }
                else if case .npm(let environment) = preview.intent.scope {
                    Text("Node Environment: \(environment.nodeVersion) · npm \(environment.npmVersion)")
                }
                let count = String(preview.plan.executableCount)
                let total = String(preview.intent.items.count)
                Text("\(count) of \(total) Items Can Be Installed").font(.headline)
                Text("Installation runs one item at a time. A failure does not stop other items. Completed installations cannot be rolled back.")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if let binding = preview.plan.npmBindings.first { DiscoverNPMDestinationView(destination: binding.destination) }
                        ForEach(preview.plan.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.item.displayIdentifier).textSelection(.enabled)
                                Text(item.status.discoverTitle).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 260)
                HStack {
                    Button("Back", action: installation.dismissPreview)
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                    Button("Install") { Task { dismiss(); await installation.confirmInstall() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview.plan.executableCount == 0)
                }
            } else {
                Picker("Install Scope", selection: $scope) {
                    ForEach(CatalogProviderScope.allCases, id: \.self) { Text($0.cardTitle).tag($0) }
                }.pickerStyle(.segmented).disabled(installation.isPreparing)
                if scope == .npm, let npm = context.npm { DiscoverNPMContextView(context: npm, isDefault: true) }
                Text("Enter one package per line. Blank lines and duplicate entries are removed. Maximum 100 items from one scope.")
                TextEditor(text: $input)
                    .font(.body.monospaced())
                    .accessibilityLabel("Packages to Install")
                    .frame(minHeight: 140, maxHeight: 220)
                    .border(.separator)
                    .disabled(installation.isPreparing)
                if installation.isPreparing { ProgressView("Checking Installation…") }
                if let error = installation.error { Text(error.discoverMessage).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                    Button("Review Installation") { Task { await installation.preview(input, scope: scope) } }
                        .disabled(installation.isPreparing || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24).frame(width: 520)
    }

    private func cancel() { installation.dismissPreview(); dismiss() }
}

struct DiscoverInstallResultView: View {
    let result: BatchExecutionResult
    var body: some View {
        GroupBox("Installation Results") {
            VStack(alignment: .leading, spacing: 8) {
                if result.refreshStatus == .failed {
                    Label("Installation finished, but the environment could not be refreshed. Use Refresh to check the current state.", systemImage: "exclamationmark.circle")
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(result.outcome.itemOutcomes, id: \.item) { outcome in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(outcome.item.displayIdentifier).textSelection(.enabled)
                                    Spacer()
                                    Text(outcome.status.discoverTitle)
                                }
                                if let reason = outcome.reason { Text(reason.message).foregroundStyle(.secondary) }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }.frame(maxHeight: 160)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

extension BatchItemStatus {
    var discoverTitle: LocalizedStringResource {
        self == .succeeded ? LocalizedStringResource("Installed") : libraryTitle
    }
}

extension DiscoverInputError {
    var discoverMessage: LocalizedStringResource {
        switch self {
        case .empty: LocalizedStringResource("Enter at least one package.")
        case .tooMany: LocalizedStringResource("Use up to 100 packages in one installation.")
        case .invalidTarget: LocalizedStringResource("Use package names from the selected scope. npm also accepts a version or tag. URLs, local paths and mixed scopes are not supported.")
        case .missingContext: LocalizedStringResource("Refresh and check Homebrew, or the target Node environment and Registry, before installing.")
        case .staleContext: LocalizedStringResource("The target environment or Registry changed. Review the installation again.")
        case .sourceMismatch: LocalizedStringResource("This package uses another Registry. Search its full @scope/name to use that source before installing.")
        case .mixedRegistries: LocalizedStringResource("These packages use different Registries. Install them in separate batches so each source can be confirmed.")
        case .installationFailed: LocalizedStringResource("Installation could not start. Refresh and check the selected packages, then try again.")
        }
    }
}

extension BatchPreparationStatus {
    var discoverTitle: LocalizedStringResource {
        switch self {
        case .ready: LocalizedStringResource("Ready to Install")
        case .unavailable: LocalizedStringResource("Unavailable · Will Not Install")
        case .alreadyInstalled: LocalizedStringResource("Already Installed · Will Not Install")
        }
    }
}
