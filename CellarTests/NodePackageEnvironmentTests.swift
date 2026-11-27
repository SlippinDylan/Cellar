import XCTest
@testable import Cellar

final class NodePackageEnvironmentTests: XCTestCase {
    @MainActor
    func testActualProviderRunsNPMSelfLastAndReconcilesChangedNPMVersion() async throws {
        for selfSpec in ["npm", "npm@11.0.0"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            let coordinator = BatchOperationCoordinator(provider: try fixture.batchProvider(), operationStore: OperationStore())
            let operation: BatchOperation = selfSpec == "npm" ? .update : .install
            let intent = try XCTUnwrap(BatchIntent(operation: operation, items: [selfSpec, "one", "two"].map { .npm(.init(name: $0, environment: fixture.context)) }))
            let confirmed = try await coordinator.prepare(intent)
            XCTAssertEqual(confirmed.intent.items.map(\.displayIdentifier), ["one", "two", selfSpec])
            let result = try await coordinator.execute(confirmed)
            XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .succeeded, .succeeded])
            XCTAssertEqual(result.outcome.itemOutcomes.map(\.item), confirmed.intent.items)
            XCTAssertEqual(result.refreshStatus, .succeeded)
            guard case .npm(let snapshot) = result.refreshedState else { return XCTFail("Expected final npm snapshot") }
            XCTAssertEqual(snapshot.summary.npmVersion, "11.0.0")
            let calls = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n")
            let selfPlans = calls.filter { $0.hasPrefix("plan|") && $0.contains(" npm") }
            XCTAssertEqual(selfPlans.count, 3)
            XCTAssertTrue(selfPlans.allSatisfy { $0.hasSuffix("\(operation.nodeAction.rawValue) \(selfSpec)") })
            let writes = calls.filter { $0.hasPrefix("execute|") }
            XCTAssertEqual(writes.count, 3)
            XCTAssertTrue(writes[0].hasSuffix("install one@3.0.0"))
            XCTAssertTrue(writes[1].hasSuffix("install two@3.0.0"))
            XCTAssertTrue(writes[2].hasSuffix("install npm@11.0.0"))
        }
    }

    @MainActor
    func testNPMSelfFailureKeepsEarlierWritesAndFinalReconciliation() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.root.appending(path: "npm-self-fails"))
        let coordinator = BatchOperationCoordinator(provider: try fixture.batchProvider(), operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .update, items: ["npm", "one"].map { .npm(.init(name: $0, environment: fixture.context)) }))
        let result = try await coordinator.execute(coordinator.prepare(intent))
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .failed])
        XCTAssertEqual(result.outcome.status, .partiallySucceeded)
        XCTAssertEqual(result.refreshStatus, .succeeded)
    }

    func testProviderRenewsAgedInstallAndUpdateWithExactBindings() async throws {
        for operation: BatchOperation in [.install, .update] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            let provider = try fixture.batchProvider()
            let original = try await provider.planNPM(.init(name: "example", environment: fixture.context), operation: operation)
            let aged = NodeActionPlan(id: original.id, request: original.request, payload: original.payload,
                generatedAt: Date().addingTimeInterval(-601), confirmedPackageDestination: original.confirmedPackageDestination,
                confirmedInstallRegistry: original.confirmedInstallRegistry)
            let renewed = try await provider.renewNPM(aged, environment: fixture.context)
            let fresh = try XCTUnwrap(renewed)
            XCTAssertLessThan(Date().timeIntervalSince(fresh.generatedAt), 300)
            XCTAssertEqual(fresh.confirmedPackageDestination, aged.confirmedPackageDestination)
            let result = try await provider.executeNPM(fresh, environment: fixture.context)
            XCTAssertEqual(result.batchItemStatus, .succeeded)
            XCTAssertTrue(try String(contentsOf: fixture.log, encoding: .utf8).contains("install example@3.0.0"))
        }
    }

    func testBatchRenewalRefusesChangedTargetRegistryDestinationAndEnvironment() async throws {
        for marker in ["target-version-changed", "scope-registry-changed", "global-prefix-changed", "global-root-changed", "npm-changed", "other-npm-entry", "package-version-changed"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            let provider = try fixture.batchProvider()
            let confirmed = try await provider.planNPM(.init(name: "@scope/example", environment: fixture.context), operation: .update)
            try Data().write(to: fixture.root.appending(path: marker))
            do { _ = try await provider.renewNPM(confirmed, environment: fixture.context); XCTFail("Changed binding: \(marker)") }
            catch { XCTAssertEqual(ActivityItemReason(error: error), .stateChanged) }
            XCTAssertFalse(try String(contentsOf: fixture.log, encoding: .utf8).contains("execute|"))
        }
    }

    func testBatchRenewalRefusesUnknownConfirmedIdentityOrVersion() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let original = try await fixture.client.planPackage(.init(name: "example", environment: fixture.context), action: .installPackage, managerDirectory: fixture.root)
        for payloadJSON in [
            #"{"action":"install","packageName":"other","installedVersion":"3.0.0","targetVersion":"3.0.0"}"#,
            #"{"action":"install","packageName":"example","installedVersion":"git","targetVersion":"git"}"#
        ] {
            let payload = try JSONDecoder().decode(NodeActionPlanPayload.self, from: Data(payloadJSON.utf8))
            let invalid = NodeActionPlan(id: UUID(), request: original.request, payload: payload, generatedAt: original.generatedAt,
                confirmedPackageDestination: original.confirmedPackageDestination, confirmedInstallRegistry: original.confirmedInstallRegistry)
            do { _ = try await fixture.client.renewBatchPackagePlan(invalid, environment: fixture.context, managerDirectory: fixture.root); XCTFail("Unknown confirmation must not skip or write") }
            catch { XCTAssertEqual(ActivityItemReason(error: error), .stateChanged) }
        }
        XCTAssertFalse(try String(contentsOf: fixture.log, encoding: .utf8).contains("execute|"))
    }

    func testBatchRenewalSkipsOnlyExactInstalledTarget() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let provider = try fixture.batchProvider()
        let confirmed = try await provider.planNPM(.init(name: "example", environment: fixture.context), operation: .update)
        try Data().write(to: fixture.root.appending(path: "target-already-installed"))
        let renewed = try await provider.renewNPM(confirmed, environment: fixture.context)
        XCTAssertNil(renewed)
        XCTAssertFalse(try String(contentsOf: fixture.log, encoding: .utf8).contains("execute|"))
    }

    func testOrdinaryInstallPinsConfirmedVersionWhenLatestOrCustomTagMoves() async throws {
        for name in ["example", "example@next", "@scope/example", "@scope/example@next"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            let plan = try await fixture.client.planPackage(.init(name: name, environment: fixture.context), action: .installPackage, managerDirectory: fixture.root)
            try Data().write(to: fixture.root.appending(path: "latest-changes-during-execute"))
            let result = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTAssertEqual(result.batchItemStatus, .succeeded)
            XCTAssertEqual(try String(contentsOf: fixture.root.appending(path: "written-version"), encoding: .utf8), "3.0.0\n")
            let writes = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("execute|") }
            XCTAssertEqual(writes.count, 1)
            XCTAssertTrue(writes[0].hasSuffix("install \(try XCTUnwrap(plan.payload.packageName))@3.0.0"))
        }
    }

    func testOrdinaryInstallVerifiesExactTargetOrReportsUnknown() async throws {
        for marker in ["wrong-installed-target", "verification-unavailable"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            let plan = try await fixture.client.planPackage(.init(name: "@scope/example@next", environment: fixture.context), action: .installPackage, managerDirectory: fixture.root)
            try Data().write(to: fixture.root.appending(path: marker))
            let result = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)
            XCTAssertEqual(result.batchItemStatus, marker == "wrong-installed-target" ? .failed : .unknown)
        }
    }

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
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.unknown, .failed])
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
        XCTAssertEqual(try String(contentsOf: fixture.root.appending(path: ".nvm/alias/default"), encoding: .utf8), "v20.0.0")
        XCTAssertEqual(fixture.context.nodeVersion, "v22.0.0", "The Bridge explicit target remains independent of the current default")
        let identity = NPMPackageIdentity(name: "example", environment: fixture.context)
        let plan = try await fixture.client.planPackage(identity, action: .installPackage, managerDirectory: fixture.root)
        let result = try await fixture.client.executePackage(plan, environment: fixture.context, managerDirectory: fixture.root)

        XCTAssertEqual(result.status, "ok")
        let calls = try String(contentsOf: fixture.log, encoding: .utf8).split(separator: "\n").map(String.init)
        let selectedPath = fixture.selectedBin.resolvingSymlinksInPath().path
        XCTAssertEqual(calls.count, 9)
        let fields = calls.map { $0.components(separatedBy: "|") }
        XCTAssertEqual(fields.map { $0[0] }, ["summary", "plan", "summary", "summary", "plan", "summary", "execute", "summary", "packages"])
        XCTAssertEqual(fields.map { $0[1] }, ["0", "0", "0", "0", "0", "0", "1", "0", "0"])
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
          [ ! -e '\#(root.path)/npm-self-updated' ] || npm_version=11.0.0
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
          [ ! -e '\#(root.path)/target-already-installed' ] || installed_version=3.0.0
          target_version=3.0.0
          [ ! -e '\#(root.path)/target-version-changed' ] || target_version=4.0.0
          [ ! -e '\#(root.path)/target-ahead' ] || target_version=0.5.0
          [ ! -e '\#(root.path)/target-current' ] || target_version=1.0.0
          [ ! -e '\#(root.path)/target-unknown' ] || target_version=git
          package_name="$4"
          case "$4" in *@next|*@latest|*@[0-9]*) package_name="${4%@*}" ;; esac
          if [ "$package_name" = npm ]; then target_version=11.0.0; installed_version=10.0.0; fi
          printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"%s","subject":"%s","packageName":"%s","installedVersion":"%s","targetVersion":"%s","executeSupported":true,"executable":true}}\n' "$3" "$4" "$package_name" "$installed_version" "$target_version"
        elif [ "$2" = execute ]; then
          if [ "$4" = npm@11.0.0 ]; then
            if [ -e '\#(root.path)/npm-self-fails' ]; then
              printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"fake","action":"install","subject":"npm","exitCode":1,"status":"failed","logFile":"/fake/log"}}'
              exit 0
            fi
            /usr/bin/touch '\#(root.path)/npm-self-updated'
          fi
          if [ "$4" = one ] || [ "$4" = one@3.0.0 ]; then
            [ ! -e '\#(root.path)/change-root-after-first' ] || /usr/bin/touch '\#(root.path)/global-root-changed'
          fi
          package_name="$4"
          written_version=3.0.0
          case "$4" in
            *@[0-9]*) package_name="${4%@*}"; written_version="${4##*@}" ;;
          esac
          case "$4" in
            *@[0-9]*) ;;
            *) [ ! -e '\#(root.path)/latest-changes-during-execute' ] || written_version=0.5.0 ;;
          esac
          [ ! -e '\#(root.path)/wrong-installed-target' ] || written_version=4.0.0
          printf '%s\n' "$package_name" > '\#(root.path)/written-name'
          printf '%s\n' "$written_version" > '\#(root.path)/written-version'
          printf '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"fake","action":"%s","subject":"%s","exitCode":0,"status":"ok","logFile":"/fake/log"}}\n' "$3" "$package_name"
        elif [ "$2" = packages ]; then
          [ ! -e '\#(root.path)/verification-unavailable' ] || exit 2
          package_name=$(/bin/cat '\#(root.path)/written-name')
          written_version=$(/bin/cat '\#(root.path)/written-version')
          printf '{"ok":true,"schemaVersion":1,"command":"packages","data":{"dependencies":{"%s":{"version":"%s"}}}}\n' "$package_name" "$written_version"
        elif [ "$2" = config ]; then
          printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"config","data":{"registry":"https://registry.npmjs.org","cache":"/fake/cache","prefix":"/fake","userRegistry":"","projectRegistry":"","globalRegistry":""}}'
        elif [ "$2" = outdated ]; then
          printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"outdated","data":{}}'
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
    func renewHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionPlan? { throw Unsupported.operation }
    func renewNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeActionPlan? {
        try await fixture.client.renewBatchPackagePlan(plan, environment: environment, managerDirectory: fixture.root)
    }
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

extension NodePackageEnvironmentTests {
    @MainActor
    func testRealInstallationCapabilityControlsDirectBatchAndDiscoverWithoutHidingReads() async throws {
        let fixture = try PackageManagerFixture()
        defer { fixture.remove() }
        let service = try fixture.batchProvider().service
        let managers = try await service.installManagers()
        let model = AppModel(service: service, operationStore: OperationStore(), managerSnapshot: managers)
        let resolver = NodeEnvironmentResolver(homeDirectory: fixture.root)
        let summary: NodeSummary = try await fixture.client.request("summary", managerDirectory: fixture.root, environment: resolver.environment(preferredNodeVersion: "v22.0.0"))
        let configuration = try JSONDecoder().decode(NodeConfiguration.self, from: Data(#"{"registry":"https://registry.npmjs.org/","cache":"/fake/cache","prefix":"/fake","userRegistry":"","projectRegistry":"","globalRegistry":""}"#.utf8))
        func snapshot(_ summary: NodeSummary) -> NodeSnapshot {
            .init(summary: summary, configuration: configuration, packages: [.init(name: "example", installedVersion: "1.0.0", wantedVersion: "2.0.0", latestVersion: "3.0.0")],
                  installations: resolver.installations(preferredNodeVersion: "v22.0.0"), managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil,
                  packageEnvironment: NodeEnvironmentResolver.packageInstallation(summary: summary, installations: resolver.installations()).map { _ in LibraryCatalog.context(summary) })
        }
        XCTAssertFalse(summary.nvmLoaded)
        let supported = snapshot(summary)
        let environment = LibraryCatalog.context(summary)
        XCTAssertNotNil(NodeEnvironmentResolver.packageInstallation(summary: summary, installations: supported.installations))
        model.applyNodeReadResult(.success(supported))
        XCTAssertTrue(model.canMutatePackages(in: .npm(environment)))
        XCTAssertNotNil(model.discoverContext.npm)
        await model.prepareNodeAction(.init(action: .updatePackage, subject: "example"))
        let direct = try XCTUnwrap(model.nodePlan)
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: [.npm(.init(name: "example", environment: environment))]))
        let batch = try await model.prepareBatch(intent)
        let detected = fixture.root.appending(path: "detected/bin")
        try FileManager.default.createDirectory(at: detected, withIntermediateDirectories: true)
        for entry in ["node", "npm"] {
            let file = detected.appending(path: entry)
            try Data("#!/bin/sh\nexit 97\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let other = NodeSummary(nodePath: detected.appending(path: "node").path, npmPath: detected.appending(path: "npm").path,
                                nodeVersion: summary.nodeVersion, npmVersion: summary.npmVersion, nvmLoaded: true,
                                globalPrefix: summary.globalPrefix, globalRoot: summary.globalRoot, registry: summary.registry)
        model.applyNodeReadResult(.success(snapshot(other)))
        XCTAssertEqual(model.node?.packages.count, 1)
        XCTAssertNil(model.nodePackageEnvironment)
        XCTAssertNil(model.discoverContext.npm)
        XCTAssertTrue(model.discoverContext.nodeAvailable)
        XCTAssertFalse(model.canMutatePackages(in: .npm(environment)))
        XCTAssertTrue(model.canMutatePackages(in: .nodeRuntime(environment)))
        await model.executeNodePlan(confirmed: direct)
        XCTAssertNil(model.nodeActionResult)
        do { _ = try await model.executeBatch(batch); XCTFail("Changed package context must refuse confirmed batch") }
        catch BatchOperationError.reconciliationUnavailable {}
        for operation in [BatchOperation.install, .update, .uninstall] {
            let rejected = try XCTUnwrap(BatchIntent(operation: operation, items: intent.items))
            do { _ = try await model.prepareBatch(rejected); XCTFail("Unsupported package context must refuse \(operation)") }
            catch BatchOperationError.reconciliationUnavailable {}
        }
        for action in [NodeAction.installPackage, .updatePackage, .uninstallPackage] {
            await model.prepareNodeAction(.init(action: action, subject: "example"))
            XCTAssertNil(model.nodePlan)
        }
        XCTAssertFalse(try String(contentsOf: fixture.log, encoding: .utf8).contains("execute|"))
        model.applyNodeReadResult(.success(supported))
        model.applyNodeReadResult(.failure(BridgeError.invalidOutput("fixture failed read")))
        XCTAssertNil(model.discoverContext.npm)
        XCTAssertFalse(model.canMutatePackages(in: .npm(environment)))
        XCTAssertEqual(model.node?.packages.count, 1)
    }

    func testCapabilityRejectsMissingOrEscapingNPMAndSameVersionForeignNode() async throws {
        for variant in ["npm-missing", "npm-escape", "foreign-node"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            let resolver = NodeEnvironmentResolver(homeDirectory: fixture.root)
            let summary: NodeSummary = try await fixture.client.request("summary", managerDirectory: fixture.root, environment: resolver.environment(preferredNodeVersion: "v22.0.0"))
            XCTAssertNotNil(NodeEnvironmentResolver.packageInstallation(summary: summary, installations: resolver.installations()))
            if variant == "foreign-node" {
                let foreign = NodeSummary(nodePath: fixture.root.appending(path: ".nvm/versions/node/v20.0.0/bin/node").path,
                                          npmPath: summary.npmPath, nodeVersion: summary.nodeVersion, npmVersion: summary.npmVersion,
                                          nvmLoaded: true, globalPrefix: summary.globalPrefix, globalRoot: summary.globalRoot, registry: summary.registry)
                XCTAssertNil(NodeEnvironmentResolver.packageInstallation(summary: foreign, installations: resolver.installations()))
            } else {
                let npm = fixture.selectedBin.appending(path: "npm")
                try FileManager.default.removeItem(at: npm)
                if variant == "npm-escape" {
                    try FileManager.default.createSymbolicLink(at: npm, withDestinationURL: fixture.root.appending(path: ".nvm/versions/node/v20.0.0/bin/npm"))
                }
                XCTAssertNil(NodeEnvironmentResolver.packageInstallation(summary: summary, installations: resolver.installations()))
                do { _ = try await fixture.client.planPackage(.init(name: "example", environment: LibraryCatalog.context(summary)), action: .installPackage, managerDirectory: fixture.root); XCTFail("Unsupported installation must refuse") }
                catch BridgeError.managerFailure(let code, _) { XCTAssertEqual(code, "node-environment-changed") }
            }
        }
    }
}

extension NodePackageEnvironmentTests {
    func testSnapshotBoundaryClassifiesActualEntriesAndPreservesCapabilityDuringEnrichment() async throws {
        for variant in ["supported", "npm-missing", "npm-escape", "foreign-node"] {
            let fixture = try PackageManagerFixture()
            defer { fixture.remove() }
            try Data("example\n".utf8).write(to: fixture.root.appending(path: "written-name"))
            try Data("1.0.0\n".utf8).write(to: fixture.root.appending(path: "written-version"))
            if variant == "npm-missing" { try FileManager.default.removeItem(at: fixture.selectedBin.appending(path: "npm")) }
            if variant == "npm-escape" || variant == "foreign-node" {
                let name = variant == "npm-escape" ? "npm" : "node"
                let entry = fixture.selectedBin.appending(path: name)
                try FileManager.default.removeItem(at: entry)
                try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: fixture.root.appending(path: ".nvm/versions/node/v20.0.0/bin/\(name)"))
            }
            let snapshot = try await fixture.client.loadSnapshot(managerDirectory: fixture.root, preferredNodeVersion: "v22.0.0")
            XCTAssertFalse(snapshot.summary.nvmLoaded)
            XCTAssertEqual(snapshot.packageEnvironment != nil, variant == "supported", variant)
            let enriched = snapshot.replacingOutdated(packages: ["example": .init(current: "1.0.0", wanted: "2.0.0", latest: "2.0.0")], error: "fixture partial read")
            XCTAssertEqual(enriched.packageEnvironment, snapshot.packageEnvironment)
            let retained = enriched.retainingKnownOutdated(from: snapshot)
            XCTAssertEqual(retained.packageEnvironment, snapshot.packageEnvironment)
        }
    }

    @MainActor
    func testApprovedHomebrewPrefixProducesPackageEnvironmentAndSupportsPackageFlow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarHomebrewNodeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "opt/homebrew", directoryHint: .isDirectory)
        let bin = prefix.appending(path: "bin", directoryHint: .isDirectory)
        let cellarBin = prefix.appending(path: "Cellar/node/22.14.0/bin", directoryHint: .isDirectory)
        let npmBin = prefix.appending(path: "lib/node_modules/npm/bin", directoryHint: .isDirectory)
        for dir in [bin, cellarBin, npmBin] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let realNode = cellarBin.appending(path: "node")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: realNode)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realNode.path)

        let npmCLI = npmBin.appending(path: "npm-cli.js")
        let npmScript = #"""
        #!/bin/bash
        [ "$1 $2 $3" = 'config get @scope:registry' ] || exit 2
        printf '%s\n' https://scope.fixture.invalid
        """#
        try Data(npmScript.utf8).write(to: npmCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npmCLI.path)

        try FileManager.default.createSymbolicLink(at: cellarBin.appending(path: "npm"), withDestinationURL: npmCLI)
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "node"), withDestinationURL: realNode)
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "npm"), withDestinationURL: cellarBin.appending(path: "npm"))

        let managerScript = #"""
        #!/bin/bash
        if [ "$2" = summary ]; then
          printf '{"ok":true,"schemaVersion":1,"command":"summary","data":{"nodePath":"\#(bin.path)/node","npmPath":"\#(bin.path)/npm","nodeVersion":"v22.14.0","npmVersion":"10.9.2","nvmLoaded":false,"globalPrefix":"\#(prefix.path)","globalRoot":"\#(prefix.path)/lib/node_modules","registry":"https://registry.npmjs.org/"}}\n'
        elif [ "$2" = packages ]; then
          if [ -e '\#(root.path)/installed-example' ]; then
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"packages","data":{"dependencies":{"example":{"version":"3.0.0"}}}}'
          else
            printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"packages","data":{"dependencies":{}}}'
          fi
        elif [ "$2" = config ]; then
          printf '{"ok":true,"schemaVersion":1,"command":"config","data":{"registry":"https://registry.npmjs.org/","cache":"/fake/cache","prefix":"\#(prefix.path)","userRegistry":"","projectRegistry":"","globalRegistry":""}}\n'
        elif [ "$2" = outdated ]; then
          printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"outdated","data":{}}'
        elif [ "$2" = plan ]; then
          printf '{"ok":true,"schemaVersion":1,"command":"plan","data":{"action":"%s","subject":"%s","packageName":"example","installedVersion":"","targetVersion":"3.0.0","executeSupported":true,"executable":true}}\n' "$3" "$4"
        elif [ "$2" = execute ]; then
          /usr/bin/touch '\#(root.path)/installed-example'
          printf '%s\n' '{"ok":true,"schemaVersion":1,"command":"execute","data":{"operationId":"fake","action":"install","subject":"example","exitCode":0,"status":"ok","logFile":"/fake/log"}}'
        else
          exit 2
        fi
        """#
        try Data(managerScript.utf8).write(to: root.appending(path: "main.sh"))

        let resolver = NodeEnvironmentResolver(homeDirectory: root, approvedSystemPrefixes: [prefix])
        XCTAssertTrue(resolver.installations().isEmpty)

        let client = NodeManagerClient(runner: ProcessRunner(), environmentResolver: resolver)
        let snapshot = try await client.loadSnapshot(managerDirectory: root)
        let context = try XCTUnwrap(snapshot.packageEnvironment)
        XCTAssertEqual(context.nodeVersion, "v22.14.0")
        XCTAssertEqual(context.npmVersion, "10.9.2")

        let runner = ProcessRunner()
        let service = SystemProbeService(
            runner: runner,
            installer: ManagerSnapshotInstaller(applicationSupportDirectory: root.appending(path: "support")),
            nodeClient: client,
            shellClient: ShellManagerClient(runner: runner),
            environmentResolver: resolver
        )
        let model = AppModel(service: service, operationStore: OperationStore())
        model.applyNodeReadResult(.success(snapshot))
        XCTAssertEqual(model.discoverContext.npm?.environment, context)
        XCTAssertEqual(model.discoverContext.npm?.registryURL.absoluteString, "https://registry.npmjs.org/")
        XCTAssertTrue(model.discoverContext.nodeAvailable)
        XCTAssertTrue(model.discoverContext.registryAvailable)

        let scopedRegistry = try await client.effectivePackageRegistry("@scope/example", environment: context, managerDirectory: root)
        XCTAssertEqual(scopedRegistry.absoluteString, "https://scope.fixture.invalid/")

        let plan = try await client.planPackage(.init(name: "example", environment: context), action: .installPackage, managerDirectory: root)
        let result = try await client.executePackage(plan, environment: context, managerDirectory: root)
        XCTAssertEqual(result.batchItemStatus, .succeeded)

        let refreshed = try await client.loadPackageSnapshot(context, managerDirectory: root)
        XCTAssertEqual(refreshed.packageEnvironment, context)
        XCTAssertEqual(refreshed.packages.first?.name, "example")
    }

    func testApprovedHomebrewPrefixRejectsEscapingSymlinkMissingNPMAndUnapprovedPrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CellarHomebrewRejectTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "opt/homebrew", directoryHint: .isDirectory)
        let bin = prefix.appending(path: "bin", directoryHint: .isDirectory)
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        for dir in [bin, outside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for name in ["node", "npm"] {
            let file = bin.appending(path: name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let escapedNPM = outside.appending(path: "npm")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: escapedNPM)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: escapedNPM.path)

        let summary = NodeSummary(
            nodePath: bin.appending(path: "node").path,
            npmPath: bin.appending(path: "npm").path,
            nodeVersion: "v22.14.0",
            npmVersion: "10.9.2",
            nvmLoaded: false,
            globalPrefix: prefix.path,
            globalRoot: prefix.appending(path: "lib/node_modules").path,
            registry: "https://registry.npmjs.org/"
        )

        // Unapproved prefix must be rejected.
        XCTAssertNil(NodeEnvironmentResolver.packageInstallation(summary: summary, installations: [], approvedSystemPrefixes: []))
        XCTAssertNotNil(NodeEnvironmentResolver.packageInstallation(summary: summary, installations: [], approvedSystemPrefixes: [prefix]))

        // Symlink escaping the approved prefix must be rejected.
        try FileManager.default.removeItem(at: bin.appending(path: "npm"))
        try FileManager.default.createSymbolicLink(at: bin.appending(path: "npm"), withDestinationURL: escapedNPM)
        XCTAssertNil(NodeEnvironmentResolver.packageInstallation(summary: summary, installations: [], approvedSystemPrefixes: [prefix]))

        let resolver = NodeEnvironmentResolver(homeDirectory: root, approvedSystemPrefixes: [prefix])
        let client = NodeManagerClient(runner: ProcessRunner(), environmentResolver: resolver)
        do {
            _ = try await client.planPackage(.init(name: "example", environment: LibraryCatalog.context(summary)), action: .installPackage, managerDirectory: root)
            XCTFail("Escaping symlink in approved prefix must fail closed")
        } catch BridgeError.managerFailure(let code, _) {
            XCTAssertEqual(code, "node-environment-changed")
        }

        // Missing npm must be rejected.
        try FileManager.default.removeItem(at: bin.appending(path: "npm"))
        XCTAssertNil(NodeEnvironmentResolver.packageInstallation(summary: summary, installations: [], approvedSystemPrefixes: [prefix]))
    }
}
