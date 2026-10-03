import Foundation

enum CommandLineToolsError: Error { case invalidResponse; case installationRequestFailed }

struct CommandLineToolsService: Sendable {
    private let run: @Sendable (ProcessRequest) async throws -> ProcessResult
    private let workingDirectory: URL

    init(workingDirectory: URL, run: @escaping @Sendable (ProcessRequest) async throws -> ProcessResult) {
        self.workingDirectory = workingDirectory
        self.run = run
    }

    init(runner: ProcessRunner, workingDirectory: URL = FileManager.default.temporaryDirectory) {
        self.init(workingDirectory: workingDirectory, run: { try await runner.run($0) })
    }

    func state() async throws -> CommandLineToolsState {
        try Task.checkCancellation()
        let result = try await run(request(["--print-path"]))
        try Task.checkCancellation()
        guard !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else { throw CommandLineToolsError.invalidResponse }
        if result.terminationStatus != 0 { return .notInstalled }
        let path = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\n") else { throw CommandLineToolsError.invalidResponse }
        return .installed(developerDirectory: path)
    }

    func requestInstallation() async throws {
        try Task.checkCancellation()
        let result = try await run(request(["--install"]))
        try Task.checkCancellation()
        guard result.terminationStatus == 0, !result.standardOutputWasTruncated, !result.standardErrorWasTruncated else { throw CommandLineToolsError.installationRequestFailed }
    }

    private func request(_ arguments: [String]) -> ProcessRequest {
        ProcessRequest(executableURL: URL(filePath: "/usr/bin/xcode-select"), arguments: arguments, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"], currentDirectoryURL: workingDirectory, timeout: .seconds(15), standardOutputLimit: 8_192, standardErrorLimit: 8_192)
    }
}
