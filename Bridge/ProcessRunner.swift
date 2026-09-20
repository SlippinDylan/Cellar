import Foundation

struct ProcessRequest: Sendable {
    static let defaultCaptureLimit = 8 * 1_024 * 1_024

    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectoryURL: URL?
    let timeout: Duration?
    let standardOutputLimit: Int
    let standardErrorLimit: Int

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        timeout: Duration? = nil,
        standardOutputLimit: Int = defaultCaptureLimit,
        standardErrorLimit: Int = defaultCaptureLimit
    ) {
        if let timeout {
            precondition(timeout > .zero)
        }
        precondition(standardOutputLimit >= 0)
        precondition(standardErrorLimit >= 0)

        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.standardOutputLimit = standardOutputLimit
        self.standardErrorLimit = standardErrorLimit
    }
}

struct ProcessResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
    let standardOutputWasTruncated: Bool
    let standardErrorWasTruncated: Bool

    var outputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var errorText: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

actor ProcessRunner {
    private struct CapturedOutput: Sendable {
        let data: Data
        let wasTruncated: Bool
    }

    private enum WaitOutcome: Sendable {
        case exited
        case timedOut
        case cancelled
    }

    private var runningProcesses: [UUID: Process] = [:]

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let identifier = UUID()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let terminationStream = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield(())
                continuation.finish()
            }
        }

        try process.run()
        try outputPipe.fileHandleForWriting.close()
        try errorPipe.fileHandleForWriting.close()
        runningProcesses[identifier] = process
        defer { runningProcesses[identifier] = nil }

        return try await withTaskCancellationHandler {
            async let output = Self.capture(
                outputPipe.fileHandleForReading,
                limit: request.standardOutputLimit
            )
            async let error = Self.capture(
                errorPipe.fileHandleForReading,
                limit: request.standardErrorLimit
            )
            let timedOut = await Self.waitForExitOrTerminateAfterTimeout(
                process,
                terminationStream: terminationStream,
                timeout: request.timeout
            )

            let (capturedOutput, capturedError) = try await (output, error)

            if timedOut {
                throw BridgeError.processTimedOut(request.executableURL.lastPathComponent)
            }

            try Task.checkCancellation()
            return ProcessResult(
                standardOutput: capturedOutput.data,
                standardError: capturedError.data,
                terminationStatus: process.terminationStatus,
                standardOutputWasTruncated: capturedOutput.wasTruncated,
                standardErrorWasTruncated: capturedError.wasTruncated
            )
        } onCancel: {
            Task { await self.terminate(identifier) }
        }
    }

    func terminateAll() {
        for process in runningProcesses.values where process.isRunning {
            process.terminate()
        }
    }

    private func terminate(_ identifier: UUID) {
        guard let process = runningProcesses[identifier], process.isRunning else { return }
        process.terminate()
    }

    private static func capture(_ fileHandle: FileHandle, limit: Int) async throws -> CapturedOutput {
        try await Task.detached {
            var captured = Data()
            var wasTruncated = false

            while let chunk = try fileHandle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                let remainingCapacity = limit - captured.count
                if remainingCapacity > 0 {
                    captured.append(chunk.prefix(remainingCapacity))
                }
                if chunk.count > remainingCapacity {
                    wasTruncated = true
                }
            }

            return CapturedOutput(data: captured, wasTruncated: wasTruncated)
        }.value
    }

    private static func waitForExitOrTerminateAfterTimeout(
        _ process: Process,
        terminationStream: AsyncStream<Void>,
        timeout: Duration?
    ) async -> Bool {
        guard let timeout else {
            await waitForExit(terminationStream)
            return false
        }

        return await withTaskGroup(of: WaitOutcome.self) { group in
            group.addTask {
                await waitForExit(terminationStream)
                return .exited
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            while let outcome = await group.next() {
                switch outcome {
                case .exited:
                    group.cancelAll()
                    return false
                case .timedOut:
                    if process.isRunning {
                        process.terminate()
                    }
                    group.cancelAll()
                    return true
                case .cancelled:
                    continue
                }
            }

            return false
        }
    }

    private static func waitForExit(_ terminationStream: AsyncStream<Void>) async {
        for await _ in terminationStream {
            return
        }
    }
}
