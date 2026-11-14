import Darwin
import XCTest
@testable import Cellar

final class ShellManagerClientTests: XCTestCase {
    @MainActor
    func testRealAdapterTidyNonzeroPreservesMovedFilesAndSharedPartialEvidence() async throws {
        for failFirst in [false, true] {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            let completion = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
            let backup = fixture.homeDirectory.appending(path: ".zshrc.backup-fixture")
            try Data("completion".utf8).write(to: completion)
            try Data("historical".utf8).write(to: backup)
            let original = try Data(contentsOf: fixture.zshrcURL)
            try fixture.injectAdapterFunctions("""
            mv() {
                if [ "$1" = "$HOME/\(failFirst ? ".zcompdump-fixture" : ".zshrc.backup-fixture")" ]; then return 77; fi
                /bin/mv "$@"
            }
            """)
            let store = ActivityStore()
            let model = fixture.model(activityStore: store)
            await model.prepareShellAction(.init(action: .tidy, subject: "zsh-files"))
            let plan = try XCTUnwrap(model.shellPlan)
            await model.executeShellPlan(confirmed: plan)
            let result = try XCTUnwrap(model.shellActionResult)
            XCTAssertEqual(result.operation.status, "failed")
            XCTAssertEqual(result.operation.exitCode, 1)
            XCTAssertFalse(result.operation.operationId.isEmpty)
            XCTAssertFalse(result.operation.logFile.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.operation.logFile))
            XCTAssertEqual(result.executionOutcome, failFirst ? .failed : .partiallySucceeded)
            XCTAssertEqual(store.summaries.first?.status, failFirst ? .failed : .partiallySucceeded)
            XCTAssertEqual(store.summaries.first?.itemOutcomes.first?.status, failFirst ? .failed : .partiallySucceeded)
            XCTAssertEqual(FileManager.default.fileExists(atPath: completion.path), failFirst)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/.zcompdump-fixture").path), !failFirst)
            XCTAssertEqual(try Data(contentsOf: backup), Data("historical".utf8))
            XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
            XCTAssertNotNil(model.shellOperationError)
            let diagnostics = try XCTUnwrap(model.activityDiagnostics.records.first)
            XCTAssertTrue(diagnostics.detail.contains(result.operation.logFile))
            let summaryJSON = String(decoding: try JSONEncoder().encode(store.summaries), as: UTF8.self)
            XCTAssertFalse(summaryJSON.contains(fixture.root.path))
            XCTAssertFalse(summaryJSON.contains(result.operation.operationId))
            XCTAssertFalse(model.operationStore.hasActiveOperations)
        }
    }

    @MainActor
    func testRealAdapterConfigurationFailureKeepsPreviousStepAndActualBackup() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        try fixture.injectAdapterFunctions("""
        original_switch_theme=$(declare -f switch_theme)
        eval "${original_switch_theme/switch_theme/fixture_switch_theme}"
        switch_theme() { fixture_switch_theme "$@" || return; return 73; }
        """)
        let plan = try await fixture.client.planConfiguration(plugins: ["git", "example"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
        let store = ActivityStore()
        let model = fixture.model(activityStore: store)
        model.terminalConfigurationPlan = plan
        await model.executeTerminalConfiguration(plan)
        let result = try XCTUnwrap(model.terminalConfigurationResult)
        XCTAssertEqual(store.summaries.first?.status, .partiallySucceeded)
        XCTAssertEqual(store.summaries.first?.itemOutcomes.map(\.status), [.succeeded, .partiallySucceeded])
        XCTAssertEqual(result.status, .partiallySucceeded)
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.operations.count, 2)
        XCTAssertEqual(result.stepOutcomes.map(\.status), [.succeeded, .partiallySucceeded])
        let failure = try XCTUnwrap(result.operations.last)
        XCTAssertEqual(failure.status, "failed")
        XCTAssertEqual(failure.exitCode, 73)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failure.logFile))
        XCTAssertFalse(failure.backupPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failure.backupPath))
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), plan.expectedContents.last)
    }

    func testMalformedOrMismatchedShellFailureCannotBecomeExecutionEvidence() async throws {
        let errors = [
            "{\"code\":\"action-failed\",\"operationId\":\"id\",\"action\":\"tidy\",\"subject\":\"zsh-files\",\"status\":\"failed\",\"exitCode\":1,\"logFile\":\"log\"}",
            "{\"code\":\"action-failed\",\"operationId\":\"id\",\"action\":\"switch-theme\",\"subject\":\"zsh-files\",\"status\":\"failed\",\"exitCode\":1,\"logFile\":\"log\",\"backupPath\":\"\"}",
            "{\"code\":\"action-failed\",\"operationId\":\"id\",\"action\":\"tidy\",\"subject\":\"wrong\",\"status\":\"failed\",\"exitCode\":1,\"logFile\":\"log\",\"backupPath\":\"\"}",
            "{\"code\":\"action-failed\",\"operationId\":\"id\",\"action\":\"tidy\",\"subject\":\"zsh-files\",\"status\":\"failed\",\"exitCode\":0,\"logFile\":\"log\",\"backupPath\":\"\"}"
        ]
        for payload in errors {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            try fixture.injectAdapterFunctions("run_zsh_tidy_flow() { return 1; }\noperation_error_json() { printf '%s' '\(payload)'; }")
            let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
            do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory); XCTFail("Invalid evidence must throw") }
            catch is ShellExecutionFailure { XCTFail("Invalid evidence must never be recovered") }
            catch BridgeError.invalidOutput { }
        }
    }

    func testRealAdapterPreflightRefusalHasNoExecutionEvidence() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        try fixture.injectAdapterFunctions("require_fresh_plan() { return 1; }")
        let original = try Data(contentsOf: fixture.zshrcURL)
        let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory); XCTFail("Preflight must refuse") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-stale") }
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.managerDirectory.appending(path: ".runtime/logs").path))
    }

    @MainActor
    func testRealAdapterTimeoutAfterMoveKeepsObservedPartialWithoutInventingExecutionFields() async throws {
        let fixture = try ShellManagerFixture(executionTimeout: .seconds(2))
        defer { fixture.remove() }
        let completion = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
        try Data("completion".utf8).write(to: completion)
        let block = fixture.root.appending(path: "blocked-move")
        XCTAssertEqual(mkfifo(block.path, 0o600), 0)
        try fixture.injectAdapterFunctions("""
        mv() {
            /bin/mv "$@" || return
            if [ "$1" = "$HOME/.zcompdump-fixture" ]; then read -r fixture_input < '\(block.path)'; fi
        }
        """)
        let store = ActivityStore()
        let model = fixture.model(activityStore: store)
        await model.prepareShellAction(.init(action: .tidy, subject: "zsh-files"))
        await model.executeShellPlan(confirmed: try XCTUnwrap(model.shellPlan))
        XCTAssertNil(model.shellActionResult)
        XCTAssertEqual(store.summaries.first?.status, .partiallySucceeded)
        XCTAssertEqual(store.summaries.first?.itemOutcomes.first?.status, .partiallySucceeded)
        XCTAssertNotNil(model.shellOperationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completion.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/.zcompdump-fixture").path))
        XCTAssertFalse(model.operationStore.hasActiveOperations)
    }

    func testTidyFailureWithUnverifiableDestinationStaysUnknown() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let completion = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
        try Data("completion".utf8).write(to: completion)
        try fixture.injectAdapterFunctions("""
        mv() {
            /bin/mv "$@" || return
            /bin/mv "$HOME/.zsh" "$HOME/moved-zsh"
            /bin/ln -s "$HOME/moved-zsh" "$HOME/.zsh"
            return 77
        }
        """)
        let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory); XCTFail("Failure must retain unknown verification") }
        catch let failure as ShellExecutionFailure {
            XCTAssertEqual(failure.outcome, .unknown)
            XCTAssertNotNil(failure.verificationError)
            XCTAssertEqual(failure.operation?.exitCode, 1)
            XCTAssertTrue(failure.movedPaths.isEmpty)
        }
    }

    func testInstallFailuresKeepEvidenceWithoutTreatingDirectoriesOrBackupsAsCompletion() async throws {
        for action in [ShellAction.installOhMyZsh, .switchTheme, .installPlugin] {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            let subject: String
            let functions: String
            switch action {
            case .installOhMyZsh:
                try FileManager.default.removeItem(at: fixture.homeDirectory.appending(path: ".oh-my-zsh"))
                subject = ""
                functions = "install_omz_once() { /bin/mkdir -p \"$HOME/.oh-my-zsh\"; return 72; }"
            case .switchTheme:
                subject = "agnoster"
                functions = "switch_theme() { backup_zshrc || return; return 72; }"
            case .installPlugin:
                subject = "https://github.com/fixture/newplugin"
                functions = "install_plugin_once() { /bin/mkdir \"$SHELL_MANAGER_PLUGIN_STAGING/repository\"; return 72; }"
            default: return XCTFail("Unexpected fixture action")
            }
            try fixture.injectAdapterFunctions(functions)
            let plan = try await fixture.client.plan(.init(action: action, subject: subject), managerDirectory: fixture.managerDirectory)
            do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory); XCTFail("Execution must fail") }
            catch let failure as ShellExecutionFailure {
                XCTAssertEqual(failure.operation?.exitCode, 72)
                XCTAssertEqual(failure.outcome, action == .installOhMyZsh ? .unknown : .failed)
                let operation = try XCTUnwrap(failure.operation)
                XCTAssertTrue(FileManager.default.fileExists(atPath: operation.logFile))
                if action == .switchTheme {
                    XCTAssertFalse(operation.backupPath.isEmpty)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: operation.backupPath))
                }
                if action == .installPlugin {
                    let parent = fixture.homeDirectory.appending(path: ".oh-my-zsh/custom/plugins")
                    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".cellar-plugin-") })
                    XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appending(path: "newplugin").path))
                }
            }
        }
    }

    @MainActor
    func testRealAdapterCancellationAfterMoveKeepsObservedPartialAndReapsProcess() async throws {
        let fixture = try ShellManagerFixture(executionTimeout: .seconds(5))
        defer { fixture.remove() }
        let completion = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
        try Data("completion".utf8).write(to: completion)
        let block = fixture.root.appending(path: "block")
        let notification = fixture.root.appending(path: "started")
        let pidFile = fixture.root.appending(path: "worker.pid")
        try Data().write(to: notification)
        XCTAssertEqual(mkfifo(block.path, 0o600), 0)
        let descriptor = open(notification.path, O_EVTONLY | O_CLOEXEC)
        let queue = kqueue()
        defer { close(descriptor); close(queue) }
        var registration = kevent()
        registration.ident = UInt(descriptor)
        registration.filter = Int16(EVFILT_VNODE)
        registration.flags = UInt16(EV_ADD | EV_ONESHOT)
        registration.fflags = UInt32(NOTE_WRITE | NOTE_EXTEND)
        XCTAssertEqual(kevent(queue, &registration, 1, nil, 0, nil), 0)
        try fixture.injectAdapterFunctions("""
        mv() {
            /bin/mv "$@" || return
            printf '%s' "$$" > '\(pidFile.path)'
            printf ready >> '\(notification.path)'
            read -r fixture_input < '\(block.path)'
        }
        """)
        let store = ActivityStore()
        let model = fixture.model(activityStore: store)
        await model.prepareShellAction(.init(action: .tidy, subject: "zsh-files"))
        let plan = try XCTUnwrap(model.shellPlan)
        let owner = Task { await model.executeShellPlan(confirmed: plan) }
        let ready = await Task.detached {
            var event = kevent()
            var deadline = timespec(tv_sec: 3, tv_nsec: 0)
            return kevent(queue, nil, 0, &event, 1, &deadline) == 1
        }.value
        XCTAssertTrue(ready)
        XCTAssertTrue(model.operationStore.hasActiveOperations)
        owner.cancel()
        await owner.value
        XCTAssertEqual(store.summaries.first?.status, .partiallySucceeded)
        XCTAssertEqual(store.summaries.first?.reason, .cancelledByUser)
        XCTAssertNil(model.shellActionResult)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/.zcompdump-fixture").path))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testSuccessfulAdapterEvidenceSurvivesConfigurationPostflightFailure() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let adapter = fixture.managerDirectory.appending(path: "app-json.sh")
        let original = fixture.managerDirectory.appending(path: "app-json-real.sh")
        try FileManager.default.copyItem(at: adapter, to: original)
        let outside = fixture.root.appending(path: "outside")
        let contents = Data("# externally redirected file\n".utf8)
        try contents.write(to: outside)
        try Data("""
        #!/bin/bash
        /bin/bash '\(original.path)' "$@"
        fixture_result=$?
        if [ "$2" = execute ]; then
            /bin/rm "$HOME/.zshrc"
            /bin/ln -s '\(outside.path)' "$HOME/.zshrc"
        fi
        exit "$fixture_result"
        """.utf8).write(to: adapter)
        let plan = try await fixture.client.plan(.init(action: .switchTheme, subject: "agnoster"), managerDirectory: fixture.managerDirectory)
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory); XCTFail("Postflight must refuse redirected file") }
        catch let failure as ShellExecutionFailure {
            XCTAssertEqual(failure.operation?.status, "ok")
            XCTAssertEqual(failure.operation?.exitCode, 0)
            XCTAssertEqual(failure.outcome, .unknown)
            XCTAssertNotNil(failure.verificationError)
            let operation = try XCTUnwrap(failure.operation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: operation.backupPath))
        }
        XCTAssertEqual(try Data(contentsOf: outside), contents)
    }

    @MainActor
    func testConfigurationUnchangedFailureKeepsEvidenceWithoutSavedOutcome() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.zshrcURL)
        try fixture.injectAdapterFunctions("switch_theme() { backup_zshrc || return; return 72; }")
        let configuration = try await fixture.client.planConfiguration(plugins: ["git"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
        let store = ActivityStore()
        let model = fixture.model(activityStore: store)
        model.terminalConfigurationPlan = configuration
        await model.executeTerminalConfiguration(configuration)
        let result = try XCTUnwrap(model.terminalConfigurationResult)
        XCTAssertEqual(result.operations.count, 1)
        XCTAssertEqual(result.operations.first?.status, "failed")
        XCTAssertEqual(result.operations.first?.exitCode, 72)
        XCTAssertEqual(result.stepOutcomes.map(\.status), [.failed])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(store.summaries.first?.status, .failed)
        XCTAssertEqual(store.summaries.first?.itemOutcomes.map(\.status), [.failed])
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        let operation = try XCTUnwrap(result.operations.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: operation.backupPath))
        let diagnostic = try XCTUnwrap(model.activityDiagnostics.records.first { $0.id == configuration.id })
        XCTAssertTrue(diagnostic.detail.contains(operation.operationId))
        XCTAssertTrue(diagnostic.detail.contains(DiagnosticText.sanitized(operation.backupPath)))
    }

    @MainActor
    func testSuccessfulAdapterThenSwiftSyntaxFailureRetainsVerifiedRestoreAndFailedStep() async throws {
        let fixture = try ShellManagerFixture(validateSyntax: { _, _ in 91 })
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.zshrcURL.path)
        let original = try Data(contentsOf: fixture.zshrcURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.zshrcURL.path)
        let configuration = try await fixture.client.planConfiguration(plugins: ["git"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
        let store = ActivityStore()
        let model = fixture.model(activityStore: store)
        model.terminalConfigurationPlan = configuration
        await model.executeTerminalConfiguration(configuration)
        let result = try XCTUnwrap(model.terminalConfigurationResult)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stepOutcomes.map(\.status), [.failed])
        XCTAssertEqual(store.summaries.first?.status, .failed)
        let operation = try XCTUnwrap(result.operations.first)
        XCTAssertEqual(operation.status, "ok")
        XCTAssertEqual(operation.exitCode, 0)
        XCTAssertFalse(operation.operationId.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: operation.backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: operation.logFile))
        XCTAssertTrue(result.failure?.contains("shell-syntax-restored") == true)
        XCTAssertTrue(result.failure?.contains("exitCode=91") == true)
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        let restored = try FileManager.default.attributesOfItem(atPath: fixture.zshrcURL.path)
        for key in [FileAttributeKey.posixPermissions, .ownerAccountID, .groupOwnerAccountID] {
            XCTAssertEqual(restored[key] as? NSNumber, attributes[key] as? NSNumber)
        }
        for key in [FileAttributeKey.creationDate, .modificationDate] { XCTAssertEqual(restored[key] as? Date, attributes[key] as? Date) }
        XCTAssertFalse(model.operationStore.hasActiveOperations)
    }

    @MainActor
    func testConfigurationCancellationBeforeWritePreservesPriorStepsAndCancelledItem() async throws {
        for priorStep in [false, true] {
            let fixture = try ShellManagerFixture(executionTimeout: .seconds(5))
            defer { fixture.remove() }
            let block = fixture.root.appending(path: "block")
            let notification = fixture.root.appending(path: "started")
            try Data().write(to: notification)
            XCTAssertEqual(mkfifo(block.path, 0o600), 0)
            let descriptor = open(notification.path, O_EVTONLY | O_CLOEXEC)
            let queue = kqueue()
            defer { close(descriptor); close(queue) }
            var registration = kevent()
            registration.ident = UInt(descriptor)
            registration.filter = Int16(EVFILT_VNODE)
            registration.flags = UInt16(EV_ADD | EV_ONESHOT)
            registration.fflags = UInt32(NOTE_WRITE | NOTE_EXTEND)
            XCTAssertEqual(kevent(queue, &registration, 1, nil, 0, nil), 0)
            try fixture.injectAdapterFunctions("""
            switch_theme() {
                printf ready >> '\(notification.path)'
                read -r fixture_input < '\(block.path)'
                return 1
            }
            """)
            let configuration = try await fixture.client.planConfiguration(plugins: priorStep ? ["git", "example"] : ["git"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
            let store = ActivityStore()
            let model = fixture.model(activityStore: store)
            model.terminalConfigurationPlan = configuration
            let owner = Task { await model.executeTerminalConfiguration(configuration) }
            let ready = await Task.detached {
                var event = kevent()
                var deadline = timespec(tv_sec: 3, tv_nsec: 0)
                return kevent(queue, nil, 0, &event, 1, &deadline) == 1
            }.value
            XCTAssertTrue(ready)
            XCTAssertTrue(model.operationStore.hasActiveOperations)
            owner.cancel()
            await owner.value
            let result = try XCTUnwrap(model.terminalConfigurationResult)
            XCTAssertTrue(result.wasCancelled)
            XCTAssertEqual(result.operations.count, priorStep ? 1 : 0)
            XCTAssertEqual(result.stepOutcomes.map(\.status), priorStep ? [.succeeded, .cancelled] : [.cancelled])
            XCTAssertEqual(result.status, priorStep ? .partiallySucceeded : .cancelled)
            XCTAssertEqual(store.summaries.first?.status, result.status)
            XCTAssertEqual(store.summaries.first?.itemOutcomes.last?.status, .cancelled)
            XCTAssertEqual(store.summaries.first?.reason, .cancelledByUser)
            XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), priorStep ? configuration.expectedContents[0] : configuration.originalContents)
            XCTAssertFalse(model.operationStore.hasActiveOperations)
        }
    }

    @MainActor
    func testPluginCancellationAfterSuccessfulCloneDoesNotPublishOrBecomeFailure() async throws {
        let arrived = expectation(description: "actual clone evidence received before publication")
        let publication = AsyncStream<Void>.makeStream()
        defer { publication.continuation.finish() }
        let fixture = try ShellManagerFixture(beforePluginPublication: {
            arrived.fulfill()
            for await _ in publication.stream { break }
        })
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.zshrcURL)
        try fixture.injectAdapterFunctions("install_plugin_once() { /bin/mkdir \"$SHELL_MANAGER_PLUGIN_STAGING/repository\"; }")
        let store = ActivityStore()
        let model = fixture.model(activityStore: store)
        await model.prepareShellAction(.init(action: .installPlugin, subject: "https://github.com/fixture/cancelled"))
        let plan = try XCTUnwrap(model.shellPlan)
        let owner = Task { await model.executeShellPlan(confirmed: plan) }
        let ready = await XCTWaiter.fulfillment(of: [arrived], timeout: 3)
        XCTAssertEqual(ready, .completed)
        XCTAssertTrue(model.operationStore.hasActiveOperations)
        owner.cancel()
        publication.continuation.finish()
        await owner.value
        let result = try XCTUnwrap(model.shellActionResult)
        XCTAssertEqual(result.operation.status, "ok")
        XCTAssertEqual(result.operation.exitCode, 0)
        XCTAssertFalse(result.operation.operationId.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.operation.logFile))
        XCTAssertEqual(result.executionOutcome, .cancelled)
        XCTAssertEqual(store.summaries.first?.status, .cancelled)
        XCTAssertEqual(store.summaries.first?.itemOutcomes.first?.status, .cancelled)
        XCTAssertEqual(store.summaries.first?.reason, .cancelledByUser)
        let parent = fixture.homeDirectory.appending(path: ".oh-my-zsh/custom/plugins")
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appending(path: "cancelled").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".cellar-plugin-") })
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
    }

    func testPluginPublishNeverReplacesExternalDestinationAndCleanupDoesNotFollowLinks() throws {
        for kind in ["directory", "symlink", "file"] {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            let staging = try ShellPluginStaging(home: fixture.homeDirectory)
            let clone = staging.directory.appending(path: "repository")
            try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
            let outside = fixture.root.appending(path: "outside")
            try Data("external".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: clone.appending(path: "escape"), withDestinationURL: outside)
            let final = staging.directory.deletingLastPathComponent().appending(path: "raced")
            if kind == "directory" { try FileManager.default.createDirectory(at: final, withIntermediateDirectories: false) }
            if kind == "file" { try Data("external".utf8).write(to: final) }
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: final, withDestinationURL: outside) }
            let before = try FileManager.default.attributesOfItem(atPath: final.path)[.systemFileNumber] as? NSNumber
            XCTAssertThrowsError(try staging.publish(name: "raced"))
            try staging.cleanup()
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: final.path)[.systemFileNumber] as? NSNumber, before)
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "external")
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
        }
    }

    func testPluginStagingCleanupRemovesNestedCloneAndLinksWithoutFollowingTargets() throws {
        for repositoryIsLink in [false, true] {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            let staging = try ShellPluginStaging(home: fixture.homeDirectory)
            let repository = staging.directory.appending(path: "repository")
            let outside = fixture.root.appending(path: "outside-directory")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let sentinel = outside.appending(path: "sentinel")
            try Data("external".utf8).write(to: sentinel)
            if repositoryIsLink {
                try FileManager.default.createSymbolicLink(at: repository, withDestinationURL: outside)
            } else {
                let nested = repository.appending(path: "first/second")
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                try Data("plugin".utf8).write(to: nested.appending(path: "plugin.zsh"))
                try Data("root".utf8).write(to: repository.appending(path: "README"))
                try FileManager.default.createSymbolicLink(at: nested.appending(path: "external"), withDestinationURL: outside)
                try FileManager.default.createSymbolicLink(at: nested.appending(path: "dangling"), withDestinationURL: fixture.root.appending(path: "missing"))
            }
            try staging.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("external".utf8))
        }
    }

    func testPluginStagingCleanupUsesRetainedParentAfterAncestorRenameAndReplacement() throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let staging = try ShellPluginStaging(home: fixture.homeDirectory)
        try FileManager.default.createDirectory(at: staging.directory.appending(path: "repository/nested"), withIntermediateDirectories: true)
        let parent = staging.directory.deletingLastPathComponent()
        let moved = fixture.root.appending(path: "moved-plugins")
        try FileManager.default.moveItem(at: parent, to: moved)
        let outside = fixture.root.appending(path: "replacement-plugins")
        let replacement = outside.appending(path: staging.directory.lastPathComponent)
        try FileManager.default.createDirectory(at: replacement.appending(path: "repository"), withIntermediateDirectories: true)
        try Data(staging.token.utf8).write(to: replacement.appending(path: ".cellar-owner"))
        let sentinel = replacement.appending(path: "repository/sentinel")
        try Data("external".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        // This verifies descriptor anchoring, not a race inside removefileat.
        try staging.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appending(path: staging.directory.lastPathComponent).path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("external".utf8))
        XCTAssertEqual(try Data(contentsOf: replacement.appending(path: ".cellar-owner")), Data(staging.token.utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: parent.path), outside.path)
    }

    func testPluginStagingCleanupRejectsReplacedStagingInodeEvenWithMatchingMarker() throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let staging = try ShellPluginStaging(home: fixture.homeDirectory)
        let originalRepository = staging.directory.appending(path: "repository")
        try FileManager.default.createDirectory(at: originalRepository, withIntermediateDirectories: false)
        try Data("owned".utf8).write(to: originalRepository.appending(path: "sentinel"))
        let moved = staging.directory.deletingLastPathComponent().appending(path: "moved-staging")
        try FileManager.default.moveItem(at: staging.directory, to: moved)
        try FileManager.default.createDirectory(at: originalRepository, withIntermediateDirectories: true)
        try Data(staging.token.utf8).write(to: staging.directory.appending(path: ".cellar-owner"))
        let replacementSentinel = originalRepository.appending(path: "sentinel")
        try Data("replacement".utf8).write(to: replacementSentinel)
        XCTAssertThrowsError(try staging.cleanup())
        XCTAssertEqual(try Data(contentsOf: replacementSentinel), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: moved.appending(path: "repository/sentinel")), Data("owned".utf8))
    }

    func testPluginStagingCleanupRejectsExcessiveDepthAndRetainsOwnershipMarker() throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let staging = try ShellPluginStaging(home: fixture.homeDirectory)
        var deepest = staging.directory.appending(path: "repository")
        try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: false)
        for _ in 0..<256 {
            deepest.append(path: "d")
            try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: false)
        }
        XCTAssertThrowsError(try staging.cleanup()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ELOOP)
        }
        XCTAssertEqual(try Data(contentsOf: staging.directory.appending(path: ".cellar-owner")), Data(staging.token.utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deepest.path))
    }

    func testPluginStagingCleanupSyscallFailurePreservesCallerVisibleContextAndPOSIXReason() throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let staging = try ShellPluginStaging(home: fixture.homeDirectory)
        let unreadable = staging.directory.appending(path: "repository/unreadable-node")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        defer { XCTAssertEqual(chmod(unreadable.path, 0o700), 0) }
        XCTAssertThrowsError(try staging.cleanup()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
            // executePlugin preserves cleanup errors through localizedDescription.
            XCTAssertTrue(error.localizedDescription.contains("openat"))
            XCTAssertTrue(error.localizedDescription.contains("unreadable-node"))
            XCTAssertTrue(error.localizedDescription.contains(POSIXError(.EACCES).localizedDescription))
        }
        XCTAssertEqual(try Data(contentsOf: staging.directory.appending(path: ".cellar-owner")), Data(staging.token.utf8))
    }

    func testPluginStagingCleanupStillRunsInCancelledTask() async throws {
        try await Task {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            let staging = try ShellPluginStaging(home: fixture.homeDirectory)
            try FileManager.default.createDirectory(at: staging.directory.appending(path: "repository/nested"), withIntermediateDirectories: true)
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            try staging.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
        }.value
    }

    func testPluginStagingPublishesAtomicallyAndRejectsRedirectedParentsOrMarkerDrift() throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let staging = try ShellPluginStaging(home: fixture.homeDirectory)
        let clone = staging.directory.appending(path: "repository")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try Data("plugin".utf8).write(to: clone.appending(path: "plugin.zsh"))
        let inode = try FileManager.default.attributesOfItem(atPath: clone.path)[.systemFileNumber] as? NSNumber
        XCTAssertThrowsError(try staging.publish(name: "../escape"))
        try staging.publish(name: "published")
        let final = staging.directory.deletingLastPathComponent().appending(path: "published")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: final.path)[.systemFileNumber] as? NSNumber, inode)
        try staging.cleanup()
        XCTAssertEqual(try String(contentsOf: final.appending(path: "plugin.zsh"), encoding: .utf8), "plugin")
        let changed = try ShellPluginStaging(home: fixture.homeDirectory)
        try Data("foreign".utf8).write(to: changed.directory.appending(path: ".cellar-owner"))
        XCTAssertThrowsError(try changed.cleanup())
        let parent = final.deletingLastPathComponent()
        let moved = fixture.root.appending(path: "moved-plugins")
        try FileManager.default.moveItem(at: parent, to: moved)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: moved)
        XCTAssertThrowsError(try ShellPluginStaging(home: fixture.homeDirectory))
        XCTAssertThrowsError(try changed.publish(name: "escape"))
    }

    func testMissingMultipleCommentedAndConditionalInitializationRejectBeforeWrites() async throws {
        for source in ["", "# source $ZSH/oh-my-zsh.sh\n", "source $ZSH/oh-my-zsh.sh\nsource \"$ZSH/oh-my-zsh.sh\"\n",
                       "if true; then\nsource $ZSH/oh-my-zsh.sh\nfi\n", "source $OTHER/oh-my-zsh.sh\n", "FOO=bar &&\nsource $ZSH/oh-my-zsh.sh\n"] {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            let original = Data(("ZSH_THEME=\"robbyrussell\"\nplugins=(git)\n" + source).utf8)
            try original.write(to: fixture.zshrcURL)
            do { _ = try await fixture.client.planConfiguration(plugins: ["example"], theme: "agnoster", managerDirectory: fixture.managerDirectory); XCTFail("Ambiguous init must refuse") }
            catch { }
            XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.homeDirectory.path).contains { $0.hasPrefix(".zshrc.bak") })
        }
    }

    func testPluginCloneFailurePreservesDestinationCreatedAfterPreflight() async throws {
        for cloneExit in [0, 1] {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            let original = try Data(contentsOf: fixture.zshrcURL)
            let module = fixture.managerDirectory.appending(path: "lib/app_json_execute.sh")
            let fakeGit = fixture.root.appending(path: "fake-git")
            try Data("#!/bin/bash\n/bin/mkdir repository\nprintf clone > repository/fixture\n/bin/mkdir -p \"$HOME/.oh-my-zsh/custom/plugins/raced\"\nprintf external > \"$HOME/.oh-my-zsh/custom/plugins/raced/owner\"\nexit \(cloneExit)\n".utf8).write(to: fakeGit)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)
            let script = try String(contentsOf: module, encoding: .utf8).replacingOccurrences(of: "/usr/bin/git clone", with: "'\(fakeGit.path)' clone")
            try Data(script.utf8).write(to: module)
            let plan = try await fixture.client.plan(.init(action: .installPlugin, subject: "https://github.com/example/raced"), managerDirectory: fixture.managerDirectory)
            do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory); XCTFail("Clone failure or occupied publish must fail") }
            catch let failure as ShellExecutionFailure {
                XCTAssertEqual(failure.operation?.status, cloneExit == 0 ? "ok" : "failed")
                XCTAssertEqual(failure.outcome, .failed)
                let operation = try XCTUnwrap(failure.operation)
                XCTAssertTrue(FileManager.default.fileExists(atPath: operation.logFile))
            }
            let parent = fixture.homeDirectory.appending(path: ".oh-my-zsh/custom/plugins")
            XCTAssertEqual(try String(contentsOf: parent.appending(path: "raced/owner"), encoding: .utf8), "external")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasPrefix(".cellar-plugin-") })
            XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        }
    }

    func testManagedValuesAreVisibleWhenOfficialTemplateSourcesOhMyZsh() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let loader = fixture.homeDirectory.appending(path: ".oh-my-zsh/oh-my-zsh.sh")
        try Data("print -r -- \"$ZSH_THEME|${(j:,:)plugins}|$ZSH_COMPDUMP\" > \"$HOME/seen\"\n".utf8).write(to: loader)
        try Data("export ZSH=\"$HOME/.oh-my-zsh\"\nZSH_THEME=\"robbyrussell\"\nplugins=(git)\nsource $ZSH/oh-my-zsh.sh\n".utf8).write(to: fixture.zshrcURL)
        let plan = try await fixture.client.planConfiguration(plugins: ["git", "example"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
        let result = await fixture.client.executeConfiguration(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertNil(result.failure)
        let tidy = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        _ = try await fixture.client.execute(tidy, managerDirectory: fixture.managerDirectory)
        let run = try await ProcessRunner().run(ProcessRequest(executableURL: URL(filePath: "/bin/zsh"), arguments: ["-f", fixture.zshrcURL.path],
            environment: ShellEnvironmentResolver(homeDirectory: fixture.homeDirectory, temporaryDirectory: fixture.root).environment(), currentDirectoryURL: fixture.root))
        XCTAssertEqual(run.terminationStatus, 0, run.errorText)
        XCTAssertEqual(try String(contentsOf: fixture.homeDirectory.appending(path: "seen"), encoding: .utf8), "agnoster|example,git|\(fixture.homeDirectory.path)/.zsh/zcompdump\n")
    }

    func testTidyRejectsNonUTF8BeforeAnyMovementOrWrite() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let bytes = Data([0xff, 0xfe, 0x0a])
        try bytes.write(to: fixture.zshrcURL)
        let cache = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
        try Data("cache".utf8).write(to: cache)
        do { _ = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory); XCTFail("Non-UTF8 input must refuse before planning") }
        catch BridgeError.invalidOutput { }
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh").path))
    }

    func testTidyValidationRunFailureRestoresSafelyAndReturnsPartial() async throws {
        let fixture = try ShellManagerFixture(validateSyntax: { _, _ in throw CocoaError(.fileReadNoSuchFile) })
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.zshrcURL)
        let cache = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
        try Data("cache".utf8).write(to: cache)
        let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        let result = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(result.status, "partial")
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/.zcompdump-fixture").path))
    }

    @MainActor
    func testTidyCancellationAwaitsValidationProcessAndRetainsPartialFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarTidyValidation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notification = root.appending(path: "started")
        try Data().write(to: notification)
        let block = root.appending(path: "block")
        XCTAssertEqual(mkfifo(block.path, 0o600), 0)
        let script = root.appending(path: "validate.sh")
        let pidFile = root.appending(path: "validation.pid")
        try Data("#!/bin/bash\nprintf '%s' \"$$\" > '\(pidFile.path)'\nprintf ready >> '\(notification.path)'\nread -r task_input < '\(block.path)'\n".utf8).write(to: script)
        let fileDescriptor = open(notification.path, O_EVTONLY | O_CLOEXEC)
        let queue = kqueue()
        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
        XCTAssertGreaterThanOrEqual(queue, 0)
        defer { close(fileDescriptor); close(queue) }
        var registration = kevent()
        registration.ident = UInt(fileDescriptor)
        registration.filter = Int16(EVFILT_VNODE)
        registration.flags = UInt16(EV_ADD | EV_ONESHOT)
        registration.fflags = UInt32(NOTE_WRITE | NOTE_EXTEND)
        XCTAssertEqual(kevent(queue, &registration, 1, nil, 0, nil), 0)
        let runner = ProcessRunner()
        let fixture = try ShellManagerFixture(validateSyntax: { _, directory in
            try await runner.run(ProcessRequest(executableURL: URL(filePath: "/bin/bash"), arguments: [script.path],
                                                environment: ShellEnvironmentResolver(homeDirectory: root).environment(), currentDirectoryURL: directory,
                                                timeout: .seconds(5))).terminationStatus
        })
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.zshrcURL)
        let cache = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
        try Data("cache".utf8).write(to: cache)
        let model = fixture.model(activityStore: ActivityStore())
        await model.prepareShellAction(.init(action: .tidy, subject: "zsh-files"))
        let plan = try XCTUnwrap(model.shellPlan)
        let ownerFinished = expectation(description: "operation owner completes cancellation")
        let owner = Task { await model.executeShellPlan(confirmed: plan); ownerFinished.fulfill() }
        let started = await Task.detached {
            var event = kevent()
            var deadline = timespec(tv_sec: 3, tv_nsec: 0)
            return kevent(queue, nil, 0, &event, 1, &deadline) == 1
        }.value
        XCTAssertTrue(started)
        owner.cancel()
        let timely = await XCTWaiter.fulfillment(of: [ownerFinished], timeout: 2)
        await owner.value
        XCTAssertEqual(timely, .completed)
        XCTAssertFalse(model.operationStore.hasActiveOperations)
        XCTAssertEqual(model.shellActionResult?.operation.status, "partial")
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/.zcompdump-fixture").path))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    @MainActor
    func testPluginSuccessThemeFailureKeepsExactSemanticStepsInSession() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planConfiguration(plugins: ["git", "example"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
        let adapter = fixture.managerDirectory.appending(path: "app-json.sh")
        let originalAdapter = fixture.managerDirectory.appending(path: "app-json-real.sh")
        try FileManager.default.copyItem(at: adapter, to: originalAdapter)
        let wrapper = """
        #!/bin/bash
        /bin/bash '\(originalAdapter.path)' "$@"
        task_result=$?
        if [ "$2" = execute ] && [ "$3" = set-plugins ]; then /bin/rm "$HOME/.oh-my-zsh/themes/agnoster.zsh-theme"; fi
        exit "$task_result"
        """
        try Data(wrapper.utf8).write(to: adapter)
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: fixture.root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: .init(homeDirectory: fixture.homeDirectory)),
                                         shellClient: fixture.client, environmentResolver: .init(homeDirectory: fixture.homeDirectory))
        let store = ActivityStore()
        let model = AppModel(service: service, operationStore: OperationStore(), activityStore: store,
                             managerSnapshot: .init(version: "fixture", location: fixture.root.path, nodeAvailable: false, homebrewAvailable: false, shellAvailable: true))
        model.terminalConfigurationPlan = plan
        await model.executeTerminalConfiguration(plan)
        XCTAssertEqual(model.terminalConfigurationResult?.operations.count, 1)
        XCTAssertTrue(ActivityStore().summaries.isEmpty)
        let summary = try XCTUnwrap(store.summaries.first)
        XCTAssertNotNil(summary.scope)
        XCTAssertEqual(summary.status, .partiallySucceeded)
        XCTAssertEqual(summary.itemOutcomes.map(\.status), [.succeeded, .failed])
        let json = String(decoding: try JSONEncoder().encode(store.summaries), as: UTF8.self)
        XCTAssertTrue(json.contains("plugins"))
        XCTAssertTrue(json.contains("theme"))
        for forbidden in ["example", "agnoster", fixture.homeDirectory.path, "stdout", "stderr", "planToken"] { XCTAssertFalse(json.contains(forbidden), forbidden) }
    }

    func testMandatoryGitIsAppliedWithoutOtherDraftChangesAndWithThemeOnlyChange() async throws {
        for theme in ["robbyrussell", "agnoster"] {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            try Data("ZSH_THEME=\"robbyrussell\"\nplugins=(example)\nsource $ZSH/oh-my-zsh.sh\n".utf8).write(to: fixture.zshrcURL)
            let initial = try await fixture.client.loadSnapshot(managerDirectory: fixture.managerDirectory, managerAvailable: true)
            XCTAssertTrue(TerminalConfigurationSelection.hasChanges(plugins: ["example", "git"], theme: theme, snapshot: initial))
            let plan = try await fixture.client.planConfiguration(plugins: ["example", "git"], theme: theme, managerDirectory: fixture.managerDirectory)
            XCTAssertTrue(plan.plans.contains { $0.request.action == .setPlugins })
            let result = await fixture.client.executeConfiguration(plan, managerDirectory: fixture.managerDirectory)
            XCTAssertNil(result.failure)
            let snapshot = try await fixture.client.loadSnapshot(managerDirectory: fixture.managerDirectory, managerAvailable: true)
            XCTAssertTrue(snapshot.activePlugins.contains("git"))
        }
    }

    func testMissingThemeFailsWholeApplyBeforePluginWrite() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.zshrcURL)
        let plan = try await fixture.client.planConfiguration(plugins: ["git", "example"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
        try FileManager.default.removeItem(at: fixture.homeDirectory.appending(path: ".oh-my-zsh/themes/agnoster.zsh-theme"))
        let result = await fixture.client.executeConfiguration(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertTrue(result.operations.isEmpty)
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
    }

    func testTidyInvalidSyntaxRestoresExactFileAndAttributesButKeepsMovedFiles() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        // The original is valid; replacing this managed block removes the matching fi.
        try Data("\nif true; then\n# >>> omz-manager compdump >>>\nprint okay\nfi\n# <<< omz-manager compdump <<<\n".utf8).append(to: fixture.zshrcURL)
        let initialValidation = try await ProcessRunner().run(ProcessRequest(executableURL: URL(filePath: "/bin/zsh"), arguments: ["-n", fixture.zshrcURL.path],
                                                                           environment: ShellEnvironmentResolver(homeDirectory: fixture.homeDirectory).environment(), currentDirectoryURL: fixture.root))
        XCTAssertEqual(initialValidation.terminationStatus, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.zshrcURL.path)
        let original = try Data(contentsOf: fixture.zshrcURL)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: fixture.zshrcURL.path)
        let cache = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
        try Data("cache".utf8).write(to: cache)
        let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        let result = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(result.status, "partial")
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.zshrcURL.path)[.posixPermissions] as? Int, 0o640)
        let restoredAttributes = try FileManager.default.attributesOfItem(atPath: fixture.zshrcURL.path)
        for key in [FileAttributeKey.creationDate, .modificationDate] { XCTAssertEqual(restoredAttributes[key] as? Date, originalAttributes[key] as? Date) }
        for key in [FileAttributeKey.ownerAccountID, .groupOwnerAccountID] { XCTAssertEqual(restoredAttributes[key] as? Int, originalAttributes[key] as? Int) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/.zcompdump-fixture").path))
    }

    @MainActor
    func testTidySyntaxFailureReportsPartialOnlyWhenFilesActuallyMoved() async throws {
        for hasCandidate in [false, true] {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            try Data("\nif then\n".utf8).append(to: fixture.zshrcURL)
            let original = try Data(contentsOf: fixture.zshrcURL)
            if hasCandidate { try Data("cache".utf8).write(to: fixture.homeDirectory.appending(path: ".zcompdump-fixture")) }
            let store = ActivityStore()
            let model = fixture.model(activityStore: store)
            await model.prepareShellAction(.init(action: .tidy, subject: "zsh-files"))
            let plan = try XCTUnwrap(model.shellPlan)
            await model.executeShellPlan(confirmed: plan)
            XCTAssertEqual(model.shellActionResult?.operation.status, hasCandidate ? "partial" : "ok")
            XCTAssertNotNil(model.shellOperationError)
            XCTAssertEqual(store.summaries.first?.status, hasCandidate ? .partiallySucceeded : .failed)
            XCTAssertEqual(store.summaries.first?.itemOutcomes.first?.status, hasCandidate ? .partiallySucceeded : .failed)
            XCTAssertEqual(store.summaries.first?.itemOutcomes.first?.shellStep, .tidy)
            XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/.zcompdump-fixture").path), hasCandidate)
        }
    }

    func testTidyRefusesSymlinkDriftBeforeExecutionAndAfterAdapterResult() async throws {
        for afterExecution in [false, true] {
            let fixture = try ShellManagerFixture()
            defer { fixture.remove() }
            let outside = fixture.root.appending(path: "outside-zshrc")
            let protected = Data("if then\n# outside file must remain unchanged\n".utf8)
            try protected.write(to: outside)
            let cache = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
            try Data("cache".utf8).write(to: cache)
            let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
            if afterExecution {
                let adapter = fixture.managerDirectory.appending(path: "app-json.sh")
                let original = fixture.managerDirectory.appending(path: "app-json-real.sh")
                try FileManager.default.copyItem(at: adapter, to: original)
                let wrapper = """
                #!/bin/bash
                /bin/bash '\(original.path)' "$@"
                task_result=$?
                if [ "$2" = execute ]; then
                  /bin/rm "$HOME/.zshrc"
                  /bin/ln -s '\(outside.path)' "$HOME/.zshrc"
                fi
                exit "$task_result"
                """
                try Data(wrapper.utf8).write(to: adapter)
                let result = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
                XCTAssertEqual(result.status, "partial")
                XCTAssertNotNil(result.detail)
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/.zcompdump-fixture").path))
            } else {
                try FileManager.default.removeItem(at: fixture.zshrcURL)
                try FileManager.default.createSymbolicLink(at: fixture.zshrcURL, withDestinationURL: outside)
                do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory); XCTFail("Symlink drift must prevent execution") }
                catch BridgeError.managerFailure { XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path)) }
            }
            XCTAssertEqual(try Data(contentsOf: outside), protected)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.zshrcURL.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        }
    }

    func testTerminalReadsOnlyInstalledPluginsAndAppliesBothChangesOnce() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let initialContents = try Data(contentsOf: fixture.zshrcURL)
        let snapshot = try await fixture.client.loadSnapshot(managerDirectory: fixture.managerDirectory, managerAvailable: true)
        XCTAssertEqual(snapshot.defaultPluginNames, ["git"])
        XCTAssertEqual(snapshot.installedCustomPlugins, ["example"])
        let plan = try await fixture.client.planConfiguration(plugins: ["git", "example"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(plan.plans.count, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), initialContents)
        let result = await fixture.client.executeConfiguration(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.operations.count, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), plan.expectedContents.last)
        XCTAssertTrue(result.operations.allSatisfy { FileManager.default.fileExists(atPath: $0.backupPath) })
        let duplicate = await fixture.client.executeConfiguration(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertNotNil(duplicate.failure)
        XCTAssertTrue(duplicate.operations.isEmpty)
    }

    func testTerminalApplyRejectsDriftAndNonLocalThemeBeforeAnyWrite() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planConfiguration(plugins: ["example", "git"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
        try Data("\n# edited after confirmation\n".utf8).append(to: fixture.zshrcURL)
        let changed = try Data(contentsOf: fixture.zshrcURL)
        let result = await fixture.client.executeConfiguration(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertNotNil(result.failure)
        XCTAssertTrue(result.operations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), changed)
        do {
            _ = try await fixture.client.planConfiguration(plugins: ["git"], theme: "online-theme", managerDirectory: fixture.managerDirectory)
            XCTFail("Only local themes may be used")
        } catch { XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), changed) }
        do {
            _ = try await fixture.client.planConfiguration(plugins: ["git", "not-installed"], theme: "agnoster", managerDirectory: fixture.managerDirectory)
            XCTFail("Only installed plugins may be used")
        } catch { XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), changed) }
    }

    func testSyntaxFailureRestoresExactPreviousConfigurationAndRetainsBackup() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        try Data("\nif then\n".utf8).append(to: fixture.zshrcURL)
        let original = try Data(contentsOf: fixture.zshrcURL)
        let plan = try await fixture.client.plan(.init(action: .switchTheme, subject: "agnoster"), managerDirectory: fixture.managerDirectory)
        do {
            _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
            XCTFail("Syntax failure must fail and restore")
        } catch let failure as ShellExecutionFailure {
            guard case BridgeError.managerFailure(let code, _) = failure.cause else { return XCTFail("Expected syntax failure") }
            XCTAssertEqual(code, "action-failed")
            XCTAssertTrue(failure.verificationError?.contains("restored") == true)
            XCTAssertEqual(failure.operation?.status, "failed")
            XCTAssertEqual(failure.outcome, .failed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.homeDirectory.path).filter { $0.hasPrefix(".zshrc.bak.") }
        XCTAssertFalse(backups.isEmpty)
    }

    func testCustomPluginSyntaxFailureRestoresConfigurationWithoutNetwork() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        try Data("\nif then\n".utf8).append(to: fixture.zshrcURL)
        let original = try Data(contentsOf: fixture.zshrcURL)
        let request = ShellActionRequest(action: .installPlugin, subject: "https://github.com/fixture/newplugin")
        let plan = try await fixture.client.plan(request, managerDirectory: fixture.managerDirectory)
        let module = fixture.managerDirectory.appending(path: "lib/app_json_execute.sh")
        let script = try String(contentsOf: module, encoding: .utf8).replacingOccurrences(of: "/usr/bin/git clone --depth=1 \"$url\" repository", with: "/bin/mkdir repository && printf fixture > repository/newplugin.plugin.zsh")
        try Data(script.utf8).write(to: module)
        let result = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(result.status, "partial")
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".oh-my-zsh/custom/plugins/newplugin/newplugin.plugin.zsh").path))
    }

    func testTidyListsExactCandidatesAndDoesNotChangeZprofileBody() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let zprofile = fixture.homeDirectory.appending(path: ".zprofile")
        try Data("# profile remains unchanged\n".utf8).write(to: zprofile)
        let completion = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
        try Data("completion cache".utf8).write(to: completion)
        let historical = fixture.homeDirectory.appending(path: ".zprofile.bak")
        try Data("historical profile".utf8).write(to: historical)
        let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(Set(plan.candidates.map { URL(filePath: $0).resolvingSymlinksInPath().path }), Set([completion, historical].map { $0.resolvingSymlinksInPath().path }))
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(operation.status, "ok")
        XCTAssertEqual(try String(contentsOf: zprofile, encoding: .utf8), "# profile remains unchanged\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/.zcompdump-fixture").path))
        XCTAssertFalse(operation.backupPath.isEmpty)
    }

    func testTidyRejectsNewCandidateAndSymlinks() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        let candidate = fixture.homeDirectory.appending(path: ".zcompdump-new")
        try Data("new".utf8).write(to: candidate)
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory); XCTFail("Candidate drift must fail") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-stale") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        try FileManager.default.createSymbolicLink(at: fixture.homeDirectory.appending(path: ".zcompdump-link"), withDestinationURL: candidate)
        do { _ = try await fixture.client.plan(.init(action: .tidy), managerDirectory: fixture.managerDirectory); XCTFail("Symlinks must be refused") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "tidy-nonregular-candidate") }
    }

    func testTidyRefusesRedirectedDirectoryAndBackupCollision() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let destination = fixture.homeDirectory.appending(path: ".zsh")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        do { _ = try await fixture.client.plan(.init(action: .tidy), managerDirectory: fixture.managerDirectory); XCTFail("Redirected tidy target must fail") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "tidy-unsafe-destination") }
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let candidate = fixture.homeDirectory.appending(path: ".zcompdump-fixture")
        try Data("new completion".utf8).write(to: candidate)
        let existing = destination.appending(path: ".zcompdump-fixture")
        try Data("existing completion".utf8).write(to: existing)
        do { _ = try await fixture.client.plan(.init(action: .tidy), managerDirectory: fixture.managerDirectory); XCTFail("Tidy cannot overwrite an existing file") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "tidy-destination-occupied") }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing completion")
    }

    func testLoadsSnapshotAndSwitchesThemeOnlyAfterConfirmedExecution() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }

        let initial = try await fixture.client.loadSnapshot(
            managerDirectory: fixture.managerDirectory,
            managerAvailable: true
        )
        XCTAssertEqual(initial.currentTheme, "robbyrussell")
        XCTAssertEqual(initial.activePlugins, ["git"])
        XCTAssertTrue(initial.availableThemes.contains("agnoster"))

        let plan = try await fixture.client.plan(
            .init(action: .switchTheme, subject: "agnoster"),
            managerDirectory: fixture.managerDirectory
        )
        let beforeExecution = try String(contentsOf: fixture.zshrcURL, encoding: .utf8)
        XCTAssertFalse(beforeExecution.contains("omz-manager theme"))

        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
        let updated = try String(contentsOf: fixture.zshrcURL, encoding: .utf8)

        XCTAssertEqual(operation.status, "ok")
        XCTAssertTrue(updated.contains("# >>> omz-manager theme >>>"))
        XCTAssertTrue(updated.contains("ZSH_THEME=\"agnoster\""))
        XCTAssertFalse(operation.backupPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: operation.backupPath))
    }

    func testRejectsExecutionWhenZshrcChangedAfterPlan() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.plan(
            .init(action: .switchTheme, subject: "agnoster"),
            managerDirectory: fixture.managerDirectory
        )
        try Data("\n# changed after plan\n".utf8).append(to: fixture.zshrcURL)

        do {
            _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
            XCTFail("Expected stale plan rejection")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "plan-stale")
        } catch {
            XCTFail("Expected structured manager failure, got: \(error.localizedDescription)")
        }
    }

    func testUpdatesManagedPluginSelectionInTemporaryHome() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.plan(
            .init(action: .setPlugins, subject: "git,example"),
            managerDirectory: fixture.managerDirectory
        )
        let operation = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
        let updated = try String(contentsOf: fixture.zshrcURL, encoding: .utf8)

        XCTAssertEqual(operation.status, "ok")
        XCTAssertTrue(updated.contains("plugins=(git example)"))
        XCTAssertTrue(updated.contains("# >>> omz-manager plugins >>>"))

        let disablePlan = try await fixture.client.plan(
            .init(action: .setPlugins, subject: "git"),
            managerDirectory: fixture.managerDirectory
        )
        _ = try await fixture.client.execute(disablePlan, managerDirectory: fixture.managerDirectory)
        let disabled = try String(contentsOf: fixture.zshrcURL, encoding: .utf8)
        XCTAssertTrue(disabled.contains("plugins=(git)"))
        XCTAssertFalse(disabled.contains("plugins=(git example)"))
    }

    func testBlocksSymlinkedZshrcPlan() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let target = fixture.homeDirectory.appending(path: "actual-zshrc")
        try FileManager.default.moveItem(at: fixture.zshrcURL, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.zshrcURL, withDestinationURL: target)

        let plan = try await fixture.client.plan(
            .init(action: .switchTheme, subject: "agnoster"),
            managerDirectory: fixture.managerDirectory
        )

        XCTAssertFalse(plan.canExecute)
        XCTAssertEqual(plan.payload.blockedReason, "zshrc-is-symlink")
    }
}

private struct ShellManagerFixture {
    let root: URL
    let homeDirectory: URL
    let managerDirectory: URL
    let zshrcURL: URL
    let client: ShellManagerClient

    init(executionTimeout: Duration = .seconds(1_800), beforePluginPublication: @escaping @Sendable () async -> Void = {}, validateSyntax: (@Sendable (URL, URL) async throws -> Int32)? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "CellarShellManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        homeDirectory = root.appending(path: "home", directoryHint: .isDirectory)
        managerDirectory = root.appending(path: "zsh-manager", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)

        let source = try XCTUnwrap(Bundle.main.resourceURL)
            .appending(path: "Managers/zsh-manager", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: managerDirectory)

        let themes = homeDirectory.appending(path: ".oh-my-zsh/themes", directoryHint: .isDirectory)
        let plugins = homeDirectory.appending(path: ".oh-my-zsh/plugins/git", directoryHint: .isDirectory)
        let customPlugin = homeDirectory.appending(
            path: ".oh-my-zsh/custom/plugins/example",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customPlugin, withIntermediateDirectories: true)
        try Data().write(to: themes.appending(path: "robbyrussell.zsh-theme"))
        try Data().write(to: themes.appending(path: "agnoster.zsh-theme"))
        zshrcURL = homeDirectory.appending(path: ".zshrc")
        try Data("ZSH_THEME=\"robbyrussell\"\nplugins=(git)\nsource $ZSH/oh-my-zsh.sh\n".utf8).write(to: zshrcURL)

        client = ShellManagerClient(
            runner: ProcessRunner(),
            environmentResolver: ShellEnvironmentResolver(
                homeDirectory: homeDirectory,
                temporaryDirectory: root
            ), executionTimeout: executionTimeout, beforePluginPublication: beforePluginPublication, validateSyntax: validateSyntax
        )
    }

    func injectAdapterFunctions(_ functions: String) throws {
        let adapter = managerDirectory.appending(path: "app-json.sh")
        let script = try String(contentsOf: adapter, encoding: .utf8)
        let source = "source \"$SCRIPT_DIR/lib/app_json_execute.sh\""
        try Data(script.replacingOccurrences(of: source, with: source + "\n" + functions).utf8).write(to: adapter)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func model(activityStore: ActivityStore) -> AppModel {
        let runner = ProcessRunner()
        let resolver = NodeEnvironmentResolver(homeDirectory: homeDirectory)
        let service = SystemProbeService(runner: runner, installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
                                         nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver), shellClient: client, environmentResolver: resolver)
        return AppModel(service: service, operationStore: OperationStore(), activityStore: activityStore,
                        managerSnapshot: .init(version: "fixture", location: root.path, nodeAvailable: false, homebrewAvailable: false, shellAvailable: true))
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
