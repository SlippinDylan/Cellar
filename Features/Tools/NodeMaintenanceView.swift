import SwiftUI

struct NodeMaintenanceView: View {
    @ObservedObject var model: AppModel
    let category: MaintenanceCategory
    @State private var showsDiagnostics = false
    @State private var runningAction: NodeMaintenanceAction?

    private var actions: [NodeMaintenanceAction] {
        NodeMaintenanceAction.allCases.filter { $0.category == category }
    }

    var body: some View {
        SettingsSection(title: category == .checks ? "npm Cache" : "Node Maintenance",
                        detail: category == .cleanup ? String(localized: "Review the exact targets before removing anything.") : nil) {
            VStack(alignment: .leading, spacing: 8) {
                if let node = model.node, let error = node.maintenanceError {
                    Label("Some maintenance information could not be read.", systemImage: "exclamationmark.triangle")
                    Button("Session Diagnostics…") {
                        model.activityDiagnostics.record(operation: .maintenance, scope: node.summary.activityEnvironment.map(ActivityScope.npm), detail: error)
                        showsDiagnostics = true
                    }.padding(.bottom, 4)
                }
                ForEach(actions) { action in
                    HStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.title).fontWeight(.medium)
                            Text(action.detail).font(.callout).foregroundStyle(.secondary)
                            if action == .verify {
                                verificationSummary
                            } else if runningAction == action {
                                Text("Preparing…")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else if let result = model.nodeActionResult, result.plan.request == action.request {
                                resultSummary(result)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            Task {
                                runningAction = action
                                if action == .verify {
                                    await model.performDirectNodeAction(action.request)
                                } else {
                                    await model.prepareNodeAction(action.request)
                                }
                                runningAction = nil
                            }
                        } label: {
                            Text(action == .verify ? LocalizedStringResource("Verify npm Cache") : LocalizedStringResource("Review…"))
                        }
                        .disabled(model.node == nil || model.isBusy)
                        .fixedSize()
                        .accessibilityLabel(Text(action.title))
                        .accessibilityHint(Text(action.detail))
                        .help(Text(action.title))
                    }.frame(minHeight: AppLayout.minimumDescribedRowHeight)
                    if action != actions.last { Divider() }
                }
            }
        }
        .sheet(isPresented: $showsDiagnostics) {
            ActivityDiagnosticsView(store: model.activityDiagnostics, initialSelection: nil, clipboard: .live)
        }
    }

    @ViewBuilder private var verificationSummary: some View {
        switch model.currentNodeCacheVerification {
        case .running:
            Text("Checking npm Cache…").font(.callout).foregroundStyle(.secondary)
        case .completed(let result):
            resultSummary(result)
        case .failed:
            Label("Cache Verification Failed", systemImage: "exclamationmark.triangle")
        case nil:
            Text("Not Checked").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func resultSummary(_ result: NodeActionResult) -> some View {
        let status: BatchItemStatus = result.operation.batchItemStatus == .succeeded && result.postflightError != nil
            ? .partiallySucceeded : result.operation.batchItemStatus
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Last Result")
                Label { Text(status.activityTitle) } icon: {
                    Image(systemName: status.systemImage)
                }
            }
            if let snapshot = result.snapshot {
                LabeledContent("Node Version", value: snapshot.summary.nodeVersion)
            }
            if result.postflightError != nil {
                Text(ActivityItemReason.stateUnavailable.message)
            } else if let reason = result.operation.activityReason {
                Text(reason.message)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
