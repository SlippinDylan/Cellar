import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedDestination: AppDestination = .overview
    @Published private(set) var homebrew: HomebrewStatus?
    @Published private(set) var node: NodeSnapshot?
    @Published private(set) var shell: ShellStatus?
    @Published private(set) var managers: SnapshotStatus?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var errorMessages: [String] = []
    @Published private(set) var activities: [ActivityEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var homebrewSearchResults: [HomebrewSearchResult] = []
    @Published private(set) var homebrewDiagnostics: [HomebrewDiagnostic] = []
    @Published private(set) var homebrewDiagnosticReport: HomebrewDiagnosticReport?
    @Published private(set) var homebrewPlan: HomebrewActionPlan?
    @Published private(set) var homebrewActionResult: HomebrewActionResult?
    @Published private(set) var homebrewOperationError: String?
    @Published private(set) var isHomebrewWorking = false
    @Published private(set) var preferredNodeVersion: String?
    @Published private(set) var nodePlan: NodeActionPlan?
    @Published private(set) var nodeActionResult: NodeActionResult?
    @Published private(set) var nodeOperationError: String?
    @Published private(set) var isNodeWorking = false

    private let service: SystemProbeService
    private let operationStore: OperationStore

    init(
        service: SystemProbeService,
        operationStore: OperationStore = .shared
    ) {
        self.service = service
        self.operationStore = operationStore
    }

    static func live() -> AppModel {
        let runner = ProcessRunner()
        let installer = ManagerSnapshotInstaller()
        let client = NodeManagerClient(runner: runner)
        return AppModel(service: SystemProbeService(
            runner: runner,
            installer: installer,
            nodeClient: client
        ))
    }

    var dashboard: DashboardSnapshot? {
        guard let homebrew, let node, let shell, let managers, let refreshedAt else { return nil }
        return DashboardSnapshot(
            homebrew: homebrew,
            node: node,
            shell: shell,
            managers: managers,
            refreshedAt: refreshedAt
        )
    }

    func refresh() async {
        guard !isRefreshing, !isHomebrewWorking, !isNodeWorking else { return }
        isRefreshing = true
        errorMessages = []
        let operationID = operationStore.begin()
        let activityID = UUID()
        activities.insert(ActivityEntry(
            id: activityID,
            date: Date(),
            title: "刷新本机环境",
            outcome: .started,
            detail: "正在读取 Homebrew、Node 和 Shell 状态"
        ), at: 0)

        defer {
            isRefreshing = false
            operationStore.end(operationID)
        }

        do {
            let installedManagers = try await service.installManagers()
            managers = installedManagers

            async let homebrewResult = capture { try await service.loadHomebrew(snapshot: installedManagers) }
            async let nodeResult = capture {
                try await service.loadNode(
                    snapshot: installedManagers,
                    preferredNodeVersion: self.preferredNodeVersion
                )
            }
            async let shellResult = capture { try await service.loadShell(snapshot: installedManagers) }
            let results = await (homebrewResult, nodeResult, shellResult)

            homebrew = assign(results.0, name: "Homebrew")
            node = assign(results.1, name: "Node")
            shell = assign(results.2, name: "Shell")
            if let outdatedError = node?.outdatedError {
                errorMessages.append("Node 更新检查：\(outdatedError)")
            }
            refreshedAt = Date()
        } catch {
            errorMessages.append("Manager 快照：\(error.localizedDescription)")
        }

        activities.removeAll { $0.id == activityID }
        activities.insert(ActivityEntry(
            id: UUID(),
            date: Date(),
            title: "刷新本机环境",
            outcome: errorMessages.isEmpty ? .succeeded : .failed,
            detail: errorMessages.isEmpty ? "已读取全部环境状态" : errorMessages.joined(separator: "；")
        ), at: 0)
    }

    func searchHomebrew(_ query: String) async {
        guard !isRefreshing, !isHomebrewWorking else { return }
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
        guard !isRefreshing, !isHomebrewWorking else { return }
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
        guard let plan = homebrewPlan, plan.canExecute, !isHomebrewWorking else { return }
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

    func prepareNodeAction(_ request: NodeActionRequest) async {
        guard !isRefreshing, !isHomebrewWorking, !isNodeWorking, let managers else { return }
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
        guard let plan = nodePlan, plan.canExecute, !isNodeWorking, let managers else { return }
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
            let operation = try await service.executeNode(
                plan,
                snapshot: managers,
                preferredNodeVersion: preferredNodeVersion
            )
            updatePreferredNodeVersion(after: plan)
            let refreshedSnapshot: NodeSnapshot?
            let postflightError: String?
            do {
                refreshedSnapshot = try await service.loadNode(
                    snapshot: managers,
                    preferredNodeVersion: preferredNodeVersion
                )
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
        } catch {
            nodeOperationError = error.localizedDescription
            if let refreshedNode = try? await service.loadNode(
                snapshot: managers,
                preferredNodeVersion: preferredNodeVersion
            ) {
                node = refreshedNode
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

    func dismissNodePlan() {
        nodePlan = nil
    }

    func dismissNodeFeedback() {
        nodeActionResult = nil
        nodeOperationError = nil
    }

    private func prepareHomebrewPlan(
        operation: @escaping @Sendable () async throws -> HomebrewActionPlan
    ) async {
        guard !isRefreshing, !isHomebrewWorking else { return }
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

    private func beginActivity(title: String, detail: String) -> UUID {
        let id = UUID()
        activities.insert(ActivityEntry(
            id: id,
            date: Date(),
            title: title,
            outcome: .started,
            detail: detail
        ), at: 0)
        return id
    }

    private func finishActivity(
        _ id: UUID,
        title: String,
        outcome: ActivityEntry.Outcome,
        detail: String,
        command: HomebrewCommandOutput? = nil
    ) {
        activities.removeAll { $0.id == id }
        activities.insert(ActivityEntry(
            id: UUID(),
            date: Date(),
            title: title,
            outcome: outcome,
            detail: detail,
            command: command
        ), at: 0)
    }

    private func assign<Value>(_ result: Result<Value, Error>, name: String) -> Value? {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            errorMessages.append("\(name)：\(error.localizedDescription)")
            return nil
        }
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
        if let detail = operation.detail?.nilIfBlank {
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

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
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
    var activityExcerpt: String {
        let normalized = split(whereSeparator: \.isNewline).joined(separator: " ")
        return normalized.count > 240 ? "\(normalized.prefix(240))…" : normalized
    }
}

private func capture<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
) async -> Result<Value, Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}
