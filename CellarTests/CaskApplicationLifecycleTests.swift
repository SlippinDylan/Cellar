import Darwin
import Synchronization
import XCTest
@testable import Cellar

@MainActor
final class CaskApplicationLifecycleTests: XCTestCase {
    private let identity = CaskApplicationIdentity(bundleURL: URL(filePath: "/fixture/Applications/Sample.app"),
                                                   bundleIdentifier: "com.example.sample")

    func testAcceptedQuitWaitsForObservedTermination() async throws {
        let started = expectation(description: "Waiting for process termination")
        let application = FakeCaskApplication(identity: identity, behavior: .wait)
        application.onWait = { started.fulfill() }
        let lifecycle = CaskApplicationLifecycle.fixture { [application] }
        var finished = false
        let task = Task { try await lifecycle.quitApplications([identity]); finished = true }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(application.requestCount, 1)
        XCTAssertFalse(application.isTerminated)
        XCTAssertFalse(finished, "An accepted request does not mean that the application has exited")
        application.finishTermination()
        try await task.value
        XCTAssertTrue(finished)
    }

    func testRefusedQuitFailsWithoutWaitingOrClaimingTermination() async {
        let application = FakeCaskApplication(identity: identity, behavior: .refuse)
        let lifecycle = CaskApplicationLifecycle.fixture { [application] }
        do { try await lifecycle.quitApplications([identity]); XCTFail("A refused quit must prevent uninstall") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .terminationRefused(identity)) }
        XCTAssertEqual(application.requestCount, 1)
        XCTAssertEqual(application.waitCount, 0)
        XCTAssertFalse(application.isTerminated)
    }

    func testTimeoutLeavesApplicationRunning() async {
        let application = FakeCaskApplication(identity: identity, behavior: .wait)
        let lifecycle = CaskApplicationLifecycle.fixture(terminationTimeout: .zero) { [application] }
        do { try await lifecycle.quitApplications([identity]); XCTFail("A running process cannot pass its deadline") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .terminationTimedOut(identity)) }
        XCTAssertEqual(application.requestCount, 1)
        XCTAssertFalse(application.isTerminated)
    }

    func testDeadlineCancelsThePendingTerminationObservation() async {
        let application = FakeCaskApplication(identity: identity, behavior: .wait)
        let lifecycle = CaskApplicationLifecycle.fixture(terminationTimeout: .seconds(1)) { [application] }
        do { try await lifecycle.quitApplications([identity]); XCTFail("An unresponsive process must time out") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .terminationTimedOut(identity)) }
        XCTAssertEqual(application.waitCount, 1)
        XCTAssertTrue(application.finishedWaiting, "Timeout must also unwind the pending observer")
        XCTAssertFalse(application.isTerminated)
    }

    func testAnotherCopyWithTheSameBundleIdentifierIsNeverQuit() async throws {
        let root = try applicationLocationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let targetIdentity = CaskApplicationIdentity(bundleURL: root.appending(path: "Expected/Sample.app"), bundleIdentifier: identity.bundleIdentifier)
        let target = FakeCaskApplication(identity: targetIdentity, behavior: .finish)
        let sibling = FakeCaskApplication(identity: .init(bundleURL: root.appending(path: "Other/Sample.app"),
                                                         bundleIdentifier: identity.bundleIdentifier), behavior: .wait)
        let lifecycle = CaskApplicationLifecycle.fixture { [sibling, target] }
        try await lifecycle.quitApplications([targetIdentity])
        XCTAssertEqual(target.requestCount, 1)
        XCTAssertEqual(sibling.requestCount, 0)
        XCTAssertFalse(sibling.isTerminated)
    }

    func testDirectoryHintAndFinalSlashDoNotBypassQuitOrStoppedCheck() async throws {
        for url in [URL(fileURLWithPath: identity.bundleURL.path, isDirectory: true),
                    URL(filePath: identity.bundleURL.path + "/", directoryHint: .isDirectory)] {
            let application = FakeCaskApplication(identity: .init(bundleURL: url, bundleIdentifier: identity.bundleIdentifier),
                                                  behavior: .finish)
            let lifecycle = CaskApplicationLifecycle.fixture { [application] }
            XCTAssertThrowsError(try lifecycle.checkApplicationsAreStopped([identity])) { error in
                XCTAssertEqual(error as? CaskApplicationLifecycleError, .applicationStillRunning(self.identity))
            }
            try await lifecycle.quitApplications([identity])
            XCTAssertEqual(application.requestCount, 1)
            try lifecycle.checkApplicationsAreStopped([identity])
        }
    }

    func testCaseOnlyPathDifferenceRequiresTheSameFileIdentity() async throws {
        let root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarApplicationIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = root.appending(path: "Sample.app")
        let observed = root.appending(path: "SAMPLE.app")
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: false)
        // The fixture works on both kinds of APFS volume without assuming case sensitivity.
        let sameFile = CaskRemovalFileSystem.exists(observed.path)
        if !sameFile { try FileManager.default.createDirectory(at: observed, withIntermediateDirectories: false) }
        let expectedIdentity = CaskApplicationIdentity(bundleURL: expected, bundleIdentifier: identity.bundleIdentifier)
        let application = FakeCaskApplication(identity: .init(bundleURL: observed, bundleIdentifier: identity.bundleIdentifier),
                                              behavior: .finish)
        let lifecycle = CaskApplicationLifecycle.fixture { [application] }
        try await lifecycle.quitApplications([expectedIdentity])
        XCTAssertEqual(application.requestCount, sameFile ? 1 : 0)
        XCTAssertEqual(application.isTerminated, sameFile)
    }

    func testFirmlinkAliasesMatchTheSameInstallationWithoutTouchingRealApplications() async throws {
        let root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarFirmlinkLifecycle-\(UUID().uuidString)")
        let app = root.appending(path: "Sample.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = URL(filePath: "/System/Volumes/Data" + app.path)
        XCTAssertNotEqual(app.standardizedFileURL.path, alias.standardizedFileURL.path)
        XCTAssertEqual(try CaskRemovalFileSystem.fingerprint(app.path), try CaskRemovalFileSystem.fingerprint(alias.path))
        let target = CaskApplicationIdentity(bundleURL: alias, bundleIdentifier: identity.bundleIdentifier)
        let application = FakeCaskApplication(identity: .init(bundleURL: app, bundleIdentifier: identity.bundleIdentifier), behavior: .finish)
        let lifecycle = CaskApplicationLifecycle.fixture { [application] }
        XCTAssertThrowsError(try lifecycle.checkApplicationsAreStopped([target])) { error in
            XCTAssertEqual(error as? CaskApplicationLifecycleError, .applicationStillRunning(target))
        }
        try await lifecycle.quitApplications([target])
        XCTAssertEqual(application.requestCount, 1)
    }

    func testFirmlinkAliasRestartIsDetectedAfterApplicationBundleWasRemoved() async throws {
        let root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarRemovedFirmlink-\(UUID().uuidString)")
        let app = root.appending(path: "Sample.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = URL(filePath: "/System/Volumes/Data" + app.path)
        let target = CaskApplicationIdentity(bundleURL: alias, bundleIdentifier: identity.bundleIdentifier)
        let sibling = FakeCaskApplication(identity: .init(bundleURL: root.appending(path: "Other.app"), bundleIdentifier: identity.bundleIdentifier), behavior: .wait)
        try FileManager.default.removeItem(at: app)
        let runtime = FakeCaskApplicationRuntime(applications: [sibling])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        try lifecycle.checkApplicationsAreStopped([target])
        let started = expectation(description: "Cleanup guarded after bundle removal")
        let task = Task {
            try await lifecycle.withApplicationsStopped([target], onInvalidation: {}) {
                started.fulfill()
                let (events, _) = AsyncStream<Void>.makeStream()
                for await _ in events { }
                try Task.checkCancellation()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        runtime.applications = [FakeCaskApplication(identity: .init(bundleURL: app, bundleIdentifier: identity.bundleIdentifier), behavior: .wait)]
        do { try await task.value; XCTFail("An alias must still identify the target after its bundle was removed") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .applicationStillRunning(target)) }
        XCTAssertEqual(runtime.observerCount, 0)
        XCTAssertEqual(sibling.requestCount, 0)
    }

    func testFirmlinkAliasWithChangedBundleIdentifierFailsClosed() async throws {
        let root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarChangedFirmlink-\(UUID().uuidString)")
        let app = root.appending(path: "Sample.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = CaskApplicationIdentity(bundleURL: URL(filePath: "/System/Volumes/Data" + app.path), bundleIdentifier: identity.bundleIdentifier)
        let application = FakeCaskApplication(identity: .init(bundleURL: app, bundleIdentifier: "com.example.changed"), behavior: .finish)
        let lifecycle = CaskApplicationLifecycle.fixture { [application] }
        do { try await lifecycle.quitApplications([target]); XCTFail("A changed identity at the same physical location must fail closed") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .identityMismatch(target)) }
        XCTAssertEqual(application.requestCount, 0)
    }

    func testUnverifiableCaseAliasFailsClosedWithoutQuitting() async {
        let application = FakeCaskApplication(identity: .init(bundleURL: URL(filePath: "/fixture/Applications/SAMPLE.app"),
                                                              bundleIdentifier: identity.bundleIdentifier), behavior: .finish)
        let lifecycle = CaskApplicationLifecycle.fixture { [application] }
        do { try await lifecycle.quitApplications([identity]); XCTFail("An unverifiable alias must not bypass the guard") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .identityMismatch(identity)) }
        XCTAssertEqual(application.requestCount, 0)
    }

    func testSameURLWithDifferentOrMissingBundleIdentifierIsRejectedWithoutQuitting() async {
        for bundleID in [nil, "com.example.other"] {
            let application = FakeCaskApplication(identity: identity, behavior: .finish)
            application.bundleIdentifier = bundleID
            let lifecycle = CaskApplicationLifecycle.fixture { [application] }
            do { try await lifecycle.quitApplications([identity]); XCTFail("Changed process identity must fail closed") }
            catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .identityMismatch(identity)) }
            XCTAssertEqual(application.requestCount, 0)
        }
    }

    func testCancellationWhileWaitingDoesNotInventTermination() async {
        let started = expectation(description: "Termination observation started")
        let application = FakeCaskApplication(identity: identity, behavior: .wait)
        application.onWait = { started.fulfill() }
        let lifecycle = CaskApplicationLifecycle.fixture { [application] }
        let task = Task { try await lifecycle.quitApplications([identity]) }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(application.isTerminated)
        XCTAssertEqual(application.requestCount, 1)
    }

    func testAllMatchingInstancesReceiveQuitBeforeWaiting() async throws {
        let firstStarted = expectation(description: "First instance observed")
        let secondStarted = expectation(description: "Second instance observed")
        let first = FakeCaskApplication(identity: identity, behavior: .wait)
        let second = FakeCaskApplication(identity: identity, behavior: .wait)
        first.onWait = { firstStarted.fulfill() }
        second.onWait = { secondStarted.fulfill() }
        let lifecycle = CaskApplicationLifecycle.fixture { [first, second] }
        let task = Task { try await lifecycle.quitApplications([identity]) }
        await fulfillment(of: [firstStarted], timeout: 3)
        XCTAssertEqual(first.requestCount, 1)
        XCTAssertEqual(second.requestCount, 1)
        first.finishTermination()
        await fulfillment(of: [secondStarted], timeout: 3)
        second.finishTermination()
        try await task.value
    }

    func testRelaunchedInstanceIsRefusedWithoutASecondQuitRequest() async {
        let first = FakeCaskApplication(identity: identity, behavior: .finish)
        let relaunched = FakeCaskApplication(identity: identity, behavior: .wait)
        let runtime = FakeCaskApplicationRuntime(applications: [first])
        first.onRequest = { runtime.applications.append(relaunched) }
        let lifecycle = CaskApplicationLifecycle.fixture { runtime.applications }
        do { try await lifecycle.quitApplications([identity]); XCTFail("New instances were not part of the quit request") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .applicationStillRunning(identity)) }
        XCTAssertEqual(relaunched.requestCount, 0)
        XCTAssertFalse(relaunched.isTerminated)
    }

    func testStoppedCheckRejectsNewlyStartedApplicationsWithoutSendingQuit() throws {
        let runtime = FakeCaskApplicationRuntime(applications: [])
        let lifecycle = CaskApplicationLifecycle.fixture { runtime.applications }
        try lifecycle.checkApplicationsAreStopped([identity])
        let application = FakeCaskApplication(identity: identity, behavior: .wait)
        runtime.applications = [application]
        XCTAssertThrowsError(try lifecycle.checkApplicationsAreStopped([identity])) { error in
            XCTAssertEqual(error as? CaskApplicationLifecycleError, .applicationStillRunning(self.identity))
        }
        XCTAssertEqual(application.requestCount, 0)
    }

    func testRestartRevokesLeaseBeforeOperationCancellationAndWaitsForCleanup() async throws {
        let started = expectation(description: "Guarded operation started")
        let runtime = FakeCaskApplicationRuntime(applications: [])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        let leaseURL = FileManager.default.temporaryDirectory.appending(path: "CellarLifecycleLease-\(UUID().uuidString)")
        try Data("lease".utf8).write(to: leaseURL)
        defer { try? FileManager.default.removeItem(at: leaseURL) }
        let recorder = LifecycleGuardRecorder(leasePath: leaseURL.path)
        let task = Task {
            try await lifecycle.withApplicationsStopped([identity], onInvalidation: { recorder.invalidate() }) {
                defer { recorder.finishOperation() }
                started.fulfill()
                let (events, _) = AsyncStream<Void>.makeStream()
                for await _ in events { }
                try Task.checkCancellation()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        runtime.applications = [FakeCaskApplication(identity: identity, behavior: .wait)]
        do { try await task.value; XCTFail("Restart must cancel privileged cleanup") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .applicationStillRunning(identity)) }
        XCTAssertTrue(recorder.cleanupFinished)
        XCTAssertTrue(recorder.wasRevokedBeforeCleanup)
        XCTAssertEqual(runtime.observerCount, 0)
    }

    func testChangedBundleIdentityAlsoRevokesBeforeCancellation() async {
        let started = expectation(description: "Guarded operation started")
        let runtime = FakeCaskApplicationRuntime(applications: [])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        let recorder = LifecycleGuardRecorder()
        let task = Task {
            try await lifecycle.withApplicationsStopped([identity], onInvalidation: { recorder.invalidate() }) {
                defer { recorder.finishOperation() }
                started.fulfill()
                let (events, _) = AsyncStream<Void>.makeStream()
                for await _ in events { }
                try Task.checkCancellation()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        let changed = FakeCaskApplication(identity: identity, behavior: .wait)
        changed.bundleIdentifier = "com.example.changed"
        runtime.applications = [changed]
        do { try await task.value; XCTFail("Changed identity must stop cleanup") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .identityMismatch(identity)) }
        XCTAssertTrue(recorder.wasRevokedBeforeCleanup)
        XCTAssertEqual(runtime.observerCount, 0)
    }

    func testDifferentInstallationDoesNotInvalidateGuardAndObserverIsRemoved() async throws {
        let root = try applicationLocationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let targetIdentity = CaskApplicationIdentity(bundleURL: root.appending(path: "Expected/Sample.app"), bundleIdentifier: identity.bundleIdentifier)
        let runtime = FakeCaskApplicationRuntime(applications: [])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        let recorder = LifecycleGuardRecorder()
        let sibling = FakeCaskApplication(identity: .init(bundleURL: root.appending(path: "Other/Sample.app"),
                                                         bundleIdentifier: identity.bundleIdentifier), behavior: .wait)
        let value = try await lifecycle.withApplicationsStopped([targetIdentity], onInvalidation: { recorder.invalidate() }) {
            await MainActor.run { runtime.applications = [sibling] }
            await Task.yield()
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertFalse(recorder.invalidated)
        XCTAssertEqual(runtime.observerCount, 0)
    }

    func testCallerCancellationRevokesLeaseAndUnwindsOperation() async {
        let started = expectation(description: "Guarded operation started")
        let runtime = FakeCaskApplicationRuntime(applications: [])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        let recorder = LifecycleGuardRecorder()
        let task = Task {
            try await lifecycle.withApplicationsStopped([identity], onInvalidation: { recorder.invalidate() }) {
                defer { recorder.finishOperation() }
                started.fulfill()
                let (events, _) = AsyncStream<Void>.makeStream()
                for await _ in events { }
                try Task.checkCancellation()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Caller cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(recorder.wasRevokedBeforeCleanup)
        XCTAssertEqual(runtime.observerCount, 0)
    }

    func testInitialRunningApplicationPreventsOperationAndSubscribesBeforeSnapshot() async {
        let runtime = FakeCaskApplicationRuntime(applications: [FakeCaskApplication(identity: identity, behavior: .wait)])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        let recorder = LifecycleGuardRecorder()
        do {
            try await lifecycle.withApplicationsStopped([identity], onInvalidation: { recorder.invalidate() }) {
                recorder.finishOperation()
            }
            XCTFail("An initially running application must prevent operation")
        } catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .applicationStillRunning(identity)) }
        XCTAssertTrue(runtime.snapshotsHadObserver)
        XCTAssertTrue(recorder.invalidated)
        XCTAssertFalse(recorder.cleanupFinished)
        XCTAssertEqual(runtime.observerCount, 0)
    }

    func testBriefRestartSnapshotIsNotLostWhenProcessAlreadyExited() async {
        let started = expectation(description: "Guarded operation started")
        let runtime = FakeCaskApplicationRuntime(applications: [])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        let recorder = LifecycleGuardRecorder()
        let task = Task {
            try await lifecycle.withApplicationsStopped([identity], onInvalidation: { recorder.invalidate() }) {
                defer { recorder.finishOperation() }
                started.fulfill()
                let (events, _) = AsyncStream<Void>.makeStream()
                for await _ in events { }
                try Task.checkCancellation()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        runtime.applications = [FakeCaskApplication(identity: identity, behavior: .wait)]
        runtime.applications = []
        do { try await task.value; XCTFail("A brief restart must still invalidate cleanup") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .applicationStillRunning(identity)) }
        XCTAssertTrue(recorder.wasRevokedBeforeCleanup)
        XCTAssertEqual(runtime.observerCount, 0)
    }

    func testUnexpectedObservationEndRevokesLeaseBeforeCancellingOperation() async {
        let started = expectation(description: "Guarded operation started")
        let runtime = FakeCaskApplicationRuntime(applications: [])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        let recorder = LifecycleGuardRecorder()
        let task = Task {
            try await lifecycle.withApplicationsStopped([identity], onInvalidation: { recorder.invalidate() }) {
                defer { recorder.finishOperation() }
                started.fulfill()
                let (events, _) = AsyncStream<Void>.makeStream()
                for await _ in events { }
                try Task.checkCancellation()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        runtime.endObservation()
        do { try await task.value; XCTFail("Loss of observation must fail closed") }
        catch { guard case HomebrewClientError.stateChanged = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertTrue(recorder.wasRevokedBeforeCleanup)
        XCTAssertEqual(runtime.observerCount, 0)
    }

    func testRestartDuringRecursiveDeletionPreservesRemainingFilesAndTypedFailure() async throws {
        let checkpoint = expectation(description: "Recursive deletion has removed one child")
        let deletion = try ControlledRecursiveDeletion(checkpointReached: checkpoint)
        defer { deletion.removeFixture() }
        let runtime = FakeCaskApplicationRuntime(applications: [])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        let task = Task {
            try await lifecycle.withApplicationsStopped([identity], onInvalidation: {}) {
                try await deletion.run()
            }
        }
        await fulfillment(of: [checkpoint], timeout: 3)
        XCTAssertEqual(try deletion.remainingFiles().count, 2)
        runtime.applications = [FakeCaskApplication(identity: identity, behavior: .wait)]
        do { try await task.value; XCTFail("A restart must interrupt the active recursive deletion") }
        catch { XCTAssertEqual(error as? CaskApplicationLifecycleError, .applicationStillRunning(identity)) }
        XCTAssertEqual(try deletion.remainingFiles().count, 2, "Already deleted files stay deleted; later files must survive")
        XCTAssertTrue(deletion.cleanupFinished)
        XCTAssertEqual(runtime.observerCount, 0)
    }

    func testCallerCancellationDuringRecursiveDeletionPreservesRemainingFilesAndReleasesObserver() async throws {
        let checkpoint = expectation(description: "Recursive deletion has removed one child")
        let deletion = try ControlledRecursiveDeletion(checkpointReached: checkpoint)
        defer { deletion.removeFixture() }
        let runtime = FakeCaskApplicationRuntime(applications: [])
        let lifecycle = CaskApplicationLifecycle(runtime: runtime.runtime)
        let task = Task {
            try await lifecycle.withApplicationsStopped([identity], onInvalidation: {}) {
                try await deletion.run()
            }
        }
        await fulfillment(of: [checkpoint], timeout: 3)
        XCTAssertEqual(try deletion.remainingFiles().count, 2)
        task.cancel()
        do { try await task.value; XCTFail("Caller cancellation must interrupt recursive deletion") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try deletion.remainingFiles().count, 2)
        XCTAssertTrue(deletion.cleanupFinished)
        XCTAssertEqual(runtime.observerCount, 0)
    }

    private func applicationLocationFixture() throws -> URL {
        let root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarSeparateLocations-\(UUID().uuidString)")
        for name in ["Expected", "Other"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        return root
    }

    func testExplicitEmptyRuntimeNeverTouchesRealApplications() async throws {
        try await CaskApplicationLifecycle.noRunningApplications.quitApplications([identity])
        try CaskApplicationLifecycle.noRunningApplications.checkApplicationsAreStopped([identity])
    }
}

@MainActor
private final class FakeCaskApplicationRuntime {
    var applications: [any CaskRunningApplicationProcess] {
        didSet {
            let snapshot = applications.filter { !$0.isTerminated }.map {
                CaskRunningApplicationSnapshot(bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
            }
            for continuation in observers.values { continuation.yield(snapshot) }
        }
    }
    private var observers: [UUID: AsyncStream<[CaskRunningApplicationSnapshot]>.Continuation] = [:]
    private(set) var snapshotsHadObserver = true
    var observerCount: Int { observers.count }

    init(applications: [any CaskRunningApplicationProcess]) { self.applications = applications }

    var runtime: CaskApplicationRuntime {
        .init(snapshot: {
            self.snapshotsHadObserver = self.snapshotsHadObserver && !self.observers.isEmpty
            return self.applications
        }, observe: {
            let id = UUID()
            let (events, continuation) = AsyncStream<[CaskRunningApplicationSnapshot]>.makeStream()
            self.observers[id] = continuation
            return CaskApplicationObservation(events: events) {
                self.observers.removeValue(forKey: id)
                continuation.finish()
            }
        })
    }

    func endObservation() {
        for continuation in observers.values { continuation.finish() }
    }
}

private final class LifecycleGuardRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private var finished = false
    private var revokedBeforeCleanup = false
    private let leasePath: String?

    init(leasePath: String? = nil) { self.leasePath = leasePath }

    var invalidated: Bool { lock.withLock { revoked } }
    var cleanupFinished: Bool { lock.withLock { finished } }
    var wasRevokedBeforeCleanup: Bool { lock.withLock { revokedBeforeCleanup } }

    func invalidate() {
        lock.withLock {
            if let leasePath { _ = unlink(leasePath) }
            revoked = true
        }
    }
    func finishOperation() {
        lock.withLock {
            revokedBeforeCleanup = revoked && (leasePath.map { !FileManager.default.fileExists(atPath: $0) } ?? true)
            finished = true
        }
    }
}

@MainActor
private final class FakeCaskApplication: CaskRunningApplicationProcess {
    enum Behavior { case refuse, finish, wait }
    let bundleURL: URL?
    var bundleIdentifier: String?
    private(set) var isTerminated = false
    private(set) var requestCount = 0
    private(set) var waitCount = 0
    private(set) var finishedWaiting = false
    var onRequest: (() -> Void)?
    var onWait: (() -> Void)?
    private let behavior: Behavior
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(identity: CaskApplicationIdentity, behavior: Behavior) {
        bundleURL = identity.bundleURL
        bundleIdentifier = identity.bundleIdentifier
        self.behavior = behavior
        (events, continuation) = AsyncStream<Void>.makeStream()
    }

    func requestTermination() -> Bool {
        requestCount += 1
        onRequest?()
        switch behavior {
        case .refuse: return false
        case .finish: finishTermination(); return true
        case .wait: return true
        }
    }

    func finishTermination() {
        isTerminated = true
        continuation.yield(())
        continuation.finish()
    }

    func waitUntilTerminated() async throws {
        waitCount += 1
        defer { finishedWaiting = true }
        onWait?()
        if isTerminated { return }
        for await _ in events { break }
        try Task.checkCancellation()
    }
}

// Stops at a real recursive-deletion checkpoint after one unlink, without relying on file order or sleeps.
private final class ControlledRecursiveDeletion: Sendable {
    private struct State {
        var paused = false
        var cleanupFinished = false
    }

    private let root: URL
    private let directory: URL
    private let entry: CaskRemovalEntry
    private let checkpointReached: XCTestExpectation
    private let cancellation = DispatchSemaphore(value: 0)
    private let state = Mutex(State())

    init(checkpointReached: XCTestExpectation) throws {
        self.checkpointReached = checkpointReached
        root = CaskRemovalFileSystem.physicalURL(FileManager.default.temporaryDirectory)
            .appending(path: "CellarRecursiveLifecycle-\(UUID().uuidString)")
        let cache = root.appending(path: "Cache")
        directory = cache.appending(path: "Nested")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["first", "second", "third"] {
            try Data(name.utf8).write(to: directory.appending(path: name))
        }
        entry = CaskRemovalEntry(path: cache.path, category: .cache, estimatedBytes: nil, disposition: .remove,
                                 fingerprint: try CaskRemovalFileSystem.fingerprint(cache.path))
    }

    var cleanupFinished: Bool { state.withLock { $0.cleanupFinished } }

    func remainingFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            defer { state.withLock { $0.cleanupFinished = true } }
            try CaskRemovalFileSystem.remove(entry) {
                try Task.checkCancellation()
                let remaining = try self.remainingFiles().count
                let shouldPause = self.state.withLock { state in
                    guard remaining == 2, !state.paused else { return false }
                    state.paused = true
                    return true
                }
                if shouldPause {
                    self.checkpointReached.fulfill()
                    // Only actual operation cancellation releases the recursive delete. A test failure is bounded.
                    guard self.cancellation.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
                }
                try Task.checkCancellation()
            }
        } onCancel: {
            self.cancellation.signal()
        }
    }

    func removeFixture() { try? FileManager.default.removeItem(at: root) }
}
