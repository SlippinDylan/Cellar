import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedDestination: AppDestination = .home
    @Published var homebrew: HomebrewStatus?
    @Published var node: NodeSnapshot?
    @Published var shell: ShellStatus?
    @Published private(set) var managers: SnapshotStatus?
    @Published var refreshedAt: Date?
    @Published private(set) var errorMessages: [String] = []
    @Published private(set) var activities: [ActivityEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var homebrewRefreshFailed = false
    @Published private(set) var nodeRefreshFailed = false
    @Published private(set) var homebrewRefreshedAt: Date?
    @Published private(set) var nodeRefreshedAt: Date?
    @Published var homebrewUpdateState = HomePackageUpdateState.notLoaded
    @Published var nodeUpdateState = HomePackageUpdateState.notLoaded
    @Published var homebrewOutdatedCheckedAt: Date?
    @Published var nodeOutdatedCheckedAt: Date?
    @Published var homebrewSearchResults: [HomebrewSearchResult] = []
    @Published var homebrewDiagnostics: [HomebrewDiagnostic] = []
    @Published var homebrewDiagnosticReport: HomebrewDiagnosticReport?
    @Published var homebrewDiagnosticRecordID: UUID?
    @Published var homebrewPlan: HomebrewActionPlan?
    @Published var homebrewActionResult: HomebrewActionResult?
    @Published var homebrewOperationError: String?
    @Published var isHomebrewWorking = false
    @Published var preferredNodeVersion: String?
    @Published var nodePlan: NodeActionPlan?
    @Published var nodeActionResult: NodeActionResult?
    @Published var nodeOperationError: String?
    @Published var isNodeWorking = false
    @Published var shellPlan: ShellActionPlan?
    @Published var shellActionResult: ShellActionResult?
    @Published var shellOperationError: String?
    @Published var isShellWorking = false
    @Published var selectedToolsCategory: ToolsCategory = .environment
    @Published var terminalConfigurationPlan: ShellConfigurationPlan?
    @Published var terminalConfigurationResult: ShellConfigurationResult?

    let service: SystemProbeService
    let operationStore: OperationStore
    let activityStore: ActivityStore?
    let activityDiagnostics = ActivityDiagnosticsStore()
    let batchCoordinator: BatchOperationCoordinator
    let homeDashboard: HomeDashboardModel
    let homeOutdatedDependencies: HomeOutdatedDependencies
    var checkedOutdatedRefresh: Date?
    var activeOutdatedRefreshID: UUID?
    var homeBackgroundOwner: (operationID: UUID, refreshedAt: Date, task: Task<Bool, Never>)?
    var latestHomeBackgroundRequestID: UUID?

    init(
        service: SystemProbeService,
        operationStore: OperationStore = .shared,
        activityStore: ActivityStore? = nil,
        batchProvider: (any BatchOperationProviding)? = nil,
        homeDashboardDependencies: HomeDashboardDependencies? = nil,
        homeOutdatedDependencies: HomeOutdatedDependencies? = nil,
        managerSnapshot: SnapshotStatus? = nil
    ) {
        self.service = service
        managers = managerSnapshot
        self.operationStore = operationStore
        self.activityStore = activityStore
        self.homeOutdatedDependencies = homeOutdatedDependencies ?? HomeOutdatedDependencies(service: service)
        homeDashboard = HomeDashboardModel(dependencies: homeDashboardDependencies ?? .live(runner: ProcessRunner()), operationStore: operationStore,
                                           activityStore: activityStore, diagnosticsStore: activityDiagnostics)
        batchCoordinator = BatchOperationCoordinator(provider: batchProvider ?? ProviderBatchOperations(service: service),
                                                     operationStore: operationStore, activityStore: activityStore, diagnosticsStore: activityDiagnostics)
    }

    static func live() -> AppModel {
        let runner = ProcessRunner()
        let installer = ManagerSnapshotInstaller()
        let client = NodeManagerClient(runner: runner)
        let shellClient = ShellManagerClient(runner: runner)
        let activityStore: ActivityStore?
        if !AppRuntime.isRunningTests {
            let store = ActivityStore(applicationSupportRoot: .applicationSupportDirectory)
            store.restore()
            activityStore = store
        } else {
            activityStore = nil
        }
        return AppModel(service: SystemProbeService(
            runner: runner,
            installer: installer,
            nodeClient: client,
            shellClient: shellClient
        ), activityStore: activityStore, homeDashboardDependencies: .live(runner: runner))
    }

    var dashboard: DashboardSnapshot? {
        guard let homebrew, let node, let shell, let managers, let refreshedAt else { return nil }
        return DashboardSnapshot(
            homebrew: homebrew,
            node: node,
            shell: shell,
            managers: managers,
            refreshedAt: refreshedAt
        )
    }

    var isBusy: Bool {
        operationStore.hasActiveOperations || isRefreshing || isHomebrewWorking || isNodeWorking || isShellWorking
    }

    var activeOperationLabel: String? {
        if isRefreshing { return "正在读取 Homebrew、Node 和 Shell" }
        if isHomebrewWorking { return "正在处理 Homebrew 任务" }
        if isNodeWorking { return "正在处理 Node 任务" }
        if isShellWorking { return "正在处理 Shell 任务" }
        if let intent = batchCoordinator.activeIntent {
            switch intent.scope {
            case .homebrew: return "正在处理 Homebrew 任务"
            case .npm, .nodeRuntime: return "正在处理 Node 任务"
            }
        }
        return nil
    }

    func refreshOnLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard AppRuntime.shouldRefreshOnLaunch(refreshedAt: refreshedAt, environment: environment) else { return }
        await refresh()
    }

    func performShellAction(_ action: AppShellAction) async {
        switch action {
        case .refresh: await refresh()
        case .show(let destination): selectedDestination = destination
        case .cancel:
            latestHomeBackgroundRequestID = nil
            operationStore.cancelActiveTask()
        }
    }

    func showActivity(presentMainWindow: (String, MainWindowIdentity) -> Void) {
        selectedDestination = .activity
        presentMainWindow(AppScene.mainWindowID, .main)
    }

    func refresh() async {
        guard !isBusy else { return }
        invalidateHomeUpdates()
        isRefreshing = true
        errorMessages = []
        let operationID = operationStore.begin()
        let activityID = UUID()
        recordActivity(ActivityEntry(
            id: activityID,
            date: Date(),
            title: "刷新本机环境",
            outcome: .started,
            detail: "正在读取 Homebrew、Node 和 Shell 状态"
        ))

        defer {
            isRefreshing = false
            operationStore.end(operationID)
        }

        do {
            let installedManagers = try await service.installManagers()
            managers = installedManagers

            async let homebrewResult: Void = refreshHomebrewState(snapshot: installedManagers)
            async let nodeResult: Void = refreshNodeState(snapshot: installedManagers)
            async let shellResult = capture { try await service.loadShell(snapshot: installedManagers) }
            let results = await (homebrewResult, nodeResult, shellResult)

            shell = assign(results.2, name: "Shell")
            refreshedAt = Date()
        } catch {
            homebrewRefreshFailed = true
            nodeRefreshFailed = true
            homebrewUpdateState = .failed
            nodeUpdateState = .failed
            errorMessages.append(failureMessage(error))
            refreshedAt = Date()
        }

        activities.removeAll { $0.id == activityID }
        recordActivity(ActivityEntry(
            id: activityID,
            date: Date(),
            title: "刷新本机环境",
            outcome: errorMessages.isEmpty ? .succeeded : .failed,
            detail: errorMessages.isEmpty ? "已读取全部环境状态" : errorMessages.joined(separator: "；")
        ))
        activityStore?.append(ActivitySummary(id: activityID, operation: .refresh, scope: nil,
                                             targetDisplayNames: [], date: Date(),
                                             status: errorMessages.isEmpty ? .succeeded : .failed, itemOutcomes: [], reason: errorMessages.isEmpty ? nil : .stateUnavailable))
    }

    private func refreshHomebrewState(snapshot: SnapshotStatus) async {
        let result = await capture { try await self.service.loadHomebrew(snapshot: snapshot, includingOutdated: false) }
        applyHomebrewReadResult(result)
    }

    private func refreshNodeState(snapshot: SnapshotStatus) async {
        let result = await capture {
            try await self.service.loadNode(snapshot: snapshot, preferredNodeVersion: self.preferredNodeVersion, includingOutdated: false)
        }
        applyNodeReadResult(result)
    }

    func applyHomebrewReadResult(_ result: Result<HomebrewStatus, Error>) {
        switch result {
        case .success(let status):
            homebrew = status
            homebrewRefreshFailed = false
            homebrewRefreshedAt = Date()
            homebrewUpdateState = .notLoaded
            homebrewOutdatedCheckedAt = nil
        case .failure(let error):
            homebrewRefreshFailed = true
            homebrewUpdateState = .failed
            errorMessages.append(failureMessage(error))
        }
    }

    func applyNodeReadResult(_ result: Result<NodeSnapshot, Error>) {
        switch result {
        case .success(let snapshot):
            node = snapshot
            nodeRefreshFailed = false
            nodeRefreshedAt = Date()
            nodeUpdateState = .notLoaded
            nodeOutdatedCheckedAt = nil
        case .failure(let error):
            nodeRefreshFailed = true
            nodeUpdateState = .failed
            errorMessages.append(failureMessage(error))
        }
    }

    func prepareBatch(_ intent: BatchIntent) async throws -> BatchPlan {
        guard !isBusy else { throw BatchOperationError.busy }
        setBatchWorking(intent.scope, true)
        defer { setBatchWorking(intent.scope, false) }
        return try await batchCoordinator.prepare(intent)
    }

    func executeBatch(_ plan: BatchPlan) async throws -> BatchExecutionResult {
        guard !isBusy else { throw BatchOperationError.busy }
        setBatchWorking(plan.intent.scope, true)
        defer { setBatchWorking(plan.intent.scope, false) }
        let result = try await batchCoordinator.execute(plan)
        applyBatchResult(result)
        return result
    }

    func applyBatchResult(_ result: BatchExecutionResult) {
        switch result.refreshedState {
        case .homebrew(let status):
            let snapshot = status.snapshot.map { $0.retainingKnownOutdated(from: homebrew?.snapshot) }
            homebrew = HomebrewStatus(executablePath: status.executablePath, version: status.version, managerAvailable: status.managerAvailable, snapshot: snapshot)
            homebrewRefreshFailed = false
            homebrewRefreshedAt = Date()
            homebrewUpdateState = status.snapshot.map { $0.sectionErrors[.outdated] == nil ? .available : .failed } ?? .notLoaded
        case .npm(let snapshot), .nodeRuntime(let snapshot):
            node = snapshot.retainingKnownOutdated(from: node)
            preferredNodeVersion = snapshot.summary.nodeVersion
            nodeRefreshFailed = false
            nodeRefreshedAt = Date()
            nodeUpdateState = snapshot.outdatedError == nil ? .available : .failed
        case nil:
            if result.refreshStatus == .failed {
                switch result.outcome.intent.scope {
                case .homebrew:
                    homebrewRefreshFailed = true
                    homebrewUpdateState = .failed
                case .npm, .nodeRuntime:
                    nodeRefreshFailed = true
                    nodeUpdateState = .failed
                }
            }
        }
        if result.refreshedState != nil {
            refreshedAt = Date()
            checkedOutdatedRefresh = refreshedAt
        }
    }

    private func setBatchWorking(_ scope: BatchScope, _ working: Bool) {
        switch scope {
        case .homebrew: isHomebrewWorking = working
        case .npm, .nodeRuntime: isNodeWorking = working
        }
    }

    func beginActivity(title: String, detail: String) -> UUID {
        let id = UUID()
        recordActivity(ActivityEntry(
            id: id,
            date: Date(),
            title: title,
            outcome: .started,
            detail: detail
        ))
        return id
    }

    func finishActivity(
        _ id: UUID,
        title: String,
        outcome: ActivityEntry.Outcome,
        detail: String,
        command: HomebrewCommandOutput? = nil
    ) {
        activities.removeAll { $0.id == id }
        recordActivity(ActivityEntry(
            id: id,
            date: Date(),
            title: title,
            outcome: outcome,
            detail: detail,
            command: command
        ))
    }

    private func recordActivity(_ entry: ActivityEntry) {
        if entry.outcome != .started {
            let context = operationStore.currentOperation?.context
            activityDiagnostics.record(id: entry.id, operation: context?.operation ?? .refresh, scope: context?.scope,
                                       detail: entry.detail, command: entry.command)
        }
        activities.insert(entry, at: 0)
        if activities.count > 100 {
            activities.removeLast(activities.count - 100)
        }
    }

    func failureMessage(_ error: Error, preparing: Bool = false) -> String {
        let context = operationStore.currentOperation?.context
        activityDiagnostics.record(operation: context?.operation ?? .configuration, scope: context?.scope, detail: error.localizedDescription)
        return String(localized: ActivityItemReason(error: error, preparing: preparing).message)
    }

    private func assign<Value>(_ result: Result<Value, Error>, name: String) -> Value? {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            errorMessages.append(failureMessage(error))
            return nil
        }
    }

}

private func capture<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
) async -> Result<Value, Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}
