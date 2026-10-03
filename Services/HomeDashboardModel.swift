import Combine
import Foundation

struct HomeDashboardDependencies: Sendable {
    var commandLineTools: @Sendable () async throws -> CommandLineToolsState
    var nvmInstalled: @Sendable () async -> Bool
    var homebrewLocationOccupied: @Sendable () async -> Bool = { false }
    var latestVersion: @Sendable (HomeOnlineSource) async throws -> String
    var requestCommandLineTools: @Sendable () async throws -> Void
    var openInstaller: @Sendable () async throws -> Void
    var finishInstallerHandoff: @Sendable () async throws -> Void

    static func live(runner: ProcessRunner) -> Self {
        let tools = CommandLineToolsService(runner: runner)
        let installer = HomebrewSetupService(runner: runner)
        let homebrew = HomebrewReleaseClient()
        let node = NodeVersionMetadataClient()
        return Self(
            commandLineTools: { try await tools.state() },
            nvmInstalled: { FileManager.default.fileExists(atPath: URL.homeDirectory.appending(path: ".nvm/nvm.sh").path) },
            homebrewLocationOccupied: { !Self.installationLocationIsClear(at: URL(filePath: "/opt/homebrew")) },
            latestVersion: { source in
                switch source {
                case .homebrew: try await homebrew.latestVersion()
                case .node: try await node.latestNodeVersion()
                case .npm: try await node.latestNPMVersion()
                case .nvm: try await node.latestNVMVersion()
                }
            },
            requestCommandLineTools: { try await tools.requestInstallation() },
            openInstaller: { _ = try await installer.openInstaller() },
            finishInstallerHandoff: { try await installer.finishInstallerHandoff() }
        )
    }

    static func installationLocationIsClear(at url: URL) -> Bool {
        do {
            // Inspect the directory entry itself so a dangling symlink is still occupied.
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return false
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return true
        } catch {
            // An inaccessible or indeterminate location is not proven safe for installation.
            return false
        }
    }
}

@MainActor
final class HomeDashboardModel: ObservableObject {
    @Published private(set) var commandLineTools = HomeCommandLineToolsState.notLoaded
    @Published private(set) var nvmInstalled: Bool?
    @Published private(set) var homebrewLocationOccupied: Bool?
    @Published private(set) var onlineVersions = Dictionary(uniqueKeysWithValues: HomeOnlineSource.allCases.map { ($0, OnlineVersionState.notLoaded) })
    @Published private(set) var onlineCheckedAt: [HomeOnlineSource: Date] = [:]
    @Published private(set) var setupState = HomeSetupState.idle
    @Published private(set) var installerHandoffPending = false

    let officialHomebrewURL = CatalogWebsites.homebrew
    private let dependencies: HomeDashboardDependencies
    private let operationStore: OperationStore
    private var checkedLocalRefresh: Date?
    private var activeRefreshID: UUID?

    init(dependencies: HomeDashboardDependencies, operationStore: OperationStore) {
        self.dependencies = dependencies
        self.operationStore = operationStore
    }

    func onlineVersion(for source: HomeOnlineSource) -> OnlineVersionState {
        guard let state = onlineVersions[source] else { preconditionFailure("Every official source has a version state") }
        return state
    }

    // The view owns this structured task. It starts only after local data is published.
    func refresh(after localRefresh: Date?, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard environment["XCTestConfigurationFilePath"] == nil,
              let localRefresh, localRefresh != checkedLocalRefresh, !Task.isCancelled else { return }
        let refreshID = UUID()
        activeRefreshID = refreshID
        let previousTools = commandLineTools == .loading ? .notLoaded : commandLineTools
        commandLineTools = .loading
        let previousVersions = onlineVersions.mapValues { $0 == .loading ? .notLoaded : $0 }
        for source in HomeOnlineSource.allCases { onlineVersions[source] = .loading }

        async let prerequisites: Void = refreshPrerequisites(refreshID: refreshID)
        // Exactly four bounded requests; each publishes independently as it finishes.
        await withTaskGroup(of: (HomeOnlineSource, OnlineVersionState).self) { group in
            for source in HomeOnlineSource.allCases {
                group.addTask { [dependencies] in
                    do {
                        let version = try await dependencies.latestVersion(source)
                        return (source, .available(version: version))
                    } catch {
                        let offline = (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost].contains($0.code) } == true
                        return (source, .unavailable(reason: offline ? "offline" : "error"))
                    }
                }
            }
            for await (source, state) in group {
                if !Task.isCancelled && activeRefreshID == refreshID {
                    onlineVersions[source] = state
                    onlineCheckedAt[source] = Date()
                }
            }
        }
        await prerequisites
        guard activeRefreshID == refreshID else { return }
        activeRefreshID = nil
        if Task.isCancelled {
            for source in HomeOnlineSource.allCases where onlineVersions[source] == .loading {
                onlineVersions[source] = previousVersions[source]
            }
            if commandLineTools == .loading { commandLineTools = previousTools }
        } else { checkedLocalRefresh = localRefresh }
    }

    func installationState(homebrew: HomebrewStatus?, readFailed: Bool, hasRefreshed: Bool) -> HomebrewInstallationState {
        if readFailed { return .unavailable(reason: "local-read") }
        if let homebrew, let path = homebrew.executablePath, let version = homebrew.version {
            return .installed(HomebrewInstallation(executablePath: path, version: HomeVersion.normalized(version)))
        }
        guard hasRefreshed else { return .notChecked }
        if commandLineTools == .available(.notInstalled) { return .commandLineToolsRequired }
        if case .available(.installed) = commandLineTools, let homebrew, !homebrew.isInstalled,
           homebrewLocationOccupied == false { return .notInstalled }
        if homebrew?.isInstalled == true { return .unavailable(reason: "local-read") }
        return commandLineTools == .loading ? .checking : .unavailable(reason: "prerequisites")
    }

    func requestCommandLineTools(installation: HomebrewInstallationState) async {
        guard installation == .commandLineToolsRequired, canBeginSetup else { return }
        setupState = .requestingCommandLineTools
        await performSetup { [dependencies] in try await dependencies.requestCommandLineTools() }
        if setupState == .requestingCommandLineTools { setupState = .commandLineToolsRequested }
    }

    func openHomebrewInstaller(installation: HomebrewInstallationState) async {
        guard installation == .notInstalled, canBeginSetup else { return }
        setupState = .preparingInstaller
        await performSetup { [dependencies] in try await dependencies.openInstaller() }
        if setupState == .preparingInstaller {
            installerHandoffPending = true
            setupState = .installerOpened
        }
    }

    // Only an explicit completion signal releases the package that Installer may still read.
    func finishInstallerHandoff() async -> Bool {
        guard installerHandoffPending, !operationStore.hasActiveOperations else { return false }
        do {
            try await dependencies.finishInstallerHandoff()
            installerHandoffPending = false
            setupState = .idle
            return true
        } catch {
            setupState = .failed(.homebrew(.temporaryFile))
            return false
        }
    }

    private var canBeginSetup: Bool {
        guard !operationStore.hasActiveOperations, !installerHandoffPending else { return false }
        return switch setupState {
        case .idle, .failed, .commandLineToolsRequested: true
        case .requestingCommandLineTools, .preparingInstaller, .installerOpened: false
        }
    }

    private func refreshPrerequisites(refreshID: UUID) async {
        async let nvm = dependencies.nvmInstalled()
        async let occupied = dependencies.homebrewLocationOccupied()
        do {
            let tools = try await dependencies.commandLineTools()
            if !Task.isCancelled && activeRefreshID == refreshID { commandLineTools = .available(tools) }
        } catch {
            if !Task.isCancelled && activeRefreshID == refreshID { commandLineTools = .failed }
        }
        let values = await (nvm, occupied)
        if !Task.isCancelled && activeRefreshID == refreshID {
            nvmInstalled = values.0
            homebrewLocationOccupied = values.1
        }
    }

    private func performSetup(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async {
        let id = operationStore.begin()
        defer { operationStore.end(id) }
        do {
            try await operationStore.performCancellable(operationID: id, operation: operation)
        } catch {
            if Task.isCancelled || error is CancellationError { setupState = .idle }
            else if setupState == .requestingCommandLineTools { setupState = .failed(.commandLineTools) }
            else { setupState = .failed(.homebrew((error as? HomebrewSetupError)?.failure ?? .systemOpen)) }
        }
    }
}
