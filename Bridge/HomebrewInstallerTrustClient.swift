import Foundation

struct HomebrewInstallerTrustClient: Sendable {
    private let run: @Sendable (ProcessRequest) async throws -> ProcessResult

    init(run: @escaping @Sendable (ProcessRequest) async throws -> ProcessResult) { self.run = run }
    init(runner: ProcessRunner) { self.init(run: { try await runner.run($0) }) }

    func validatePackageSignature(_ package: URL) async throws {
        try Task.checkCancellation()
        let result = try await run(request(executable: "/usr/sbin/pkgutil", arguments: ["--check-signature", package.path], package: package))
        try Task.checkCancellation()
        let lines = result.outputText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Accept either Apple's Developer ID distribution chain (real Homebrew.pkg)
        // or an Apple-trusted root status, requiring exit code 0 and untruncated output.
        let hasTrustedStatus = lines.contains { $0.hasPrefix("Status: signed by a certificate trusted by") }
        let hasDeveloperIDDistributionChain =
            lines.contains { $0.hasPrefix("Status: signed by a developer certificate issued by Apple for distribution") }
            && lines.contains { $0.contains("Developer ID Installer:") }
            && lines.contains { $0.contains("Apple Root CA") }
        guard result.terminationStatus == 0, !result.standardOutputWasTruncated, !result.standardErrorWasTruncated,
              hasTrustedStatus || hasDeveloperIDDistributionChain
        else { throw HomebrewSetupFailure.packageSignature }
    }

    func assessGatekeeper(_ package: URL) async throws {
        try Task.checkCancellation()
        let result = try await run(request(executable: "/usr/sbin/spctl", arguments: ["--assess", "--type", "install", "--verbose=2", "--ignore-cache", "--no-cache", package.path], package: package))
        try Task.checkCancellation()
        guard result.terminationStatus == 0, !result.standardOutputWasTruncated, !result.standardErrorWasTruncated,
              result.errorText.split(separator: "\n").contains("\(package.path): accepted")
        else { throw HomebrewSetupFailure.gatekeeper }
    }

    // Invokes macOS native administrator authorization (Touch ID / password) to run
    // /usr/sbin/installer silently without collecting passwords or spawning a daemon.
    func installPackageWithAdministratorPrivileges(_ package: URL) async throws {
        try Task.checkCancellation()
        let process = ProcessRequest(
            executableURL: URL(filePath: "/usr/bin/osascript"),
            arguments: ["-e", Self.installerAuthorizationScript, package.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"],
            currentDirectoryURL: package.deletingLastPathComponent(),
            timeout: .seconds(600),
            standardOutputLimit: 65_536,
            standardErrorLimit: 65_536
        )
        let result = try await run(process)
        try Task.checkCancellation()
        if result.terminationStatus != 0 {
            let errorText = result.errorText
            if errorText.contains("User canceled") || errorText.contains("-128") {
                throw CancellationError()
            }
            throw HomebrewSetupFailure.systemOpen
        }
    }

    static let installerAuthorizationScript = #"""
    on run argv
        set pkgPath to item 1 of argv
        set commandText to "/usr/sbin/installer -pkg " & quoted form of pkgPath & " -target /"
        do shell script commandText with administrator privileges
    end run
    """#

    private func request(executable: String, arguments: [String], package: URL) -> ProcessRequest {
        ProcessRequest(executableURL: URL(filePath: executable), arguments: arguments, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"], currentDirectoryURL: package.deletingLastPathComponent(), timeout: .seconds(30), standardOutputLimit: 32_768, standardErrorLimit: 32_768)
    }
}
