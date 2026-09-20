import XCTest
@testable import Cellar

final class HomebrewClientTests: XCTestCase {
    func testLoadsStructuredSnapshotAndIgnoresUnknownJSONFields() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let snapshot = try await fixture.client.loadSnapshot()

        XCTAssertEqual(snapshot.version, "Homebrew 5.0.0")
        XCTAssertEqual(snapshot.configuration.prefix, "/opt/homebrew")
        XCTAssertEqual(snapshot.configuration.cellar, "/opt/homebrew/Cellar")
        XCTAssertEqual(snapshot.configuration.values["CPU"], "arm64")
        XCTAssertEqual(snapshot.packages.map(\.identity.name), ["acme/tools/demo", "acme/apps/sample"])
        XCTAssertEqual(snapshot.packages.first?.dependencies, ["libexample"])
        XCTAssertEqual(snapshot.outdatedPackages.map(\.identity.name), ["acme/tools/demo"])
        XCTAssertEqual(snapshot.taps.first?.name, "acme/tools")
    }

    func testSearchTreatsNoMatchesAsEmptyResults() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let results = try await fixture.client.search("missing")

        XCTAssertTrue(results.isEmpty)
    }

    func testKeepsInstalledPackagesWhenOutdatedSectionFails() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.directoryURL.appending(path: "outdated-fails"))

        let snapshot = try await fixture.client.loadSnapshot()

        XCTAssertEqual(snapshot.packages.count, 2)
        XCTAssertTrue(snapshot.outdatedPackages.isEmpty)
        XCTAssertNotNil(snapshot.sectionErrors[.outdated])
    }

    func testRejectsMismatchedFullyQualifiedPackageIdentity() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        do {
            _ = try await fixture.client.loadPackage(
                HomebrewPackageIdentity(name: "other/tools/demo", kind: .formula)
            )
            XCTFail("Expected package identity mismatch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("身份与请求不匹配"))
        }
    }

    func testDoctorReturnsTextDiagnosticsDespiteNonzeroExit() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let report = try await fixture.client.diagnose()
        let diagnostics = report.diagnostics

        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertEqual(report.command.terminationStatus, 1)
        XCTAssertTrue(report.command.standardOutput.contains("Unbrewed dylibs"))
        XCTAssertTrue(report.command.standardError.contains("Prefix has a problem"))
        XCTAssertTrue(diagnostics.contains { $0.severity == .warning && $0.message == "Warning: Unbrewed dylibs found" })
        XCTAssertTrue(diagnostics.contains { $0.severity == .warning && $0.message == "Prefix has a problem" })
    }

    func testFormulaUninstallUsesConservativeEnvironmentAndRereadsState() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planFormulaUninstall("demo")
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(plan.dependencies, ["libexample"])
        XCTAssertEqual(plan.dependents, ["consumer"])
        XCTAssertEqual(result.command.arguments, ["uninstall", "--formula", "acme/tools/demo"])
        XCTAssertEqual(result.command.terminationStatus, 0)
        XCTAssertNotNil(result.snapshot)
        XCTAssertTrue(result.succeeded)
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("uninstall --formula acme/tools/demo|1|1|1"))
        XCTAssertFalse(log.contains("--force"))
        XCTAssertFalse(log.contains("autoremove"))
    }

    func testCaskZapPlanReportsArtifactsWithoutDeletingThemDirectly() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planCaskUninstall("sample", zap: true)
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(plan.artifacts.first(where: { $0.category == .installed })?.values, ["Sample.app"])
        XCTAssertEqual(plan.artifacts.first(where: { $0.category == .zap })?.values, ["~/Library/Preferences/com.acme.sample.plist"])
        XCTAssertEqual(plan.residualPaths.map(\.artifactKind), ["trash"])
        XCTAssertEqual(result.remainingResidualPaths.count, 1)
        XCTAssertEqual(result.command.arguments, ["uninstall", "--cask", "--zap", "acme/apps/sample"])
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("uninstall --cask --zap acme/apps/sample|1|1|1"))
        XCTAssertFalse(log.contains("sudo"))
        XCTAssertFalse(log.contains("rm "))
    }

    func testInstallUpgradeUpdateAndTapActionsUseExplicitCommands() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let install = try await fixture.client.planInstall(
            HomebrewPackageIdentity(name: "newpkg", kind: .formula)
        )
        let installResult = try await fixture.client.execute(install)
        XCTAssertEqual(installResult.command.arguments, ["install", "--formula", "newpkg"])
        XCTAssertTrue(installResult.succeeded)

        let upgrade = try await fixture.client.planUpgrade([
            HomebrewPackageIdentity(name: "acme/tools/demo", kind: .formula)
        ])
        let upgradeResult = try await fixture.client.execute(upgrade)
        XCTAssertEqual(upgradeResult.command.arguments, ["upgrade", "--formula", "acme/tools/demo"])
        XCTAssertTrue(upgradeResult.succeeded)

        let updateResult = try await fixture.client.execute(await fixture.client.planUpdate())
        XCTAssertEqual(updateResult.command.arguments, ["update"])
        XCTAssertTrue(updateResult.succeeded)

        let addTap = try await fixture.client.planAddTap("newco/apps")
        let addResult = try await fixture.client.execute(addTap)
        XCTAssertEqual(addResult.command.arguments, ["tap", "newco/apps"])
        XCTAssertTrue(addResult.succeeded)

        let removeTap = try await fixture.client.planRemoveTap("newco/apps")
        let removeResult = try await fixture.client.execute(removeTap)
        XCTAssertEqual(removeResult.command.arguments, ["untap", "newco/apps"])
        XCTAssertTrue(removeResult.succeeded)
    }

    func testBatchInstallUsesOneTypedCommandAndRereadsEveryTarget() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planInstall([
            HomebrewPackageIdentity(name: "newpkg", kind: .formula),
            HomebrewPackageIdentity(name: "batchpkg", kind: .formula),
        ])
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(plan.targets.map(\.name), ["newpkg", "batchpkg"])
        XCTAssertEqual(result.command.arguments, ["install", "--formula", "newpkg", "batchpkg"])
        XCTAssertEqual(result.outcome, .succeeded)
        XCTAssertTrue(result.snapshot?.packages.contains { $0.identity.name == "newpkg" } == true)
        XCTAssertTrue(result.snapshot?.packages.contains { $0.identity.name == "batchpkg" } == true)
    }

    func testBatchInstallRejectsMixedPackageKinds() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        do {
            _ = try await fixture.client.planInstall([
                HomebrewPackageIdentity(name: "newpkg", kind: .formula),
                HomebrewPackageIdentity(name: "sample", kind: .cask),
            ])
            XCTFail("Expected mixed package kinds to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("不能混合 Formula 与 Cask"))
        }
    }

    func testBatchInstallRejectsNamesWithTheSameCanonicalIdentity() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        do {
            _ = try await fixture.client.planInstall([
                HomebrewPackageIdentity(name: "aliaspkg", kind: .formula),
                HomebrewPackageIdentity(name: "acme/tools/aliaspkg", kind: .formula),
            ])
            XCTFail("Expected canonical duplicates to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("同一个软件包"))
        }
    }

    func testBatchInstallReportsPartialWhenSuccessfulCommandDoesNotReachEveryTarget() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.directoryURL.appending(path: "partial-batch-install"))

        let plan = try await fixture.client.planInstall([
            HomebrewPackageIdentity(name: "newpkg", kind: .formula),
            HomebrewPackageIdentity(name: "batchpkg", kind: .formula),
        ])
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(result.command.terminationStatus, 0)
        XCTAssertEqual(result.outcome, .partial)
    }

    func testBatchInstallRejectsExecutionWhenAnyTargetChangedAfterPlanning() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planInstall([
            HomebrewPackageIdentity(name: "newpkg", kind: .formula),
            HomebrewPackageIdentity(name: "batchpkg", kind: .formula),
        ])
        try Data().write(to: fixture.directoryURL.appending(path: "batch-installed"))

        do {
            _ = try await fixture.client.execute(plan)
            XCTFail("Expected stale batch install plan rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("状态已经变化"))
        }
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("install --formula newpkg batchpkg"))
    }

    func testTapRemovalIsBlockedWhenInstalledPackagesBelongToTap() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planRemoveTap("acme/tools")

        XCTAssertFalse(plan.canExecute)
        XCTAssertEqual(plan.associatedPackages.map(\.name), ["acme/tools/demo"])
    }

    func testRejectsInstallWhenStateChangedAfterPlanning() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planInstall(
            HomebrewPackageIdentity(name: "newpkg", kind: .formula)
        )
        try Data().write(to: fixture.directoryURL.appending(path: "new-installed"))

        do {
            _ = try await fixture.client.execute(plan)
            XCTFail("Expected stale install plan rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("状态已经变化"))
        }
        let log = try String(contentsOf: fixture.logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("install --formula newpkg"))
    }

    func testReportsPartialWhenCommandFailsAfterChangingState() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.directoryURL.appending(path: "uninstall-reports-failure"))

        let plan = try await fixture.client.planFormulaUninstall("demo")
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(result.command.terminationStatus, 1)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertNotNil(result.snapshot)
    }

    func testReportsUnknownStateWhenPostflightRefreshFails() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planFormulaUninstall("demo")
        try Data().write(to: fixture.directoryURL.appending(path: "postflight-fails"))
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(result.command.terminationStatus, 0)
        XCTAssertEqual(result.outcome, .stateUnknown)
        XCTAssertNil(result.snapshot)
        XCTAssertNotNil(result.postflightError)
    }

    func testReportsUnknownStateWhenPostflightPackageSectionFails() async throws {
        let fixture = try FakeBrewFixture()
        defer { fixture.remove() }

        let plan = try await fixture.client.planFormulaUninstall("demo")
        try Data().write(to: fixture.directoryURL.appending(path: "postflight-packages-fail"))
        let result = try await fixture.client.execute(plan)

        XCTAssertEqual(result.command.terminationStatus, 0)
        XCTAssertEqual(result.outcome, .stateUnknown)
        XCTAssertNotNil(result.snapshot)
        XCTAssertNotNil(result.snapshot?.sectionErrors[.packages])
    }
}

private struct FakeBrewFixture {
    let directoryURL: URL
    let brewURL: URL
    let logURL: URL
    let client: HomebrewClient

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "CellarHomebrewClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let preferences = directoryURL.appending(path: "Library/Preferences", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: preferences.appending(path: "com.acme.sample.plist"))
        brewURL = directoryURL.appending(path: "bin/brew")
        logURL = directoryURL.appending(path: "commands.log")
        try FileManager.default.createDirectory(at: brewURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let script = #"""
        #!/bin/bash
        set -u
        log_path='\#(logURL.path)'
        state_dir='\#(directoryURL.path)'
        printf '%s|%s|%s|%s\n' "$*" "${HOMEBREW_NO_AUTO_UPDATE:-}" "${HOMEBREW_NO_AUTOREMOVE:-}" "${HOMEBREW_NO_INSTALL_CLEANUP:-}" >> "$log_path"

        case "$*" in
          "--version")
            if [ -f "$state_dir/postflight-fails" ] && [ -f "$state_dir/formula-removed" ]; then
              printf '%s\n' 'postflight unavailable' >&2
              exit 1
            fi
            printf '%s\n' 'Homebrew 5.0.0' 'Homebrew/homebrew-core (git revision test)'
            ;;
          "-p") printf '%s\n' '/Library/Developer/CommandLineTools' ;;
          "--prefix") printf '%s\n' '/opt/homebrew' ;;
          "--repository") printf '%s\n' '/opt/homebrew' ;;
          "--cache") printf '%s\n' '/tmp/homebrew-cache' ;;
          "--cellar") printf '%s\n' '/opt/homebrew/Cellar' ;;
          "config") printf '%s\n' 'HOMEBREW_VERSION: 5.0.0' 'CPU: arm64' ;;
          "info --json=v2 --installed")
            if [ -f "$state_dir/postflight-packages-fail" ] && [ -f "$state_dir/formula-removed" ]; then
              printf '%s\n' 'installed package query unavailable' >&2
              exit 1
            fi
            formula='{"name":"demo","full_name":"acme/tools/demo","tap":"acme/tools","desc":"Demo formula","homepage":"https://example.test/demo","versions":{"stable":"2.0.0","head":null,"bottle":true},"installed":[{"version":"1.0.0","future":"ignored"}],"dependencies":["libexample"],"pinned":false,"deprecated":false,"disabled":false,"future":{"nested":true}}'
            cask='{"token":"sample","full_token":"acme/apps/sample","tap":"acme/apps","name":["Sample"],"desc":"Sample cask","homepage":"https://example.test/sample","version":"3.0","installed":"3.0","outdated":false,"artifacts":[{"app":["Sample.app"]},{"zap":[{"trash":["~/Library/Preferences/com.acme.sample.plist"]}]}],"future":42}'
            [ -f "$state_dir/formula-removed" ] && formula=''
            [ -f "$state_dir/cask-removed" ] && cask=''
            new_formula=''
            [ -f "$state_dir/new-installed" ] && new_formula='{"name":"newpkg","full_name":"newpkg","tap":"homebrew/core","desc":"New formula","homepage":null,"versions":{"stable":"1.0.0","head":null},"installed":[{"version":"1.0.0"}],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}'
            batch_formula=''
            [ -f "$state_dir/batch-installed" ] && batch_formula='{"name":"batchpkg","full_name":"batchpkg","tap":"homebrew/core","desc":"Batch formula","homepage":null,"versions":{"stable":"2.0.0","head":null},"installed":[{"version":"2.0.0"}],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}'
            formula_list="$formula"
            for candidate in "$new_formula" "$batch_formula"; do
              if [ -n "$formula_list" ] && [ -n "$candidate" ]; then
                formula_list="$formula_list,$candidate"
              elif [ -n "$candidate" ]; then
                formula_list="$candidate"
              fi
            done
            printf '{"formulae":[%s],"casks":[%s],"future":true}\n' "$formula_list" "$cask"
            ;;
          "outdated --json=v2")
            if [ -f "$state_dir/outdated-fails" ]; then
              printf '%s\n' 'outdated unavailable' >&2
              exit 1
            elif [ -f "$state_dir/formula-removed" ] || [ -f "$state_dir/formula-upgraded" ]; then
              printf '%s\n' '{"formulae":[],"casks":[]}'
            else
              printf '%s\n' '{"formulae":[{"name":"acme/tools/demo","installed_versions":["1.0.0"],"current_version":"2.0.0","pinned":false,"pinned_version":null}],"casks":[]}'
            fi
            ;;
          "tap-info --installed --json=v1")
            extra_tap=''
            if [ -f "$state_dir/tap-added" ] && [ ! -f "$state_dir/tap-removed" ]; then
              extra_tap=',{"name":"newco/apps","path":"/opt/homebrew/Library/Taps/newco/homebrew-apps","remote":"https://github.com/newco/homebrew-apps","official":false,"trusted":false,"formula_names":[],"cask_tokens":[]}'
            fi
            printf '[{"name":"acme/tools","path":"/opt/homebrew/Library/Taps/acme/homebrew-tools","remote":"https://github.com/acme/homebrew-tools","official":false,"trusted":false,"formula_names":["acme/tools/demo"],"cask_tokens":[],"future":"ignored"}%s]\n' "$extra_tap"
            ;;
          "search --formula -- missing"|"search --cask -- missing")
            printf '%s\n' 'No formulae or casks found for "missing".' >&2
            exit 1
            ;;
          "doctor")
            printf '%s\n' 'Warning: Unbrewed dylibs found'
            printf '%s\n' 'Prefix has a problem' >&2
            exit 1
            ;;
          "info --json=v2 --formula demo"|"info --json=v2 --formula acme/tools/demo")
            printf '%s\n' '{"formulae":[{"name":"demo","full_name":"acme/tools/demo","tap":"acme/tools","desc":"Demo formula","homepage":null,"versions":{"stable":"2.0.0","head":null},"installed":[{"version":"1.0.0"}],"dependencies":["libexample"],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}'
            ;;
          "info --json=v2 --formula other/tools/demo")
            printf '%s\n' '{"formulae":[{"name":"demo","full_name":"acme/tools/demo","tap":"acme/tools","desc":"Demo formula","homepage":null,"versions":{"stable":"2.0.0","head":null},"installed":[],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}'
            ;;
          "info --json=v2 --formula newpkg")
            installed='[]'
            [ -f "$state_dir/new-installed" ] && installed='[{"version":"1.0.0"}]'
            printf '{"formulae":[{"name":"newpkg","full_name":"newpkg","tap":"homebrew/core","desc":"New formula","homepage":null,"versions":{"stable":"1.0.0","head":null},"installed":%s,"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}\n' "$installed"
            ;;
          "info --json=v2 --formula batchpkg")
            installed='[]'
            [ -f "$state_dir/batch-installed" ] && installed='[{"version":"2.0.0"}]'
            printf '{"formulae":[{"name":"batchpkg","full_name":"batchpkg","tap":"homebrew/core","desc":"Batch formula","homepage":null,"versions":{"stable":"2.0.0","head":null},"installed":%s,"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}\n' "$installed"
            ;;
          "info --json=v2 --formula aliaspkg"|"info --json=v2 --formula acme/tools/aliaspkg")
            printf '%s\n' '{"formulae":[{"name":"aliaspkg","full_name":"acme/tools/aliaspkg","tap":"acme/tools","desc":"Alias formula","homepage":null,"versions":{"stable":"1.0.0","head":null},"installed":[],"dependencies":[],"pinned":false,"deprecated":false,"disabled":false}],"casks":[]}'
            ;;
          "uses --installed --formula acme/tools/demo") printf '%s\n' 'consumer' ;;
          "info --json=v2 --cask sample"|"info --json=v2 --cask acme/apps/sample")
            printf '%s\n' '{"formulae":[],"casks":[{"token":"sample","full_token":"acme/apps/sample","tap":"acme/apps","name":["Sample"],"desc":null,"homepage":null,"version":"3.0","installed":"3.0","outdated":false,"artifacts":[{"app":["Sample.app"]},{"zap":[{"trash":["~/Library/Preferences/com.acme.sample.plist"]}]}]}]}'
            ;;
          "uninstall --formula acme/tools/demo")
            touch "$state_dir/formula-removed"
            printf '%s\n' 'completed'
            [ ! -f "$state_dir/uninstall-reports-failure" ] || exit 1
            ;;
          "uninstall --cask --zap acme/apps/sample")
            touch "$state_dir/cask-removed"
            printf '%s\n' 'completed'
            ;;
          "install --formula newpkg")
            touch "$state_dir/new-installed"
            printf '%s\n' 'installed'
            ;;
          "install --formula newpkg batchpkg")
            touch "$state_dir/new-installed"
            [ -f "$state_dir/partial-batch-install" ] || touch "$state_dir/batch-installed"
            printf '%s\n' 'installed batch'
            ;;
          "upgrade --formula acme/tools/demo")
            touch "$state_dir/formula-upgraded"
            printf '%s\n' 'upgraded'
            ;;
          "update") printf '%s\n' 'updated' ;;
          "tap newco/apps")
            touch "$state_dir/tap-added"
            printf '%s\n' 'tapped'
            ;;
          "untap newco/apps")
            touch "$state_dir/tap-removed"
            printf '%s\n' 'untapped'
            ;;
          *)
            printf 'unexpected arguments: %s\n' "$*" >&2
            exit 64
            ;;
        esac
        """#
        try Data(script.utf8).write(to: brewURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brewURL.path)
        client = HomebrewClient(
            brewURL: brewURL,
            runner: ProcessRunner(),
            homeDirectoryURL: directoryURL,
            temporaryDirectoryURL: directoryURL,
            userName: "cellar-test",
            developerDirectoryProbeURL: brewURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
