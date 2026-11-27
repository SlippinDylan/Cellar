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
    @Published private(set) var isRefreshing = false
    @Published private(set) var homebrewRefreshFailed = false
    @Published private(set) var nodeRefreshFailed = false
    @Published private(set) var shellRefreshFailed = false
    @Published private(set) var homebrewRefreshedAt: Date?
    @Published private(set) var homebrewPackagesRefreshedAt: Date?
    @Published private(set) var nodeRefreshedAt: Date?
    @Published var homebrewUpdateState = HomePackageUpdateState.notLoaded
    @Published var nodeUpdateState = HomePackageUpdateState.notLoaded
    @Published var homebrewOutdatedCheckedAt: Date?
    @Published var nodeOutdatedCheckedAt: Date?
    @Published var homebrewDiagnosticReport: HomebrewDiagnosticReport?
    @Published var homebrewDiagnosticRecordID: UUID?
    @Published var homebrewPlan: HomebrewActionPlan?
    @Published var homebrewActionResult: HomebrewActionResult?
    @Published var homebrewOperationError: String?
    @Published var isHomebrewWorking = false
    @Published var preferredNodeVersion: String?
    @Published var nodePlan: NodeActionPlan?
    @Published var nodeActionResult: NodeActionResult?
    @Published var nodeCacheVerification: NodeCacheVerification?
    @Published private(set) var nvmInstalled: Bool?
    @Published var nodeOperationError: String?
    @Published var isNodeWorking = false
    @Published var shellPlan: ShellActionPlan?
    @Published var shellActionResult: ShellActionResult?
    @Published var shellOperationError: String?
    @Published var isShellWorking = false
    @Published var selectedToolsCategory: ToolsCategory = .terminal
    @Published var selectedSettingsCategory: SettingsCategory = .general
    @Published var terminalConfigurationPlan: ShellConfigurationPlan?
    @Published var terminalConfigurationResult: ShellConfigurationResult?
    @Published private(set) var activeModalCount = 0
    @Published private(set) var queuedBatchFailureMessage: String?

    func recordQueuedBatchFailure(_ message: String) {
        if let existing = queuedBatchFailureMessage, !existing.isEmpty {
            queuedBatchFailureMessage = "\(existing)\n\(message)"
        } else {
            queuedBatchFailureMessage = message
        }
    }

    func dismissQueuedBatchFailure() {
        queuedBatchFailureMessage = nil
    }

    func beginModalPresentation() {
        activeModalCount += 1
    }

    func endModalPresentation() {
        activeModalCount = max(0, activeModalCount - 1)
    }

    let service: SystemProbeService
    let operationStore: OperationStore
    let activityStore: ActivityStore?
    let logStore: FileLogStore?
    let activityDiagnostics = ActivityDiagnosticsStore()
    let batchCoordinator: BatchOperationCoordinator
    let homeDashboard: HomeDashboardModel
    let homeOutdatedDependencies: HomeOutdatedDependencies
    var checkedOutdatedRefresh: Date?
    var activeOutdatedRefreshID: UUID?
    var homeBackgroundOwner: (refreshedAt: Date, task: Task<Bool, Never>)?
    var latestHomeBackgroundRequestID: UUID?

    init(
        service: SystemProbeService,
        operationStore: OperationStore = .shared,
        activityStore: ActivityStore? = nil,
        logStore: FileLogStore? = nil,
        batchProvider: (any BatchOperationProviding)? = nil,
        homeDashboardDependencies: HomeDashboardDependencies? = nil,
        homeOutdatedDependencies: HomeOutdatedDependencies? = nil,
        managerSnapshot: SnapshotStatus? = nil
    ) {
        self.service = service
        managers = managerSnapshot
        self.operationStore = operationStore
        self.activityStore = activityStore
        self.logStore = logStore
        operationStore.logStore = logStore
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
        let logStore: FileLogStore?
        if AppRuntime.isRunningTests {
            logStore = nil
        } else {
            let store = FileLogStore(directory: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Cellar"), defaults: .standard)
            store.retry()
            store.record(level: .info, category: "application", message: "Cellar started")
            logStore = store
        }
        let activityStore = AppRuntime.isRunningTests ? nil : ActivityStore(logStore: logStore, operationStore: .shared)
        return AppModel(service: SystemProbeService(
            runner: runner,
            installer: installer,
            nodeClient: client,
            shellClient: shellClient
        ), activityStore: activityStore, logStore: logStore, homeDashboardDependencies: .live(runner: runner))
    }

    var isBusy: Bool {
        operationStore.hasActiveOperations || operationStore.isTerminating || isRefreshing || isHomebrewWorking || isNodeWorking || isShellWorking
    }

    var currentNodeCacheVerification: NodeCacheVerification.State? {
        guard let node, let verification = nodeCacheVerification,
              verification.target == NodeCacheVerification.Target(node: node) else { return nil }
        return verification.state
    }

    func refreshOnLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard AppRuntime.shouldRefreshOnLaunch(refreshedAt: refreshedAt, environment: environment) else { return }
        await refresh()
    }

    func performShellAction(_ action: AppShellAction) async {
        switch action {
        case .refresh:
            guard !isBusy else { return }
            if selectedDestination == .tools && selectedToolsCategory == .homebrewSources && homebrew?.isInstalled == true {
                await performHomebrewMetadataUpdate()
            }
            await refresh()
        case .show(let destination): selectedDestination = destination
        }
    }

    func showDestination(_ destination: AppDestination, presentMainWindow: (String, MainWindowIdentity) -> Void) {
        selectedDestination = destination
        presentMainWindow(AppScene.mainWindowID, .main)
    }

    func refresh() async {
        guard !isBusy else { return }
        invalidateHomeUpdates()
        isRefreshing = true
        errorMessages = []
        let refreshID = UUID()

        var cancelled = false
        let task = Task<Bool, Error> {
            try Task.checkCancellation()
            let nvmInstalled = await self.service.isNVMInstalled()
            try Task.checkCancellation()
            self.nvmInstalled = nvmInstalled
            let installedManagers = try await self.service.installManagers()
            self.managers = installedManagers
            try Task.checkCancellation()
            async let homebrewResult: Void = self.refreshHomebrewState(snapshot: installedManagers)
            async let nodeResult: Void = self.refreshNodeState(snapshot: installedManagers)
            async let shellResult: Void = self.refreshShellState(snapshot: installedManagers)
            _ = await (homebrewResult, nodeResult, shellResult)
            return Task.isCancelled
        }
        let readOnlyID = operationStore.registerReadOnlyOperation(
            cancel: { task.cancel() },
            awaitCompletion: { _ = try? await task.value }
        )
        defer {
            operationStore.unregisterReadOnlyOperation(readOnlyID)
            if isRefreshing { isRefreshing = false }
        }

        do {
            cancelled = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            cancelled = error is CancellationError || Task.isCancelled || task.isCancelled
            if !cancelled {
                homebrewRefreshFailed = true
                nodeRefreshFailed = true
                shellRefreshFailed = true
                homebrewUpdateState = .failed
                nodeUpdateState = .failed
                errorMessages.append(failureMessage(error))
            }
        }

        operationStore.unregisterReadOnlyOperation(readOnlyID)
        isRefreshing = false
        if !cancelled {
            // Publish refreshedAt after isRefreshing resets so .task(id: refreshedAt) is not blocked by !isBusy.
            refreshedAt = Date()
        }

        let detail = cancelled
            ? String(localized: ActivityItemReason.cancelledByUser.message)
            : errorMessages.isEmpty ? "Loaded all environment states" : errorMessages.joined(separator: "; ")
        recordDiagnostic(id: refreshID, detail: detail)
        activityStore?.append(ActivitySummary(id: refreshID, operation: .refresh, scope: nil,
                                             targetDisplayNames: [], date: Date(),
                                             status: cancelled ? .cancelled : errorMessages.isEmpty ? .succeeded : .failed, itemOutcomes: [], reason: cancelled ? .cancelledByUser : errorMessages.isEmpty ? nil : .stateUnavailable))
    }

    private func refreshHomebrewState(snapshot: SnapshotStatus) async {
        let result = await capture { try await self.service.loadHomebrew(snapshot: snapshot, includingOutdated: false) }
        if case .failure(let error) = result, error is CancellationError || Task.isCancelled { return }
        applyHomebrewReadResult(result)
    }

    private func refreshNodeState(snapshot: SnapshotStatus) async {
        let result = await capture {
            try await self.service.loadNode(snapshot: snapshot, preferredNodeVersion: self.preferredNodeVersion, includingOutdated: false)
        }
        if case .failure(let error) = result, error is CancellationError || Task.isCancelled { return }
        applyNodeReadResult(result)
    }

    private func refreshShellState(snapshot: SnapshotStatus) async {
        let result = await capture { try await self.service.loadShell(snapshot: snapshot) }
        if case .failure(let error) = result, error is CancellationError || Task.isCancelled { return }
        applyShellReadResult(result)
        if case .failure(let error) = result { errorMessages.append(failureMessage(error)) }
    }

    func applyShellReadResult(_ result: Result<ShellStatus, Error>) {
        switch result {
        case .success(let snapshot):
            shell = snapshot
            shellRefreshFailed = false
        case .failure:
            shellRefreshFailed = true
        }
    }

    func applyHomebrewReadResult(_ result: Result<HomebrewStatus, Error>, includingOutdated: Bool = false) {
        switch result {
        case .success(let status):
            let snapshot = status.snapshot.map { $0.retainingFailedSections(from: homebrew?.snapshot) }
            homebrew = HomebrewStatus(executablePath: status.executablePath, version: status.version,
                                      managerAvailable: status.managerAvailable, snapshot: snapshot)
            homebrewRefreshFailed = false
            if snapshot?.sectionErrors.keys.contains(where: { $0 != .outdated }) != true {
                homebrewRefreshedAt = Date()
            }
            if status.snapshot != nil && status.snapshot?.sectionErrors[.packages] == nil {
                homebrewPackagesRefreshedAt = Date()
            }
            homebrewUpdateState = includingOutdated && snapshot != nil
                ? (snapshot?.sectionErrors[.outdated] == nil ? .available : .failed) : .notLoaded
            homebrewOutdatedCheckedAt = includingOutdated && snapshot != nil ? Date() : nil
        case .failure(let error):
            homebrewRefreshFailed = true
            homebrewUpdateState = .failed
            errorMessages.append(failureMessage(error))
        }
    }

    func applyNodeReadResult(_ result: Result<NodeSnapshot, Error>, includingOutdated: Bool = false) {
        switch result {
        case .success(let snapshot):
            node = snapshot.retainingKnownOutdated(from: node)
            nodeRefreshFailed = false
            nodeRefreshedAt = Date()
            nodeUpdateState = includingOutdated ? (snapshot.outdatedError == nil ? .available : .failed) : .notLoaded
            nodeOutdatedCheckedAt = includingOutdated ? Date() : nil
        case .failure(let error):
            if case BridgeError.managerFailure(let code, _) = error, code == "missing-dependency", node == nil {
                nodeRefreshFailed = false
                nodeUpdateState = .notLoaded
            } else {
                nodeRefreshFailed = true
                nodeUpdateState = .failed
                errorMessages.append(failureMessage(error))
            }
        }
    }

    func prepareBatch(_ intent: BatchIntent) async throws -> BatchPlan {
        guard !isBusy else { throw BatchOperationError.busy }
        guard canMutatePackages(in: intent.scope) else { throw BatchOperationError.reconciliationUnavailable }
        setBatchWorking(intent.scope, true)
        defer { setBatchWorking(intent.scope, false) }
        return try await batchCoordinator.prepare(intent)
    }

    func executeBatch(_ plan: BatchPlan, caskRemovalProgress: CaskRemovalProgressHandler? = nil) async throws -> BatchExecutionResult {
        guard !isBusy else { throw BatchOperationError.busy }
        guard canMutatePackages(in: plan.intent.scope) else { throw BatchOperationError.reconciliationUnavailable }
        setBatchWorking(plan.intent.scope, true)
        defer { setBatchWorking(plan.intent.scope, false) }
        let result = try await batchCoordinator.execute(plan, caskRemovalProgress: caskRemovalProgress)
        applyBatchResult(result)
        return result
    }

    func applyBatchResult(_ result: BatchExecutionResult) {
        switch result.refreshedState {
        case .homebrew(let status):
            applyHomebrewReadResult(.success(status), includingOutdated: true)
        case .npm(let snapshot), .nodeRuntime(let snapshot):
            applyNodeReadResult(.success(snapshot), includingOutdated: true)
            if NodeEnvironmentResolver.packageInstallation(summary: snapshot.summary, installations: snapshot.installations,
                                                           approvedSystemPrefixes: []) != nil {
                preferredNodeVersion = snapshot.summary.nodeVersion
            }
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
            let homebrewPending = homebrew?.isInstalled == true && homebrewUpdateState == .notLoaded
            let nodePending = node != nil && nodeUpdateState == .notLoaded
            if !homebrewPending && !nodePending {
                checkedOutdatedRefresh = refreshedAt
            }
        }
    }

    var nodePackageEnvironment: NodeEnvironmentContext? {
        nodeRefreshFailed ? nil : node?.packageEnvironment
    }

    func canMutatePackages(in scope: BatchScope) -> Bool {
        switch scope {
        case .homebrew:
            return !homebrewRefreshFailed && homebrew?.snapshot?.sectionErrors[.packages] == nil
        case .npm(let environment):
            return nodePackageEnvironment == environment
        case .nodeRuntime:
            return !nodeRefreshFailed
        }
    }

    private func setBatchWorking(_ scope: BatchScope, _ working: Bool) {
        switch scope {
        case .homebrew: isHomebrewWorking = working
        case .npm, .nodeRuntime: isNodeWorking = working
        }
    }

    func recordDiagnostic(
        id: UUID,
        detail: String,
        command: HomebrewCommandOutput? = nil
    ) {
        let context = operationStore.currentOperation?.context
        activityDiagnostics.record(
            id: id,
            operation: context?.operation ?? .refresh,
            scope: context?.scope,
            detail: detail,
            command: command
        )
    }

    func failureMessage(_ error: Error, preparing: Bool = false) -> String {
        let context = operationStore.currentOperation?.context
        let operation = context?.operation ?? (isRefreshing ? .refresh : .configuration)
        activityDiagnostics.record(operation: operation, scope: context?.scope, detail: error.localizedDescription)
        let reason = ActivityItemReason(error: error, preparing: preparing)
        logStore?.record(level: .error, category: "operation", message: "\(operation.rawValue): \(reason.rawValue)", taskID: operationStore.currentOperation?.id)
        return String(localized: reason.message)
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
