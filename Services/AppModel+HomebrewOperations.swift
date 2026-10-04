import Foundation

extension AppModel {
    func performHomebrewMetadataUpdate() async {
        do {
            let plan = try await createHomebrewPlan { try await self.service.planHomebrewUpdate() }
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
        let operationID = operationStore.begin(context: .init(operation: .maintenance, scope: .homebrew(.formula), targets: [], stage: .checking))
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
            activityDiagnostics.record(operation: .maintenance, scope: .homebrew(.formula), detail: "", command: report.command)
        } catch {
            homebrewDiagnosticReport = nil
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
        await prepareHomebrewPlan {
            try await self.service.planHomebrewUpdate()
        }
    }

    func prepareHomebrewAddTap(_ name: String) async {
        await prepareHomebrewPlan {
            try await self.service.planHomebrewAddTap(name)
        }
    }

    func prepareHomebrewRemoveTap(_ name: String) async {
        await prepareHomebrewPlan {
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
                homebrew = HomebrewStatus(
                    executablePath: snapshot.executablePath,
                    version: snapshot.version,
                    managerAvailable: managers?.homebrewAvailable ?? homebrew?.managerAvailable ?? false,
                    snapshot: snapshot
                )
                refreshedAt = Date()
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
                if let refreshedHomebrew = try? await refresh.value {
                    homebrew = refreshedHomebrew
                    refreshedAt = Date()
                }
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
        operation: @escaping @Sendable () async throws -> HomebrewActionPlan
    ) async {
        do { homebrewPlan = try await createHomebrewPlan(operation: operation) }
        catch { homebrewOperationError = failureMessage(error) }
    }

    private func createHomebrewPlan(operation: @escaping @Sendable () async throws -> HomebrewActionPlan) async throws -> HomebrewActionPlan {
        guard !isBusy else { throw BatchOperationError.busy }
        isHomebrewWorking = true
        homebrewOperationError = nil
        homebrewActionResult = nil
        let operationID = operationStore.begin(context: .init(operation: .configuration, scope: nil, targets: [], stage: .preparing))
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

    private func recordHomebrewSummary(_ plan: HomebrewActionPlan, id: UUID, status: ActivityStatus, reason: ActivityItemReason? = nil) {
        let operation: ActivityOperationKind = switch plan.action {
        case .install: .install
        case .upgrade: .update
        case .update: .maintenance
        case .uninstallFormula, .uninstallCask, .zapCask: .uninstall
        case .addTap, .removeTap: .configuration
        }
        let scope = plan.targets.first.map { ActivityScope.homebrew($0.kind) }
        activityStore?.append(ActivitySummary(id: id, operation: operation, scope: scope,
                                             targetDisplayNames: plan.targets.map(\.name), date: Date(),
                                             status: status, itemOutcomes: plan.targets.map {
            ActivityItemSummary(displayName: $0.name, status: status.itemStatus, reason: reason ?? status.itemReason)
        }, reason: reason ?? status.itemReason))
    }
}

private extension HomebrewActionPlan {
    var activityContext: ActiveOperationContext {
        let operation: ActivityOperationKind = switch action {
        case .install: .install
        case .upgrade: .update
        case .update: .maintenance
        case .uninstallFormula, .uninstallCask, .zapCask: .uninstall
        case .addTap, .removeTap: .configuration
        }
        return .init(operation: operation, scope: targets.first.map { .homebrew($0.kind) }, targets: targets.map(\.name), stage: .executing)
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
