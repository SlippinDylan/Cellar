import Darwin
import XCTest
@testable import Cellar

final class ShellManagerClientTests: XCTestCase {

    // MARK: - Standard .zshrc Updates & Real-World Compatibility

    func testUpdatesStandardZshrcWithBrewShellenvConditionalsAndMultilinePlugins() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let realWorldZshrc = """
        eval "$(/opt/homebrew/bin/brew shellenv)"
        if [[ -r "$HOME/.cache/p10k.zsh" ]]; then
            source "$HOME/.cache/p10k.zsh"
        fi
        export ZSH="$HOME/.oh-my-zsh"
        ZSH_THEME="robbyrussell"
        plugins=(
            git
        )
        ZSH_AUTOSUGGEST_STRATEGY=(history completion)
        source $ZSH/oh-my-zsh.sh
        alias ll="ls -la"
        """
        try Data((realWorldZshrc + "\n").utf8).write(to: fixture.zshrcURL)

        let plan = try await fixture.client.planConfiguration(
            plugins: ["git", "example"],
            theme: "agnoster",
            managerDirectory: fixture.managerDirectory
        )
        let result = await fixture.client.executeConfiguration(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(result.status, .succeeded, result.failure ?? "")

        let updated = try String(contentsOf: fixture.zshrcURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"eval "$(/opt/homebrew/bin/brew shellenv)""#))
        XCTAssertTrue(updated.contains("ZSH_AUTOSUGGEST_STRATEGY=(history completion)"))
        XCTAssertTrue(updated.contains("alias ll=\"ls -la\""))
        XCTAssertTrue(updated.contains(#"ZSH_THEME="agnoster""#))
        XCTAssertTrue(updated.contains("plugins=(example git)") || updated.contains("plugins=(git example)"))
        XCTAssertFalse(updated.contains("# >>> omz-manager"))

        let snapshot = try await fixture.client.loadSnapshot(managerDirectory: fixture.managerDirectory, managerAvailable: true)
        XCTAssertEqual(snapshot.currentTheme, "agnoster")
        XCTAssertEqual(Set(snapshot.activePlugins), ["git", "example"])
    }

    func testSupportsCustomThemesInOhMyZshCustomThemesDirectory() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let customThemes = fixture.homeDirectory.appending(path: ".oh-my-zsh/custom/themes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: customThemes, withIntermediateDirectories: true)
        try Data().write(to: customThemes.appending(path: "my-custom.zsh-theme"))

        let snapshot = try await fixture.client.loadSnapshot(managerDirectory: fixture.managerDirectory, managerAvailable: true)
        XCTAssertTrue(snapshot.availableThemes.contains("my-custom"))

        let plan = try await fixture.client.plan(.init(action: .switchTheme, subject: "my-custom"), managerDirectory: fixture.managerDirectory)
        XCTAssertTrue(plan.canExecute)
        let result = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(result.status, "ok")
        XCTAssertTrue(try String(contentsOf: fixture.zshrcURL, encoding: .utf8).contains(#"ZSH_THEME="my-custom""#))
    }

    func testRemovesLegacyManagedBlocksWhenUpdatingPluginsAndTheme() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let legacy = """
        export ZSH="$HOME/.oh-my-zsh"
        # >>> omz-manager theme >>>
        ZSH_THEME="robbyrussell"
        # <<< omz-manager theme <<<
        # >>> omz-manager plugins >>>
        plugins=(git)
        # <<< omz-manager plugins <<<
        source $ZSH/oh-my-zsh.sh
        """
        try Data((legacy + "\n").utf8).write(to: fixture.zshrcURL)

        let plan = try await fixture.client.planConfiguration(
            plugins: ["git", "example"],
            theme: "agnoster",
            managerDirectory: fixture.managerDirectory
        )
        let result = await fixture.client.executeConfiguration(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(result.status, .succeeded)
        let updated = try String(contentsOf: fixture.zshrcURL, encoding: .utf8)
        XCTAssertFalse(updated.contains("omz-manager"))
        XCTAssertTrue(updated.contains(#"ZSH_THEME="agnoster""#))
        XCTAssertTrue(updated.contains("plugins=(example git)") || updated.contains("plugins=(git example)"))
    }

    func testRejectsGlobWildcardInPluginCSVWithoutExpandingFiles() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        do {
            _ = try await fixture.client.plan(.init(action: .setPlugins, subject: "git,*"), managerDirectory: fixture.managerDirectory)
            XCTFail("Wildcard plugin name must be rejected")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "invalid-plugin-selection")
        }
    }

    func testSyntaxFailureRestoresExactPreviousConfigurationAndRetainsBackup() async throws {
        let fixture = try ShellManagerFixture(validateSyntax: { _, _ in 1 })
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.zshrcURL)
        let plan = try await fixture.client.plan(.init(action: .switchTheme, subject: "agnoster"), managerDirectory: fixture.managerDirectory)

        do {
            _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
            XCTFail("Syntax failure must throw")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "shell-syntax-restored")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.zshrcURL), original)
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.homeDirectory.appending(path: ".zsh/backups").path)
        XCTAssertFalse(backups.isEmpty)
    }

    func testRejectsExecutionWhenZshrcChangedAfterPlan() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.plan(.init(action: .switchTheme, subject: "agnoster"), managerDirectory: fixture.managerDirectory)
        try Data("# drift\n".utf8).append(to: fixture.zshrcURL)

        do {
            _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
            XCTFail("Stale plan must be rejected")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "plan-stale")
        }
    }

    func testBlocksSymlinkedZshrcPlan() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let target = fixture.homeDirectory.appending(path: "actual-zshrc")
        try FileManager.default.moveItem(at: fixture.zshrcURL, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.zshrcURL, withDestinationURL: target)

        let plan = try await fixture.client.plan(.init(action: .switchTheme, subject: "agnoster"), managerDirectory: fixture.managerDirectory)
        XCTAssertFalse(plan.canExecute)
        XCTAssertEqual(plan.payload.blockedReason, "zshrc-is-symlink")
    }

    // MARK: - Tidy Aligned with setup-zsh.sh

    func testTidyWritesZshenvCleansOldZshrcCompdumpRemovesStaleCachesAndMovesBackups() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }

        let oldZshrc = """
        # Zsh completion dump location
        export ZSH_COMPDUMP="$HOME/.zsh/zcompdump"
        ZSH_THEME="robbyrussell"
        plugins=(git)
        source $ZSH/oh-my-zsh.sh
        """
        try Data((oldZshrc + "\n").utf8).write(to: fixture.zshrcURL)
        let zprofile = fixture.homeDirectory.appending(path: ".zprofile")
        try Data("eval \"$(/opt/homebrew/bin/brew shellenv)\"\n".utf8).write(to: zprofile)

        let homeCompdump = fixture.homeDirectory.appending(path: ".zcompdump-host")
        let zshDir = fixture.homeDirectory.appending(path: ".zsh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: zshDir, withIntermediateDirectories: true)
        let oldZshCompdump = zshDir.appending(path: "zcompdump")
        let zshrcBackup = fixture.homeDirectory.appending(path: ".zshrc.backup-20260101")
        let zprofileBackup = fixture.homeDirectory.appending(path: ".zprofile.bak")
        try Data("dump1".utf8).write(to: homeCompdump)
        try Data("dump2".utf8).write(to: oldZshCompdump)
        try Data("old-rc".utf8).write(to: zshrcBackup)
        try Data("old-prof".utf8).write(to: zprofileBackup)

        let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        XCTAssertTrue(plan.canExecute)
        let candidatePaths = Set(plan.candidates.map { URL(filePath: $0).resolvingSymlinksInPath().path })
        XCTAssertTrue(candidatePaths.contains(homeCompdump.resolvingSymlinksInPath().path))
        XCTAssertTrue(candidatePaths.contains(oldZshCompdump.resolvingSymlinksInPath().path))
        XCTAssertTrue(candidatePaths.contains(zshrcBackup.resolvingSymlinksInPath().path))
        XCTAssertTrue(candidatePaths.contains(zprofileBackup.resolvingSymlinksInPath().path))

        let result = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(result.status, "ok")

        let zshenv = try String(contentsOf: fixture.homeDirectory.appending(path: ".zshenv"), encoding: .utf8)
        XCTAssertTrue(zshenv.contains(ShellManagerClient.compdumpComment))
        XCTAssertTrue(zshenv.contains(ShellManagerClient.compdumpSetting))

        let zshrc = try String(contentsOf: fixture.zshrcURL, encoding: .utf8)
        XCTAssertFalse(zshrc.contains("ZSH_COMPDUMP"))
        XCTAssertTrue(zshrc.contains("source $ZSH/oh-my-zsh.sh"))
        XCTAssertEqual(try String(contentsOf: zprofile, encoding: .utf8), "eval \"$(/opt/homebrew/bin/brew shellenv)\"\n")

        XCTAssertFalse(FileManager.default.fileExists(atPath: homeCompdump.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldZshCompdump.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: zshrcBackup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: zprofileBackup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/backups/.zshrc.backup-20260101").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".zsh/backups/.zprofile.bak").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.homeDirectory.appending(path: ".cache/zsh").path))
    }

    func testTidySkipsBackupCollisionWithoutOverwritingExistingBackup() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let backupDir = fixture.homeDirectory.appending(path: ".zsh/backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let existing = backupDir.appending(path: ".zshrc.backup-dup")
        let source = fixture.homeDirectory.appending(path: ".zshrc.backup-dup")
        try Data("existing".utf8).write(to: existing)
        try Data("source".utf8).write(to: source)

        let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        XCTAssertFalse(plan.candidates.contains(source.path))
        _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
    }

    func testTidyBlocksSymlinkedZshenvAndRejectsSymlinkCandidate() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let realEnv = fixture.homeDirectory.appending(path: "real-zshenv")
        try Data().write(to: realEnv)
        try FileManager.default.createSymbolicLink(at: fixture.homeDirectory.appending(path: ".zshenv"), withDestinationURL: realEnv)

        let plan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        XCTAssertFalse(plan.canExecute)
        XCTAssertEqual(plan.payload.blockedReason, "zshenv-is-symlink")

        try FileManager.default.removeItem(at: fixture.homeDirectory.appending(path: ".zshenv"))
        let outside = fixture.root.appending(path: "outside-dump")
        try Data("dump".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.homeDirectory.appending(path: ".zcompdump-link"), withDestinationURL: outside)
        do {
            _ = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
            XCTFail("Symlink tidy candidate must be rejected")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "tidy-nonregular-candidate")
        }
    }

    func testRejectsUnterminatedPluginsAndUnterminatedManagedBlockFailClosed() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let unterminatedPlugins = """
        ZSH_THEME="robbyrussell"
        plugins=(
            git
        source $ZSH/oh-my-zsh.sh
        alias keep_me="echo ok"
        """
        try Data((unterminatedPlugins + "\n").utf8).write(to: fixture.zshrcURL)
        do {
            _ = try await fixture.client.plan(.init(action: .setPlugins, subject: "git,example"), managerDirectory: fixture.managerDirectory)
            XCTFail("Unterminated plugins=( must fail closed")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "shell-init-ambiguous")
        }

        let unterminatedBlock = """
        # >>> omz-manager theme >>>
        ZSH_THEME="robbyrussell"
        source $ZSH/oh-my-zsh.sh
        """
        try Data((unterminatedBlock + "\n").utf8).write(to: fixture.zshrcURL)
        do {
            _ = try await fixture.client.plan(.init(action: .switchTheme, subject: "agnoster"), managerDirectory: fixture.managerDirectory)
            XCTFail("Unterminated managed block must fail closed")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "invalid-managed-block")
        }
    }

    func testUpdatesLastEffectiveThemeAndPluginsWithSpaceAfterEquals() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let duplicateZshrc = """
        ZSH_THEME="robbyrussell"
        ZSH_THEME="af-magic"
        plugins=(git)
        plugins= (git)
        source $ZSH/oh-my-zsh.sh
        """
        try Data((duplicateZshrc + "\n").utf8).write(to: fixture.zshrcURL)

        let plan = try await fixture.client.planConfiguration(
            plugins: ["git", "example"],
            theme: "agnoster",
            managerDirectory: fixture.managerDirectory
        )
        let result = await fixture.client.executeConfiguration(plan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(result.status, .succeeded, result.failure ?? "")

        let snapshot = try await fixture.client.loadSnapshot(managerDirectory: fixture.managerDirectory, managerAvailable: true)
        XCTAssertEqual(snapshot.currentTheme, "agnoster")
        XCTAssertEqual(Set(snapshot.activePlugins), ["git", "example"])
    }

    func testRejectsSymlinkedZshDirectoryAncestorBeforeBackupWrite() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appending(path: "outside-zsh")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.homeDirectory.appending(path: ".zsh"), withDestinationURL: outside)

        let plan = try await fixture.client.plan(.init(action: .switchTheme, subject: "agnoster"), managerDirectory: fixture.managerDirectory)
        do {
            _ = try await fixture.client.execute(plan, managerDirectory: fixture.managerDirectory)
            XCTFail("Symlinked ~/.zsh ancestor must be rejected")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "tidy-unsafe-destination")
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testTidyRejectsStalePlanAfterZshenvDriftAndSucceedsWithFreshPlan() async throws {
        let fixture = try ShellManagerFixture()
        defer { fixture.remove() }
        let dump = fixture.homeDirectory.appending(path: ".zcompdump-a")
        try Data("dump".utf8).write(to: dump)
        let stalePlan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        try Data("existing=1\n".utf8).write(to: fixture.homeDirectory.appending(path: ".zshenv"))
        do {
            _ = try await fixture.client.execute(stalePlan, managerDirectory: fixture.managerDirectory)
            XCTFail("Stale tidy plan must be rejected after .zshenv drift")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "plan-stale")
        }
        let freshPlan = try await fixture.client.plan(.init(action: .tidy, subject: "zsh-files"), managerDirectory: fixture.managerDirectory)
        XCTAssertNotEqual(stalePlan.id, freshPlan.id)
        let result = try await fixture.client.execute(freshPlan, managerDirectory: fixture.managerDirectory)
        XCTAssertEqual(result.status, "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dump.path))
    }

    // MARK: - Plugin Staging Security Boundaries

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
    }
}

private struct ShellManagerFixture {
    let root: URL
    let homeDirectory: URL
    let managerDirectory: URL
    let zshrcURL: URL
    let client: ShellManagerClient

    init(
        executionTimeout: Duration = .seconds(1_800),
        beforePluginPublication: @escaping @Sendable () async -> Void = {},
        validateSyntax: (@Sendable (URL, URL) async throws -> Int32)? = nil
    ) throws {
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
        let customPlugin = homeDirectory.appending(path: ".oh-my-zsh/custom/plugins/example", directoryHint: .isDirectory)
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
            ),
            executionTimeout: executionTimeout,
            beforePluginPublication: beforePluginPublication,
            validateSyntax: validateSyntax
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
        let service = SystemProbeService(
            runner: runner,
            installer: ManagerSnapshotInstaller(applicationSupportDirectory: root),
            nodeClient: NodeManagerClient(runner: runner, environmentResolver: resolver),
            shellClient: client,
            environmentResolver: resolver
        )
        return AppModel(
            service: service,
            operationStore: OperationStore(),
            activityStore: activityStore,
            managerSnapshot: .init(version: "fixture", location: root.path, nodeAvailable: false, homebrewAvailable: false, shellAvailable: true)
        )
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
