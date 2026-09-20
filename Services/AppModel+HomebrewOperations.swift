import Foundation

extension AppModel {
    func searchHomebrew(_ query: String) async {
        guard !isBusy else { return }
        isHomebrewWorking = true
        homebrewOperationError = nil
        let operationID = operationStore.begin()
        defer {
            isHomebrewWorking = false
            operationStore.end(operationID)
        }
        do {
            homebrewSearchResults = try await service.searchHomebrew(query)
        } catch {
            homebrewSearchResults = []
            homebrewOperationError = error.localizedDescription
        }
    }

    func diagnoseHomebrew() async {
        guard !isBusy else { return }
        isHomebrewWorking = true
        homebrewOperationError = nil
        let operationID = operationStore.begin()
        defer {
            isHomebrewWorking = false
            operationStore.end(operationID)
        }
        do {
            let report = try await service.diagnoseHomebrew()
            homebrewDiagnosticReport = report
            homebrewDiagnostics = report.diagnostics
        } catch {
            homebrewDiagnosticReport = nil
            homebrewDiagnostics = []
            homebrewOperationError = error.localizedDescription
        }
    }

    func prepareHomebrewInstall(_ identity: HomebrewPackageIdentity) async {
        await prepareHomebrewPlan {
            try await self.service.planHomebrewInstall(identity)
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

    func executeHomebrewPlan() async {
        guard let plan = homebrewPlan, plan.canExecute, !isBusy else { return }
        homebrewPlan = nil
        isHomebrewWorking = true
        homebrewOperationError = nil
        homebrewActionResult = nil
        let operationID = operationStore.begin()
        let activityID = beginActivity(title: plan.activityTitle, detail: "正在执行 Homebrew 操作")

        defer {
            isHomebrewWorking = false
            operationStore.end(operationID)
        }

        do {
            let result = try await service.executeHomebrew(plan)
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
                let message = "命令报告失败，但复查发现目标状态已经改变；请检查命令输出"
                homebrewOperationError = message
                activityDetail = result.activityDetail(prefix: message)
            case .failed:
                activityOutcome = .failed
                let message = result.command.standardError.nilIfBlank ?? "Homebrew 操作没有完成"
                homebrewOperationError = message
                activityDetail = result.activityDetail(prefix: message)
            case .stateUnknown:
                activityOutcome = .failed
                let message = result.postflightError ?? "操作结束后无法确认本机状态"
                homebrewOperationError = message
                activityDetail = result.activityDetail(prefix: message)
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: activityOutcome,
                detail: activityDetail,
                command: result.command
            )
        } catch {
            homebrewOperationError = error.localizedDescription
            if let managers,
               let refreshedHomebrew = try? await service.loadHomebrew(snapshot: managers)
            {
                homebrew = refreshedHomebrew
                refreshedAt = Date()
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: .failed,
                detail: error.localizedDescription
            )
        }
    }

    func dismissHomebrewPlan() {
        homebrewPlan = nil
    }

    func dismissHomebrewFeedback() {
        homebrewActionResult = nil
        homebrewOperationError = nil
    }

    private func prepareHomebrewPlan(
        operation: @escaping @Sendable () async throws -> HomebrewActionPlan
    ) async {
        guard !isBusy else { return }
        isHomebrewWorking = true
        homebrewOperationError = nil
        homebrewActionResult = nil
        let operationID = operationStore.begin()
        defer {
            isHomebrewWorking = false
            operationStore.end(operationID)
        }
        do {
            homebrewPlan = try await operation()
        } catch {
            homebrewOperationError = error.localizedDescription
        }
    }
}

private extension HomebrewActionPlan {
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
