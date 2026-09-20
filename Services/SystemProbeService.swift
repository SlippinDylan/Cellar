import Foundation

actor SystemProbeService {
    private let runner: ProcessRunner
    private let installer: ManagerSnapshotInstaller
    private let nodeClient: NodeManagerClient
    private let environmentResolver: NodeEnvironmentResolver
    private let locator: ExecutableLocator
    private var homebrewClient: HomebrewClient?

    init(
        runner: ProcessRunner,
        installer: ManagerSnapshotInstaller,
        nodeClient: NodeManagerClient,
        environmentResolver: NodeEnvironmentResolver = NodeEnvironmentResolver(),
        locator: ExecutableLocator = ExecutableLocator()
    ) {
        self.runner = runner
        self.installer = installer
        self.nodeClient = nodeClient
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
        let environment = environmentResolver.environment()
        let result = try await runner.run(ProcessRequest(
            executableURL: URL(filePath: "/bin/zsh"),
            arguments: ["--version"],
            environment: environment,
            currentDirectoryURL: nil
        ))
        guard result.terminationStatus == 0 else {
            throw BridgeError.managerFailure(code: "zsh-version-failed", detail: result.errorText)
        }
        let ohMyZsh = URL.homeDirectory.appending(path: ".oh-my-zsh", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: ohMyZsh.path, isDirectory: &isDirectory)
        return ShellStatus(
            zshVersion: result.outputText.trimmingCharacters(in: .whitespacesAndNewlines),
            ohMyZshPath: ohMyZsh.path,
            ohMyZshInstalled: exists && isDirectory.boolValue,
            managerAvailable: snapshot.shellAvailable
        )
    }

    func loadNode(snapshot: SnapshotStatus) async throws -> NodeSnapshot {
        guard snapshot.nodeAvailable else {
            throw BridgeError.executableNotFound("node-manager/main.sh")
        }
        let directory = URL(filePath: snapshot.location, directoryHint: .isDirectory)
            .appending(path: "node-manager", directoryHint: .isDirectory)
        return try await nodeClient.loadSnapshot(managerDirectory: directory)
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
}
