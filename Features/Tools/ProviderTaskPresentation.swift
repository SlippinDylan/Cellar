import SwiftUI

enum ProviderTaskSurface { case tools, sources, terminal }

struct ProviderTaskPresentation: ViewModifier {
    @ObservedObject var model: AppModel
    let surface: ProviderTaskSurface
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            ProviderTaskFeedback(model: model)
            content
        }
        .sheet(item: nodeConfirmation) { plan in
            NodeTaskConfirmation(plan: plan, cancel: { model.dismissNodePlan(confirmed: plan) }, confirm: { Task { await model.executeNodePlan(confirmed: plan) } })
        }
        .sheet(item: homebrewConfirmation) { plan in
            TapTaskConfirmation(plan: plan, cancel: { model.dismissHomebrewPlan(confirmed: plan) }, confirm: { Task { await model.executeHomebrewPlan(confirmed: plan) } })
        }
        .sheet(item: shellConfirmation) { plan in
            ShellTaskConfirmation(plan: plan, cancel: { model.dismissShellPlan(confirmed: plan) }, confirm: { Task { await model.executeShellPlan(confirmed: plan) } })
        }
    }
    var nodeConfirmation: Binding<NodeActionPlan?> {
        let presented = nodePlanForSurface
        return Binding(get: { nodePlanForSurface }, set: {
            if $0 == nil, let presented { model.dismissNodePlan(confirmed: presented) }
        })
    }
    var homebrewConfirmation: Binding<HomebrewActionPlan?> {
        let presented = homebrewPlanForSurface
        return Binding(get: { homebrewPlanForSurface }, set: {
            if $0 == nil, let presented { model.dismissHomebrewPlan(confirmed: presented) }
        })
    }
    var shellConfirmation: Binding<ShellActionPlan?> {
        let presented = shellPlanForSurface
        return Binding(get: { shellPlanForSurface }, set: {
            if $0 == nil, let presented { model.dismissShellPlan(confirmed: presented) }
        })
    }
    private var nodePlanForSurface: NodeActionPlan? {
        guard let plan = model.nodePlan, ![.installNode, .useNode].contains(plan.request.action),
              surface == (plan.request.action.isRegistryConfiguration ? .sources : .tools),
              !(plan.request.action == .cleanup && plan.request.subject == NodeMaintenanceAction.verify.rawValue) else { return nil }
        return plan
    }
    private var homebrewPlanForSurface: HomebrewActionPlan? {
        guard surface == .sources, let plan = model.homebrewPlan, [.addTap, .removeTap].contains(plan.action) else { return nil }
        return plan
    }
    private var shellPlanForSurface: ShellActionPlan? {
        guard let plan = model.shellPlan, surface == (plan.request.action == .tidy ? .tools : .terminal) else { return nil }
        return plan
    }
}

struct ProviderTaskFeedback: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isNodeWorking || model.isHomebrewWorking || model.isShellWorking {
                HStack { ProgressView().controlSize(.small); Text("Working on Environment") }
            }
            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                if let plan = model.nodePlan, !plan.canExecute { Text(plan.blockingMessage) }
            }
            if let result = model.nodeActionResult {
                let status = result.operation.batchItemStatus.activityStatus
                resultLabel(status == .succeeded && result.postflightError != nil ? .partiallySucceeded : status)
            }
            if let result = model.shellActionResult {
                let status: ActivityStatus = result.operation.status == "ok" ? result.postflightError == nil ? .succeeded : .partiallySucceeded : result.operation.status == "partial" ? .partiallySucceeded : .failed
                resultLabel(status)
            }
            if let result = model.homebrewActionResult {
                let status: ActivityStatus = switch result.outcome {
                case .succeeded: .succeeded
                case .partial: .partiallySucceeded
                case .failed: .failed
                case .stateUnknown: .unknown
                }
                resultLabel(status)
            }
            if !errors.isEmpty || model.nodeActionResult != nil || model.shellActionResult != nil || model.homebrewActionResult != nil {
                Button("View Activity") { model.showActivity { openWindow(id: $0, value: $1) } }
                Button("Dismiss Feedback") { model.dismissNodeFeedback(); model.dismissShellFeedback(); model.dismissHomebrewFeedback() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(errors.isEmpty && model.nodeActionResult == nil && model.shellActionResult == nil && model.homebrewActionResult == nil && !model.isBusy ? 0 : AppLayout.spacing)
    }
    private var errors: [String] { [model.nodeOperationError, model.homebrewOperationError, model.shellOperationError].compactMap { $0 } }
    private func resultLabel(_ status: ActivityStatus) -> some View {
        Label { Text(status.title) } icon: { Image(systemName: status.systemImage) }
    }
}
