import SwiftUI

struct HomebrewHealthSheet: View {
    @ObservedObject var model: AppModel
    let clipboard: ActivityClipboard
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var isChecking = true
    @State private var report: HomebrewDiagnosticReport?
    @State private var diagnosticRecord: ActivityDiagnosticRecord?
    @State private var checkTask: Task<Void, Never>?

    private var diagnosticOutput: String {
        guard let diagnosticRecord else { return "" }
        return [diagnosticRecord.standardOutput, diagnosticRecord.standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Diagnostics may contain sensitive information. Review before sharing; redaction cannot recognize every secret.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if diagnosticRecord?.wasTruncated == true {
                        Text("Diagnostic output was truncated.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    MaintenanceDetailWell(maxHeight: 260) {
                        Text(verbatim: diagnosticOutput.isEmpty ? "—" : diagnosticOutput)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            if !isChecking, let diagnosticRecord, !diagnosticOutput.isEmpty {
                Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                    _ = clipboard.write(diagnosticRecord.copyText(locale: locale))
                }
            }
            Spacer()
            if !isChecking {
                Button("OK") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .interactiveDismissDisabled(isChecking)
        .onAppear {
            guard checkTask == nil else { return }
            guard !model.isBusy else {
                isChecking = false
                report = nil
                diagnosticRecord = nil
                model.homebrewOperationError = nil
                return
            }
            isChecking = true
            report = nil
            diagnosticRecord = nil
            let previousRecordID = model.homebrewDiagnosticRecordID
            checkTask = Task {
                await model.diagnoseHomebrew()
                guard !Task.isCancelled else { return }
                if let latestRecordID = model.homebrewDiagnosticRecordID, latestRecordID != previousRecordID {
                    report = model.homebrewDiagnosticReport
                    diagnosticRecord = model.activityDiagnostics.records.first { $0.id == latestRecordID }
                }
                isChecking = false
            }
        }
        .onDisappear {
            if !isChecking {
                checkTask = nil
                model.homebrewOperationError = nil
            }
        }
    }
}

struct NodeMaintenanceSheet: View {
    private enum Phase {
        case preparing
        case ready(NodeActionPlan)
        case executing
        case completed(NodeActionResult)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .preparing, .executing: true
            case .ready, .completed, .failed: false
            }
        }
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
                EmptyView()
            case .ready(let plan):
                Button("Cancel", role: .cancel) {
                    model.dismissNodePlan(confirmed: plan)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    guard case .ready(let confirmed) = phase else { return }
                    phase = .executing
                    activeTask = Task { await execute(confirmed) }
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(!plan.canExecute || model.isBusy)
            case .completed, .failed:
                Button("OK") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .interactiveDismissDisabled(phase.isRunning)
        .onAppear {
            guard activeTask == nil else { return }
            activeTask = Task { await start() }
        }
        .onDisappear {
            guard !phase.isRunning else { return }
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

extension NodeMaintenanceAction {
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
