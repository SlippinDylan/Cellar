import SwiftUI

enum ProviderTaskSurface { case tools, homebrewSources, npmSources, terminal, maintenance }

struct ProviderTaskPresentation: ViewModifier {
    @ObservedObject var model: AppModel
    let surface: ProviderTaskSurface
    @State private var retainedNodePlan: NodeActionPlan?
    @State private var retainedHomebrewPlan: HomebrewActionPlan?
    @State private var retainedShellPlan: ShellActionPlan?

    func body(content: Content) -> some View {
        content
        .onChange(of: nodePlanForSurface?.id) { _, _ in
            if let plan = nodePlanForSurface { retainedNodePlan = plan }
        }
        .onChange(of: homebrewPlanForSurface?.id) { _, _ in
            if let plan = homebrewPlanForSurface { retainedHomebrewPlan = plan }
        }
        .onChange(of: shellPlanForSurface?.id) { _, _ in
            if let plan = shellPlanForSurface { retainedShellPlan = plan }
        }
        .sheet(item: nodeConfirmation) { plan in
            NodeTaskConfirmation(plan: plan, cancel: { dismissNode() }, confirm: {
                retainedNodePlan = plan
                model.dismissNodeFeedback()
                await model.executeNodePlan(confirmed: plan)
                if let error = model.nodeOperationError { return error }
                guard let result = model.nodeActionResult, result.plan.id == plan.id else {
                    return String(localized: ActivityItemReason.stateUnavailable.message)
                }
                return result.operation.exitCode == 0 ? nil : String(localized: ActivityItemReason.providerFailure.message)
            })
            .onAppear { model.beginModalPresentation() }
            .onDisappear { model.endModalPresentation() }
        }
        .sheet(item: homebrewConfirmation) { plan in
            TapTaskConfirmation(plan: plan, cancel: { dismissHomebrew() }, confirm: {
                retainedHomebrewPlan = plan
                model.dismissHomebrewFeedback()
                await model.executeHomebrewPlan(confirmed: plan)
                if let error = model.homebrewOperationError { return error }
                guard let result = model.homebrewActionResult, result.plan.id == plan.id else {
                    return String(localized: ActivityItemReason.stateUnavailable.message)
                }
                if case .succeeded = result.outcome { return nil }
                return String(localized: ActivityItemReason.providerFailure.message)
            })
            .onAppear { model.beginModalPresentation() }
            .onDisappear { model.endModalPresentation() }
        }
        .sheet(item: shellConfirmation) { plan in
            ShellTaskConfirmation(plan: plan, cancel: { dismissShell() }, confirm: {
                retainedShellPlan = plan
                model.dismissShellFeedback()
                await model.executeShellPlan(confirmed: plan)
                if let error = model.shellOperationError { return error }
                guard let result = model.shellActionResult, result.plan.id == plan.id else {
                    return String(localized: ActivityItemReason.stateUnavailable.message)
                }
                return result.operation.exitCode == 0 ? nil : String(localized: ActivityItemReason.providerFailure.message)
            })
            .onAppear { model.beginModalPresentation() }
            .onDisappear { model.endModalPresentation() }
        }
        .onDisappear {
            if !model.isBusy {
                retainedNodePlan = nil
                retainedHomebrewPlan = nil
                retainedShellPlan = nil
            }
        }
    }

    var nodeConfirmation: Binding<NodeActionPlan?> {
        let presented = retainedNodePlan ?? nodePlanForSurface
        return Binding(get: { retainedNodePlan ?? nodePlanForSurface }, set: {
            if $0 == nil, let presented {
                model.dismissNodePlan(confirmed: presented)
                if retainedNodePlan?.id == presented.id { retainedNodePlan = nil }
                model.dismissNodeFeedback()
            }
        })
    }

    var homebrewConfirmation: Binding<HomebrewActionPlan?> {
        let presented = retainedHomebrewPlan ?? homebrewPlanForSurface
        return Binding(get: { retainedHomebrewPlan ?? homebrewPlanForSurface }, set: {
            if $0 == nil, let presented {
                model.dismissHomebrewPlan(confirmed: presented)
                if retainedHomebrewPlan?.id == presented.id { retainedHomebrewPlan = nil }
                model.dismissHomebrewFeedback()
            }
        })
    }

    var shellConfirmation: Binding<ShellActionPlan?> {
        let presented = retainedShellPlan ?? shellPlanForSurface
        return Binding(get: { retainedShellPlan ?? shellPlanForSurface }, set: {
            if $0 == nil, let presented {
                model.dismissShellPlan(confirmed: presented)
                if retainedShellPlan?.id == presented.id { retainedShellPlan = nil }
                model.dismissShellFeedback()
            }
        })
    }

    private func dismissNode() {
        if let plan = retainedNodePlan ?? nodePlanForSurface { model.dismissNodePlan(confirmed: plan) }
        retainedNodePlan = nil
        model.dismissNodeFeedback()
    }

    private func dismissHomebrew() {
        if let plan = retainedHomebrewPlan ?? homebrewPlanForSurface { model.dismissHomebrewPlan(confirmed: plan) }
        retainedHomebrewPlan = nil
        model.dismissHomebrewFeedback()
    }

    private func dismissShell() {
        if let plan = retainedShellPlan ?? shellPlanForSurface { model.dismissShellPlan(confirmed: plan) }
        retainedShellPlan = nil
        model.dismissShellFeedback()
    }

    private var nodePlanForSurface: NodeActionPlan? {
        guard let plan = model.nodePlan else { return nil }
        let target: ProviderTaskSurface
        switch plan.request.action {
        case .installNode, .useNode: return nil
        case .cleanup:
            guard plan.request.subject != NodeMaintenanceAction.verify.rawValue else { return nil }
            target = .maintenance
        default: target = plan.request.action.isRegistryConfiguration ? .npmSources : .tools
        }
        return surface == target ? plan : nil
    }
    private var homebrewPlanForSurface: HomebrewActionPlan? {
        guard surface == .homebrewSources, let plan = model.homebrewPlan, [.addTap, .removeTap].contains(plan.action) else { return nil }
        return plan
    }
    private var shellPlanForSurface: ShellActionPlan? {
        guard let plan = model.shellPlan, surface == .terminal else { return nil }
        return plan
    }
}
