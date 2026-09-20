import SwiftUI

struct ShellView: View {
    @ObservedObject var model: AppModel
    let page: ShellPage

    var body: some View {
        pageContent
            .sheet(item: planBinding) { plan in
                ShellPlanSheet(model: model, plan: plan)
            }
            .sheet(isPresented: resultBinding) {
                if let result = model.shellActionResult {
                    ShellResultSheet(model: model, result: result)
                }
            }
            .alert("Shell 操作失败", isPresented: errorBinding) {
                Button("好", role: .cancel) { model.dismissShellFeedback() }
            } message: {
                Text(model.shellOperationError ?? "操作未完成")
            }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .overview: ShellOverviewPage(model: model)
        case .ohMyZsh: OhMyZshPage(model: model)
        case .extensions: ShellExtensionsPage(model: model)
        case .maintenance: ShellMaintenancePage(model: model)
        }
    }

    private var planBinding: Binding<ShellActionPlan?> {
        Binding(get: { model.shellPlan }, set: { if $0 == nil { model.dismissShellPlan() } })
    }

    private var resultBinding: Binding<Bool> {
        Binding(get: { model.shellActionResult != nil }, set: { if !$0 { model.dismissShellFeedback() } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.shellOperationError != nil && model.shellActionResult == nil },
            set: { if !$0 { model.dismissShellFeedback() } }
        )
    }
}
