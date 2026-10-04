import XCTest
@testable import Cellar

final class ShellManagerClientTests: XCTestCase {
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
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "shell-syntax-restored") }
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
        let snapshot = try await fixture.client.loadSnapshot(managerDirectory: fixture.managerDirectory, managerAvailable: true)
        let expected = try ShellManagerClient.expectedConfiguration(original, request: .init(action: .setPlugins, subject: "git,newplugin"))
        let payload: [String: Any] = ["zshVersion": "fixture", "ohMyZshInstalled": true, "ohMyZshPath": snapshot.ohMyZshPath,
                                     "zshrcPath": fixture.zshrcURL.path, "zshrcExists": true, "currentTheme": "robbyrussell",
                                     "activePlugins": ["git"], "installedCustomPlugins": ["example"], "availableThemes": ["robbyrussell", "agnoster"],
                                     "defaultPluginNames": [], "runtimeDirectory": fixture.managerDirectory.path]
        let envelope = try JSONSerialization.data(withJSONObject: ["ok": true, "schemaVersion": 1, "command": "snapshot", "data": payload])
        let script = """
        #!/bin/bash
        if [ "$2" = snapshot ]; then
          printf '%s' '\(envelope.base64EncodedString())' | /usr/bin/base64 -D
        else
          printf '%s' '\(expected.base64EncodedString())' | /usr/bin/base64 -D > "$HOME/.zshrc"
          printf '%s\\n' '{"ok":false,"schemaVersion":1,"command":"execute","error":{"code":"action-failed"}}'
          exit 1
        fi
        """
        let adapter = fixture.managerDirectory.appending(path: "app-json.sh")
        try Data(script.utf8).write(to: adapter)
        do { _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory); XCTFail("Failed plugin configuration must restore") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "shell-syntax-restored") }
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
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

    init() throws {
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
        try Data("ZSH_THEME=\"robbyrussell\"\nplugins=(git)\n".utf8).write(to: zshrcURL)

        client = ShellManagerClient(
            runner: ProcessRunner(),
            environmentResolver: ShellEnvironmentResolver(
                homeDirectory: homeDirectory,
                temporaryDirectory: root
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
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
