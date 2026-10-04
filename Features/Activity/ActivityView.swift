import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: AppModel
    var clipboard: ActivityClipboard = .live
    var body: some View {
        if let store = model.activityStore {
            ActivityHistoryView(model: model, store: store, operations: model.operationStore, diagnostics: model.activityDiagnostics, clipboard: clipboard)
        } else {
            ContentUnavailableView("History Unavailable", systemImage: "clock.badge.exclamationmark",
                                   description: Text("Operation history is disabled in this test session."))
        }
    }
}

private struct ActivityHistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ActivityStore
    @ObservedObject var operations: OperationStore
    @ObservedObject var diagnostics: ActivityDiagnosticsStore
    let clipboard: ActivityClipboard
    @Environment(\.locale) private var locale
    @State private var filter = ActivityFilter()
    @State private var selection: UUID?
    @State private var showingDiagnostics = false
    @State private var copyFailed = false
    @State private var searchPresented = false
    private var renderer: ActivityRenderer { .init(locale: locale) }

    var body: some View {
        let visible = filter.apply(store.summaries, locale: locale)
        VStack(spacing: 0) {
            if let current = operations.currentOperation { currentTask(current) }
            if let error = store.persistenceError { persistenceFeedback(error) }
            if copyFailed { Label("The summary could not be copied. Try Copy Summary again.", systemImage: "exclamationmark.circle").padding(12) }
            switch ActivityHistoryState(summaries: store.summaries, visible: visible, error: store.persistenceError) {
            case .populated:
                VSplitView {
                    historyTable(visible).frame(minHeight: 140)
                    detail(visible.first { $0.id == selection }).frame(minHeight: 140, idealHeight: 240)
                }
            case .empty:
                ContentUnavailableView("No History Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Completed tasks appear here. Cellar keeps the latest 100 summaries across launches."))
            case .noMatches:
                ContentUnavailableView { Label("No Matching History", systemImage: "line.3.horizontal.decrease") }
                description: { Text("Try another search or clear the filters to see more tasks.") }
                actions: { Button("Clear Activity Filters") { filter = ActivityFilter() } }
            case .unavailable:
                ContentUnavailableView("History Unavailable", systemImage: "clock.badge.exclamationmark",
                                       description: Text("Environment tasks remain available. Check the history notice above for recovery guidance."))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $filter.search, isPresented: $searchPresented, placement: .toolbar, prompt: Text("Search Operation History"))
        .focusedSceneValue(\.catalogSearchAction, { searchPresented = true })
        .focusedSceneValue(\.activityActions, ActivityActions(canCopy: selection != nil, copy: { copySelection(visible) },
            showDiagnostics: { showingDiagnostics = true }, clearFilters: { filter = ActivityFilter() },
            setProvider: { filter.provider = $0 }, setStatus: { filter.status = $0 }))
        .toolbar {
            ToolbarItem { filterMenu }
            ToolbarItem {
                Button("Copy Summary", systemImage: "doc.on.doc") { copySelection(visible) }
                    .help("Copy Selected Activity Summary").disabled(selection == nil)
            }
            ToolbarItem {
                Button("Session Diagnostics…", systemImage: "stethoscope") { showingDiagnostics = true }
                    .help("Show Current Session Diagnostics")
            }
        }
        .onChange(of: visible.map(\.id), initial: true) { _, _ in selection = ActivityFilter.reconciledSelection(selection, visible: visible) }
        .onChange(of: selection) { _, _ in copyFailed = false }
        .sheet(isPresented: $showingDiagnostics) { ActivityDiagnosticsView(store: diagnostics, initialSelection: selection, clipboard: clipboard) }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Provider", selection: $filter.provider) {
                ForEach(ActivityProviderFilter.allCases, id: \.self) { provider in Text(renderer.provider(provider)).tag(provider) }
            }
            Picker("Status", selection: $filter.status) {
                Text("All Statuses").tag(nil as ActivityStatus?)
                ForEach(ActivityStatus.allCases, id: \.self) { status in Text(status.title).tag(Optional(status)) }
            }
            Divider()
            Button("Clear Activity Filters") { filter = ActivityFilter() }
        } label: { Label("Filter History", systemImage: "line.3.horizontal.decrease") }
        .help("Filter Operation History")
    }

    private func historyTable(_ visible: [ActivitySummary]) -> some View {
        Table(visible, selection: $selection) {
            TableColumn("Operation") { summary in Text(renderer.operation(summary.operation)) }.width(min: 130, ideal: 170)
            TableColumn("Status") { summary in Label { Text(summary.status.title) } icon: { Image(systemName: summary.status.systemImage) } }.width(min: 120, ideal: 145)
            TableColumn("Scope") { summary in Text(renderer.scope(summary.scope)) }.width(min: 150, ideal: 180)
            TableColumn("Targets") { summary in Text(renderer.target(summary)).lineLimit(1) }.width(min: 120, ideal: 180)
            TableColumn("Time") { summary in Text(summary.date, format: .dateTime.month().day().hour().minute()).monospacedDigit() }.width(min: 110, ideal: 130)
        }
        .onCopyCommand(perform: selection == nil ? nil : {
            guard let summary = visible.first(where: { $0.id == selection }) else { return [] }
            return [NSItemProvider(object: renderer.detail(summary) as NSString)]
        })
        .accessibilityLabel("Operation History")
    }

    @ViewBuilder private func detail(_ summary: ActivitySummary?) -> some View {
        if let summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(renderer.operation(summary.operation), systemImage: summary.status.systemImage).font(.headline)
                    LabeledContent("Status", value: renderer.status(summary.status))
                    LabeledContent("Scope", value: renderer.scope(summary.scope))
                    LabeledContent("Time") { Text(summary.date, format: .dateTime.year().month().day().hour().minute().second()) }
                    if !renderer.target(summary).isEmpty { LabeledContent("Targets", value: renderer.target(summary)) }
                    if let reason = summary.reason { Text(reason.message) }
                    if !summary.itemOutcomes.isEmpty {
                        Text(renderer.counts(summary)).font(.body.weight(.medium))
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
                }.textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else { ContentUnavailableView("Select a Task", systemImage: "sidebar.right", description: Text("Select a history row to see its targets and item results.")) }
    }

    private func currentTask(_ current: ActiveOperationState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Current Task", systemImage: "clock").font(.headline)
                Spacer()
                if let task = operations.activeTask {
                    Button("Cancel Task", systemImage: "stop") { Task { await model.performShellAction(.cancel) } }.disabled(!task.canCancel)
                }
            }
            Text(renderer.operation(current.context.operation)).font(.body.weight(.medium))
            Text(renderer.scope(current.context.scope))
            if !current.context.targets.isEmpty { Text(current.context.targets.joined(separator: ", ")).lineLimit(2) }
            HStack {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                if current.cancellationRequested { Text("Cancellation Requested · Verifying Completed Changes") }
                else { Text(current.context.stage.title) }
                if let completed = current.completed, let total = current.total {
                    let completedCount = String(completed)
                    let totalCount = String(total)
                    Text("\(completedCount) of \(totalCount) Items Processed").monospacedDigit()
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background).overlay(alignment: .bottom) { Divider() }.accessibilityElement(children: .contain)
    }

    private func persistenceFeedback(_ error: ActivityStoreError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(error.message) } icon: { Image(systemName: "exclamationmark.triangle") }
            if error == .writeFailed { Button("Retry Saving History") { store.retrySaving() } }
            else if error == .readFailed || error == .isolationFailed { Button("Retry Loading History") { store.retryLoading() } }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func copySelection(_ visible: [ActivitySummary]) {
        guard let selected = visible.first(where: { $0.id == selection }) else { return }
        copyFailed = !clipboard.copy(selected, locale: locale)
    }
}

struct ActivityActions {
    let canCopy: Bool
    let copy: () -> Void
    let showDiagnostics: () -> Void
    let clearFilters: () -> Void
    let setProvider: (ActivityProviderFilter) -> Void
    let setStatus: (ActivityStatus?) -> Void
}
private struct ActivityActionsKey: FocusedValueKey { typealias Value = ActivityActions }
extension FocusedValues {
    var activityActions: ActivityActions? {
        get { self[ActivityActionsKey.self] }
        set { self[ActivityActionsKey.self] = newValue }
    }
}
