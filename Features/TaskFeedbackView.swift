import SwiftUI

struct TaskFeedbackView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var operations: OperationStore
    @Environment(\.locale) private var locale
    private let maximumHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    init(model: AppModel, maximumHeight: CGFloat) {
        self.model = model
        operations = model.operationStore
        self.maximumHeight = maximumHeight
    }

    var body: some View {
        ScrollView {
            feedbackContent
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maximumHeight))
    }

    private var feedbackContent: some View {
        VStack(spacing: 0) {
            if let current = operations.currentOperation, current.context.operation.showsTaskFeedback {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ActivityRenderer(locale: locale).operation(current.context.operation)).fontWeight(.medium)
                        HStack {
                            Text(current.context.stage.title)
                            Text(ActivityRenderer(locale: locale).scope(current.context.scope))
                        }.foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let completed = current.completed, let total = current.total {
                        let completedCount = String(completed)
                        let totalCount = String(total)
                        Text("\(completedCount) of \(totalCount) Items Processed").monospacedDigit()
                    }
                }
                .padding(AppLayout.spacing)
                .accessibilityElement(children: .combine)
                Divider()
            } else if let store = model.activityStore {
                TaskResultFeedback(store: store)
            }
            if operations.terminationBlockedNotice {
                HStack(spacing: 12) {
                    Label("Cannot quit while a task is running. Wait for it to finish, then try again.", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Dismiss Feedback", systemImage: "xmark") { operations.dismissTerminationBlockedNotice() }
                        .labelStyle(.iconOnly).help("Dismiss Feedback")
                }
                .padding(AppLayout.spacing)
                Divider()
            }
            if !errors.isEmpty && !model.isBusy {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle")
                        }
                        if let plan = model.nodePlan, !plan.canExecute { Text(plan.blockingMessage) }
                    }
                    Spacer()
                    Button("Dismiss Feedback") {
                        model.dismissNodeFeedback()
                        model.dismissShellFeedback()
                        model.dismissHomebrewFeedback()
                    }
                }.padding(AppLayout.spacing)
                Divider()
            }
            if let logStore = model.logStore { LogFailureFeedback(store: logStore) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var errors: [String] {
        Array(Set([model.nodeOperationError, model.homebrewOperationError, model.shellOperationError].compactMap { $0 })).sorted()
    }
}

private struct TaskResultFeedback: View {
    @ObservedObject var store: ActivityStore
    var body: some View {
        ForEach(store.latestResults) { summary in
            TaskResultCard(summary: summary, dismiss: store.dismissResult)
        }
        if let warning = store.verificationWarning {
            Label { Text(warning.message) } icon: { Image(systemName: "exclamationmark.triangle") }
                .padding(AppLayout.spacing)
            Divider()
        }
        if let error = store.validationError {
            Label { Text(error.message) } icon: { Image(systemName: "exclamationmark.triangle") }
                .padding(AppLayout.spacing)
            Divider()
        }
    }
}

private struct TaskResultCard: View {
    let summary: ActivitySummary
    let dismiss: () -> Void
    @Environment(\.locale) private var locale
    @State private var expanded = false
    @State private var copyFailed = false

    var body: some View {
        Group {
            let renderer = ActivityRenderer(locale: locale)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Scope", value: renderer.scope(summary.scope))
                            LabeledContent("Time") {
                                Text(summary.date, format: .dateTime.year().month().day().hour().minute().second())
                            }
                            let target = renderer.target(summary)
                            if !target.isEmpty { Text(target) }
                            if let reason = summary.reason { Text(reason.message).foregroundStyle(.secondary) }
                            if let items = summary.cleanupItems {
                                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                    NodeCleanupItemView(item: item)
                                }
                            }
                            if !summary.itemOutcomes.isEmpty {
                                Text(renderer.counts(summary)).fontWeight(.medium)
                                ForEach(Array(summary.itemOutcomes.enumerated()), id: \.offset) { _, item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(item.shellStep.map { renderer.localized($0.title) } ?? item.displayName)
                                            Spacer()
                                            Label { Text(item.status.activityTitle) } icon: { Image(systemName: item.status.systemImage) }
                                        }
                                        if let reason = item.reason { Text(reason.message).foregroundStyle(.secondary) }
                                    }.accessibilityElement(children: .combine)
                                }
                            }
                        }
                        .padding(.top, 8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        HStack {
                            Text(renderer.operation(summary.operation)).fontWeight(.medium)
                            Text(renderer.scope(summary.scope)).foregroundStyle(.secondary)
                            Label { Text(summary.status.title) } icon: { Image(systemName: summary.status.systemImage) }
                            Spacer()
                        }
                    }
                    Button("Copy Summary", systemImage: "doc.on.doc") {
                        copyFailed = !ActivityClipboard.live.copy(summary, locale: locale)
                    }.labelStyle(.iconOnly).help("Copy Summary")
                    Button("Dismiss Feedback", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).help("Dismiss Feedback")
                }
                if copyFailed { Text("Summary could not be copied. Try again.").foregroundStyle(.secondary) }
            }
            .padding(AppLayout.spacing)
            .onChange(of: summary.id, initial: true) { _, _ in
                expanded = summary.status != .succeeded
                copyFailed = false
            }
            Divider()
        }

    }
}

private struct LogFailureFeedback: View {
    @ObservedObject var store: FileLogStore
    var body: some View {
        if store.errorMessage != nil {
            HStack {
                Label("Logs could not be saved. Check storage and permissions in Settings.", systemImage: "exclamationmark.triangle")
                Spacer()
                Button("Retry Saving Logs") { store.retry() }
            }.padding(AppLayout.spacing)
            Divider()
        }
    }
}
