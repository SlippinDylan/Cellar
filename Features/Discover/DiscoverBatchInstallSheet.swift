import SwiftUI

struct DiscoverBatchInstallSheet: View {
    @ObservedObject var installation: DiscoverInstallationModel
    let context: DiscoverContext
    @State private var scope: CatalogProviderScope
    @State private var input = ""
    @State private var activeTask: Task<Void, Never>?
    @State private var isStartingPreview = false
    @State private var isStartingInstall = false
    @Environment(\.dismiss) private var dismiss

    init(installation: DiscoverInstallationModel, context: DiscoverContext, initialScope: CatalogProviderScope) {
        self.installation = installation
        self.context = context
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        MaintenanceModalFrame(
            title: LocalizedStringResource("Batch Install"),
            systemImage: "square.stack.3d.up.fill",
            tint: .blue
        ) {
            if installation.isSubmitting {
                Text("Running").foregroundStyle(.secondary)
            } else if installation.result != nil {
                Text("Installation Results").foregroundStyle(.secondary)
            } else if let preview = installation.preview {
                Text(preview.intent.scope.libraryTitle).foregroundStyle(.secondary)
            } else {
                Text("Install Scope").foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if !installation.isSubmitting && installation.result == nil {
                    GlassCategoryPicker(selection: $scope, label: "Install Scope", title: scopeTitle)
                        .disabled(installation.isPreparing || installation.preview != nil)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if installation.isSubmitting {
                    MaintenanceLoadingState(title: "Running")
                } else if let result = installation.result {
                    DiscoverInstallResultView(result: result)
                } else if let preview = installation.preview {
                    if let npm = preview.npm { DiscoverNPMContextView(context: npm) }
                    else if case .npm(let environment) = preview.intent.scope {
                        Text("Node Environment: \(environment.nodeVersion) · npm \(environment.npmVersion)")
                    }
                    let count = String(preview.plan.executableCount)
                    let total = String(preview.intent.items.count)
                    Text("\(count) of \(total) Items Can Be Installed").font(.headline)
                    Text("Installation runs one item at a time. A failure does not stop other items. Completed installations cannot be rolled back.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    MaintenanceDetailWell(maxHeight: 220) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if let binding = preview.plan.npmBindings.first { DiscoverNPMDestinationView(destination: binding.destination) }
                            ForEach(preview.plan.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.item.displayIdentifier).textSelection(.enabled)
                                    Text(item.status.discoverTitle).foregroundStyle(.secondary)
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                } else {
                    if scope == .npm, let npm = context.npm { DiscoverNPMContextView(context: npm, isDefault: true) }
                    Text("Enter one package per line. Blank lines and duplicate entries are removed. Maximum 100 items from one scope.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    BatchPackageEditor(text: $input, isEditable: !installation.isPreparing)
                        .frame(height: 184)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                                .allowsHitTesting(false)
                        }
                    if installation.isPreparing { ProgressView("Checking Installation…") }
                    if let error = installation.error { Text(error.discoverMessage).foregroundStyle(.secondary) }
                }
            }
        } footer: {
            if installation.isSubmitting || isStartingInstall {
                Spacer()
            } else if installation.result != nil {
                Spacer()
                Button("OK") {
                    installation.dismissResult()
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .keyboardShortcut(.defaultAction)
            } else if let preview = installation.preview {
                Button("Back", action: installation.dismissPreview)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Install") {
                    guard !isStartingInstall, !installation.isSubmitting else { return }
                    isStartingInstall = true
                    activeTask = Task {
                        await installation.confirmInstall()
                        isStartingInstall = false
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .keyboardShortcut(.defaultAction)
                .disabled(preview.plan.executableCount == 0)
            } else {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Review Installation") {
                    guard !isStartingPreview, !installation.isPreparing else { return }
                    isStartingPreview = true
                    activeTask = Task {
                        await installation.preview(input, scope: scope)
                        isStartingPreview = false
                    }
                }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .disabled(installation.isPreparing || isStartingPreview || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .interactiveDismissDisabled(installation.isSubmitting || isStartingInstall)
        .onDisappear {
            if !installation.isSubmitting && !isStartingInstall {
                activeTask?.cancel()
                activeTask = nil
                installation.dismissPreview()
                installation.dismissResult()
            }
        }
    }

    private func scopeTitle(_ scope: CatalogProviderScope) -> LocalizedStringResource {
        switch scope {
        case .homebrewFormula: "Formula"
        case .homebrewCask: "Cask"
        case .npm: "NPM"
        }
    }

    private func cancel() { installation.dismissPreview(); dismiss() }
}

struct DiscoverInstallResultView: View {
    let result: BatchExecutionResult
    var dismiss: (() -> Void)? = nil
    var body: some View {
        GroupBox {
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
        } label: {
            HStack {
                Text("Installation Results")
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
