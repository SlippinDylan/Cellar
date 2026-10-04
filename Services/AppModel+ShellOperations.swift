import Foundation

extension AppModel {
    func prepareShellAction(_ request: ShellActionRequest) async {
        guard !isBusy, let managers else { return }
        isShellWorking = true
        shellOperationError = nil
        shellActionResult = nil
        let operationID = operationStore.begin()
        defer {
            isShellWorking = false
            operationStore.end(operationID)
        }
        do {
            shellPlan = try await operationStore.performCancellable(operationID: operationID) {
                try await self.service.planShell(request, snapshot: managers)
            }
        } catch {
            shellOperationError = error.localizedDescription
        }
    }

    func executeShellPlan(confirmed: ShellActionPlan? = nil) async {
        if let confirmed, shellPlan?.id != confirmed.id { return }
        guard let plan = shellPlan, plan.canExecute, !isBusy, let managers else { return }
        shellPlan = nil
        isShellWorking = true
        shellOperationError = nil
        shellActionResult = nil
        let operationID = operationStore.begin()
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
                refreshedShell = nil
                postflightError = error.localizedDescription
            }
            if let refreshedShell {
                shell = refreshedShell
                refreshedAt = Date()
            }
            let result = ShellActionResult(
                plan: plan,
                operation: operation,
                snapshot: refreshedShell,
                postflightError: postflightError
            )
            shellActionResult = result
            if let postflightError {
                shellOperationError = "操作已结束，但无法复查 Shell 状态：\(postflightError)"
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: operation.status == "ok" && postflightError == nil ? .succeeded : .partiallySucceeded,
                detail: result.activityDetail
            )
            recordShellSummary(plan, status: operation.status == "ok" && postflightError == nil ? .succeeded : .partiallySucceeded)
        } catch {
            shellOperationError = error.localizedDescription
            let refresh = Task { try await service.loadShell(snapshot: managers) }
            if let refreshedShell = try? await refresh.value {
                shell = refreshedShell
                refreshedAt = Date()
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: .failed,
                detail: error.localizedDescription
            )
            recordShellSummary(plan, status: error is CancellationError ? .cancelled : .failed)
        }
    }

    func dismissShellPlan(confirmed: ShellActionPlan? = nil) {
        if let confirmed, shellPlan?.id != confirmed.id { return }
        shellPlan = nil
    }

    func dismissShellFeedback() {
        shellActionResult = nil
        shellOperationError = nil
    }

    private func recordShellSummary(_ plan: ShellActionPlan, status: ActivityStatus) {
        let operation: ActivityOperationKind = switch plan.request.action {
        case .installOhMyZsh, .installPlugin: .install
        case .tidy: .maintenance
        case .setPlugins, .switchTheme: .configuration
        }
        activityStore?.append(ActivitySummary(id: UUID(), operation: operation, scope: nil,
                                             targetDisplayNames: [], date: Date(), status: status, itemOutcomes: []))
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
        var parts = ["状态 \(operation.status)", "退出状态 \(operation.exitCode)"]
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
