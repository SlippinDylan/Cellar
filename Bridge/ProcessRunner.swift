import Darwin
import Foundation

struct ProcessRequest: Sendable {
    static let defaultCaptureLimit = 2 * 1_024 * 1_024

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

    private struct SpawnedProcess: Sendable {
        let processIdentifier: pid_t
        let standardOutput: FileHandle
        let standardError: FileHandle
        let terminationStream: AsyncStream<Void>
    }

    private enum WaitOutcome: Sendable {
        case exited
        case timedOut
        case cancelled
    }

    private var runningProcesses: [UUID: pid_t] = [:]

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let identifier = UUID()
        let process = try Self.spawn(request)
        runningProcesses[identifier] = process.processIdentifier
        defer { runningProcesses[identifier] = nil }

        return try await withTaskCancellationHandler {
            async let output = Self.capture(
                process.standardOutput,
                limit: request.standardOutputLimit
            )
            async let error = Self.capture(
                process.standardError,
                limit: request.standardErrorLimit
            )
            let timedOut = await Self.waitForExitOrTerminateAfterTimeout(
                process.processIdentifier,
                terminationStream: process.terminationStream,
                timeout: request.timeout
            )

            if !timedOut {
                await Self.terminateRemainingGroup(process.processIdentifier)
            }
            let capturedOutput: CapturedOutput
            let capturedError: CapturedOutput
            do {
                (capturedOutput, capturedError) = try await (output, error)
            } catch {
                await Self.terminateProcessGroup(process.processIdentifier)
                _ = Self.reap(process.processIdentifier)
                throw error
            }
            let terminationStatus = Self.reap(process.processIdentifier)

            if timedOut {
                throw BridgeError.processTimedOut(request.executableURL.lastPathComponent)
            }

            try Task.checkCancellation()
            return ProcessResult(
                standardOutput: capturedOutput.data,
                standardError: capturedError.data,
                terminationStatus: terminationStatus,
                standardOutputWasTruncated: capturedOutput.wasTruncated,
                standardErrorWasTruncated: capturedError.wasTruncated
            )
        } onCancel: {
            Task { await self.terminate(identifier) }
        }
    }

    func terminateAll() async {
        let processIdentifiers = Array(runningProcesses.values)
        await withTaskGroup(of: Void.self) { group in
            for processIdentifier in processIdentifiers {
                group.addTask {
                    await Self.terminateProcessGroup(processIdentifier)
                }
            }
        }
    }

    private func terminate(_ identifier: UUID) async {
        guard let processIdentifier = runningProcesses[identifier] else { return }
        await Self.terminateProcessGroup(processIdentifier)
    }

    private static func spawn(_ request: ProcessRequest) throws -> SpawnedProcess {
        var outputDescriptors = [Int32](repeating: -1, count: 2)
        var errorDescriptors = [Int32](repeating: -1, count: 2)
        guard outputDescriptors.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
            throw posixError(errno)
        }
        guard errorDescriptors.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
            closeDescriptors(outputDescriptors)
            throw posixError(errno)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var processIdentifier: pid_t = 0
        let executablePath = request.executableURL.path

        do {
            try check(posix_spawn_file_actions_init(&fileActions))
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }

            try check(posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            ))
            try check(posix_spawn_file_actions_adddup2(&fileActions, outputDescriptors[1], STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&fileActions, errorDescriptors[1], STDERR_FILENO))
            try check(posix_spawn_file_actions_addclose(&fileActions, outputDescriptors[0]))
            try check(posix_spawn_file_actions_addclose(&fileActions, errorDescriptors[0]))
            try check(posix_spawn_file_actions_addclose(&fileActions, outputDescriptors[1]))
            try check(posix_spawn_file_actions_addclose(&fileActions, errorDescriptors[1]))
            if let currentDirectoryURL = request.currentDirectoryURL {
                try check(posix_spawn_file_actions_addchdir(&fileActions, currentDirectoryURL.path))
            }

            try check(posix_spawnattr_setpgroup(&attributes, 0))
            let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            try check(posix_spawnattr_setflags(&attributes, flags))

            let arguments = [executablePath] + request.arguments
            let environment = request.environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
            let spawnResult = try withCStringArray(arguments) { argumentPointers in
                try withCStringArray(environment) { environmentPointers in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
            try check(spawnResult)
        } catch {
            closeDescriptors(outputDescriptors)
            closeDescriptors(errorDescriptors)
            throw error
        }

        Darwin.close(outputDescriptors[1])
        Darwin.close(errorDescriptors[1])
        return SpawnedProcess(
            processIdentifier: processIdentifier,
            standardOutput: FileHandle(fileDescriptor: outputDescriptors[0], closeOnDealloc: true),
            standardError: FileHandle(fileDescriptor: errorDescriptors[0], closeOnDealloc: true),
            terminationStream: terminationStream(for: processIdentifier)
        )
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> Result
    ) throws -> Result {
        var pointers = strings.map { strdup($0) }
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        guard pointers.allSatisfy({ $0 != nil }) else {
            throw posixError(ENOMEM)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress)
        }
    }

    private static func terminationStream(for processIdentifier: pid_t) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let source = DispatchSource.makeProcessSource(
                identifier: processIdentifier,
                eventMask: .exit,
                queue: .global(qos: .utility)
            )
            source.setEventHandler {
                continuation.yield(())
                continuation.finish()
                source.cancel()
            }
            source.activate()
        }
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
        _ processIdentifier: pid_t,
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
                    await terminateProcessGroup(processIdentifier)
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

    private static func terminateRemainingGroup(_ processIdentifier: pid_t) async {
        guard !processGroupMembers(processIdentifier).filter({ $0 != processIdentifier }).isEmpty else {
            return
        }
        await terminateProcessGroup(processIdentifier)
    }

    private static func terminateProcessGroup(_ processIdentifier: pid_t) async {
        guard processIdentifier > 1 else { return }
        _ = Darwin.kill(-processIdentifier, SIGTERM)
        try? await Task.sleep(for: .milliseconds(500))
        if !processGroupMembers(processIdentifier).isEmpty {
            _ = Darwin.kill(-processIdentifier, SIGKILL)
        }
    }

    private static func processGroupMembers(_ processGroupIdentifier: pid_t) -> [pid_t] {
        var capacity = 16
        while capacity <= 4_096 {
            var processIdentifiers = [pid_t](repeating: 0, count: capacity)
            let count = processIdentifiers.withUnsafeMutableBytes { buffer in
                proc_listpgrppids(processGroupIdentifier, buffer.baseAddress, Int32(buffer.count))
            }
            guard count > 0 else { return [] }
            if count < capacity {
                return Array(processIdentifiers.prefix(Int(count))).filter { $0 > 1 }
            }
            if capacity == 4_096 {
                return processIdentifiers.filter { $0 > 1 }
            }
            capacity *= 2
        }
        return []
    }

    private static func reap(_ processIdentifier: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(processIdentifier, &status, 0) == -1 {
            guard errno == EINTR else { return -1 }
        }
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + (status & 0x7f)
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else { throw posixError(result) }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }
}
