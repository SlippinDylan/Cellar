import XCTest
@testable import Cellar

final class ProcessRunnerTests: XCTestCase {
    func testKeepsStandardOutputAndErrorSeparate() async throws {
        let script = FileManager.default.temporaryDirectory
            .appending(path: "cellar-process-runner-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\nprintf output\nprintf error >&2\nexit 7\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let runner = ProcessRunner()
        let result = try await runner.run(ProcessRequest(
            executableURL: script,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: nil
        ))

        XCTAssertEqual(result.outputText, "output")
        XCTAssertEqual(result.errorText, "error")
        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertFalse(result.standardOutputWasTruncated)
        XCTAssertFalse(result.standardErrorWasTruncated)
    }

    func testBoundsEachCapturedStreamAndContinuesDraining() async throws {
        let script = try makeScript(
            "#!/bin/sh\ni=0\nwhile [ $i -lt 10000 ]; do\n  printf 1234567890\n  printf abcdefghij >&2\n  i=$((i + 1))\ndone\n"
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let result = try await ProcessRunner().run(ProcessRequest(
            executableURL: script,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: nil,
            standardOutputLimit: 4,
            standardErrorLimit: 6
        ))

        XCTAssertEqual(result.outputText, "1234")
        XCTAssertEqual(result.errorText, "abcdef")
        XCTAssertTrue(result.standardOutputWasTruncated)
        XCTAssertTrue(result.standardErrorWasTruncated)
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testTerminatesProcessAndThrowsWhenTimeoutExpires() async throws {
        let script = try makeScript("#!/bin/sh\nsleep 10\n")
        defer { try? FileManager.default.removeItem(at: script) }

        do {
            _ = try await ProcessRunner().run(ProcessRequest(
                executableURL: script,
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: nil,
                timeout: .milliseconds(100)
            ))
            XCTFail("Expected the process to time out")
        } catch let error as BridgeError {
            guard case .processTimedOut(let executable) = error else {
                return XCTFail("Unexpected bridge error: \(error)")
            }
            XCTAssertEqual(executable, script.lastPathComponent)
        }
    }

    func testCancellationTerminatesProcessAndThrowsCancellation() async throws {
        let script = try makeScript("#!/bin/sh\nsleep 10\n")
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = ProcessRunner()
        let task = Task {
            try await runner.run(ProcessRequest(
                executableURL: script,
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                currentDirectoryURL: nil
            ))
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func makeScript(_ contents: String) throws -> URL {
        let script = FileManager.default.temporaryDirectory
            .appending(path: "cellar-process-runner-\(UUID().uuidString).sh")
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
