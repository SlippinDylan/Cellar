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

    func searchHomebrew(_ query: String) async {
        guard !isBusy else { return }
        isHomebrewWorking = true
        homebrewOperationError = nil
        let operationID = operationStore.begin(context: .init(operation: .refresh, scope: .homebrew(.formula), targets: [], stage: .checking))
        defer {
            isHomebrewWorking = false
            operationStore.end(operationID)
        }
        do {
            homebrewSearchResults = try await service.searchHomebrew(query)
        } catch {
            homebrewSearchResults = []
            homebrewOperationError = failureMessage(error)
        }
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
            homebrewDiagnostics = report.diagnostics
            homebrewDiagnosticRecordID = operationID
            activityDiagnostics.record(id: operationID, operation: .maintenance, scope: .homebrewDiagnostics, detail: "", command: report.command)
        } catch {
            homebrewDiagnosticReport = nil
            homebrewDiagnosticRecordID = nil
            homebrewDiagnostics = []
            homebrewOperationError = failureMessage(error)
        }
    }

    func prepareHomebrewInstall(_ identity: HomebrewPackageIdentity) async {
        await prepareHomebrewPlan {
            try await self.service.planHomebrewInstall(identity)
        }
    }

    func prepareHomebrewInstall(_ identities: [HomebrewPackageIdentity]) async {
        await prepareHomebrewPlan {
            try await self.service.planHomebrewInstall(identities)
        }
    }

    func prepareHomebrewUpgrade(_ targets: [HomebrewPackageIdentity]) async {
        await prepareHomebrewPlan {
            try await self.service.planHomebrewUpgrade(targets)
        }
    }

    func prepareHomebrewUpdate() async {
        await prepareHomebrewPlan(context: .init(operation: .updateHomebrewMetadata, scope: .homebrewMetadata, targets: [], stage: .preparing)) {
            try await self.service.planHomebrewUpdate()
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

    func prepareHomebrewUninstall(_ identity: HomebrewPackageIdentity, zap: Bool = false) async {
        await prepareHomebrewPlan {
            switch identity.kind {
            case .formula:
                return try await self.service.planHomebrewFormulaUninstall(identity.name)
            case .cask:
                return try await self.service.planHomebrewCaskUninstall(identity.name, zap: zap)
            }
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
        let activityID = beginActivity(title: plan.activityTitle, detail: "正在执行 Homebrew 操作")

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
            let activityOutcome: ActivityEntry.Outcome
            let activityDetail: String
            switch result.outcome {
            case .succeeded:
                activityOutcome = .succeeded
                activityDetail = result.activityDetail(prefix: "操作完成并已复查本机状态")
            case .partial:
                activityOutcome = .partiallySucceeded
                let message = result.command.terminationStatus == 0
                    ? "命令结束后复查未确认所有目标，但部分目标状态已经改变；请检查命令输出"
                    : "命令报告失败，但复查发现目标状态已经改变；请检查命令输出"
                homebrewOperationError = String(localized: ActivityItemReason.providerFailure.message)
                activityDetail = result.activityDetail(prefix: message)
            case .failed:
                activityOutcome = .failed
                let message = result.command.standardError.nilIfBlank ?? "Homebrew 操作没有完成"
                homebrewOperationError = String(localized: ActivityItemReason.providerFailure.message)
                activityDetail = result.activityDetail(prefix: message)
            case .stateUnknown:
                activityOutcome = .failed
                let message = result.postflightError ?? "操作结束后无法确认本机状态"
                homebrewOperationError = String(localized: ActivityItemReason.stateUnavailable.message)
                activityDetail = result.activityDetail(prefix: message)
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: activityOutcome,
                detail: activityDetail,
                command: result.command
            )
            let status: ActivityStatus = switch result.outcome {
            case .succeeded: .succeeded
            case .partial: .partiallySucceeded
            case .failed: .failed
            case .stateUnknown: .unknown
            }
            recordHomebrewSummary(plan, id: activityID, status: status)
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
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: .failed,
                detail: error.localizedDescription
            )
            recordHomebrewSummary(plan, id: activityID, status: error is CancellationError ? .cancelled : .failed, reason: .init(error: error))
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
    var activityTitle: String {
        switch action {
        case .install: "安装 Homebrew 软件包"
        case .upgrade: "升级 Homebrew 软件包"
        case .update: "更新 Homebrew 元数据"
        case .addTap: "添加 Homebrew Tap"
        case .removeTap: "移除 Homebrew Tap"
        case .uninstallFormula: "卸载 Homebrew Formula"
        case .uninstallCask: "卸载 Homebrew Cask"
        case .zapCask: "卸载并清理 Homebrew Cask"
        }
    }
}

private extension HomebrewActionResult {
    func activityDetail(prefix: String) -> String {
        var parts = [prefix, "退出状态 \(command.terminationStatus)"]
        if let output = command.standardOutput.nilIfBlank {
            parts.append("stdout：\(output.activityExcerpt)")
        }
        if let error = command.standardError.nilIfBlank {
            parts.append("stderr：\(error.activityExcerpt)")
        }
        if command.standardOutputWasTruncated || command.standardErrorWasTruncated {
            parts.append("命令输出已截断")
        }
        return parts.joined(separator: "；")
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
