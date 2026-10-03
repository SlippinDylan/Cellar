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
        locator: ExecutableLocator = ExecutableLocator()
    ) {
        self.runner = runner
        self.installer = installer
        self.nodeClient = nodeClient
        self.shellClient = shellClient
        self.environmentResolver = environmentResolver
        self.locator = locator
    }

    func installManagers() async throws -> SnapshotStatus {
        try await installer.installIfNeeded()
    }

    func loadHomebrew(snapshot: SnapshotStatus) async throws -> HomebrewStatus {
        let environment = environmentResolver.environment()
        guard let executable = locator.locate("brew", path: environment["PATH", default: ""]) else {
            return HomebrewStatus(
                executablePath: nil,
                version: nil,
                managerAvailable: snapshot.homebrewAvailable,
                snapshot: nil
            )
        }
        let client = HomebrewClient(brewURL: executable, runner: runner)
        homebrewClient = client
        let homebrewSnapshot = try await client.loadSnapshot()
        return HomebrewStatus(
            executablePath: executable.path,
            version: homebrewSnapshot.version,
            managerAvailable: snapshot.homebrewAvailable,
            snapshot: homebrewSnapshot
        )
    }

    func searchHomebrew(_ query: String) async throws -> [HomebrewSearchResult] {
        try await requireHomebrewClient().search(query)
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

    func executeHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionResult {
        try await requireHomebrewClient().execute(plan)
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

    func loadNode(
        snapshot: SnapshotStatus,
        preferredNodeVersion: String? = nil
    ) async throws -> NodeSnapshot {
        guard snapshot.nodeAvailable else {
            throw BridgeError.executableNotFound("node-manager/main.sh")
        }
        return try await nodeClient.loadSnapshot(
            managerDirectory: nodeManagerDirectory(snapshot),
            preferredNodeVersion: preferredNodeVersion
        )
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

    func executeNPMPackage(_ plan: NodeActionPlan, environment: NodeEnvironmentContext, snapshot: SnapshotStatus) async throws -> NodeOperationResult {
        try await nodeClient.executePackage(plan, environment: environment, managerDirectory: nodeManagerDirectory(snapshot))
    }

    func loadNPMPackageEnvironment(_ environment: NodeEnvironmentContext, snapshot: SnapshotStatus) async throws -> NodeSnapshot {
        try await nodeClient.loadPackageSnapshot(environment, managerDirectory: nodeManagerDirectory(snapshot))
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
