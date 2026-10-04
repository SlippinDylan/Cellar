import XCTest
@testable import Cellar

final class NodePackageEnvironmentTests: XCTestCase {
    func testUpdateWritesExactConfirmedScopedVersionWhenLatestChangesDuringExecution() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "@scope/example", environment: fixture.context), action: .updatePackage, managerDirectory: fixture.root)
        XCTAssertEqual(plan.payload.targetVersion, "3.0.0")
        try Data().write(to: fixture.root.appending(path: "latest-changes-during-execute"))
        let result = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
        XCTAssertEqual(result.action, NodeAction.updatePackage.rawValue)
        XCTAssertEqual(result.subject, "@scope/example")
        XCTAssertEqual(result.batchItemStatus, .succeeded)
        XCTAssertEqual(try String(contentsOf: fixture.root.appending(path: "written-version"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "3.0.0")
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        let writes = calls.split(separator: "\n").filter { $0.hasPrefix("execute|") }
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes.first?.contains("install @scope/example@3.0.0") == true)
        XCTAssertFalse(writes.first?.contains("update-latest") == true)
        XCTAssertTrue(writes.first?.contains("|1|") == true)
    }

    func testUpdateDoesNotReportSuccessWhenInstalledVersionDiffersFromConfirmedTarget() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .updatePackage, managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "wrong-installed-target"))
        let result = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
        XCTAssertEqual(result.batchItemStatus, .failed)
        XCTAssertEqual(result.exitCode, 0)
        let writes = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("execute|") }
        XCTAssertEqual(writes.count, 1)
    }

    func testUpdateVerificationReadFailureRetainsUnknownOutcomeAndActualExitStatus() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .updatePackage, managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "verification-unavailable"))
        let result = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
        XCTAssertEqual(result.batchItemStatus, .unknown)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.detail, "update-verification-unavailable")
        let calls = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "|") }
        XCTAssertEqual(calls.filter { $0[0] == "execute" }.map { $0[1] }, ["1"])
        XCTAssertEqual(calls.filter { $0[0] == "packages" }.map { $0[1] }, ["0"])
    }

    func testProviderBatchOperationsEnforcesExactScopedUpdateTargetAfterLatestChanges() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let provider = try fixture.batchProvider()
        let plan = try await provider.planNPM(.init(name: "@scope/example", environment: fixture.context), operation: .update)
        XCTAssertEqual(plan.request.action, .updatePackage)
        XCTAssertEqual(plan.exactUpdateSpec, "@scope/example@3.0.0")
        XCTAssertEqual(plan.confirmedInstallRegistry?.absoluteString, "https://scope.fixture.invalid/")
        try Data().write(to: fixture.root.appending(path: "latest-changes-during-execute"))
        let result = try await provider.executeNPM(plan, environment: fixture.context)
        XCTAssertEqual(result.action, NodeAction.updatePackage.rawValue)
        XCTAssertEqual(result.batchItemStatus, .succeeded)
        XCTAssertEqual(try String(contentsOf: fixture.root.appending(path: "written-version"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "3.0.0")
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertTrue(calls.contains("install @scope/example@3.0.0"))
        XCTAssertFalse(calls.split(separator: "\n").filter { $0.hasPrefix("execute|") }.contains { $0.contains("update-latest") })
    }
    func testUpdateBindsScopeRegistryDestinationAndTargetBeforeOpeningWriteGate() async throws {
        for changed in ["scope-registry-changed", "global-root-changed", "global-prefix-changed", "target-version-changed", "package-version-changed"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            let plan = try await fixture.client.planPackage(.init(name: "@scope/example", environment: fixture.context), action: .updatePackage, managerDirectory: fixture.root)
            XCTAssertEqual(plan.confirmedInstallRegistry?.absoluteString, "https://scope.fixture.invalid/")
            XCTAssertEqual(plan.confirmedPackageDestination?.globalRoot, "/fake")
            try Data().write(to: fixture.root.appending(path: changed))
            do {
                _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
                XCTFail("Changed update binding must refuse writes: \(changed)")
            } catch {
                guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected typed update refusal") }
                XCTAssertEqual(code, "npm-update-state-changed")
            }
            let calls = try String(contentsOf: fixture.log, encoding: .utf8)
            XCTAssertFalse(calls.contains("execute|"))
            XCTAssertFalse(calls.contains("|1|"))
        }
    }

    func testUpdateRejectsCurrentAheadAndUnknownRegistryVersions() async throws {
        for marker in ["target-current", "target-ahead", "target-unknown"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            try Data().write(to: fixture.root.appending(path: marker))
            do {
                _ = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .updatePackage, managerDirectory: fixture.root)
                XCTFail("Only behind can be updated")
            } catch {
                guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected typed version refusal") }
                XCTAssertEqual(code, "npm-update-not-behind")
            }
            let calls = try String(contentsOf: fixture.log, encoding: .utf8)
            XCTAssertFalse(calls.contains("execute|"))
            XCTAssertFalse(calls.contains("|1|"))
        }
    }

    func testUpdateKeepsOriginalPlanExpiryAfterBindingRevalidation() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .updatePackage, managerDirectory: fixture.root)
        let expired = NodeActionPlan(id: plan.id, request: plan.request, payload: plan.payload, generatedAt: Date().addingTimeInterval(-301), confirmedPackageDestination: plan.confirmedPackageDestination, confirmedInstallRegistry: plan.confirmedInstallRegistry)
        do { _ = try await fixture.client.executePackage(expired, environment: fixture.context, managerDirectory: fixture.root); XCTFail("Old update confirmation must expire") }
        catch {
            guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected expiry refusal") }
            XCTAssertEqual(code, "plan-expired")
        }
        XCTAssertFalse(try String(contentsOf: fixture.log, encoding: .utf8).contains("execute|"))
    }

    func testScopedInstallBindsActualScopeRegistryAndRejectsItsPostConfirmationChange() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "@scope/example", environment: fixture.context), action: .installPackage, managerDirectory: fixture.root)
        XCTAssertEqual(plan.confirmedInstallRegistry?.absoluteString, "https://scope.fixture.invalid/")
        try Data().write(to: fixture.root.appending(path: "scope-registry-changed"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Changed effective scope Registry must reject the confirmed install")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "npm-install-state-changed") }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }

    func testTypedRegistryReadHonorsScopeFallbackAndFailsClosedOnInvalidConfiguration() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let scoped = try await fixture.client.effectivePackageRegistry("@scope/example@latest", environment: fixture.context, managerDirectory: fixture.root)
        let unscoped = try await fixture.client.effectivePackageRegistry("example", environment: fixture.context, managerDirectory: fixture.root)
        XCTAssertEqual(scoped.absoluteString, "https://scope.fixture.invalid/")
        XCTAssertEqual(unscoped, CatalogWebsites.npmRegistry)
        try Data().write(to: fixture.root.appending(path: "scope-registry-unset"))
        let fallback = try await fixture.client.effectivePackageRegistry("@scope/example", environment: fixture.context, managerDirectory: fixture.root)
        XCTAssertEqual(fallback, CatalogWebsites.npmRegistry)
        try Data().write(to: fixture.root.appending(path: "scope-registry-invalid"))
        do { _ = try await fixture.client.effectivePackageRegistry("@scope/example", environment: fixture.context, managerDirectory: fixture.root); XCTFail("Invalid Registry must fail closed") }
        catch { XCTAssertEqual(error as? CatalogSourceError, .invalidURL) }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertEqual(calls.split(separator: "\n").filter { $0.hasPrefix("scope-config") }.count, 3)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
        XCTAssertFalse(calls.contains("/opt/homebrew/"))
    }

    @MainActor
    func testBatchKeepsBothOriginalDestinationsWhenFirstExecutionChangesGlobalRoot() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.root.appending(path: "change-root-after-first"))
        let coordinator = BatchOperationCoordinator(provider: NodeFixtureBatchProvider(fixture: fixture), operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["one", "two"].map { .npm(.init(name: $0, environment: fixture.context)) }))
        let plan = try await coordinator.prepare(intent)
        XCTAssertEqual(plan.npmBindings.map(\.destination.globalRoot), ["/fake", "/fake"])
        let before = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(before.contains("execute|"))
        let result = try await coordinator.execute(plan)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .failed])
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        let writes = calls.split(separator: "\n").filter { $0.hasPrefix("execute|") }
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes.first?.contains("install one") == true)
        XCTAssertFalse(calls.contains("|1|" + "install two"))
    }

    func testProviderBatchOperationsKeepsScopedRegistryBindingWithTemporaryManagerRoot() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let provider = try fixture.batchProvider()
        let plan = try await provider.planNPM(.init(name: "@scope/example", environment: fixture.context), operation: .install)
        XCTAssertEqual(plan.confirmedInstallRegistry, CatalogWebsites.url(host: "scope.fixture.invalid", path: "/"))
        XCTAssertEqual(plan.confirmedPackageDestination?.globalRoot, "/fake")
        let before = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(before.contains("execute|"))
        try Data().write(to: fixture.root.appending(path: "scope-registry-changed"))
        do { _ = try await provider.executeNPM(plan, environment: fixture.context); XCTFail("Provider must preserve the bound Registry") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "npm-install-state-changed") }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }
    func testInstallRefusesChangedGlobalDestinationOrRegistryBeforeWriteGate() async throws {
        for changed in ["global-prefix-changed", "global-root-changed", "registry-changed"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .installPackage, managerDirectory: fixture.root)
            try Data().write(to: fixture.root.appending(path: changed))
            do {
                _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
                XCTFail("Changed npm destination or Registry must invalidate install: \(changed)")
            } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "npm-install-state-changed") }
            let calls = try String(contentsOf: fixture.log, encoding: .utf8)
            XCTAssertFalse(calls.contains("execute|"), changed)
            XCTAssertFalse(calls.contains("|1|"), changed)
        }
    }

    func testInstallRefusesChangedInstalledStateAndKeepsOriginalExpiry() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .installPackage, managerDirectory: fixture.root)
        let expired = NodeActionPlan(id: plan.id, request: plan.request, payload: plan.payload, generatedAt: Date().addingTimeInterval(-301), confirmedPackageDestination: plan.confirmedPackageDestination, confirmedInstallRegistry: plan.confirmedInstallRegistry)
        do { _ = try await fixture.client.executePackage(expired, environment: fixture.context, managerDirectory: fixture.root); XCTFail("Expired install") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-expired") }
        try Data().write(to: fixture.root.appending(path: "package-version-changed"))
        do { _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root); XCTFail("Changed installed state") }
        catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "npm-install-state-changed") }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }
    func testUninstallRefusesChangedGlobalPrefixOrRootBeforeOpeningWriteGate() async throws {
        for changed in ["global-prefix-changed", "global-root-changed"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .uninstallPackage, managerDirectory: fixture.root)
            try Data().write(to: fixture.root.appending(path: changed))
            do {
                _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
                XCTFail("Changed global destination must invalidate confirmation: \(changed)")
            } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "npm-uninstall-state-changed") }
            let calls = try String(contentsOf: fixture.log, encoding: .utf8)
            XCTAssertFalse(calls.contains("execute|"), changed)
            XCTAssertFalse(calls.contains("|1|"), changed)
        }
    }

    func testUninstallAcceptsEquivalentCanonicalGlobalDestinations() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .uninstallPackage, managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "global-destination-alias"))
        let result = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
        XCTAssertEqual(result.status, "ok")
    }

    func testUninstallRechecksDestinationAfterItsFinalPackagePlan() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .uninstallPackage, managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "change-root-during-plan"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("The final plan must not change the confirmed destination")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "npm-uninstall-state-changed") }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }

    func testUninstallDestinationBindingPreservesOriginalPlanExpiry() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .uninstallPackage, managerDirectory: fixture.root)
        let expired = NodeActionPlan(id: plan.id, request: plan.request, payload: plan.payload,
                                     generatedAt: Date().addingTimeInterval(-301), confirmedPackageDestination: plan.confirmedPackageDestination)
        do {
            _ = try await fixture.client.executePackage(expired, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Revalidation must not extend the confirmation lifetime")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "plan-expired") }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }
    func testAbsoluteEnvironmentIdentityRejectsAnotherInstallationWithSameVersion() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let wrong = NodeEnvironmentContext(identifier: fixture.root.appending(path: "other/bin/node").path,
                                           nodeVersion: fixture.context.nodeVersion, npmVersion: fixture.context.npmVersion)
        do {
            _ = try await fixture.client.planPackage(.init(name: "example", environment: wrong), action: .uninstallPackage, managerDirectory: fixture.root)
            XCTFail("Identical versions must not replace executable identity")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "node-environment-changed") }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("plan|"))
        XCTAssertFalse(calls.contains("execute|"))
    }

    func testRuntimeUninstallRechecksConfirmedStateBeforeOpeningWriteGate() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let identity = NodeRuntimeIdentity(version: "v18.0.0", environment: fixture.context)
        let plan = try await fixture.client.planRuntimeUninstall(identity, managerDirectory: fixture.root)
        XCTAssertTrue(plan.canExecute)
        XCTAssertFalse(try String(contentsOf: fixture.log, encoding: .utf8).contains("execute|"))
        try Data().write(to: fixture.root.appending(path: "runtime-plan-changed"))
        do {
            _ = try await fixture.client.executeRuntimeUninstall(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Changed inventory must refuse the confirmed uninstall")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "node-uninstall-state-changed") }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }

    func testRuntimeUninstallPreservesProviderCurrentAndDefaultProtection() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        for version in ["v22.0.0", "v20.0.0"] {
            let plan = try await fixture.client.planRuntimeUninstall(.init(version: version, environment: fixture.context), managerDirectory: fixture.root)
            XCTAssertFalse(plan.canExecute)
            do {
                _ = try await fixture.client.executeRuntimeUninstall(plan, environment: fixture.context, managerDirectory: fixture.root)
                XCTFail("Provider-protected runtime cannot execute")
            } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "node-uninstall-state-changed") }
        }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }

    func testRuntimeUninstallUsesOneInvocationGateAfterRevalidation() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planRuntimeUninstall(.init(version: "v18.0.0", environment: fixture.context), managerDirectory: fixture.root)
        let result = try await fixture.client.executeRuntimeUninstall(plan, environment: fixture.context, managerDirectory: fixture.root)
        XCTAssertEqual(result.action, "node-uninstall")
        let calls = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "|") }
        XCTAssertEqual(calls.map { $0[0] }, ["summary", "plan", "summary", "plan", "execute"])
        XCTAssertEqual(calls.map { $0[1] }, ["0", "0", "0", "0", "1"])
    }

    func testPackageUninstallRefusesChangedConfirmedInstalledVersion() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .uninstallPackage, managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "package-version-changed"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("An installed package change invalidates uninstall confirmation")
        } catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "npm-uninstall-state-changed") }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }
    func testPackageActionUsesExplicitInstallationAndOneInvocationWriteGate() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let identity = NPMPackageIdentity(name: "example", environment: fixture.context)
        let plan = try await fixture.client.planPackage(identity, action: .installPackage, managerDirectory: fixture.root)
        let result = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)

        XCTAssertEqual(result.status, "ok")
        let calls = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n").map(String.init)
        let selectedPath = fixture.selectedBin.resolvingSymlinksInPath().path
        XCTAssertEqual(calls.count, 7)
        let fields = calls.map { $0.components(separatedBy: "|") }
        XCTAssertEqual(fields.map { $0[0] }, ["summary", "plan", "summary", "summary", "plan", "summary", "execute"])
        XCTAssertEqual(fields.map { $0[1] }, ["0", "0", "0", "0", "0", "0", "1"])
        for call in fields {
            let firstPath = try XCTUnwrap(call[2].split(separator: ":").first)
            XCTAssertEqual(URL(filePath: String(firstPath)).resolvingSymlinksInPath().path, selectedPath)
            XCTAssertFalse(call[2].contains("/opt/homebrew/"))
            XCTAssertFalse(call[2].contains("/usr/local/"))
        }
        XCTAssertFalse(calls.contains { $0.contains("v20.0.0/bin:") })
    }

    func testRemovedInstallationIsRejectedBeforeExecuteOrFallbackRefresh() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context),
                                                        action: .uninstallPackage, managerDirectory: fixture.root)
        try FileManager.default.removeItem(at: fixture.selectedBin.appending(path: "node"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Removed environment must never fall back to the default Node")
        } catch {
            guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected environment failure") }
            XCTAssertEqual(code, "node-environment-changed")
        }
        do {
            _ = try await fixture.client.loadPackageSnapshot(fixture.context, managerDirectory: fixture.root)
            XCTFail("Refresh must retain its package environment")
        } catch {}
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertEqual(calls.split(separator: "\n").count, 2)
    }

    func testChangedNPMVersionRejectsWriteBeforeOpeningGate() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context),
                                                        action: .updatePackage, managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "npm-changed"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Confirmed Node/npm context changed")
        } catch {
            guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected environment failure") }
            XCTAssertEqual(code, "node-environment-changed")
        }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
        XCTAssertEqual(calls.split(separator: "\n").count, 4)
    }

    func testNodeRemovedBeforeSummaryReturnsCannotFallBackToDefault() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context),
                                                        action: .updatePackage, managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "remove-node-during-summary"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Node removed during validation must prevent execute")
        } catch {
            guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected environment failure") }
            XCTAssertEqual(code, "node-environment-changed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selectedBin.appending(path: "node").path))
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }

    func testMissingSelectedNPMCannotUseAnotherMatchingNPM() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context),
                                                        action: .installPackage, managerDirectory: fixture.root)
        try FileManager.default.removeItem(at: fixture.selectedBin.appending(path: "npm"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Matching npm version from another installation must not be accepted")
        } catch {
            guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected environment failure") }
            XCTAssertEqual(code, "node-environment-changed")
        }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
        XCTAssertFalse(calls.contains("|1|"))
    }

    func testReportedNPMEntryOutsideSelectedInstallationIsRejected() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let plan = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context),
                                                        action: .installPackage, managerDirectory: fixture.root)
        try Data().write(to: fixture.root.appending(path: "other-npm-entry"))
        do {
            _ = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTFail("Versions cannot replace entry URL validation")
        } catch {
            guard case BridgeError.managerFailure(let code, _) = error else { return XCTFail("Expected environment failure") }
            XCTAssertEqual(code, "node-environment-changed")
        }
        let calls = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(calls.contains("execute|"))
    }
}

private struct PackageManagerFixture {
    let root: URL
    let selectedBin: URL
    let log: URL
    let client: NodeManagerClient
    let context = NodeEnvironmentContext(identifier: "nvm:v22.0.0", nodeVersion: "v22.0.0", npmVersion: "10.0.0")

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CellarNodePackageTests-\(UUID().uuidString)")
        selectedBin = root.appending(path: ".nvm/versions/node/v22.0.0/bin")
        log = root.appending(path: "calls.log")
        for version in ["v20.0.0", "v22.0.0"] {
            let bin = root.appending(path: ".nvm/versions/node/\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["node", "npm"] {
                let entry = bin.appending(path: name)
                try Data("fixture only".utf8).write(to: entry)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
            }
        }
        let alias = root.appending(path: ".nvm/alias")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try Data("v20.0.0".utf8).write(to: alias.appending(path: "default"))
        let npmScript = #"""
        #!/bin/bash
        printf '%s|%s|%s\n' 'scope-config' "$NODE_MANAGER_ALLOW_JSON_EXECUTE" "$PATH" >> '\#(log.path)'
        [ "$1 $2 $3" = 'config get @scope:registry' ] || exit 2
        [ ! -e '\#(root.path)/scope-registry-invalid' ] || { printf '%s\n' https://user:password@invalid.fixture.invalid; exit 0; }
        [ ! -e '\#(root.path)/scope-registry-unset' ] || { printf '%s\n' undefined; exit 0; }
        [ ! -e '\#(root.path)/scope-registry-changed' ] || { printf '%s\n' https://changed.fixture.invalid; exit 0; }
        printf '%s\n' https://scope.fixture.invalid
        """#
        try Data(npmScript.utf8).write(to: selectedBin.appending(path: "npm"))
        let script = #"""
        #!/bin/bash
        printf '%s|%s|%s|%s\n' "$2" "$NODE_MANAGER_ALLOW_JSON_EXECUTE" "$PATH" "$3 $4" >> '\#(log.path)'
        if [ "$2" = summary ]; then
          npm_version=10.0.0
          [ ! -e '\#(root.path)/npm-changed' ] || npm_version=11.0.0
          npm_path='\#(selectedBin.path)/npm'
          if [ ! -e "$npm_path" ] || [ -e '\#(root.path)/other-npm-entry' ]; then
            npm_path='\#(root.path)/.nvm/versions/node/v20.0.0/bin/npm'
          fi
          [ ! -e '\#(root.path)/remove-node-during-summary' ] || /bin/rm '\#(selectedBin.path)/node'
          global_prefix=/fake
          global_root=/fake
          [ ! -e '\#(root.path)/global-prefix-changed' ] || global_prefix=/other-prefix
          [ ! -e '\#(root.path)/global-root-changed' ] || global_root=/other-root
          [ ! -e '\#(root.path)/global-destination-alias' ] || { global_prefix=/fake/../fake; global_root=/fake/../fake; }
          registry=https://registry.npmjs.org
          [ ! -e '\#(root.path)/registry-changed' ] || registry=https://other.invalid
          printf '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"\#(selectedBin.path)/node","npmPath":"%s","nodeVersion":"v22.0.0","npmVersion":"%s","nvmLoaded":false,"globalPrefix":"%s","globalRoot":"%s","registry":"%s"}}\n' "$npm_path" "$npm_version" "$global_prefix" "$global_root" "$registry"
        elif [ "$2" = plan ]; then
          [ ! -e '\#(root.path)/change-root-during-plan' ] || /usr/bin/touch '\#(root.path)/global-root-changed'
          if [ "$3" = node-uninstall ]; then
            executable=true
            current=false
            default=false
            [ "$4" != v22.0.0 ] || { executable=false; current=true; }
            [ "$4" != v20.0.0 ] || { executable=false; default=true; }
            package_summary='user=1|protected=1|total=2'
            [ ! -e '\#(root.path)/runtime-plan-changed' ] || package_summary='user=2|protected=1|total=3'
            printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"node-uninstall","subject":"%s","normalizedVersion":"%s","currentVersion":"v22.0.0","defaultVersion":"v20.0.0","defaultStatus":"resolved","versionDir":"/fixture/%s","versionDirExists":true,"globalPackageSummary":"%s","executeSupported":true,"executable":%s,"protectedByCurrent":%s,"protectedByDefault":%s}}\n' "$4" "$4" "$4" "$package_summary" "$executable" "$current" "$default"
            exit 0
          fi
          installed_version=1.0.0
          [ ! -e '\#(root.path)/package-version-changed' ] || installed_version=2.0.0
          target_version=3.0.0
          [ ! -e '\#(root.path)/target-version-changed' ] || target_version=4.0.0
          [ ! -e '\#(root.path)/target-ahead' ] || target_version=0.5.0
          [ ! -e '\#(root.path)/target-current' ] || target_version=1.0.0
          [ ! -e '\#(root.path)/target-unknown' ] || target_version=git
          printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"%s","subject":"%s","packageName":"%s","installedVersion":"%s","targetVersion":"%s","executeSupported":true,"executable":true}}\n' "$3" "$4" "$4" "$installed_version" "$target_version"
        elif [ "$2" = execute ]; then
          if [ "$4" = one ] && [ -e '\#(root.path)/change-root-after-first' ]; then /usr/bin/touch '\#(root.path)/global-root-changed'; fi
          package_name="$4"
          written_version=3.0.0
          case "$4" in
            *@[0-9]*) package_name="${4%@*}"; written_version="${4##*@}" ;;
          esac
          if [ "$3" = update-latest ] && [ -e '\#(root.path)/latest-changes-during-execute' ]; then written_version=0.5.0; fi
          [ ! -e '\#(root.path)/wrong-installed-target' ] || written_version=4.0.0
          printf '%s\n' "$package_name" > '\#(root.path)/written-name'
          printf '%s\n' "$written_version" > '\#(root.path)/written-version'
          printf '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"fake","action":"%s","subject":"%s","exitCode":0,"status":"ok","logFile":"/fake/log"}}\n' "$3" "$package_name"
        elif [ "$2" = packages ]; then
          [ ! -e '\#(root.path)/verification-unavailable' ] || exit 2
          package_name=$(/bin/cat '\#(root.path)/written-name')
          written_version=$(/bin/cat '\#(root.path)/written-version')
          printf '{"ok":true,"schemaVersion":1,"command":"packages","data":{"dependencies":{"%s":{"version":"%s"}}}}\n' "$package_name" "$written_version"
        else
          exit 2
        fi
        """#
        try Data(script.utf8).write(to: root.appending(path: "main.sh"))
        client = NodeManagerClient(runner: ProcessRunner(), environmentResolver: NodeEnvironmentResolver(homeDirectory: root))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func batchProvider() throws -> ProviderBatchOperations {
        let support = root.appending(path: "support")
        let runtime = support.appending(path: "Cellar/Managers/\(ManagerSnapshotInstaller.snapshotVersion)")
        for directory in ["node-manager", "homebrew-manager", "zsh-manager"] {
            try FileManager.default.createDirectory(at: runtime.appending(path: directory), withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: root.appending(path: "main.sh"), to: runtime.appending(path: "node-manager/main.sh"))
        for entry in ["homebrew-manager/main.sh", "zsh-manager/omz-manager.sh", "zsh-manager/app-json.sh"] {
            let url = runtime.appending(path: entry)
            try Data("fixture only".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let runner = ProcessRunner()
        let service = SystemProbeService(runner: runner, installer: .init(applicationSupportDirectory: support), nodeClient: client,
                                         shellClient: .init(runner: runner), environmentResolver: .init(homeDirectory: root))
        return ProviderBatchOperations(service: service)
    }
}

private struct NodeFixtureBatchProvider: BatchOperationProviding {
    enum Unsupported: Error { case operation }
    let fixture: PackageManagerFixture
    func planNPM(_ identity: NPMPackageIdentity, operation: BatchOperation) async throws -> NodeActionPlan {
        try await fixture.client.planPackage(identity, action: operation.nodeAction, managerDirectory: fixture.root)
    }
    func executeNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult {
        try await fixture.client.executePackage(plan, environment: environment, managerDirectory: fixture.root)
    }
    func refreshNPM(_ environment: NodeEnvironmentContext) async throws -> NodeSnapshot { throw Unsupported.operation }
    func planHomebrew(_ identity: HomebrewPackageIdentity, operation: BatchOperation) async throws -> HomebrewActionPlan { throw Unsupported.operation }
    func executeHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionResult { throw Unsupported.operation }
    func refreshHomebrew() async throws -> HomebrewStatus { throw Unsupported.operation }
    func planNodeUninstall(_ identity: NodeRuntimeIdentity) async throws -> NodeActionPlan { throw Unsupported.operation }
    func executeNodeUninstall(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult { throw Unsupported.operation }
}
