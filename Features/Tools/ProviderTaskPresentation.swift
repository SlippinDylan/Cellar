import SwiftUI

enum ProviderTaskSurface { case tools, sources, terminal }

struct ProviderTaskPresentation: ViewModifier {
    @ObservedObject var model: AppModel
    let surface: ProviderTaskSurface
    func body(content: Content) -> some View {
        content
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
        guard let plan = model.shellPlan, surface == .terminal else { return nil }
        return plan
    }
}
