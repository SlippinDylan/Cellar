import AppKit
import SwiftUI

private enum MaintenanceSheetTool: Identifiable, Equatable {
    case batchInstall
    case homebrewHealth
    case node(NodeMaintenanceAction)

    var id: String {
        switch self {
        case .batchInstall: "batch-install"
        case .homebrewHealth: "homebrew-health"
        case .node(let action): "node-\(action.rawValue)"
        }
    }
}

struct MaintenanceView: View {
    @ObservedObject var model: AppModel
    @StateObject private var batchInstallation: DiscoverInstallationModel
    @State private var activeTool: MaintenanceSheetTool?
    @State private var showsNodeDiagnostics = false
    var clipboard: ActivityClipboard = .live

    init(model: AppModel, clipboard: ActivityClipboard = .live) {
        self.model = model
        _batchInstallation = StateObject(wrappedValue: DiscoverInstallationModel(model: model))
        self.clipboard = clipboard
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppLayout.spacing) {
                    if let node = model.node, let error = node.maintenanceError {
                        HStack(spacing: 12) {
                            Label("Some maintenance information could not be read.", systemImage: "exclamationmark.triangle")
                            Spacer(minLength: 0)
                            Button("Session Diagnostics…") {
                                model.activityDiagnostics.record(
                                    operation: .maintenance,
                                    scope: node.summary.activityEnvironment.map(ActivityScope.npm),
                                    detail: error
                                )
                                showsNodeDiagnostics = true
                            }
                            .controlSize(.regular)
                        }
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250), spacing: AppLayout.cardSpacing, alignment: .top)],
                        alignment: .leading,
                        spacing: AppLayout.cardSpacing
                    ) {
                        batchInstallCard
                        homebrewHealthCard
                        ForEach(NodeMaintenanceAction.allCases) { action in
                            nodeMaintenanceCard(action)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(AppLayout.spacing, for: .scrollContent)

            EnvironmentFooterView {
                LabeledContent("Homebrew", value: homebrewFooterValue)
                if let node = model.node {
                    LabeledContent("Node", value: "\(node.summary.nodeVersion) · npm \(node.summary.npmVersion)")
                } else {
                    Text("Node Environment Unavailable")
                }
            }
            .padding(.horizontal, AppLayout.spacing)
            .padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .focusedSceneValue(\.batchInstallAction, openBatchInstall)
        .sheet(item: $activeTool) { tool in
            switch tool {
            case .batchInstall:
                DiscoverBatchInstallSheet(
                    installation: batchInstallation,
                    context: model.discoverContext,
                    initialScope: .homebrewFormula
                )
            case .homebrewHealth:
                HomebrewHealthSheet(model: model, clipboard: clipboard)
            case .node(let action):
                NodeMaintenanceSheet(model: model, action: action)
            }
        }
        .sheet(isPresented: $showsNodeDiagnostics) {
            ActivityDiagnosticsView(store: model.activityDiagnostics, initialSelection: nil, clipboard: clipboard)
        }
    }

    private func openBatchInstall() {
        batchInstallation.dismissPreview()
        batchInstallation.dismissResult()
        activeTool = .batchInstall
    }

    private var homebrewFooterValue: String {
        if let version = model.homebrew?.version {
            return HomeVersion.normalized(version)
        }
        if model.homebrew?.isInstalled == false {
            return String(localized: "Not Installed")
        }
        return "—"
    }

    private var batchInstallCard: some View {
        MaintenanceToolCard(
            title: LocalizedStringResource("Batch Install"),
            description: LocalizedStringResource("Enter one package per line. Blank lines and duplicate entries are removed. Maximum 100 items from one scope."),
            systemImage: "square.stack.3d.up.fill",
            tint: .blue
        ) {
            Button("Batch Install", action: openBatchInstall)
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(model.isBusy || (!model.discoverContext.homebrewAvailable && model.discoverContext.npm == nil))
        }
    }

    private var homebrewHealthCard: some View {
        MaintenanceToolCard(
            title: LocalizedStringResource("Homebrew Health"),
            description: LocalizedStringResource("Check Homebrew for configuration and installation issues."),
            systemImage: "stethoscope.circle.fill",
            tint: .orange
        ) {
            Button("Check Homebrew Health") { activeTool = .homebrewHealth }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(model.homebrew?.isInstalled != true || model.isBusy)
        }
    }

    private func nodeMaintenanceCard(_ action: NodeMaintenanceAction) -> some View {
        MaintenanceToolCard(
            title: action.title,
            description: action.detail,
            systemImage: action.symbolName,
            tint: action.tint
        ) {
            Button {
                activeTool = .node(action)
            } label: {
                Text(action == .verify ? LocalizedStringResource("Verify npm Cache") : LocalizedStringResource("Review…"))
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .disabled(model.isBusy || !model.nodeActionIsAvailable(action.request))
            .accessibilityLabel(Text(action.title))
            .accessibilityHint(Text(action.detail))
        }
    }
}

struct MaintenanceIconBadge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct MaintenanceLoadingState: View {
    let title: LocalizedStringResource

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

struct MaintenanceModalFrame<Subtitle: View, Content: View, Footer: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    let tint: Color
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                MaintenanceIconBadge(systemImage: systemImage, tint: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .font(.subheadline)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 60)

            Divider()

            content
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Divider()

            HStack(spacing: 10) {
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 60)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .frame(width: 560)
    }
}

struct MaintenanceDetailWell<Content: View>: View {
    var maxHeight: CGFloat = 260
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .frame(minHeight: 110, maxHeight: maxHeight)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

private struct HomebrewHealthSheet: View {
    @ObservedObject var model: AppModel
    let clipboard: ActivityClipboard
    @Environment(\.dismiss) private var dismiss
    @State private var isChecking = true
    @State private var report: HomebrewDiagnosticReport?
    @State private var checkTask: Task<Void, Never>?

    private var diagnosticOutput: String {
        guard let report else { return "" }
        let sections = [
            report.command.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            report.command.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
        ].filter { !$0.isEmpty }
        return sections.joined(separator: "\n\n")
    }

    var body: some View {
        MaintenanceModalFrame(
            title: LocalizedStringResource("Homebrew Health"),
            systemImage: "stethoscope.circle.fill",
            tint: .orange
        ) {
            if isChecking {
                Text("Checking Homebrew…").foregroundStyle(.secondary)
            } else if let report {
                if report.command.terminationStatus == 0 {
                    Label("Homebrew Reports No Issues", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Homebrew Reported Issues", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else {
                Label("Homebrew Check Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } content: {
            if isChecking {
                MaintenanceLoadingState(title: "Checking Homebrew…")
            } else if report != nil {
                MaintenanceDetailWell(maxHeight: 280) {
                    Text(verbatim: diagnosticOutput.isEmpty ? "—" : diagnosticOutput)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                MaintenanceDetailWell(maxHeight: 180) {
                    Text(model.homebrewOperationError ?? String(localized: "Homebrew Check Failed"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } footer: {
            if !isChecking, !diagnosticOutput.isEmpty {
                Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                    _ = clipboard.write(diagnosticOutput)
                }
            }
            Spacer()
            if isChecking {
                Button("Cancel", role: .cancel) {
                    checkTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button("OK") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard checkTask == nil else { return }
            guard !model.isBusy else {
                isChecking = false
                report = nil
                return
            }
            isChecking = true
            report = nil
            let previousRecordID = model.homebrewDiagnosticRecordID
            checkTask = Task {
                await model.diagnoseHomebrew()
                guard !Task.isCancelled else { return }
                if let latestRecordID = model.homebrewDiagnosticRecordID, latestRecordID != previousRecordID {
                    report = model.homebrewDiagnosticReport
                }
                isChecking = false
            }
        }
        .onDisappear {
            checkTask?.cancel()
            checkTask = nil
            model.homebrewOperationError = nil
        }
    }
}

private struct NodeMaintenanceSheet: View {
    private enum Phase {
        case preparing
        case ready(NodeActionPlan)
        case executing
        case completed(NodeActionResult)
        case failed(String)
    }

    @ObservedObject var model: AppModel
    let action: NodeMaintenanceAction
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .preparing
    @State private var activeTask: Task<Void, Never>?

    var body: some View {
        MaintenanceModalFrame(
            title: action.title,
            systemImage: action.symbolName,
            tint: action.tint
        ) {
            switch phase {
            case .preparing:
                Text(action == .verify ? "Checking npm Cache…" : "Preparing…")
                    .foregroundStyle(.secondary)
            case .ready:
                Text(action.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .executing:
                Text("Running")
                    .foregroundStyle(.secondary)
            case .completed(let result):
                let status: BatchItemStatus = result.operation.batchItemStatus == .succeeded && result.postflightError != nil
                    ? .partiallySucceeded : result.operation.batchItemStatus
                Label { Text(status.activityTitle) } icon: {
                    Image(systemName: status.systemImage)
                }
                .foregroundStyle(status == .succeeded ? .green : .orange)
            case .failed:
                Label(action == .verify ? "Cache Verification Failed" : "Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } content: {
            switch phase {
            case .preparing:
                MaintenanceLoadingState(title: action == .verify ? "Checking npm Cache…" : "Preparing…")

            case .ready(let plan):
                MaintenanceDetailWell(maxHeight: 260) {
                    VStack(alignment: .leading, spacing: 8) {
                        let paths = plan.payload.paths ?? []
                        if !paths.isEmpty {
                            ForEach(paths, id: \.self) {
                                Text($0)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        if action == .logs {
                            Text("The current maintenance task counts as one of the 100 retained logs.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if plan.maintenanceCandidates.isEmpty {
                                Text("No Older Logs to Remove")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(plan.maintenanceCandidates, id: \.self) {
                                    Text($0)
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        } else if paths.isEmpty {
                            Text(action.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if !plan.canExecute {
                            Label { Text(plan.blockingMessage) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                }

            case .executing:
                MaintenanceLoadingState(title: "Running")

            case .completed(let result):
                MaintenanceDetailWell(maxHeight: 260) {
                    VStack(alignment: .leading, spacing: 8) {
                        resultDetailView(result)
                    }
                }

            case .failed(let message):
                MaintenanceDetailWell(maxHeight: 180) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } footer: {
            Spacer()
            switch phase {
            case .preparing, .executing:
                Button("Cancel", role: .cancel) {
                    activeTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            case .ready(let plan):
                Button("Cancel", role: .cancel) {
                    model.dismissNodePlan(confirmed: plan)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    activeTask?.cancel()
                    activeTask = Task { await execute(plan) }
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(!plan.canExecute)
            case .completed, .failed:
                Button("OK") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            guard activeTask == nil else { return }
            activeTask = Task { await start() }
        }
        .onDisappear {
            activeTask?.cancel()
            activeTask = nil
            if let plan = model.nodePlan, plan.request == action.request {
                model.dismissNodePlan(confirmed: plan)
            }
            model.nodeOperationError = nil
        }
    }

    private func start() async {
        phase = .preparing
        if action == .verify {
            await model.performDirectNodeAction(action.request)
            guard !Task.isCancelled else { return }
            if case .completed(let result) = model.currentNodeCacheVerification {
                phase = .completed(result)
            } else {
                phase = .failed(model.nodeOperationError ?? String(localized: "Cache Verification Failed"))
            }
        } else {
            await model.prepareNodeAction(action.request)
            guard !Task.isCancelled else { return }
            if let plan = model.nodePlan, plan.request == action.request {
                phase = .ready(plan)
            } else if let error = model.nodeOperationError {
                phase = .failed(error)
            } else {
                phase = .failed(String(localized: ActivityItemReason.preparationFailed.message))
            }
        }
    }

    private func execute(_ plan: NodeActionPlan) async {
        phase = .executing
        await model.executeNodePlan(confirmed: plan)
        guard !Task.isCancelled else { return }
        if let result = model.nodeActionResult, result.plan.id == plan.id {
            phase = .completed(result)
        } else {
            phase = .failed(model.nodeOperationError ?? String(localized: "Failed"))
        }
    }

    @ViewBuilder
    private func resultDetailView(_ result: NodeActionResult) -> some View {
        if let items = result.operation.cleanupItems, !items.isEmpty {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                NodeCleanupItemView(item: item)
            }
        } else if result.postflightError != nil {
            Text(ActivityItemReason.stateUnavailable.message)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let reason = result.operation.activityReason {
            Text(reason.message)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let detail = result.operation.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Text(detail.isEmpty ? String(localized: result.operation.batchItemStatus.activityTitle) : detail)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct MaintenanceToolCard<Footer: View>: View {
    let title: LocalizedStringResource
    let description: LocalizedStringResource
    let systemImage: String
    let tint: Color
    @ViewBuilder let footer: Footer

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    MaintenanceIconBadge(systemImage: systemImage, tint: tint)

                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 2)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    footer
                }
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(6)
        }
        .accessibilityElement(children: .contain)
    }
}

private extension NodeMaintenanceAction {
    var symbolName: String {
        switch self {
        case .verify: "checkmark.shield.fill"
        case .npmCache: "trash.fill"
        case .nodeGyp: "hammer.fill"
        case .orphanBins: "link.circle.fill"
        case .oldNode: "cube.fill"
        case .logs: "doc.text.fill"
        }
    }

    var tint: Color {
        switch self {
        case .verify: .green
        case .npmCache: .orange
        case .nodeGyp: .purple
        case .orphanBins: .pink
        case .oldNode: .teal
        case .logs: .indigo
        }
    }
}

struct NodeCleanupItemView: View {
    let item: NodeCleanupItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: item.path)
                Spacer()
                Text(title)
            }
            if let recovery { Text(recovery).foregroundStyle(.secondary) }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringResource {
        switch item.status {
        case .removed: LocalizedStringResource("Removed")
        case .retained: LocalizedStringResource("Retained")
        case .failed: LocalizedStringResource("Failed")
        case .notAttempted: LocalizedStringResource("Not Started")
        case .unknown: LocalizedStringResource("Removal Unverified")
        case .partial: LocalizedStringResource("Partially Completed")
        }
    }

    private var recovery: LocalizedStringResource? {
        switch item.reason {
        case .removed, .cacheCleaned: nil
        case .stateChanged: LocalizedStringResource("The item changed. Review it again before retrying.")
        case .deletionIncomplete, .cleanupFailed: LocalizedStringResource("Some contents may have been removed. Review the remaining files before retrying.")
        case .cacheCleanedVerificationFailed: LocalizedStringResource("Cache cleared, but verification failed.")
        case .previousFailure: LocalizedStringResource("An earlier item failed. Review the remaining items before retrying.")
        case .deletionFailed: LocalizedStringResource("Removal failed. Check access and review the item before retrying.")
        }
    }
}
