import AppKit
import XCTest
@testable import Cellar

@MainActor
final class BatchOperationCoordinatorTests: XCTestCase {
    func testNPMItselfRunsLastIncludingExplicitVersionAndPreviewMatchesResults() async throws {
        for selfName in ["npm", "npm@2.0.0"] {
            let provider = FakeBatchProvider()
            let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
            let intent = try XCTUnwrap(BatchIntent(operation: .install, items: [selfName, "one", "two"].map { .npm(.init(name: $0, environment: environment)) }))
            let plan = try await coordinator.prepare(intent)
            XCTAssertEqual(plan.intent.items.map(\.displayIdentifier), ["one", "two", selfName])
            let result = try await coordinator.execute(plan)
            let names = await provider.executedNames()
            XCTAssertEqual(names, ["one", "two", selfName])
            XCTAssertEqual(result.outcome.itemOutcomes.map(\.item), plan.intent.items)
        }
    }

    func testVerifiedAliasRecoversUnavailableCanonicalSlotWithoutMovingIt() async throws {
        for inputs in [["canonical", "alias"], ["alias", "canonical"], ["canonical", "other", "alias"]] {
            let provider = FakeBatchProvider(planFailureNames: ["canonical"])
            let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
            let intent = try XCTUnwrap(BatchIntent(operation: .install, items: inputs.map { .homebrew(.init(name: $0, kind: .formula)) }))
            let plan = try await coordinator.prepare(intent)
            let expected = inputs.contains("other") ? ["canonical", "other"] : ["canonical"]
            XCTAssertEqual(plan.intent.items.map(\.displayIdentifier), expected)
            XCTAssertEqual(plan.items.map(\.status), expected.map { _ in .ready })
            XCTAssertEqual(plan.executableCount, expected.count)
            await provider.allowPlanning("canonical")
            let result = try await coordinator.execute(plan)
            let executed = await provider.executedNames()
            XCTAssertEqual(executed, expected)
            XCTAssertEqual(result.outcome.itemOutcomes.map(\.item), plan.intent.items)
            XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), expected.map { _ in .succeeded })
        }
    }

    func testFailedUnresolvedAliasStaysSeparateFromVerifiedCanonicalTarget() async throws {
        for inputs in [["alias", "canonical"], ["canonical", "alias"]] {
            let provider = FakeBatchProvider(planFailureNames: ["alias"])
            let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
            let intent = try XCTUnwrap(BatchIntent(operation: .install, items: inputs.map { .homebrew(.init(name: $0, kind: .formula)) }))
            let plan = try await coordinator.prepare(intent)
            XCTAssertEqual(plan.intent.items.map(\.displayIdentifier), inputs)
            XCTAssertEqual(plan.items.map(\.status), inputs.map { $0 == "alias" ? .unavailable : .ready })
            let result = try await coordinator.execute(plan)
            let executed = await provider.executedNames()
            XCTAssertEqual(executed, ["canonical"])
            XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), inputs.map { $0 == "alias" ? .failed : .succeeded })
        }
    }

    func testVerifiedAliasDoesNotReplaceKnownAlreadyInstalledCanonicalSkip() async throws {
        let provider = FakeBatchProvider(alreadyInstalledNames: ["canonical"])
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["canonical", "alias"].map { .homebrew(.init(name: $0, kind: .formula)) }))
        let plan = try await coordinator.prepare(intent)
        XCTAssertEqual(plan.intent.items.map(\.displayIdentifier), ["canonical"])
        XCTAssertEqual(plan.items.map(\.status), [.alreadyInstalled])
        XCTAssertEqual(plan.executableCount, 0)
        let result = try await coordinator.execute(plan)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.skipped])
        let executed = await provider.executedNames()
        XCTAssertEqual(executed, [])
    }

    func testCanonicalAliasesAreDeduplicatedBeforeConfirmation() async throws {
        let provider = FakeBatchProvider()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["alias", "canonical", "other"].map { .homebrew(.init(name: $0, kind: .formula)) }))
        let plan = try await coordinator.prepare(intent)
        XCTAssertEqual(plan.intent.items.map(\.displayIdentifier), ["canonical", "other"])
        XCTAssertEqual(plan.items.count, 2)
        let result = try await coordinator.execute(plan)
        let names = await provider.executedNames()
        XCTAssertEqual(names, ["canonical", "other"])
        XCTAssertEqual(result.outcome.itemOutcomes.count, 2)
    }

    func testEquivalentNPMSpecsDeduplicateResolvedTargetsAndPreserveExplicitInput() async throws {
        let provider = FakeBatchProvider()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["npm@2.0.0", "npm", "one"].map { .npm(.init(name: $0, environment: environment)) }))
        let plan = try await coordinator.prepare(intent)
        XCTAssertEqual(plan.intent.items.map(\.displayIdentifier), ["one", "npm@2.0.0"])
        XCTAssertEqual(plan.npmBindings.map(\.targetVersion), ["2.0.0", "2.0.0"])
        let result = try await coordinator.execute(plan)
        let specs = await provider.executedSpecs()
        XCTAssertEqual(specs, ["one@2.0.0", "npm@2.0.0"])
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.item), plan.intent.items)
    }

    func testConflictingNPMSpecsRefuseTheWholeBatchBeforeWriting() async throws {
        let provider = FakeBatchProvider()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["npm@2.0.0", "npm@3.0.0"].map { .npm(.init(name: $0, environment: environment)) }))
        do { _ = try await coordinator.prepare(intent); XCTFail("Conflicting specs must not pick a winner") }
        catch { XCTAssertEqual(error as? BatchOperationError, .conflictingVersions) }
        let names = await provider.executedNames()
        XCTAssertEqual(names, [])
        XCTAssertNil(coordinator.preparedPlan)
    }

    func testSkippedItemsDoNotCountAsWritesOrTurnFailuresIntoSuccess() async throws {
        for statuses: [BatchItemStatus] in [[.skipped, .skipped], [.skipped, .failed], [.skipped, .succeeded], [.skipped, .unknown], [.skipped, .cancelled]] {
            let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["one", "two"].map { .npm(.init(name: $0, environment: environment)) }))
            let outcome = try XCTUnwrap(BatchOutcome(intent: intent, itemOutcomes: zip(intent.items, statuses).map { .init(item: $0, status: $1, userFacingMessage: nil) }))
            XCTAssertEqual(outcome.status, statuses[1] == .skipped ? .succeeded : statuses[1].activityStatus)
            XCTAssertEqual(outcome.succeededItemCount, statuses[1] == .succeeded ? 1 : 0)
            let detail = ActivityRenderer(locale: Locale(identifier: "en")).detail(outcome.activitySummary(id: UUID()))
            XCTAssertTrue(detail.contains("Skipped"))
        }
        let provider = FakeBatchProvider(alreadyInstalledNames: ["one", "two", "three"])
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
        let result = try await coordinator.execute(coordinator.prepare(npmIntent(.install)))
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.skipped, .skipped, .skipped])
        XCTAssertEqual(result.outcome.status, .succeeded)
        XCTAssertEqual(result.outcome.succeededItemCount, 0)
        let names = await provider.executedNames()
        XCTAssertEqual(names, [])
    }

    func testFrozenPostWriteVerificationCodesRemainUnknownAndLocalizableInSession() async throws {
        for code in ["post-install-state-unavailable", "post-uninstall-state-unavailable", "update-verification-unavailable"] {
            let store = ActivityStore()
            let provider = FakeBatchProvider(failingNames: ["two"], failureCode: code)
            let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore(), activityStore: store)
            let operation: BatchOperation = code == "post-uninstall-state-unavailable" ? .uninstall : .install
            let intent = try (operation == .uninstall ? npmUninstallIntent("two") : npmIntent(operation))
            let result = try await coordinator.execute(coordinator.prepare(intent))
            let index = operation == .uninstall ? 0 : 1
            XCTAssertEqual(result.outcome.itemOutcomes[index].status, .unknown, code)
            XCTAssertEqual(result.outcome.itemOutcomes[index].reason, .stateUnavailable, code)
            XCTAssertEqual(result.outcome.status, operation == .uninstall ? .unknown : .partiallySucceeded)
            let summary = try XCTUnwrap(store.summaries.first)
            XCTAssertEqual(summary.itemOutcomes[index].status, .unknown)
            let english = ActivityRenderer(locale: .init(identifier: "en")).detail(summary)
            let chinese = ActivityRenderer(locale: .init(identifier: "zh-Hans")).detail(summary)
            XCTAssertTrue(english.contains("could not be verified"))
            XCTAssertTrue(english.contains("Refresh"))
            XCTAssertNotEqual(english, chinese)
            XCTAssertFalse(english.contains(code))
        }
        let frozen = #"{"operationId":"fixture","action":"uninstall","subject":"example","exitCode":0,"status":"failed","detail":"post-uninstall-state-unavailable","logFile":"/private/diagnostic"}"#
        let result = try JSONDecoder().decode(NodeOperationResult.self, from: Data(frozen.utf8))
        XCTAssertEqual(result.batchItemStatus, .unknown)
        let latest = NodeOperationResult(operationId: "fixture", action: "update-latest", subject: "example", exitCode: 0, status: "warn", logFile: "", detail: "latest-verification-unavailable", residues: nil)
        XCTAssertEqual(latest.batchItemStatus, .partiallySucceeded)
        XCTAssertEqual(latest.activityReason, .stateUnavailable)
        let failed = NodeOperationResult(operationId: "fixture", action: "uninstall", subject: "example", exitCode: 1, status: "failed", logFile: "", detail: "npm-uninstall-failed", residues: nil)
        XCTAssertEqual(failed.batchItemStatus, .failed)
        XCTAssertEqual(failed.activityReason, .providerFailure)
    }

    func testStaleProviderFailuresKeepFiniteReasonsAndSessionDiagnostics() async throws {
        let activity = ActivityStore()
        let diagnostics = ActivityDiagnosticsStore()
        let provider = FakeBatchProvider(failingNames: ["two"], failureCode: "npm-uninstall-state-changed")
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore(), activityStore: activity, diagnosticsStore: diagnostics)
        let plan = try await coordinator.prepare(npmUninstallIntent("two"))
        let result = try await coordinator.execute(plan)
        XCTAssertEqual(result.outcome.itemOutcomes[0].reason, .stateChanged)
        XCTAssertEqual(activity.summaries.first?.id, plan.id)
        XCTAssertEqual(activity.summaries.first?.itemOutcomes[0].reason, .stateChanged)
        XCTAssertEqual(result.outcome.status, .failed)
        XCTAssertTrue(diagnostics.records.contains { $0.detail.contains("[redacted]") })
        XCTAssertFalse(diagnostics.records.contains { $0.detail.contains("TOKEN=secret") })
        let json = String(decoding: try JSONEncoder().encode(activity.summaries), as: UTF8.self)
        for raw in ["secret", "TOKEN", "npm-uninstall-state-changed", "standardOutput", "/private"] { XCTAssertFalse(json.contains(raw), raw) }
    }

    func testNPMUninstallResidueWarningIsPartialAndDiagnosticsAreSessionOnly() async throws {
        let activity = ActivityStore()
        let provider = FakeBatchProvider(npmWarningNames: ["one"])
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore(), activityStore: activity)
        let plan = try await coordinator.prepare(npmUninstallIntent("one"))
        let result = try await coordinator.execute(plan)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.partiallySucceeded])
        XCTAssertEqual(result.outcome.status, .partiallySucceeded)
        guard case .npm(let diagnostic) = result.providerResults[0] else { return XCTFail("Expected npm diagnostic") }
        XCTAssertEqual(diagnostic.status, "warn")
        XCTAssertEqual(diagnostic.residues?.directories, ["/private/fake/lib/node_modules/one"])
        XCTAssertEqual(activity.summaries.first?.status, .partiallySucceeded)
        let semanticJSON = String(decoding: try JSONEncoder().encode(activity.summaries), as: UTF8.self)
        XCTAssertFalse(semanticJSON.contains("/private/fake"))
        XCTAssertFalse(semanticJSON.contains("residue-detected"))
    }

    func testHomebrewFailedPackagesSectionMakesBatchReconciliationFail() async throws {
        let provider = FakeBatchProvider(homebrewPackagesRefreshFails: true)
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: [.homebrew(.init(name: "one", kind: .formula))]))
        let result = try await coordinator.execute(coordinator.prepare(intent))
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded])
        XCTAssertEqual(result.refreshStatus, .failed)
        guard case .homebrew(let status) = result.refreshedState else {
            return XCTFail("A partial reconciliation must publish its independently successful sections")
        }
        XCTAssertNotNil(status.snapshot?.sectionErrors[.packages])
    }
    func testIntentRejectsEmptyDuplicateMixedProviderTypeAndEnvironment() {
        let formula = BatchItem.homebrew(.init(name: "one", kind: .formula))
        let cask = BatchItem.homebrew(.init(name: "two", kind: .cask))
        let npm = BatchItem.npm(.init(name: "one", environment: environment))
        let otherNPM = BatchItem.npm(.init(name: "two", environment: .init(
            identifier: "nvm:v20.0.0", nodeVersion: "v20.0.0", npmVersion: "10.0.0"
        )))
        XCTAssertNil(BatchIntent(operation: .install, items: []))
        XCTAssertNil(BatchIntent(operation: .install, items: [formula, formula]))
        XCTAssertNil(BatchIntent(operation: .install, items: [formula, cask]))
        XCTAssertNil(BatchIntent(operation: .install, items: [formula, npm]))
        XCTAssertNil(BatchIntent(operation: .install, items: [npm, otherNPM]))
    }

    func testSequentialExecutionContinuesAfterFailureAndRefreshesOnce() async throws {
        let provider = FakeBatchProvider(failingNames: ["two"])
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let intent = try npmIntent(.install)
        let plan = try await coordinator.prepare(intent)
        XCTAssertFalse(store.hasActiveOperations)
        let beforeExecution = await provider.executedNames()
        XCTAssertEqual(beforeExecution, [])

        let result = try await coordinator.execute(plan)

        let names = await provider.executedNames()
        let concurrency = await provider.maximumConcurrentCount()
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(names, ["one", "two", "three"])
        XCTAssertEqual(concurrency, 1)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .failed, .succeeded])
        XCTAssertEqual(result.outcome.status, .partiallySucceeded)
        XCTAssertEqual(result.outcome.succeededItemCount, 2)
        XCTAssertEqual(result.refreshStatus, .succeeded)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testRefreshFailureDoesNotEraseSuccessfulItemOutcomes() async throws {
        let provider = FakeBatchProvider(refreshFails: true)
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let plan = try await coordinator.prepare(npmIntent(.update))

        let result = try await coordinator.execute(plan)

        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .succeeded, .succeeded])
        XCTAssertEqual(result.outcome.status, .succeeded)
        XCTAssertEqual(result.refreshStatus, .failed)
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testCancellationInsideRenewalRetainsEarlierSuccessAndOwnsSlotThroughFinalRefresh() async throws {
        let renewalStarted = expectation(description: "Second renewal paused")
        let refreshStarted = expectation(description: "Final reconciliation paused")
        let provider = FakeBatchProvider(pauseRefresh: true, onRefresh: { refreshStarted.fulfill() },
            pausedRenewalName: "two", onRenewal: { renewalStarted.fulfill() })
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let plan = try await coordinator.prepare(npmIntent(.install))
        let task = Task { try await coordinator.execute(plan) }
        await fulfillment(of: [renewalStarted], timeout: 3)
        let executedBeforeCancel = await provider.executedNames()
        let renewedBeforeCancel = await provider.renewalNames()
        XCTAssertEqual(executedBeforeCancel, ["one"])
        XCTAssertEqual(renewedBeforeCancel, ["one", "two"])
        XCTAssertEqual(coordinator.runningItem, plan.intent.items[1])
        task.cancel()
        await fulfillment(of: [refreshStarted], timeout: 3)
        XCTAssertTrue(store.hasActiveOperations)
        XCTAssertEqual(store.activeOperationCount, 1)
        XCTAssertEqual(store.currentOperation?.context.stage, .reconciling)
        XCTAssertNil(coordinator.result)
        let executedDuringRefresh = await provider.executedNames()
        let renewedDuringRefresh = await provider.renewalNames()
        let refreshesDuringRefresh = await provider.refreshCount()
        XCTAssertEqual(executedDuringRefresh, ["one"])
        XCTAssertEqual(renewedDuringRefresh, ["one", "two"])
        XCTAssertEqual(refreshesDuringRefresh, 1)
        do { _ = try await coordinator.prepare(npmIntent(.install)); XCTFail("Reconciliation must retain the lifecycle slot") }
        catch { XCTAssertEqual(error as? BatchOperationError, .busy) }
        await provider.resumeRefresh()
        let result = try await task.value
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .cancelled, .cancelled])
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.reason), [nil, .cancelledByUser, .cancelledByUser])
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.item), plan.intent.items)
        XCTAssertEqual(result.outcome.status, .partiallySucceeded)
        XCTAssertEqual(result.refreshStatus, .succeeded)
        XCTAssertNotNil(result.providerResults[0])
        XCTAssertNil(result.providerResults[1])
        XCTAssertNil(result.providerResults[2])
        let executed = await provider.executedNames()
        let renewed = await provider.renewalNames()
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(executed, ["one"])
        XCTAssertEqual(renewed, ["one", "two"])
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testParentCancellationPropagatesButFinalRefreshIsNotCancelled() async throws {
        let started = expectation(description: "First item started")
        let provider = FakeBatchProvider(pausedName: "one", onPaused: { started.fulfill() })
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let plan = try await coordinator.prepare(npmIntent(.install))
        let task = Task { try await coordinator.execute(plan) }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()

        let result = try await task.value

        let cancelled = await provider.observedCancellation()
        let refreshes = await provider.refreshCount()
        XCTAssertTrue(cancelled)
        let preparationCalls = await provider.preparedNames()
        XCTAssertEqual(preparationCalls, ["one", "two", "three", "one"])
        XCTAssertEqual(result.outcome.status, .cancelled)
        XCTAssertEqual(result.refreshStatus, .succeeded)
        XCTAssertEqual(refreshes, 1)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testGlobalExclusionRejectsDuplicateAndOtherAppModelWork() async throws {
        let started = expectation(description: "First item started")
        let provider = FakeBatchProvider(pausedName: "one", onPaused: { started.fulfill() })
        let store = OperationStore.shared
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let plan = try await coordinator.prepare(npmIntent(.install))
        let task = Task { try await coordinator.execute(plan) }
        await fulfillment(of: [started], timeout: 3)
        do {
            _ = try await coordinator.execute(plan)
            XCTFail("Duplicate write must be refused")
        } catch {
            XCTAssertEqual(error as? BatchOperationError, .busy)
        }
        let model = AppModel.live()
        XCTAssertTrue(model.isBusy)
        await model.refresh()
        XCTAssertNil(model.managers)
        XCTAssertEqual(store.activeOperationCount, 1)
        task.cancel()
        _ = try await task.value
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testPreparedPlanIsSingleUseAndKeepsNPMEnvironment() async throws {
        let provider = FakeBatchProvider()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
        let plan = try await coordinator.prepare(npmIntent(.update))
        _ = try await coordinator.execute(plan)
        let environments = await provider.executedEnvironments()
        XCTAssertEqual(environments, [environment, environment, environment])
        do {
            _ = try await coordinator.execute(plan)
            XCTFail("A confirmed batch cannot be replayed")
        } catch {
            XCTAssertEqual(error as? BatchOperationError, .planUnavailable)
        }
    }

    func testPreparationFailureDoesNotWriteAndCleansUpOperation() async throws {
        let activity = ActivityStore()
        let provider = FakeBatchProvider(planFails: true)
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store, activityStore: activity)
        let plan = try await coordinator.prepare(npmIntent(.install))
        XCTAssertEqual(plan.executableCount, 0)
        XCTAssertEqual(plan.items.map(\.status), [.unavailable, .unavailable, .unavailable])
        let result = try await coordinator.execute(plan)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.failed, .failed, .failed])
        XCTAssertEqual(result.refreshStatus, .notNeeded)
        XCTAssertEqual(activity.summaries.first?.status, .failed)
        XCTAssertEqual(activity.summaries.first?.itemOutcomes.map(\.reason), [.preparationFailed, .preparationFailed, .preparationFailed])
        let semanticJSON = String(decoding: try JSONEncoder().encode(activity.summaries), as: UTF8.self)
        XCTAssertFalse(semanticJSON.contains("FakeBatchProvider"))
        let names = await provider.executedNames()
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(names, [])
        XCTAssertEqual(refreshes, 0)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testInstallPreparationFailureIsPerItemAndEligibleItemsStillExecute() async throws {
        for unavailable in [Set(["one"]), Set(["two"]), Set(["one", "two", "three"])] {
            let provider = FakeBatchProvider(planFailureNames: unavailable)
            let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
            let plan = try await coordinator.prepare(npmIntent(.install))
            let result = try await coordinator.execute(plan)
            XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), ["one", "two", "three"].map { unavailable.contains($0) ? .failed : .succeeded })
            let names = await provider.executedNames()
            XCTAssertEqual(names, ["one", "two", "three"].filter { !unavailable.contains($0) })
            XCTAssertEqual(result.refreshStatus, unavailable.count == 3 ? .notNeeded : .succeeded)
        }
    }

    func testKnownPreparationFailureAndCancellationPreserveOrderedActivitySemantics() async throws {
        let started = expectation(description: "Eligible install started")
        let activity = ActivityStore()
        let provider = FakeBatchProvider(pausedName: "two", onPaused: { started.fulfill() }, planFailureNames: ["one"])
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store, activityStore: activity)
        let plan = try await coordinator.prepare(npmIntent(.install))
        XCTAssertEqual(plan.items.map(\.status), [.unavailable, .ready, .ready])
        let task = Task { try await coordinator.execute(plan) }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.failed, .cancelled, .cancelled])
        XCTAssertEqual(activity.summaries.first?.itemOutcomes.map(\.reason), [.preparationFailed, .cancelledByUser, .cancelledByUser])
        let names = await provider.executedNames()
        XCTAssertEqual(names, ["two"])
        let semanticJSON = String(decoding: try JSONEncoder().encode(activity.summaries), as: UTF8.self)
        for secret in ["TOKEN", "secret", "FakeBatchProvider", "/private", "planFailure"] { XCTAssertFalse(semanticJSON.contains(secret), secret) }
    }

    func testAlreadyInstalledAndUnavailableHomebrewItemsDoNotPreventLaterTypedTargets() async throws {
        let provider = FakeBatchProvider(planFailureNames: ["bad"], alreadyInstalledNames: ["installed"])
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["installed", "bad", "eligible"].map { .homebrew(.init(name: $0, kind: .cask)) }))
        let plan = try await coordinator.prepare(intent)
        XCTAssertEqual(plan.items.map(\.status), [.alreadyInstalled, .unavailable, .ready])
        XCTAssertEqual(plan.homebrewImpacts.map(\.targets), [[.init(name: "eligible", kind: .cask)]])
        let result = try await coordinator.execute(plan)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.skipped, .failed, .succeeded])
    }

    func testCancellationBeforeStartingDoesNotRefreshOrExecute() async throws {
        let provider = FakeBatchProvider()
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let plan = try await coordinator.prepare(npmIntent(.install))
        let task = Task { try await coordinator.execute(plan) }
        task.cancel()
        let result = try await task.value
        let names = await provider.executedNames()
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(names, [])
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(result.refreshStatus, .notNeeded)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.cancelled, .cancelled, .cancelled])
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testQuitProtectionAndExclusionRemainUntilRefreshCompletes() async throws {
        let started = expectation(description: "Refresh started")
        let provider = FakeBatchProvider(pauseRefresh: true, onRefresh: { started.fulfill() })
        let store = OperationStore()
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: store)
        let plan = try await coordinator.prepare(npmIntent(.update))
        let task = Task { try await coordinator.execute(plan) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(store.hasActiveOperations)
        XCTAssertEqual(store.activeOperationCount, 1)
        do {
            _ = try await coordinator.prepare(npmIntent(.install))
            XCTFail("Refresh reconciliation still owns the operation slot")
        } catch {
            XCTAssertEqual(error as? BatchOperationError, .busy)
        }
        task.cancel()
        await provider.resumeRefresh()
        let result = try await task.value
        XCTAssertEqual(result.refreshStatus, .succeeded)
        XCTAssertFalse(store.hasActiveOperations)
    }

    func testHomebrewUsesTypedSinglePlansAndRetainsUnknownPartialDiagnostics() async throws {
        let provider = FakeBatchProvider(failingNames: ["two"], unknownNames: ["three"])
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore())
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["one", "two", "three"].map {
            .homebrew(.init(name: $0, kind: .cask))
        }))
        let plan = try await coordinator.prepare(intent)
        let result = try await coordinator.execute(plan)
        let names = await provider.executedNames()
        let refreshes = await provider.refreshCount()
        XCTAssertEqual(names, ["one", "two", "three"])
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(result.outcome.itemOutcomes.map(\.status), [.succeeded, .failed, .unknown])
        XCTAssertEqual(result.outcome.status, .partiallySucceeded)
        guard case .homebrew(let third) = result.providerResults[2] else { return XCTFail("Expected typed Homebrew diagnostic") }
        XCTAssertEqual(third.plan.targets.first?.kind, .cask)
        XCTAssertEqual(third.outcome, .stateUnknown)
        XCTAssertEqual(third.command.standardOutput, "TOKEN=secret stdout")
    }

    func testBatchKeepsSemanticOutcomesAndDistinctRefreshFailureWithoutProviderOutput() async throws {
        let activity = ActivityStore()
        let provider = FakeBatchProvider(failingNames: ["two"], refreshFails: true)
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore(), activityStore: activity)
        let plan = try await coordinator.prepare(npmUninstallIntent("two"))
        _ = try await coordinator.execute(plan)
        XCTAssertEqual(activity.summaries.count, 2)
        XCTAssertEqual(activity.summaries.map(\.operation), [.refresh, .uninstall])
        XCTAssertEqual(activity.summaries.last?.status, .failed)
        XCTAssertEqual(activity.summaries.last?.itemOutcomes.map(\.reason), [.providerFailure])
        let json = String(decoding: try JSONEncoder().encode(activity.summaries), as: UTF8.self)
        for secret in ["TOKEN", "secret", "stdout", "/private", "logFile", "command"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
    }

    func testHomebrewPartialIsPreservedWithoutAnyFullySucceededItem() async throws {
        let activity = ActivityStore()
        let provider = FakeBatchProvider(failingNames: ["two"], partialNames: ["one"])
        let coordinator = BatchOperationCoordinator(provider: provider, operationStore: OperationStore(), activityStore: activity)
        let intent = try XCTUnwrap(BatchIntent(operation: .install, items: ["one", "two"].map {
            .homebrew(.init(name: $0, kind: .formula))
        }))
        let plan = try await coordinator.prepare(intent)
        let result = try await coordinator.execute(plan)
        guard case .homebrew(let first) = result.providerResults[0] else { return XCTFail("Expected Homebrew result") }
        XCTAssertEqual(first.outcome, .partial)
        XCTAssertEqual(result.outcome.itemOutcomes.map { $0.status.rawValue }, ["partiallySucceeded", "failed"])
        XCTAssertEqual(result.outcome.status, .partiallySucceeded)
        XCTAssertEqual(result.outcome.succeededItemCount, 0)
        XCTAssertEqual(activity.summaries.first?.status, .partiallySucceeded)
        XCTAssertEqual(activity.summaries.first?.itemOutcomes.map { $0.status.rawValue }, ["partiallySucceeded", "failed"])
        let restored = ActivityStore()
        XCTAssertTrue(restored.summaries.isEmpty)
    }

    private var environment: NodeEnvironmentContext {
        .init(identifier: "nvm:v22.0.0", nodeVersion: "v22.0.0", npmVersion: "10.0.0")
    }

    private func npmIntent(_ operation: BatchOperation) throws -> BatchIntent {
        precondition(operation != .uninstall)
        return try XCTUnwrap(BatchIntent(operation: operation, items: ["one", "two", "three"].map {
            .npm(.init(name: $0, environment: environment))
        }))
    }

    private func npmUninstallIntent(_ name: String) throws -> BatchIntent {
        try XCTUnwrap(BatchIntent(operation: .uninstall, items: [.npm(.init(name: name, environment: environment))]))
    }
}

actor FakeBatchProvider: BatchOperationProviding {
    enum Failure: Error { case provider, refresh, plan }
    let failingNames: Set<String>
    let failureCode: String?
    let refreshFails: Bool
    let pausedName: String?
    let onPaused: @Sendable () -> Void
    let planFails: Bool
    var planFailureNames: Set<String>
    let alreadyInstalledNames: Set<String>
    let registries: [String: URL]
    let changeDestinationAfterName: String?
    let changeDestinationAfterPlanName: String?
    let pausedPlanName: String?
    let onPlan: @Sendable () -> Void
    let pausedRenewalName: String?
    let onRenewal: @Sendable () -> Void
    var renewedNames: [String] = []
    var plannedNames: [String] = []
    var destination = "/fake"
    let unknownNames: Set<String>
    let partialNames: Set<String>
    let protectedNames: Set<String>
    let npmWarningNames: Set<String>
    let homebrewPackagesRefreshFails: Bool
    let homebrewRefreshSnapshot: HomebrewSnapshot?
    let caskRemoval: CaskRemovalPlan?
    let npmRefreshSnapshot: NodeSnapshot?
    let pauseRefresh: Bool
    let onRefresh: @Sendable () -> Void
    var refreshContinuation: AsyncStream<Void>.Continuation?
    var names: [String] = []
    var specs: [String] = []
    var environments: [NodeEnvironmentContext] = []
    var refreshes = 0
    var concurrent = 0
    var maximumConcurrent = 0
    var cancelled = false

    init(failingNames: Set<String> = [], refreshFails: Bool = false,
         pausedName: String? = nil, onPaused: @escaping @Sendable () -> Void = {}, planFails: Bool = false,
         unknownNames: Set<String> = [], partialNames: Set<String> = [], pauseRefresh: Bool = false,
         onRefresh: @escaping @Sendable () -> Void = {}, protectedNames: Set<String> = [],
         npmWarningNames: Set<String> = [], homebrewPackagesRefreshFails: Bool = false, planFailureNames: Set<String> = [],
         alreadyInstalledNames: Set<String> = [], registries: [String: URL] = [:], changeDestinationAfterName: String? = nil,
         pausedPlanName: String? = nil, onPlan: @escaping @Sendable () -> Void = {}, changeDestinationAfterPlanName: String? = nil,
         homebrewRefreshSnapshot: HomebrewSnapshot? = nil, npmRefreshSnapshot: NodeSnapshot? = nil, failureCode: String? = nil,
         caskRemoval: CaskRemovalPlan? = nil, pausedRenewalName: String? = nil, onRenewal: @escaping @Sendable () -> Void = {}) {
        self.failingNames = failingNames
        self.failureCode = failureCode
        self.refreshFails = refreshFails
        self.pausedName = pausedName
        self.onPaused = onPaused
        self.planFails = planFails
        self.planFailureNames = planFailureNames
        self.alreadyInstalledNames = alreadyInstalledNames
        self.registries = registries
        self.changeDestinationAfterName = changeDestinationAfterName
        self.changeDestinationAfterPlanName = changeDestinationAfterPlanName
        self.pausedPlanName = pausedPlanName
        self.onPlan = onPlan
        self.pausedRenewalName = pausedRenewalName
        self.onRenewal = onRenewal
        self.unknownNames = unknownNames
        self.partialNames = partialNames
        self.protectedNames = protectedNames
        self.npmWarningNames = npmWarningNames
        self.homebrewPackagesRefreshFails = homebrewPackagesRefreshFails
        self.homebrewRefreshSnapshot = homebrewRefreshSnapshot
        self.caskRemoval = caskRemoval
        self.npmRefreshSnapshot = npmRefreshSnapshot
        self.pauseRefresh = pauseRefresh
        self.onRefresh = onRefresh
    }

    func renewHomebrew(_ plan: HomebrewActionPlan) async throws -> HomebrewActionPlan? {
        guard let identity = plan.targets.first else { throw BatchOperationError.invalidPlan }
        let renewed = try await planHomebrew(identity, operation: plan.action == .install ? .install : .update)
        guard renewed.targets == plan.targets, renewed.action == plan.action,
              renewed.confirmedTargets == plan.confirmedTargets, renewed.stateFingerprint == plan.stateFingerprint
        else { throw HomebrewClientError.stateChanged }
        return renewed
    }

    func renewNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeActionPlan? {
        renewedNames.append(plan.request.subject)
        if plan.request.subject == pausedRenewalName {
            let stream = AsyncStream<Void> { _ in onRenewal() }
            for await _ in stream {}
            try Task.checkCancellation()
        }
        let renewed = try await planNPM(.init(name: plan.request.subject, environment: environment), operation: plan.request.action == .installPackage ? .install : .update)
        guard renewed.request == plan.request, renewed.payload.packageName == plan.payload.packageName,
              renewed.payload.targetVersion == plan.payload.targetVersion,
              renewed.payload.installedVersion == plan.payload.installedVersion,
              renewed.confirmedPackageDestination == plan.confirmedPackageDestination,
              renewed.confirmedInstallRegistry == plan.confirmedInstallRegistry
        else { throw BridgeError.managerFailure(code: "npm-install-state-changed", detail: nil) }
        return renewed
    }

    func planHomebrew(_ identity: HomebrewPackageIdentity, operation: BatchOperation) async throws -> HomebrewActionPlan {
        if identity.name == pausedPlanName {
            let stream = AsyncStream<Void> { _ in onPlan() }
            for await _ in stream {}
            try Task.checkCancellation()
        }
        if planFails || planFailureNames.contains(identity.name) { throw Failure.plan }
        if operation == .install, alreadyInstalledNames.contains(identity.name) { throw HomebrewClientError.alreadyInstalled(identity) }
        let canonical = identity.name == "alias" ? HomebrewPackageIdentity(name: "canonical", kind: identity.kind) : identity
        return HomebrewActionPlan(id: UUID(), action: operation.homebrewAction(for: identity.kind), targets: [canonical],
                                  tapName: nil, dependencies: [], dependents: [], artifacts: [], residualPaths: [],
                                  associatedPackages: [], generatedAt: Date(), stateFingerprint: "fake-fingerprint",
                                  confirmedTargets: operation == .uninstall ? [] : [.init(identity: canonical, source: "fake/tap", version: "1.0.0", prefix: "/fake")], caskRemoval: caskRemoval)
    }

    func executeHomebrew(_ plan: HomebrewActionPlan) throws -> HomebrewActionResult {
        guard let identity = plan.targets.first else { throw Failure.plan }
        names.append(identity.name)
        let failed = failingNames.contains(identity.name)
        let package = HomebrewPackage(identity: identity, displayName: identity.name, description: nil, homepage: nil,
                                      installedVersions: failed ? [] : ["1.0.0"], currentVersion: "1.0.0", tap: "fake/tap",
                                      dependencies: [], pinned: false, deprecated: false, disabled: false, artifacts: [])
        let snapshot = HomebrewSnapshot(executablePath: "/fake/brew", version: "5.0.0",
                                        configuration: .init(prefix: "/fake", repository: "", cache: "", cellar: "", values: [:]),
                                        packages: [package], outdatedPackages: [], taps: [], sectionErrors: [:],
                                        controlledPath: "", commandLineToolsAvailable: true)
        return HomebrewActionResult(plan: plan,
                                    command: .init(arguments: ["fake"], standardOutput: "TOKEN=secret stdout", standardError: "",
                                                   terminationStatus: failed || partialNames.contains(identity.name) ? 1 : 0, standardOutputWasTruncated: false,
                                                   standardErrorWasTruncated: false),
                                    snapshot: unknownNames.contains(identity.name) ? nil : snapshot,
                                    postflightError: unknownNames.contains(identity.name) ? "secret" : nil, remainingResidualPaths: [])
    }
    func refreshHomebrew() throws -> HomebrewStatus {
        refreshes += 1
        if refreshFails { throw Failure.refresh }
        if let snapshot = homebrewRefreshSnapshot {
            return HomebrewStatus(executablePath: snapshot.executablePath, version: snapshot.version, managerAvailable: true, snapshot: snapshot)
        }
        if homebrewPackagesRefreshFails {
            let snapshot = HomebrewSnapshot(executablePath: "/fake/brew", version: "5.0.0", configuration: .init(prefix: "", repository: "", cache: "", cellar: "", values: [:]), packages: [], outdatedPackages: [], taps: [], sectionErrors: [.packages: "fixture unavailable"], controlledPath: "", commandLineToolsAvailable: true)
            return HomebrewStatus(executablePath: snapshot.executablePath, version: snapshot.version, managerAvailable: true, snapshot: snapshot)
        }
        let snapshot = HomebrewSnapshot(executablePath: "/fake/brew", version: "5.0.0", configuration: .init(prefix: "", repository: "", cache: "", cellar: "", values: [:]), packages: [], outdatedPackages: [], taps: [], sectionErrors: [:], controlledPath: "", commandLineToolsAvailable: true)
        return HomebrewStatus(executablePath: snapshot.executablePath, version: snapshot.version, managerAvailable: true, snapshot: snapshot)
    }

    func planNPM(_ identity: NPMPackageIdentity, operation: BatchOperation) async throws -> NodeActionPlan {
        plannedNames.append(identity.name)
        if identity.name == pausedPlanName {
            let stream = AsyncStream<Void> { _ in onPlan() }
            for await _ in stream {}
            try Task.checkCancellation()
        }
        if planFails || planFailureNames.contains(identity.name) { throw Failure.plan }
        let action: NodeAction = switch operation {
        case .install: .installPackage
        case .update: .updatePackage
        case .uninstall: .uninstallPackage
        }
        let packageName = identity.name.hasPrefix("npm@") ? "npm" : identity.name
        let targetVersion = identity.name.hasPrefix("npm@") ? String(identity.name.dropFirst(4)) : "2.0.0"
        let payload = try JSONDecoder().decode(NodeActionPlanPayload.self, from: Data(
            "{\"action\":\"\(action.rawValue)\",\"subject\":\"\(identity.name)\",\"packageName\":\"\(packageName)\",\"installedVersion\":\"1.0.0\",\"targetVersion\":\"\(targetVersion)\",\"executeSupported\":true,\"executable\":true,\"alreadyInstalled\":\(operation == .install && alreadyInstalledNames.contains(identity.name))}".utf8
        ))
        let plan = NodeActionPlan(id: UUID(), request: .init(action: action, subject: identity.name),
                              payload: payload, generatedAt: Date(),
                              confirmedPackageDestination: operation != .uninstall ? .init(nodeExecutable: identity.environment.identifier, npmExecutable: "/fake/npm", globalPrefix: destination, globalRoot: destination) : nil,
                              confirmedInstallRegistry: operation != .uninstall ? registries[identity.name] ?? CatalogWebsites.npmRegistry : nil)
        if identity.name == changeDestinationAfterPlanName { destination = "/changed" }
        return plan
    }

    func executeNPM(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult {
        if let bound = plan.confirmedPackageDestination, bound.globalRoot != destination { throw Failure.provider }
        names.append(plan.request.subject)
        specs.append(plan.exactInstallSpec ?? plan.exactUpdateSpec ?? plan.request.subject)
        environments.append(environment)
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        defer { concurrent -= 1 }
        if plan.request.subject == pausedName {
            let stream = AsyncStream<Void> { _ in onPaused() }
            for await _ in stream {}
            cancelled = Task.isCancelled
            try Task.checkCancellation()
        }
        if failingNames.contains(plan.request.subject) {
            if let failureCode { throw BridgeError.managerFailure(code: failureCode, detail: "TOKEN=secret") }
            throw Failure.provider
        }
        if plan.request.subject == changeDestinationAfterName { destination = "/changed" }
        if npmWarningNames.contains(plan.request.subject) {
            let envelope = try JSONDecoder().decode(ManagerEnvelope<NodeOperationResult>.self, from: Data(nodeUninstallResidueResponse.utf8))
            guard let result = envelope.data else { throw Failure.provider }
            return result
        }
        return NodeOperationResult(operationId: UUID().uuidString, action: plan.request.action.rawValue,
                                   subject: plan.request.subject, exitCode: 0, status: "ok",
                                   logFile: "/private/secret-path", detail: "TOKEN=secret stdout", residues: nil)
    }

    func refreshNPM(_ environment: NodeEnvironmentContext) async throws -> NodeSnapshot {
        refreshes += 1
        if pauseRefresh {
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            refreshContinuation = continuation
            onRefresh()
            for await _ in stream {}
        }
        try Task.checkCancellation()
        if refreshFails { throw Failure.refresh }
        if let snapshot = npmRefreshSnapshot { return snapshot }
        return NodeSnapshot(
            summary: .init(nodePath: "/fake/node", npmPath: "/fake/npm", nodeVersion: environment.nodeVersion,
                           npmVersion: environment.npmVersion, nvmLoaded: false, globalPrefix: "/fake",
                           globalRoot: "/fake", registry: "https://registry.npmjs.org"),
            configuration: .init(registry: "", cache: "", prefix: "", userRegistry: "", projectRegistry: "", globalRegistry: ""),
            packages: [], installations: [], managerStatus: nil, logs: [], outdatedError: nil, maintenanceError: nil
        )
    }

    func executedNames() -> [String] { names }
    func executedSpecs() -> [String] { specs }
    func preparedNames() -> [String] { plannedNames }
    func renewalNames() -> [String] { renewedNames }
    func changeDestination() { destination = "/changed" }
    func allowPlanning(_ name: String) { planFailureNames.remove(name) }
    func planNodeUninstall(_ identity: NodeRuntimeIdentity) throws -> NodeActionPlan {
        if planFails { throw Failure.plan }
        let payload = try JSONDecoder().decode(NodeActionPlanPayload.self, from: Data(
            "{\"action\":\"node-uninstall\",\"executable\":true,\"executeSupported\":true,\"protectedByCurrent\":\(protectedNames.contains(identity.version))}".utf8
        ))
        return NodeActionPlan(id: UUID(), request: .init(action: .uninstallNode, subject: identity.version), payload: payload, generatedAt: Date())
    }
    func executeNodeUninstall(_ plan: NodeActionPlan, environment: NodeEnvironmentContext) async throws -> NodeOperationResult {
        try await executeNPM(plan, environment: environment)
    }
    func executedEnvironments() -> [NodeEnvironmentContext] { environments }
    func refreshCount() -> Int { refreshes }
    func maximumConcurrentCount() -> Int { maximumConcurrent }
    func observedCancellation() -> Bool { cancelled }
    func resumeRefresh() { refreshContinuation?.finish() }
}
