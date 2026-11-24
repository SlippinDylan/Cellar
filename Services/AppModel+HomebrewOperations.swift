import Foundation

extension AppModel {
    func performHomebrewMetadataUpdate() async {
        do {
            let plan = try await createHomebrewPlan(context: .init(operation: .updateHomebrewMetadata, scope: .homebrewMetadata, targets: [], stage: .preparing)) {
                try await self.service.planHomebrewUpdate()
            }
            await executeHomebrewAction(plan)
        } catch { homebrewOperationError = failureMessage(error) }
    }

    func diagnoseHomebrew() async {
        guard !isBusy else { return }
        isHomebrewWorking = true
        homebrewOperationError = nil
        let operationID = operationStore.begin(context: .init(operation: .maintenance, scope: .homebrewDiagnostics, targets: [], stage: .checking))
        defer {
            isHomebrewWorking = false
            operationStore.end(operationID)
        }
        do {
            let report = try await operationStore.performCancellable(operationID: operationID) {
                try await self.service.diagnoseHomebrew()
            }
            homebrewDiagnosticReport = report
            homebrewDiagnosticRecordID = operationID
            activityDiagnostics.record(id: operationID, operation: .maintenance, scope: .homebrewDiagnostics, detail: "", command: report.command)
        } catch {
            homebrewDiagnosticReport = nil
            homebrewDiagnosticRecordID = nil
            homebrewOperationError = failureMessage(error)
        }
    }

    func prepareHomebrewAddTap(_ name: String) async {
        guard ActivitySummarySanitizer.validHomebrewTap(name) else { homebrewOperationError = String(localized: ActivityItemReason.preparationFailed.message); return }
        await prepareHomebrewPlan(context: .init(operation: .addHomebrewTap, scope: .homebrewTaps, targets: [name], stage: .preparing)) {
            try await self.service.planHomebrewAddTap(name)
        }
    }

    func prepareHomebrewRemoveTap(_ name: String) async {
        guard ActivitySummarySanitizer.validHomebrewTap(name) else { homebrewOperationError = String(localized: ActivityItemReason.preparationFailed.message); return }
        await prepareHomebrewPlan(context: .init(operation: .removeHomebrewTap, scope: .homebrewTaps, targets: [name], stage: .preparing)) {
            try await self.service.planHomebrewRemoveTap(name)
        }
    }

    func executeHomebrewPlan(confirmed: HomebrewActionPlan? = nil) async {
        if let confirmed, homebrewPlan?.id != confirmed.id || homebrewPlan?.action != confirmed.action { return }
        guard let plan = homebrewPlan, plan.canExecute, !isBusy else { return }
        homebrewPlan = nil
        await executeHomebrewAction(plan)
    }

    private func executeHomebrewAction(_ plan: HomebrewActionPlan) async {
        guard !isBusy, plan.canExecute else { return }
        guard homebrewActionIsAvailable(plan.action) else {
            homebrewOperationError = String(localized: ActivityItemReason.stateUnavailable.message)
            return
        }
        isHomebrewWorking = true
        homebrewOperationError = nil
        homebrewActionResult = nil
        let context = plan.activityContext
        let operationID = operationStore.begin(context: context)

        defer {
            isHomebrewWorking = false
            operationStore.end(operationID)
        }

        do {
            let result = try await operationStore.performCancellable(operationID: operationID) {
                try await self.service.executeHomebrew(plan)
            }
            homebrewActionResult = result
            if let snapshot = result.snapshot {
                applyHomebrewReadResult(.success(HomebrewStatus(
                    executablePath: snapshot.executablePath,
                    version: snapshot.version,
                    managerAvailable: managers?.homebrewAvailable ?? homebrew?.managerAvailable ?? false,
                    snapshot: snapshot
                )), includingOutdated: true)
                refreshedAt = Date()
            } else {
                applyHomebrewReadResult(.failure(BatchOperationError.reconciliationUnavailable), includingOutdated: true)
            }
            let diagnosticDetail: String
            switch result.outcome {
            case .succeeded:
                diagnosticDetail = result.diagnosticDetail(prefix: "Completed and verified local state")
            case .partial:
                let message = result.command.terminationStatus == 0
                    ? "Postflight could not verify all targets, but some target states changed"
                    : "Command reported failure, but postflight observed partial state changes"
                homebrewOperationError = String(localized: ActivityItemReason.providerFailure.message)
                diagnosticDetail = result.diagnosticDetail(prefix: message)
            case .failed:
                let message = result.command.standardError.nilIfBlank ?? "Homebrew operation did not complete"
                homebrewOperationError = String(localized: ActivityItemReason.providerFailure.message)
                diagnosticDetail = result.diagnosticDetail(prefix: message)
            case .stateUnknown:
                let message = result.postflightError ?? "Could not verify local state after operation"
                homebrewOperationError = String(localized: ActivityItemReason.stateUnavailable.message)
                diagnosticDetail = result.diagnosticDetail(prefix: message)
            }
            recordDiagnostic(id: operationID, detail: diagnosticDetail, command: result.command)
            let status: ActivityStatus = switch result.outcome {
            case .succeeded: .succeeded
            case .partial: .partiallySucceeded
            case .failed: .failed
            case .stateUnknown: .unknown
            }
            recordHomebrewSummary(plan, id: operationID, status: status)
        } catch {
            homebrewOperationError = failureMessage(error)
            if let managers {
                let refresh = Task { try await service.loadHomebrew(snapshot: managers) }
                do {
                    let refreshedHomebrew = try await refresh.value
                    applyHomebrewReadResult(.success(refreshedHomebrew), includingOutdated: true)
                    refreshedAt = Date()
                } catch {
                    applyHomebrewReadResult(.failure(error), includingOutdated: true)
                }
            } else {
                applyHomebrewReadResult(.failure(error), includingOutdated: true)
            }
            recordDiagnostic(id: operationID, detail: error.localizedDescription)
            recordHomebrewSummary(plan, id: operationID, status: error is CancellationError ? .cancelled : .failed, reason: .init(error: error))
        }
    }

    func dismissHomebrewPlan(confirmed: HomebrewActionPlan? = nil) {
        if let confirmed, homebrewPlan?.id != confirmed.id || homebrewPlan?.action != confirmed.action { return }
        homebrewPlan = nil
    }

    func dismissHomebrewFeedback() {
        homebrewActionResult = nil
        homebrewOperationError = nil
    }

    private func prepareHomebrewPlan(
        context: ActiveOperationContext = .init(operation: .configuration, scope: nil, targets: [], stage: .preparing),
        operation: @escaping @Sendable () async throws -> HomebrewActionPlan
    ) async {
        do { homebrewPlan = try await createHomebrewPlan(context: context, operation: operation) }
        catch { homebrewOperationError = failureMessage(error) }
    }

    private func createHomebrewPlan(context: ActiveOperationContext = .init(operation: .configuration, scope: nil, targets: [], stage: .preparing),
                                    operation: @escaping @Sendable () async throws -> HomebrewActionPlan) async throws -> HomebrewActionPlan {
        guard !isBusy else { throw BatchOperationError.busy }
        isHomebrewWorking = true
        homebrewOperationError = nil
        homebrewActionResult = nil
        let operationID = operationStore.begin(context: context)
        defer {
            isHomebrewWorking = false
            operationStore.end(operationID)
        }
        return try await operationStore.performCancellable(operationID: operationID) {
            try Task.checkCancellation()
            let plan = try await operation()
            try Task.checkCancellation()
            return plan
        }
    }

    private func homebrewActionIsAvailable(_ action: HomebrewAction) -> Bool {
        switch action {
        case .update: return true
        case .addTap, .removeTap:
            return !homebrewRefreshFailed && homebrew?.snapshot?.sectionErrors[.taps] == nil
        case .upgrade:
            return canMutatePackages(in: .homebrew(.formula)) && homebrew?.snapshot?.sectionErrors[.outdated] == nil
        case .install, .uninstallFormula, .uninstallCask, .zapCask:
            return canMutatePackages(in: .homebrew(.formula))
        }
    }

    private func recordHomebrewSummary(_ plan: HomebrewActionPlan, id: UUID, status: ActivityStatus, reason: ActivityItemReason? = nil) {
        let context = plan.activityContext
        activityStore?.append(ActivitySummary(id: id, operation: context.operation, scope: context.scope,
                                             targetDisplayNames: context.targets, date: Date(),
                                             status: status, itemOutcomes: context.targets.map {
            ActivityItemSummary(displayName: $0, status: status.itemStatus, reason: reason ?? status.itemReason)
        }, reason: reason ?? status.itemReason))
    }
}

private extension HomebrewActionPlan {
    var activityContext: ActiveOperationContext {
        let operation: ActivityOperationKind = switch action {
        case .install: .install
        case .upgrade: .update
        case .update: .updateHomebrewMetadata
        case .uninstallFormula, .uninstallCask, .zapCask: .uninstall
        case .addTap: .addHomebrewTap
        case .removeTap: .removeHomebrewTap
        }
        let scope: ActivityScope
        let names: [String]
        switch action {
        case .addTap, .removeTap:
            guard let tapName else { preconditionFailure("Tap plans require a validated Tap name") }
            scope = .homebrewTaps
            names = [tapName]
        case .update:
            scope = .homebrewMetadata
            names = []
        case .install, .upgrade, .uninstallFormula, .uninstallCask, .zapCask:
            guard let target = targets.first else { preconditionFailure("Package plans require typed targets") }
            scope = .homebrew(target.kind)
            names = targets.map(\.name)
        }
        return .init(operation: operation, scope: scope, targets: names, stage: .executing)
    }
}

private extension HomebrewActionResult {
    func diagnosticDetail(prefix: String) -> String {
        var parts = [prefix, "exit \(command.terminationStatus)"]
        if let output = command.standardOutput.nilIfBlank {
            parts.append("stdout: \(output.activityExcerpt)")
        }
        if let error = command.standardError.nilIfBlank {
            parts.append("stderr: \(error.activityExcerpt)")
        }
        if command.standardOutputWasTruncated || command.standardErrorWasTruncated {
            parts.append("output truncated")
        }
        return parts.joined(separator: "; ")
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    var activityExcerpt: String {
        let normalized = split(whereSeparator: \.isNewline).joined(separator: " ")
        return normalized.count > 240 ? "\(normalized.prefix(240))…" : normalized
    }
}
