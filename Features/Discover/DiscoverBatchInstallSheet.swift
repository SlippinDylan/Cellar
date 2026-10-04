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
                let count = String(preview.intent.items.count)
                Text("\(count) Items to Install").font(.headline)
                Text("Installation runs one item at a time. A failure does not stop other items. Completed installations cannot be rolled back.")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.intent.items, id: \.self) { Text($0.displayIdentifier).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 260)
                HStack {
                    Button("Back", action: installation.dismissPreview)
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                    Button("Install") { Task { dismiss(); await installation.confirmInstall() } }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Picker("Install Scope", selection: $scope) {
                    ForEach(CatalogProviderScope.allCases, id: \.self) { Text($0.cardTitle).tag($0) }
                }.pickerStyle(.segmented)
                if scope == .npm, let npm = context.npm { DiscoverNPMContextView(context: npm) }
                Text("Enter one package per line. Blank lines and duplicate entries are removed. Maximum 100 items from one scope.")
                TextEditor(text: $input)
                    .font(.body.monospaced())
                    .accessibilityLabel("Packages to Install")
                    .frame(minHeight: 140, maxHeight: 220)
                    .border(.separator)
                if let error = installation.error { Text(error.discoverMessage).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                    Button("Review Installation") { installation.preview(input, scope: scope) }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                            HStack(alignment: .firstTextBaseline) {
                                Text(outcome.item.displayIdentifier).textSelection(.enabled)
                                Spacer()
                                Text(outcome.status.discoverTitle)
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
        case .installationFailed: LocalizedStringResource("Installation could not start. Refresh and check the selected packages, then try again.")
        }
    }
}
