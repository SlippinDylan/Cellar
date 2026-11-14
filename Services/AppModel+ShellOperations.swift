import Foundation

extension AppModel {
    func prepareShellAction(_ request: ShellActionRequest) async {
        guard !isBusy, let managers else { return }
        isShellWorking = true
        shellOperationError = nil
        shellActionResult = nil
        let operationID = operationStore.begin(context: .init(operation: .configuration, scope: .shell, targets: [], stage: .preparing))
        defer {
            isShellWorking = false
            operationStore.end(operationID)
        }
        do {
            shellPlan = try await operationStore.performCancellable(operationID: operationID) {
                try await self.service.planShell(request, snapshot: managers)
            }
        } catch {
            shellOperationError = failureMessage(error)
        }
    }

    func executeShellPlan(confirmed: ShellActionPlan? = nil) async {
        if let confirmed, shellPlan?.id != confirmed.id || shellPlan?.request != confirmed.request { return }
        guard let plan = shellPlan, plan.canExecute, !isBusy, let managers else { return }
        shellPlan = nil
        isShellWorking = true
        shellOperationError = nil
        shellActionResult = nil
        let operation: ActivityOperationKind = plan.request.action == .tidy ? .maintenance : [.installOhMyZsh, .installPlugin].contains(plan.request.action) ? .install : .configuration
        let operationID = operationStore.begin(context: .init(operation: operation, scope: .shell, targets: [], stage: .executing))
        let activityID = beginActivity(title: plan.activityTitle, detail: "正在执行 Shell 操作")
        defer {
            isShellWorking = false
            operationStore.end(operationID)
        }

        do {
            let operation = try await operationStore.performCancellable(operationID: operationID) {
                try await self.service.executeShell(plan, snapshot: managers)
            }
            let refreshedShell: ShellStatus?
            let postflightError: String?
            do {
                let refresh = Task { try await service.loadShell(snapshot: managers) }
                refreshedShell = try await refresh.value
                postflightError = nil
            } catch {
                applyShellReadResult(.failure(error))
                refreshedShell = nil
                postflightError = error.localizedDescription
            }
            if let refreshedShell {
                applyShellReadResult(.success(refreshedShell))
                refreshedAt = Date()
            }
            let result = ShellActionResult(
                plan: plan,
                operation: operation,
                snapshot: refreshedShell,
                postflightError: postflightError
            )
            shellActionResult = result
            if operation.status != "ok" { shellOperationError = String(localized: ActivityItemReason.providerFailure.message) }
            if postflightError != nil {
                shellOperationError = String(localized: ActivityItemReason.stateUnavailable.message)
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: operation.status == "ok" && postflightError == nil ? .succeeded : .partiallySucceeded,
                detail: result.activityDetail
            )
            recordShellSummary(plan, id: activityID, status: operation.status == "ok" ? postflightError == nil ? .succeeded : .partiallySucceeded : operation.status == "partial" ? .partiallySucceeded : .failed,
                               reason: postflightError != nil ? .stateUnavailable : nil)
        } catch {
            let evidence = error as? ShellExecutionFailure
            let outcome = evidence?.outcome ?? (error is CancellationError ? .cancelled : ActivityStatus.failed)
            let reason = outcome == .unknown ? ActivityItemReason.stateUnavailable : ActivityItemReason(error: evidence?.cause ?? error)
            shellOperationError = String(localized: reason.message)
            let refresh = Task { try await service.loadShell(snapshot: managers) }
            var refreshedShell: ShellStatus?
            var refreshError: String?
            do {
                let snapshot = try await refresh.value
                refreshedShell = snapshot
                applyShellReadResult(.success(snapshot))
                refreshedAt = Date()
            } catch {
                refreshError = error.localizedDescription
                applyShellReadResult(.failure(error))
            }
            if let operation = evidence?.operation {
                shellActionResult = .init(plan: plan, operation: operation, snapshot: refreshedShell, postflightError: refreshError, executionOutcome: outcome)
            }
            let diagnostic = [evidence?.diagnosticDetail ?? error.localizedDescription, refreshError ?? ""].joined(separator: "\n")
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: outcome == .partiallySucceeded ? .partiallySucceeded : outcome == .cancelled ? .cancelled : .failed,
                detail: diagnostic
            )
            recordShellSummary(plan, id: activityID, status: outcome, reason: reason)
        }
    }

    func dismissShellPlan(confirmed: ShellActionPlan? = nil) {
        if let confirmed, shellPlan?.id != confirmed.id || shellPlan?.request != confirmed.request { return }
        shellPlan = nil
    }

    func dismissShellFeedback() {
        shellActionResult = nil
        shellOperationError = nil
    }

    private func recordShellSummary(_ plan: ShellActionPlan, id: UUID, status: ActivityStatus, reason: ActivityItemReason? = nil) {
        let operation: ActivityOperationKind = switch plan.request.action {
        case .installOhMyZsh, .installPlugin: .install
        case .tidy: .maintenance
        case .setPlugins, .switchTheme: .configuration
        }
        let step = ShellStepOutcome(step: .init(action: plan.request.action), status: status.itemStatus)
        activityStore?.append(ActivitySummary(id: id, operation: operation, scope: .shell,
                                             targetDisplayNames: [], date: Date(), status: status, itemOutcomes: [step.summary], reason: reason))
    }
}

private extension ShellActionPlan {
    var activityTitle: String {
        switch request.action {
        case .installOhMyZsh: "安装 Oh My Zsh"
        case .installPlugin: "安装 Shell 插件"
        case .setPlugins: "更新 Shell 插件配置"
        case .switchTheme: "切换 Shell 主题"
        case .tidy: "整理 Shell 文件"
        }
    }
}

private extension ShellActionResult {
    var activityDetail: String {
        var parts = ["状态 \(operation.status)", "退出状态 \(operation.exitCode)", operation.operationId, operation.logFile]
        if let detail = operation.detail { parts.append(detail) }
        if !operation.backupPath.isEmpty {
            parts.append("备份：\(operation.backupPath)")
        }
        if let postflightError {
            parts.append("复查失败：\(postflightError)")
        } else {
            parts.append("已重新读取 Shell 状态")
        }
        return parts.joined(separator: "；")
    }
}
