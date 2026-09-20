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
        let start = ContinuousClock.now
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
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(2))
    }

    func testCleansUpDescendantThatOutlivesNormallyExitedParent() async throws {
        let script = try makeScript(
            "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; while :; do /bin/sleep 1; done' &\nexit 0\n"
        )
        defer { try? FileManager.default.removeItem(at: script) }
        let start = ContinuousClock.now

        let result = try await ProcessRunner().run(ProcessRequest(
            executableURL: script,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectoryURL: nil
        ))

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(2))
    }

    func testTimeoutTerminatesDescendantThatIgnoresTermAndKeepsPipeOpen() async throws {
        let script = try makeScript(
            "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; while :; do /bin/sleep 1; done' &\nwait\n"
        )
        defer { try? FileManager.default.removeItem(at: script) }
        let start = ContinuousClock.now

        do {
            _ = try await ProcessRunner().run(ProcessRequest(
                executableURL: script,
                arguments: [],
                environment: [
                    "PATH": "/usr/bin:/bin",
                ],
                currentDirectoryURL: nil,
                timeout: .milliseconds(500)
            ))
            XCTFail("Expected the process tree to time out")
        } catch let error as BridgeError {
            guard case .processTimedOut = error else {
                return XCTFail("Unexpected bridge error: \(error)")
            }
        }

        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(2))
    }

    func testTerminateAllStopsConcurrentProcessGroups() async throws {
        let script = try makeScript("#!/bin/sh\nsleep 10\n")
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = ProcessRunner()
        let start = ContinuousClock.now
        let tasks = (0..<3).map { _ in
            Task {
                try await runner.run(ProcessRequest(
                    executableURL: script,
                    arguments: [],
                    environment: ["PATH": "/usr/bin:/bin"],
                    currentDirectoryURL: nil
                ))
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        await runner.terminateAll()
        var results: [ProcessResult] = []
        for task in tasks {
            results.append(try await task.value)
        }

        XCTAssertTrue(results.allSatisfy { $0.terminationStatus != 0 })
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(2))
    }

    func testSpawnFailureDoesNotLeakPipeDescriptors() async throws {
        let runner = ProcessRunner()
        let descriptorCountBefore = try openDescriptorCount()

        for _ in 0..<20 {
            do {
                _ = try await runner.run(ProcessRequest(
                    executableURL: URL(filePath: "/path/that/does/not/exist"),
                    arguments: [],
                    environment: [:],
                    currentDirectoryURL: nil
                ))
                XCTFail("Expected spawn to fail")
            } catch {
                // Expected.
            }
        }

        XCTAssertEqual(try openDescriptorCount(), descriptorCountBefore)
    }

    private func makeScript(_ contents: String) throws -> URL {
        let script = FileManager.default.temporaryDirectory
            .appending(path: "cellar-process-runner-\(UUID().uuidString).sh")
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }
}
