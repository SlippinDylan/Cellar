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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isNodeWorking || model.isHomebrewWorking || model.isShellWorking {
                HStack { ProgressView().controlSize(.small); Text("Working on Environment") }
            }
            ForEach(errors, id: \.self) { error in
                Label("The task could not be completed. Review the error and refresh before trying again.", systemImage: "exclamationmark.triangle")
                if let plan = model.nodePlan, !plan.canExecute { Text(plan.blockingMessage) }
                DisclosureGroup("Error Details") { Text(DiagnosticText.sanitized(error)).textSelection(.enabled) }
            }
            if let result = model.nodeActionResult {
                Label(result.operation.status == "ok" && result.postflightError == nil ? LocalizedStringResource("Task Completed") : LocalizedStringResource("Task Partially Completed"), systemImage: "info.circle")
            }
            if let result = model.shellActionResult {
                Label(result.operation.status == "ok" && result.postflightError == nil ? LocalizedStringResource("Task Completed") : LocalizedStringResource("Task Partially Completed"), systemImage: "info.circle")
                if !result.operation.backupPath.isEmpty { Text(result.operation.backupPath).textSelection(.enabled) }
            }
            if let result = model.homebrewActionResult {
                Label(result.outcome == .succeeded ? LocalizedStringResource("Task Completed") : LocalizedStringResource("Task Partially Completed"), systemImage: "info.circle")
            }
            if !errors.isEmpty || model.nodeActionResult != nil || model.shellActionResult != nil || model.homebrewActionResult != nil {
                Button("Dismiss Feedback") { model.dismissNodeFeedback(); model.dismissShellFeedback(); model.dismissHomebrewFeedback() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(errors.isEmpty && model.nodeActionResult == nil && model.shellActionResult == nil && model.homebrewActionResult == nil && !model.isBusy ? 0 : 16)
    }
    private var errors: [String] { [model.nodeOperationError, model.homebrewOperationError, model.shellOperationError].compactMap { $0 } }
}
