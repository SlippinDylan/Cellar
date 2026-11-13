import Foundation

extension AppModel {
    func performDirectNodeAction(_ request: NodeActionRequest) async {
        guard [.installNode, .useNode].contains(request.action) || request == NodeMaintenanceAction.verify.request else { return }
        let verificationTarget: NodeCacheVerification.Target?
        if request == NodeMaintenanceAction.verify.request {
            guard !isBusy, let node else { return }
            verificationTarget = .init(node: node)
        } else {
            verificationTarget = nil
        }
        if let verificationTarget {
            nodeCacheVerification = .init(target: verificationTarget, state: .running)
        }
        var verificationResult: NodeActionResult?
        defer {
            if let verificationTarget {
                let state: NodeCacheVerification.State
                if let result = verificationResult {
                    state = .completed(result)
                } else {
                    state = .failed
                }
                nodeCacheVerification = .init(target: verificationTarget, state: state)
            }
        }
        do {
            let prepared = try await createNodePlan(request)
            let plan = prepared.plan
            guard plan.canExecute else { nodeOperationError = String(localized: plan.blockingMessage); return }
            verificationResult = await executeNodeAction(plan, snapshot: prepared.snapshot)
        } catch { nodeOperationError = failureMessage(error) }
    }

    func prepareNodeAction(_ request: NodeActionRequest) async {
        do {
            let plan = try await createNodePlan(request).plan
            nodePlan = plan
            if !plan.canExecute { nodeOperationError = String(localized: plan.blockingMessage) }
        } catch { nodeOperationError = failureMessage(error) }
    }

    private func createNodePlan(_ request: NodeActionRequest) async throws -> (plan: NodeActionPlan, snapshot: SnapshotStatus) {
        guard !isBusy, let managers else { throw BatchOperationError.busy }
        guard nodeActionIsAvailable(request) else { throw BatchOperationError.reconciliationUnavailable }
        isNodeWorking = true
        nodeOperationError = nil
        nodeActionResult = nil
        let operationID = operationStore.begin(context: .init(operation: .configuration, scope: node?.summary.activityEnvironment.map(ActivityScope.nodeRuntime), targets: [], stage: .preparing))
        defer {
            isNodeWorking = false
            operationStore.end(operationID)
        }
        let plan = try await operationStore.performCancellable(operationID: operationID) {
            try Task.checkCancellation()
            let plan = try await self.service.planNode(request, snapshot: managers, preferredNodeVersion: self.preferredNodeVersion)
            try Task.checkCancellation()
            return plan
        }
        return (plan, managers)
    }

    func executeNodePlan(confirmed: NodeActionPlan? = nil) async {
        if let confirmed, nodePlan?.id != confirmed.id { nodeOperationError = String(localized: ActivityItemReason.stateChanged.message); return }
        guard let plan = nodePlan, plan.canExecute, !isBusy, let managers else { return }
        nodePlan = nil
        await executeNodeAction(plan, snapshot: managers)
    }

    @discardableResult
    private func executeNodeAction(_ plan: NodeActionPlan, snapshot managers: SnapshotStatus) async -> NodeActionResult? {
        guard !isBusy, plan.canExecute else { return nil }
        guard nodeActionIsAvailable(plan.request) else {
            nodeOperationError = String(localized: ActivityItemReason.stateUnavailable.message)
            return nil
        }
        isNodeWorking = true
        nodeOperationError = nil
        nodeActionResult = nil
        let operationID = operationStore.begin(context: nodeActivityContext(plan))
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
            if operation.batchItemStatus == .succeeded { updatePreferredNodeVersion(after: plan) }
            let refreshedSnapshot: NodeSnapshot?
            let postflightError: String?
            do {
                let refresh = Task { try await service.loadNode(snapshot: managers, preferredNodeVersion: preferredNodeVersion) }
                let refreshed = try await refresh.value
                applyNodeReadResult(.success(refreshed), includingOutdated: true)
                refreshedAt = Date()
                refreshedSnapshot = node
                postflightError = nil
            } catch {
                applyNodeReadResult(.failure(error), includingOutdated: true)
                refreshedSnapshot = nil
                postflightError = error.localizedDescription
            }
            let result = NodeActionResult(
                plan: plan,
                operation: operation,
                snapshot: refreshedSnapshot,
                postflightError: postflightError
            )
            nodeActionResult = result
            if postflightError != nil {
                nodeOperationError = String(localized: ActivityItemReason.stateUnavailable.message)
            } else if operation.batchItemStatus != .succeeded {
                nodeOperationError = String(localized: ActivityItemReason(error: BridgeError.managerFailure(code: operation.detail ?? "provider-failure", detail: nil)).message)
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: operation.status == "ok" && postflightError == nil ? .succeeded : .partiallySucceeded,
                detail: result.activityDetail
            )
            let itemStatus = operation.batchItemStatus.activityStatus
            let status = itemStatus == .succeeded && postflightError != nil ? ActivityStatus.partiallySucceeded : itemStatus
            recordNodeSummary(plan, id: activityID, status: status, reason: postflightError != nil ? .stateUnavailable : operation.activityReason)
            return result
        } catch {
            nodeOperationError = failureMessage(error)
            let refresh = Task { try await service.loadNode(snapshot: managers, preferredNodeVersion: preferredNodeVersion) }
            do {
                let refreshedNode = try await refresh.value
                applyNodeReadResult(.success(refreshedNode), includingOutdated: true)
                refreshedAt = Date()
            } catch {
                applyNodeReadResult(.failure(error), includingOutdated: true)
            }
            finishActivity(
                activityID,
                title: plan.activityTitle,
                outcome: .failed,
                detail: error.localizedDescription
            )
            recordNodeSummary(plan, id: activityID, status: error is CancellationError ? .cancelled : ActivityItemReason.postWriteStatus(error: error)?.activityStatus ?? .failed, reason: .init(error: error))
            return nil
        }
    }

    func dismissNodePlan(confirmed: NodeActionPlan? = nil) {
        if let confirmed, nodePlan?.id != confirmed.id || nodePlan?.request != confirmed.request { return }
        nodePlan = nil
    }

    func dismissNodeFeedback() {
        nodeActionResult = nil
        nodeOperationError = nil
    }

    private func nodeActionIsAvailable(_ request: NodeActionRequest) -> Bool {
        // Selecting an explicit runtime remains available to recover a failed session read.
        !nodeRefreshFailed || [.installNode, .useNode].contains(request.action)
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

    private func nodeActivityContext(_ plan: NodeActionPlan) -> ActiveOperationContext {
        let operation: ActivityOperationKind = switch plan.request.action {
        case .installPackage, .installNode, .installNVM: .install
        case .updatePackage: .update
        case .uninstallPackage, .uninstallNode: .uninstall
        case .cleanup: .maintenance
        default: .configuration
        }
        let environment = node?.summary.activityEnvironment
        let scope: ActivityScope? = switch plan.request.action {
        case .installNode, .useNode, .setDefaultNode, .uninstallNode: environment.map(ActivityScope.nodeRuntime)
        default: environment.map(ActivityScope.npm)
        }
        let names: [String] = switch plan.request.action {
        case .installPackage, .updatePackage, .uninstallPackage: plan.payload.packageName.map { [$0] } ?? []
        case .installNode, .useNode, .setDefaultNode, .uninstallNode: [plan.payload.normalizedVersion ?? plan.request.subject]
        default: []
        }
        return .init(operation: operation, scope: scope, targets: names, stage: .executing)
    }

    private func recordNodeSummary(_ plan: NodeActionPlan, id: UUID, status: ActivityStatus, reason: ActivityItemReason? = nil) {
        guard let current = operationStore.currentOperation else { preconditionFailure("Node execution owns a registered operation") }
        let context = current.context
        let scope: ActivityScope?
        if context.scope == nil, [.installNode, .useNode, .setDefaultNode, .uninstallNode].contains(plan.request.action) {
            // Only a successful controlled reread can supply a first installation's environment.
            scope = node?.summary.activityEnvironment.map(ActivityScope.nodeRuntime)
        } else { scope = context.scope }
        let names = scope == nil ? [] : context.targets
        activityStore?.append(ActivitySummary(id: id, operation: context.operation, scope: scope,
                                             targetDisplayNames: names, date: Date(), status: status,
                                             itemOutcomes: names.map { .init(displayName: $0, status: status.itemStatus, reason: reason ?? status.itemReason) },
                                             reason: reason ?? status.itemReason))
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
