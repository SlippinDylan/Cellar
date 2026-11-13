import AppKit
import Foundation

enum CaskApplicationLifecycleError: LocalizedError, Equatable {
    case identityMismatch(CaskApplicationIdentity)
    case terminationRefused(CaskApplicationIdentity)
    case terminationTimedOut(CaskApplicationIdentity)
    case applicationStillRunning(CaskApplicationIdentity)

    var errorDescription: String? {
        switch self {
        case .identityMismatch: HomebrewClientError.stateChanged.localizedDescription
        case .terminationRefused, .terminationTimedOut, .applicationStillRunning:
            String(localized: "The application is still running. Quit it, then review the uninstallation again.")
        }
    }
}

@MainActor
protocol CaskRunningApplicationProcess: AnyObject, Sendable {
    var bundleURL: URL? { get }
    var bundleIdentifier: String? { get }
    var isTerminated: Bool { get }
    func requestTermination() -> Bool
    func waitUntilTerminated() async throws
}

struct CaskRunningApplicationSnapshot: Sendable {
    let bundleURL: URL?
    let bundleIdentifier: String?
}

@MainActor
final class CaskApplicationObservation {
    let events: AsyncStream<[CaskRunningApplicationSnapshot]>
    private let stop: () -> Void

    init(events: AsyncStream<[CaskRunningApplicationSnapshot]>, stop: @escaping () -> Void) {
        self.events = events
        self.stop = stop
    }

    func cancel() { stop() }
}

struct CaskApplicationRuntime: Sendable {
    let snapshot: @MainActor @Sendable () -> [any CaskRunningApplicationProcess]
    let observe: @MainActor @Sendable () -> CaskApplicationObservation

    static let live = CaskApplicationRuntime(snapshot: {
        NSWorkspace.shared.runningApplications.map { SystemCaskApplicationProcess(application: $0) }
    }, observe: {
        let workspace = NSWorkspace.shared
        let (events, continuation) = AsyncStream<[CaskRunningApplicationSnapshot]>.makeStream()
        // Keep event snapshots, not only wakeups: a short-lived restart must not disappear before inspection.
        let observation = workspace.observe(\.runningApplications, options: [.new]) { workspace, _ in
            continuation.yield(workspace.runningApplications.filter { !$0.isTerminated }.map {
                CaskRunningApplicationSnapshot(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
            })
        }
        return CaskApplicationObservation(events: events) {
            observation.invalidate()
            continuation.finish()
        }
    })
}

struct CaskApplicationLifecycle: Sendable {
    private let runtime: CaskApplicationRuntime
    private let terminationTimeout: Duration

    static let live = CaskApplicationLifecycle(runtime: .live)

    // An explicit injectable runtime for isolated tests, never an implicit production bypass.
    static let noRunningApplications = fixture { [] }

    init(runtime: CaskApplicationRuntime, terminationTimeout: Duration = .seconds(30)) {
        self.terminationTimeout = terminationTimeout
        self.runtime = runtime
    }

    static func fixture(terminationTimeout: Duration = .seconds(30),
                        runningApplications: @escaping @MainActor @Sendable () -> [any CaskRunningApplicationProcess]) -> Self {
        Self(runtime: .init(snapshot: runningApplications, observe: {
            let (events, continuation) = AsyncStream<[CaskRunningApplicationSnapshot]>.makeStream()
            return CaskApplicationObservation(events: events) { continuation.finish() }
        }), terminationTimeout: terminationTimeout)
    }

    @MainActor
    func quitApplications(_ identities: [CaskApplicationIdentity]) async throws {
        try Task.checkCancellation()
        let applications = try matchingApplications(identities)
        let deadline = ContinuousClock.now.advanced(by: terminationTimeout)
        // Capture instances once: a relaunched application is not the instance the user agreed to quit.
        for (application, identity) in applications {
            try Task.checkCancellation()
            if !application.isTerminated && !application.requestTermination() && !application.isTerminated {
                throw CaskApplicationLifecycleError.terminationRefused(identity)
            }
        }
        for (application, identity) in applications where !application.isTerminated {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw CaskApplicationLifecycleError.terminationTimedOut(identity) }
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask { try await application.waitUntilTerminated() }
                tasks.addTask {
                    try await Task.sleep(for: remaining)
                    throw CaskApplicationLifecycleError.terminationTimedOut(identity)
                }
                defer { tasks.cancelAll() }
                _ = try await tasks.next()
            }
        }
        try checkApplicationsAreStopped(identities)
    }

    @MainActor
    func checkApplicationsAreStopped(_ identities: [CaskApplicationIdentity]) throws {
        try Task.checkCancellation()
        if let (_, identity) = try matchingApplications(identities).first {
            throw CaskApplicationLifecycleError.applicationStillRunning(identity)
        }
    }

    @MainActor
    func withApplicationsStopped<Value: Sendable>(
        _ identities: [CaskApplicationIdentity],
        onInvalidation: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        // Subscribe before the initial snapshot so a launch between checking and starting cannot be lost.
        let observation = runtime.observe()
        let events = observation.events
        defer { observation.cancel() }
        do {
            try checkApplicationsAreStopped(identities)
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Value.self) { tasks in
                    tasks.addTask { try await operation() }
                    tasks.addTask {
                        try await monitorApplications(identities, events: events,
                                                      onInvalidation: onInvalidation, returning: Value.self)
                    }
                    defer { tasks.cancelAll() }
                    do {
                        guard let value = try await tasks.next() else {
                            preconditionFailure("The guarded operation or its observer must complete")
                        }
                        try checkApplicationsAreStopped(identities)
                        return value
                    } catch {
                        // The final snapshot and operation failure must also revoke before cancellation.
                        onInvalidation()
                        throw error
                    }
                }
            } onCancel: {
                onInvalidation()
            }
        } catch {
            onInvalidation()
            throw error
        }
    }

    private func monitorApplications<Value: Sendable>(
        _ identities: [CaskApplicationIdentity],
        events: AsyncStream<[CaskRunningApplicationSnapshot]>,
        onInvalidation: @escaping @Sendable () -> Void,
        returning: Value.Type
    ) async throws -> Value {
        do {
            for await applications in events {
                try Task.checkCancellation()
                for application in applications {
                    if let identity = try matchingIdentity(application, identities: identities) {
                        throw CaskApplicationLifecycleError.applicationStillRunning(identity)
                    }
                }
            }
            try Task.checkCancellation()
            throw HomebrewClientError.stateChanged
        } catch is CancellationError {
            // Cancelling the observer after a successful operation is normal teardown.
            throw CancellationError()
        } catch {
            // Revoke the privileged lease before the parent cancels the command task.
            onInvalidation()
            throw error
        }
    }

    @MainActor
    private func matchingApplications(_ identities: [CaskApplicationIdentity]) throws
        -> [(any CaskRunningApplicationProcess, CaskApplicationIdentity)] {
        var matches: [(any CaskRunningApplicationProcess, CaskApplicationIdentity)] = []
        for application in runtime.snapshot() where !application.isTerminated {
            guard let identity = try matchingIdentity(.init(bundleURL: application.bundleURL,
                                                           bundleIdentifier: application.bundleIdentifier), identities: identities) else { continue }
            matches.append((application, identity))
        }
        return matches
    }

    private func matchingIdentity(_ application: CaskRunningApplicationSnapshot,
                                  identities: [CaskApplicationIdentity]) throws -> CaskApplicationIdentity? {
        guard let url = application.bundleURL,
              let identity = try identities.first(where: { try sameApplicationLocation($0, url: url, matchingBundleIdentifier: application.bundleIdentifier == $0.bundleIdentifier) }) else { return nil }
        guard application.bundleIdentifier == identity.bundleIdentifier else {
            throw CaskApplicationLifecycleError.identityMismatch(identity)
        }
        return identity
    }

    private func sameApplicationLocation(_ identity: CaskApplicationIdentity, url: URL, matchingBundleIdentifier: Bool) throws -> Bool {
        let expected = identity.bundleURL.standardizedFileURL.path
        let observed = url.standardizedFileURL.path
        // File URLs can differ only in their directory hint or final slash while naming the same path.
        if expected == observed { return true }
        guard identity.bundleURL.lastPathComponent.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame else { return false }
        do {
            return try CaskApplicationFileIdentity.sameLocation(identity.bundleURL, url)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // An unreadable same-ID candidate or case alias cannot establish that the target stopped.
            if matchingBundleIdentifier || expected.caseInsensitiveCompare(observed) == .orderedSame {
                throw CaskApplicationLifecycleError.identityMismatch(identity)
            }
            return false
        }
    }
}

@MainActor
private final class SystemCaskApplicationProcess: CaskRunningApplicationProcess {
    private let application: NSRunningApplication

    init(application: NSRunningApplication) { self.application = application }

    var bundleURL: URL? { application.bundleURL }
    var bundleIdentifier: String? { application.bundleIdentifier }
    var isTerminated: Bool { application.isTerminated }
    func requestTermination() -> Bool { application.terminate() }

    func waitUntilTerminated() async throws {
        try Task.checkCancellation()
        let (events, continuation) = AsyncStream<Void>.makeStream()
        // KVO covers background and LSUIElement apps, unlike workspace termination notifications.
        let observation = application.observe(\.isTerminated, options: [.initial, .new]) { application, _ in
            if application.isTerminated {
                continuation.yield(())
                continuation.finish()
            }
        }
        defer {
            observation.invalidate()
            continuation.finish()
        }
        for await _ in events { break }
        try Task.checkCancellation()
    }
}
