import SwiftUI

struct DiscoverBatchInstallSheet: View {
    @ObservedObject var installation: DiscoverInstallationModel
    @ObservedObject private var coordinator: BatchOperationCoordinator
    let context: DiscoverContext
    @State private var scope: CatalogProviderScope
    @State private var input = ""
    @State private var activeTask: Task<Void, Never>?
    @State private var isStartingPreview = false
    @State private var isStartingInstall = false
    @Environment(\.dismiss) private var dismiss

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    init(installation: DiscoverInstallationModel, context: DiscoverContext, initialScope: CatalogProviderScope) {
        self.installation = installation
        coordinator = installation.coordinator
        self.context = context
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        MaintenanceModalFrame(
            title: LocalizedStringResource("Batch Install"),
            systemImage: "square.stack.3d.up.fill",
            tint: .blue,
            width: 540
        ) {
            if installation.isSubmitting {
                if let plan = installation.submittingPlan {
                    Text(plan.intent.scope.libraryTitle).foregroundStyle(.secondary)
                } else {
                    Text("Running").foregroundStyle(.secondary)
                }
            } else if installation.result != nil {
                Text("Installation Results").foregroundStyle(.secondary)
            } else if let preview = installation.preview {
                Text(preview.intent.scope.libraryTitle).foregroundStyle(.secondary)
            } else {
                Text("Install Scope").foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if !installation.isSubmitting && installation.result == nil && installation.preview == nil {
                    GlassCategoryPicker(selection: $scope, label: "Install Scope", title: scopeTitle)
                        .disabled(installation.isPreparing)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if installation.isSubmitting {
                    executingContent
                } else if let result = installation.result {
                    DiscoverInstallResultView(result: result)
                } else if let preview = installation.preview {
                    reviewContent(preview)
                } else {
                    inputContent
                }
            }
        } footer: {
            if installation.isSubmitting || isStartingInstall {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing…").foregroundStyle(.secondary)
                }
                Spacer()
                if let plan = installation.submittingPlan {
                    let progressCounter = "\(coordinator.liveItemOutcomes.count)/\(plan.items.count)"
                    Text(verbatim: progressCounter)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
                if installation.isPreparing || isStartingPreview {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking Installation…").foregroundStyle(.secondary)
                    }
                }
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

    @ViewBuilder private var inputContent: some View {
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
        if let error = installation.error { Text(error.discoverMessage).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func reviewContent(_ preview: DiscoverInstallPreview) -> some View {
        if let npm = preview.npm { DiscoverNPMContextView(context: npm) }
        else if case .npm(let environment) = preview.intent.scope {
            Text("Node Environment: \(environment.nodeVersion) · npm \(environment.npmVersion)")
        }
        let count = String(preview.plan.executableCount)
        let total = String(preview.intent.items.count)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(count) of \(total) Items Can Be Installed").font(.headline)
            Text("Installation runs one item at a time. A failure does not stop other items. Completed installations cannot be rolled back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        MaintenanceDetailWell(maxHeight: 240) {
            VStack(alignment: .leading, spacing: 10) {
                if let binding = preview.plan.npmBindings.first {
                    DiscoverNPMDestinationView(destination: binding.destination)
                    Divider()
                }
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                    ForEach(preview.plan.items) { item in
                        BatchItemStatusTile(name: item.item.displayIdentifier) {
                            Image(systemName: item.status.symbolName)
                                .foregroundStyle(item.status.tint)
                            Text(item.status.compactTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder private var executingContent: some View {
        if let plan = installation.submittingPlan {
            MaintenanceDetailWell(maxHeight: 240) {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                    ForEach(plan.items) { item in
                        BatchItemStatusTile(name: item.item.displayIdentifier) {
                            if coordinator.runningItem == item.item {
                                CatalogCircularProgressView(tint: .accentColor, size: 18, horizontalPadding: 0)
                                    .accessibilityLabel(Text("Installing…"))
                            } else if let status = coordinator.liveItemOutcomes[item.item] {
                                Image(systemName: status.resultSymbolName)
                                    .foregroundStyle(status.resultTint)
                                    .accessibilityLabel(Text(status.discoverTitle))
                            } else {
                                Circle()
                                    .stroke(.quaternary, lineWidth: 2)
                                    .frame(width: 18, height: 18)
                                    .accessibilityLabel(Text("Queued"))
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } else {
            MaintenanceLoadingState(title: "Running")
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

private struct BatchItemStatusTile<Trailing: View>: View {
    let name: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                trailing
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

struct DiscoverInstallResultView: View {
    let result: BatchExecutionResult
    var dismiss: (() -> Void)? = nil

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.refreshStatus == .failed {
                Label("Installation finished, but the environment could not be refreshed. Use Refresh to check the current state.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            MaintenanceDetailWell(maxHeight: 260) {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                        ForEach(result.outcome.itemOutcomes, id: \.item) { outcome in
                            BatchItemStatusTile(name: outcome.item.displayIdentifier) {
                                Image(systemName: outcome.status.resultSymbolName)
                                    .foregroundStyle(outcome.status.resultTint)
                                Text(outcome.status.discoverTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    let notes = result.outcome.itemOutcomes.filter { $0.reason != nil }
                    if !notes.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(notes, id: \.item) { outcome in
                                if let reason = outcome.reason {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(verbatim: outcome.item.displayIdentifier)
                                            .font(.caption.weight(.medium))
                                            .textSelection(.enabled)
                                        Text(reason.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension BatchPreparationStatus {
    var compactTitle: LocalizedStringResource {
        switch self {
        case .ready: LocalizedStringResource("Ready")
        case .alreadyInstalled: LocalizedStringResource("Installed")
        case .unavailable: LocalizedStringResource("Unavailable")
        }
    }

    var symbolName: String {
        switch self {
        case .ready: "circle.dashed"
        case .alreadyInstalled: "checkmark.circle.fill"
        case .unavailable: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .accentColor
        case .alreadyInstalled: .green
        case .unavailable: .orange
        }
    }
}

private extension BatchItemStatus {
    var resultSymbolName: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .skipped, .cancelled: "minus.circle.fill"
        case .failed: "xmark.circle.fill"
        case .partiallySucceeded, .unknown: "exclamationmark.triangle.fill"
        }
    }

    var resultTint: Color {
        switch self {
        case .succeeded: .green
        case .skipped, .cancelled: .secondary
        case .failed: .red
        case .partiallySucceeded, .unknown: .orange
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
