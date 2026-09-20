import XCTest
@testable import Cellar

final class ShellManagerClientTests: XCTestCase {
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
