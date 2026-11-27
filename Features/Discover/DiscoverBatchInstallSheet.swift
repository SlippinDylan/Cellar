import SwiftUI

struct DiscoverBatchInstallSheet: View {
    @ObservedObject var installation: DiscoverInstallationModel
    @ObservedObject private var coordinator: BatchOperationCoordinator
    let context: DiscoverContext
    var isBusy: Bool = false
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

    init(installation: DiscoverInstallationModel, context: DiscoverContext, initialScope: CatalogProviderScope, isBusy: Bool = false) {
        self.installation = installation
        coordinator = installation.coordinator
        self.context = context
        self.isBusy = isBusy
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
        } headerTrailing: {
            if let headerCount {
                Text(verbatim: headerCount)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if !installation.isSubmitting && installation.result == nil && installation.preview == nil {
                    GlassCategoryPicker(selection: $scope, label: "Install Scope", title: scopeTitle)
                        .disabled(installation.isPreparing || isStartingPreview)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if installation.isSubmitting {
                    executingContent
                } else if let result = installation.result {
                    DiscoverInstallResultView(result: result, npm: installation.resultNPM)
                } else if let preview = installation.preview {
                    planContent(preview.plan, items: preview.plan.items, npm: preview.npm, isExecuting: false)
                } else {
                    inputContent
                }
            }
        } footer: {
            if installation.isSubmitting || isStartingInstall {
                Spacer()
                Button {} label: { Text("Installing") }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .disabled(true)
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
                Button("Back") {
                    guard !isStartingInstall else { return }
                    installation.dismissPreview()
                }
                .disabled(isStartingInstall)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isStartingInstall)
                Button("Install") {
                    guard !isStartingInstall, !installation.isSubmitting, !isBusy else { return }
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
                .disabled(isBusy)
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
                    guard !isStartingPreview, !installation.isPreparing, !isBusy else { return }
                    isStartingPreview = true
                    activeTask = Task {
                        await installation.preview(input, scope: scope)
                        isStartingPreview = false
                    }
                }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .disabled(installation.isPreparing || isStartingPreview || isBusy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private var headerCount: String? {
        if installation.isSubmitting {
            guard let plan = installation.submittingPlan else { return nil }
            return "\(coordinator.liveItemOutcomes.count)/\(plan.items.count)"
        }
        if let result = installation.result {
            let succeeded = result.outcome.itemOutcomes.count { $0.status == .succeeded }
            return "\(succeeded)/\(result.outcome.itemOutcomes.count)"
        }
        if let preview = installation.preview {
            return "\(preview.plan.executableCount)/\(preview.intent.items.count)"
        }
        return nil
    }

    @ViewBuilder private var inputContent: some View {
        if scope == .npm, let npm = context.npm { DiscoverNPMContextView(context: npm, isDefault: true) }
        Text("Enter one package per line. Blank lines and duplicate entries are removed. Maximum 100 items from one scope.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        BatchPackageEditor(text: $input, isEditable: !installation.isPreparing && !isStartingPreview)
            .frame(height: 248)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
        if let error = installation.error { Text(error.discoverMessage).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func planContent(_ plan: BatchPlan, items: [BatchPreparedItem], npm: DiscoverNPMContext?, isExecuting: Bool) -> some View {
        if let npm { DiscoverNPMContextView(context: npm) }
        else if case .npm(let environment) = plan.intent.scope {
            Text("Node Environment: \(environment.nodeVersion) · npm \(environment.npmVersion)")
        }
        MaintenanceDetailWell(maxHeight: 260) {
            VStack(alignment: .leading, spacing: 10) {
                if let binding = plan.npmBindings.first {
                    DiscoverNPMDestinationView(destination: binding.destination)
                    Divider()
                }
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        BatchItemStatusTile(name: item.item.displayIdentifier) {
                            if isExecuting {
                                if item.status != .ready {
                                    Image(systemName: item.status.symbolName)
                                        .foregroundStyle(item.status.tint)
                                        .frame(width: 18, height: 18)
                                        .accessibilityLabel(Text(item.status.compactTitle))
                                } else if coordinator.runningItem == item.item {
                                    CatalogCircularProgressView(tint: .accentColor, size: 18, horizontalPadding: 0)
                                        .accessibilityLabel(Text("Installing…"))
                                } else if let status = coordinator.liveItemOutcomes[item.item] {
                                    Image(systemName: status.resultSymbolName)
                                        .foregroundStyle(status.resultTint)
                                        .frame(width: 18, height: 18)
                                        .accessibilityLabel(Text(status.discoverTitle))
                                } else {
                                    Circle()
                                        .stroke(.quaternary, lineWidth: 2)
                                        .frame(width: 18, height: 18)
                                        .accessibilityLabel(Text("Queued"))
                                }
                            } else {
                                Image(systemName: item.status.symbolName)
                                    .foregroundStyle(item.status.tint)
                                Text(item.status.compactTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        Text("Installation runs one item at a time. A failure does not stop other items. Completed installations cannot be rolled back.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var executingContent: some View {
        if let plan = installation.submittingPlan {
            planContent(plan, items: plan.items, npm: installation.submittingNPM, isExecuting: true)
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

    private func cancel() {
        guard !isStartingInstall, !installation.isSubmitting else { return }
        installation.dismissPreview()
        dismiss()
    }
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
            .frame(minHeight: 18)
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
    var npm: DiscoverNPMContext? = nil
    var dismiss: (() -> Void)? = nil

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let npm {
                DiscoverNPMContextView(context: npm)
            } else if case .npm(let environment) = result.outcome.intent.scope {
                Text("Node Environment: \(environment.nodeVersion) · npm \(environment.npmVersion)")
            }
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
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(notes, id: \.item) { outcome in
                                if let reason = outcome.reason {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: outcome.item.displayIdentifier)
                                            .font(.caption.weight(.medium))
                                            .textSelection(.enabled)
                                        Text(reason.message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
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
