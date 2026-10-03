import Foundation

struct HomebrewInstallerTrustClient: Sendable {
    private let run: @Sendable (ProcessRequest) async throws -> ProcessResult

    init(run: @escaping @Sendable (ProcessRequest) async throws -> ProcessResult) { self.run = run }
    init(runner: ProcessRunner) { self.init(run: { try await runner.run($0) }) }

    func validatePackageSignature(_ package: URL) async throws {
        try Task.checkCancellation()
        let result = try await run(request(executable: "/usr/sbin/pkgutil", arguments: ["--check-signature", package.path], package: package))
        try Task.checkCancellation()
        // Require the explicit trust verdict as well as a successful exit status.
        guard result.terminationStatus == 0, !result.standardOutputWasTruncated, !result.standardErrorWasTruncated,
              result.outputText.split(separator: "\n").contains(where: {
                  $0.trimmingCharacters(in: .whitespaces).hasPrefix("Status: signed by a certificate trusted by")
              })
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

    private func request(executable: String, arguments: [String], package: URL) -> ProcessRequest {
        ProcessRequest(executableURL: URL(filePath: executable), arguments: arguments, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"], currentDirectoryURL: package.deletingLastPathComponent(), timeout: .seconds(30), standardOutputLimit: 32_768, standardErrorLimit: 32_768)
    }
}
