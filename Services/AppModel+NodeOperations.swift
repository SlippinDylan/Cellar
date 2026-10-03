import Foundation

extension AppModel {
    func prepareNodeAction(_ request: NodeActionRequest) async {
        guard !isBusy, let managers else { return }
        isNodeWorking = true
        nodeOperationError = nil
        nodeActionResult = nil
        let operationID = operationStore.begin()
        defer {
            isNodeWorking = false
            operationStore.end(operationID)
        }
        do {
            nodePlan = try await service.planNode(
                request,
                snapshot: managers,
                preferredNodeVersion: preferredNodeVersion
            )
        } catch {
            nodeOperationError = error.localizedDescription
        }
    }

    func executeNodePlan() async {
        guard let plan = nodePlan, plan.canExecute, !isBusy, let managers else { return }
        nodePlan = nil
        isNodeWorking = true
        nodeOperationError = nil
        nodeActionResult = nil
        let operationID = operationStore.begin()
        let activityID = beginActivity(title: plan.activityTitle, detail: "正在执行 Node 操作")
        defer {
            isNodeWorking = false
            operationStore.end(operationID)
        }

        do {
            let operation = try await operationStore.performCancellable(operationID: operationID) {
                try await self.service.executeNode(plan, snapshot: managers,
                                                   preferredNodeVersion: self.preferredNodeVersion)
            }
            updatePreferredNodeVersion(after: plan)
            let refreshedSnapshot: NodeSnapshot?
            let postflightError: String?
            do {
                let refresh = Task { try await service.loadNode(snapshot: managers, preferredNodeVersion: preferredNodeVersion) }
                refreshedSnapshot = try await refresh.value
                postflightError = nil
            } catch {
                refreshedSnapshot = nil
                postflightError = error.localizedDescription
            }
            if let refreshedSnapshot {
                node = refreshedSnapshot
                refreshedAt = Date()
            }
            let result = NodeActionResult(
                plan: plan,
                operation: operation,
                snapshot: refreshedSnapshot,
                postflightError: postflightError
            )
            nodeActionResult = result
            if let postflightError {
                nodeOperationError = "操作已结束，但无法复查 Node 状态：\(postflightError)"
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: operation.status == "ok" && postflightError == nil ? .succeeded : .partiallySucceeded,
                detail: result.activityDetail
            )
            recordNodeSummary(plan, status: operation.status == "ok" && postflightError == nil ? .succeeded : .partiallySucceeded)
        } catch {
            nodeOperationError = error.localizedDescription
            let refresh = Task { try await service.loadNode(snapshot: managers, preferredNodeVersion: preferredNodeVersion) }
            if let refreshedNode = try? await refresh.value {
                node = refreshedNode
                refreshedAt = Date()
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: .failed,
                detail: error.localizedDescription
            )
            recordNodeSummary(plan, status: error is CancellationError ? .cancelled : .failed)
        }
    }

    func dismissNodePlan() {
        nodePlan = nil
    }

    func dismissNodeFeedback() {
        nodeActionResult = nil
        nodeOperationError = nil
    }

    private func updatePreferredNodeVersion(after plan: NodeActionPlan) {
        switch plan.request.action {
        case .useNode:
            preferredNodeVersion = plan.payload.normalizedVersion ?? plan.request.subject
        case .setDefaultNode:
            preferredNodeVersion = nil
        case .uninstallNode where preferredNodeVersion == plan.payload.normalizedVersion:
            preferredNodeVersion = nil
        default:
            break
        }
    }

    private func recordNodeSummary(_ plan: NodeActionPlan, status: ActivityStatus) {
        let operation: ActivityOperationKind = switch plan.request.action {
        case .installPackage, .installNode, .installNVM: .install
        case .updatePackage: .update
        case .uninstallPackage, .uninstallNode: .uninstall
        case .cleanup: .maintenance
        default: .configuration
        }
        let scope: ActivityScope?
        let names: [String]
        switch plan.request.action {
        case .installPackage, .updatePackage, .uninstallPackage:
            scope = node.map { snapshot in .npm(NodeEnvironmentContext(
                identifier: snapshot.summary.nodeVersion, nodeVersion: snapshot.summary.nodeVersion,
                npmVersion: snapshot.summary.npmVersion
            )) }
            names = plan.payload.packageName.map { [$0] } ?? []
        default:
            scope = nil
            names = []
        }
        activityStore?.append(ActivitySummary(id: UUID(), operation: operation, scope: scope,
                                             targetDisplayNames: names, date: Date(), status: status,
                                             itemOutcomes: names.map { .init(displayName: $0, status: status.itemStatus, reason: status.itemReason) }))
    }
}

private extension NodeActionPlan {
    var activityTitle: String {
        switch request.action {
        case .installPackage: "安装 npm 全局包"
        case .uninstallPackage: "卸载 npm 全局包"
        case .updatePackage: "更新 npm 全局包"
        case .setRegistry, .deleteRegistry, .setScopeRegistry, .deleteScopeRegistry: "修改 npm Registry"
        case .installNVM: "安装 nvm"
        case .installNode: "安装 Node 版本"
        case .useNode: "切换 Cellar Node 会话"
        case .setDefaultNode: "设置默认 Node 版本"
        case .uninstallNode: "卸载 Node 版本"
        case .cleanup: "维护 Node 环境"
        case .writeProjectNVMRC: "写入项目 .nvmrc"
        }
    }
}

private extension NodeActionResult {
    var activityDetail: String {
        var parts = ["状态 \(operation.status)", "退出状态 \(operation.exitCode)"]
        if let detail = operation.detail?.nonblank {
            parts.append(detail)
        }
        if let postflightError {
            parts.append("复查失败：\(postflightError)")
        } else {
            parts.append("已重新读取 Node 状态")
        }
        return parts.joined(separator: "；")
    }
}

private extension String {
    var nonblank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
