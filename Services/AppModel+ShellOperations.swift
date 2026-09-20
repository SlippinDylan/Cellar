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
            shellPlan = try await service.planShell(request, snapshot: managers)
        } catch {
            shellOperationError = error.localizedDescription
        }
    }

    func executeShellPlan() async {
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
            let operation = try await service.executeShell(plan, snapshot: managers)
            let refreshedShell: ShellStatus?
            let postflightError: String?
            do {
                refreshedShell = try await service.loadShell(snapshot: managers)
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
        } catch {
            shellOperationError = error.localizedDescription
            if let refreshedShell = try? await service.loadShell(snapshot: managers) {
                shell = refreshedShell
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

    func dismissShellPlan() {
        shellPlan = nil
    }

    func dismissShellFeedback() {
        shellActionResult = nil
        shellOperationError = nil
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
