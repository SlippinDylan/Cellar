import Foundation

actor SystemProbeService {
    private let runner: ProcessRunner
    private let installer: ManagerSnapshotInstaller
    private let nodeClient: NodeManagerClient
    private let shellClient: ShellManagerClient
    private let environmentResolver: NodeEnvironmentResolver
    private let locator: ExecutableLocator
    private var homebrewClient: HomebrewClient?

    init(
        runner: ProcessRunner,
        installer: ManagerSnapshotInstaller,
        nodeClient: NodeManagerClient,
        shellClient: ShellManagerClient,
        environmentResolver: NodeEnvironmentResolver = NodeEnvironmentResolver(),
        locator: ExecutableLocator = ExecutableLocator(),
        homebrewClient: HomebrewClient? = nil
    ) {
        self.runner = runner
        self.installer = installer
        self.nodeClient = nodeClient
        self.shellClient = shellClient
        self.environmentResolver = environmentResolver
        self.locator = locator
        self.homebrewClient = homebrewClient
    }

    func installManagers() async throws -> SnapshotStatus {
        try await installer.installIfNeeded()
    }

    func isNVMInstalled() -> Bool {
        environmentResolver.isNVMInstalled()
    }

    func loadHomebrew(snapshot: SnapshotStatus, includingOutdated: Bool = true) async throws -> HomebrewStatus {
        let environment = environmentResolver.environment()
        guard let executable = locator.locate("brew", path: environment["PATH", default: ""]) else {
            return HomebrewStatus(
                executablePath: nil,
                version: nil,
                managerAvailable: snapshot.homebrewAvailable,
                snapshot: nil
            )
        }
        let client = HomebrewClient(brewURL: executable, runner: runner, caskRemovalAuthorizer: .init(runner: runner))
        homebrewClient = client
        let homebrewSnapshot = try await client.loadSnapshot(includingOutdated: includingOutdated)
        return HomebrewStatus(
            executablePath: executable.path,
            version: homebrewSnapshot.version,
            managerAvailable: snapshot.homebrewAvailable,
            snapshot: homebrewSnapshot
        )
    }

    func loadHomebrewOutdatedPackages() async throws -> [HomebrewOutdatedPackage] {
        try await requireHomebrewClient().loadOutdatedPackages()
    }

    func searchHomebrew(_ query: String) async throws -> [HomebrewSearchResult] {
        try await requireHomebrewClient().search(query)
    }

    func discoverHomebrew(_ query: String, kind: HomebrewPackageKind, limit: Int = 50) async throws -> [HomebrewPackage] {
        try await requireHomebrewClient().discover(query, kind: kind, limit: limit)
    }

    func diagnoseHomebrew() async throws -> HomebrewDiagnosticReport {
        try await requireHomebrewClient().diagnose()
    }

    func planHomebrewInstall(_ identity: HomebrewPackageIdentity) async throws -> HomebrewActionPlan {
        try await requireHomebrewClient().planInstall(identity)
    }

    func planHomebrewInstall(_ identities: [HomebrewPackageIdentity]) async throws -> HomebrewActionPlan {
        try await requireHomebrewClient().planInstall(identities)
    }

    func planHomebrewUpgrade(_ targets: [HomebrewPackageIdentity]) async throws -> HomebrewActionPlan {
        try await requireHomebrewClient().planUpgrade(targets)
    }

    func renewHomebrewBatchPlan(_ plan: HomebrewActionPlan) async throws -> HomebrewActionPlan? {
        try await requireHomebrewClient().renewBatchPlan(plan)
    }

    func renewNPMBatchPlan(_ plan: NodeActionPlan, environment: NodeEnvironmentContext, snapshot: SnapshotStatus) async throws -> NodeActionPlan? {
        try await nodeClient.renewBatchPackagePlan(plan, environment: environment, managerDirectory: nodeManagerDirectory(snapshot))
    }

    func planHomebrewUpdate() async throws -> HomebrewActionPlan {
        try await requireHomebrewClient().planUpdate()
    }

    func planHomebrewAddTap(_ name: String) async throws -> HomebrewActionPlan {
        try await requireHomebrewClient().planAddTap(name)
    }

    func planHomebrewRemoveTap(_ name: String) async throws -> HomebrewActionPlan {
        try await requireHomebrewClient().planRemoveTap(name)
    }

    func planHomebrewFormulaUninstall(_ name: String) async throws -> HomebrewActionPlan {
        try await requireHomebrewClient().planFormulaUninstall(name)
    }

    func planHomebrewCaskUninstall(_ name: String, zap: Bool) async throws -> HomebrewActionPlan {
        try await requireHomebrewClient().planCaskUninstall(name, zap: zap)
    }

    func planHomebrewCaskRemoval(_ name: String) async throws -> HomebrewActionPlan {
        try await requireHomebrewClient().planCaskRemoval(name)
    }

    func executeHomebrew(_ plan: HomebrewActionPlan, caskRemovalProgress: CaskRemovalProgressHandler? = nil) async throws -> HomebrewActionResult {
        try await requireHomebrewClient().execute(plan, caskRemovalProgress: caskRemovalProgress)
    }

    func loadShell(snapshot: SnapshotStatus) async throws -> ShellStatus {
        try await shellClient.loadSnapshot(
            managerDirectory: shellManagerDirectory(snapshot),
            managerAvailable: snapshot.shellAvailable
        )
    }

    func planShell(_ request: ShellActionRequest, snapshot: SnapshotStatus) async throws -> ShellActionPlan {
        try await shellClient.plan(request, managerDirectory: shellManagerDirectory(snapshot))
    }

    func executeShell(_ plan: ShellActionPlan, snapshot: SnapshotStatus) async throws -> ShellOperationResult {
        try await shellClient.execute(plan, managerDirectory: shellManagerDirectory(snapshot))
    }

    func planTerminalConfiguration(plugins: [String], theme: String, snapshot: SnapshotStatus) async throws -> ShellConfigurationPlan {
        try await shellClient.planConfiguration(plugins: plugins, theme: theme, managerDirectory: shellManagerDirectory(snapshot))
    }

    func executeTerminalConfiguration(_ plan: ShellConfigurationPlan, snapshot: SnapshotStatus) async -> ShellConfigurationResult {
        await shellClient.executeConfiguration(plan, managerDirectory: shellManagerDirectory(snapshot))
    }

    func runtimeInstallations(preferredVersion: String?) -> [NodeInstallation] {
        environmentResolver.installations(preferredNodeVersion: preferredVersion)
    }

    func controlledNodePath(preferredVersion: String?) -> String {
        environmentResolver.environment(preferredNodeVersion: preferredVersion)["PATH", default: ""]
    }

    func loadNode(
        snapshot: SnapshotStatus,
        preferredNodeVersion: String? = nil,
        includingOutdated: Bool = true
    ) async throws -> NodeSnapshot {
        guard snapshot.nodeAvailable else {
            throw BridgeError.executableNotFound("node-manager/main.sh")
        }
        return try await nodeClient.loadSnapshot(
            managerDirectory: nodeManagerDirectory(snapshot),
            preferredNodeVersion: preferredNodeVersion,
            includingOutdated: includingOutdated
        )
    }

    func loadNodeOutdatedPackages(node: NodeSnapshot) async throws -> [String: OutdatedPackage] {
        let snapshot = await installer.status()
        guard snapshot.nodeAvailable else { throw BridgeError.executableNotFound("node-manager/main.sh") }
        return try await nodeClient.loadOutdatedPackages(managerDirectory: nodeManagerDirectory(snapshot), summary: node.summary)
    }

    func planNode(
        _ request: NodeActionRequest,
        snapshot: SnapshotStatus,
        preferredNodeVersion: String?
    ) async throws -> NodeActionPlan {
        try await nodeClient.plan(
            request,
            managerDirectory: nodeManagerDirectory(snapshot),
            preferredNodeVersion: preferredNodeVersion
        )
    }

    func executeNode(
        _ plan: NodeActionPlan,
        snapshot: SnapshotStatus,
        preferredNodeVersion: String?
    ) async throws -> NodeOperationResult {
        try await nodeClient.execute(
            plan,
            managerDirectory: nodeManagerDirectory(snapshot),
            preferredNodeVersion: preferredNodeVersion
        )
    }

    func planNPMPackage(_ identity: NPMPackageIdentity, action: NodeAction, snapshot: SnapshotStatus) async throws -> NodeActionPlan {
        try await nodeClient.planPackage(identity, action: action, managerDirectory: nodeManagerDirectory(snapshot))
    }

    func effectiveNPMRegistry(_ specOrQuery: String, environment: NodeEnvironmentContext) async throws -> URL {
        let snapshot = try await installManagers()
        return try await nodeClient.effectivePackageRegistry(specOrQuery, environment: environment, managerDirectory: nodeManagerDirectory(snapshot))
    }

    func scopeRegistryLayers(_ scope: String, environment: NodeEnvironmentContext, snapshot: SnapshotStatus) async throws -> NPMRegistryLayers {
        try await nodeClient.scopeRegistryLayers(scope, environment: environment, managerDirectory: nodeManagerDirectory(snapshot))
    }

    func executeNPMPackage(_ plan: NodeActionPlan, environment: NodeEnvironmentContext, snapshot: SnapshotStatus) async throws -> NodeOperationResult {
        try await nodeClient.executePackage(plan, environment: environment, managerDirectory: nodeManagerDirectory(snapshot))
    }

    func loadNPMPackageEnvironment(_ environment: NodeEnvironmentContext, snapshot: SnapshotStatus) async throws -> NodeSnapshot {
        try await nodeClient.loadPackageSnapshot(environment, managerDirectory: nodeManagerDirectory(snapshot))
    }

    func planNodeUninstall(_ identity: NodeRuntimeIdentity, snapshot: SnapshotStatus) async throws -> NodeActionPlan {
        try await nodeClient.planRuntimeUninstall(identity, managerDirectory: nodeManagerDirectory(snapshot))
    }

    func executeNodeUninstall(_ plan: NodeActionPlan, environment: NodeEnvironmentContext, snapshot: SnapshotStatus) async throws -> NodeOperationResult {
        try await nodeClient.executeRuntimeUninstall(plan, environment: environment, managerDirectory: nodeManagerDirectory(snapshot))
    }

    func terminateAllProcesses() async {
        await runner.terminateAll()
    }

    private func requireHomebrewClient() throws -> HomebrewClient {
        if let homebrewClient {
            return homebrewClient
        }
        let environment = environmentResolver.environment()
        guard let executable = locator.locate("brew", path: environment["PATH", default: ""]) else {
            throw BridgeError.executableNotFound("brew")
        }
        let client = HomebrewClient(brewURL: executable, runner: runner)
        homebrewClient = client
        return client
    }

    private func nodeManagerDirectory(_ snapshot: SnapshotStatus) -> URL {
        URL(filePath: snapshot.location, directoryHint: .isDirectory)
            .appending(path: "node-manager", directoryHint: .isDirectory)
    }

    private func shellManagerDirectory(_ snapshot: SnapshotStatus) -> URL {
        URL(filePath: snapshot.location, directoryHint: .isDirectory)
            .appending(path: "zsh-manager", directoryHint: .isDirectory)
    }
}
