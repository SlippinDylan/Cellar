import Foundation

struct HomeOutdatedDependencies: Sendable {
    let homebrew: @Sendable () async throws -> [HomebrewOutdatedPackage]
    let node: @Sendable (NodeSnapshot) async throws -> [String: OutdatedPackage]

    init(homebrew: @escaping @Sendable () async throws -> [HomebrewOutdatedPackage],
         node: @escaping @Sendable (NodeSnapshot) async throws -> [String: OutdatedPackage]) {
        self.homebrew = homebrew
        self.node = node
    }

    init(service: SystemProbeService) {
        self.init(homebrew: { try await service.loadHomebrewOutdatedPackages() },
                  node: { try await service.loadNodeOutdatedPackages(node: $0) })
    }
}

extension AppModel {
    func invalidateHomeUpdates() {
        activeOutdatedRefreshID = nil
        if homebrewUpdateState == .loading { homebrewUpdateState = .notLoaded }
        if nodeUpdateState == .loading { nodeUpdateState = .notLoaded }
    }

    func refreshHomeBackground(after localRefresh: Date?, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard environment["XCTestConfigurationFilePath"] == nil, let localRefresh,
              localRefresh == refreshedAt, !Task.isCancelled else { return }
        let requestID = UUID()
        latestHomeBackgroundRequestID = requestID
        if let previous = homeBackgroundOwner {
            guard !operationStore.hasActiveOperations || operationStore.isSoleOperation(previous.operationID) else { return }
            let healthyDuplicate = previous.refreshedAt == localRefresh && !previous.task.isCancelled
            if !healthyDuplicate { previous.task.cancel() }
            let completed = await previous.task.value
            guard !Task.isCancelled, latestHomeBackgroundRequestID == requestID else { return }
            if completed && previous.refreshedAt == localRefresh { return }
        }
        guard !Task.isCancelled, latestHomeBackgroundRequestID == requestID,
              localRefresh == refreshedAt, !isBusy else { return }
        let operationID = operationStore.begin()
        let task = Task { await self.runHomeBackground(operationID: operationID, localRefresh: localRefresh, environment: environment) }
        homeBackgroundOwner = (operationID, localRefresh, task)
        await withTaskCancellationHandler {
            _ = await task.value
        } onCancel: { task.cancel() }
        if homeBackgroundOwner?.operationID == operationID { homeBackgroundOwner = nil }
    }

    private func runHomeBackground(operationID: UUID, localRefresh: Date, environment: [String: String]) async -> Bool {
        // Release the slot before task.value resumes a caller waiting to take ownership.
        defer { operationStore.end(operationID) }
        do {
            try await operationStore.performCancellable(operationID: operationID) {
                async let versions: Void = self.homeDashboard.refresh(after: localRefresh, environment: environment)
                async let updates: Void = self.refreshHomeOutdated(after: localRefresh, environment: environment)
                _ = await (versions, updates)
                try Task.checkCancellation()
            }
            return true
        } catch is CancellationError {
            // Each child settles its state before the shared lifecycle slot is released.
            return false
        } catch {
            preconditionFailure("Home reads handle provider failures before returning: \(error)")
        }
    }

    // Home owns this task alongside official versions. The two providers finish independently.
    func refreshHomeOutdated(after localRefresh: Date?, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard environment["XCTestConfigurationFilePath"] == nil, let localRefresh,
              localRefresh == refreshedAt, localRefresh != checkedOutdatedRefresh, !Task.isCancelled else { return }
        let refreshID = UUID()
        activeOutdatedRefreshID = refreshID
        async let brew: Void = refreshHomebrewOutdated(localRefresh: localRefresh, refreshID: refreshID)
        async let npm: Void = refreshNodeOutdated(localRefresh: localRefresh, refreshID: refreshID)
        _ = await (brew, npm)
        guard activeOutdatedRefreshID == refreshID else { return }
        activeOutdatedRefreshID = nil
        if !Task.isCancelled && localRefresh == refreshedAt { checkedOutdatedRefresh = localRefresh }
    }

    private func refreshHomebrewOutdated(localRefresh: Date, refreshID: UUID) async {
        guard !homebrewRefreshFailed, let status = homebrew, let core = status.snapshot else { return }
        let previousState = homebrewUpdateState == .loading ? .notLoaded : homebrewUpdateState
        homebrewUpdateState = .loading
        defer {
            if Task.isCancelled && activeOutdatedRefreshID == refreshID && refreshedAt == localRefresh && homebrewUpdateState == .loading {
                homebrewUpdateState = previousState
            }
        }
        do {
            let outdated = try await homeOutdatedDependencies.homebrew()
            guard !Task.isCancelled, refreshedAt == localRefresh, activeOutdatedRefreshID == refreshID else { return }
            homebrew = HomebrewStatus(executablePath: status.executablePath, version: status.version,
                                      managerAvailable: status.managerAvailable, snapshot: core.replacingOutdated(packages: outdated, error: nil))
            homebrewUpdateState = .available
            homebrewOutdatedCheckedAt = Date()
        } catch {
            guard refreshedAt == localRefresh, activeOutdatedRefreshID == refreshID else { return }
            if Task.isCancelled || error is CancellationError { homebrewUpdateState = previousState }
            else {
                homebrew = HomebrewStatus(executablePath: status.executablePath, version: status.version,
                                          managerAvailable: status.managerAvailable, snapshot: core.replacingOutdated(packages: core.outdatedPackages, error: error.localizedDescription))
                homebrewUpdateState = .failed
                homebrewOutdatedCheckedAt = Date()
            }
        }
    }

    private func refreshNodeOutdated(localRefresh: Date, refreshID: UUID) async {
        guard !nodeRefreshFailed, let core = node else { return }
        let previousState = nodeUpdateState == .loading ? .notLoaded : nodeUpdateState
        nodeUpdateState = .loading
        defer {
            if Task.isCancelled && activeOutdatedRefreshID == refreshID && refreshedAt == localRefresh && nodeUpdateState == .loading {
                nodeUpdateState = previousState
            }
        }
        do {
            let outdated = try await homeOutdatedDependencies.node(core)
            guard !Task.isCancelled, refreshedAt == localRefresh, activeOutdatedRefreshID == refreshID else { return }
            node = core.replacingOutdated(packages: outdated, error: nil)
            nodeUpdateState = .available
            nodeOutdatedCheckedAt = Date()
        } catch {
            guard refreshedAt == localRefresh, activeOutdatedRefreshID == refreshID else { return }
            if Task.isCancelled || error is CancellationError { nodeUpdateState = previousState }
            else {
                node = NodeSnapshot(summary: core.summary, configuration: core.configuration, packages: core.packages,
                                    installations: core.installations, managerStatus: core.managerStatus, logs: core.logs,
                                    outdatedError: error.localizedDescription, maintenanceError: core.maintenanceError, packageEnvironment: core.packageEnvironment)
                nodeUpdateState = .failed
                nodeOutdatedCheckedAt = Date()
            }
        }
    }
}
