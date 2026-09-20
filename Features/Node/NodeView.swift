import SwiftUI

struct NodeView: View {
    @ObservedObject var model: AppModel
    let page: NodePage

    var body: some View {
        pageContent
            .sheet(item: planBinding) { plan in
                NodePlanSheet(model: model, plan: plan)
            }
            .sheet(isPresented: resultBinding) {
                if let result = model.nodeActionResult {
                    NodeResultSheet(model: model, result: result)
                }
            }
            .alert("Node 操作失败", isPresented: errorBinding) {
                Button("好", role: .cancel) { model.dismissNodeFeedback() }
            } message: {
                Text(model.nodeOperationError ?? "操作未完成")
            }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .overview: NodeOverviewPage(model: model)
        case .packages: NodePackagesPage(model: model)
        case .versions: NodeVersionsPage(model: model)
        case .registry: NodeRegistryPage(model: model)
        case .maintenance: NodeMaintenancePage(model: model)
        }
    }

    private var planBinding: Binding<NodeActionPlan?> {
        Binding(get: { model.nodePlan }, set: { if $0 == nil { model.dismissNodePlan() } })
    }

    private var resultBinding: Binding<Bool> {
        Binding(get: { model.nodeActionResult != nil }, set: { if !$0 { model.dismissNodeFeedback() } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.nodeOperationError != nil && model.nodeActionResult == nil },
            set: { if !$0 { model.dismissNodeFeedback() } }
        )
    }
}
