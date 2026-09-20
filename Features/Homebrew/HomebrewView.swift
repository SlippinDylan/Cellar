import SwiftUI

struct HomebrewView: View {
    @ObservedObject var model: AppModel
    let page: HomebrewPage

    var body: some View {
        pageContent
            .sheet(item: planBinding) { plan in
                HomebrewPlanSheet(model: model, plan: plan)
            }
            .sheet(isPresented: feedbackBinding) {
                if let result = model.homebrewActionResult {
                    HomebrewResultSheet(model: model, result: result)
                }
            }
            .alert("Homebrew 操作失败", isPresented: errorBinding) {
                Button("好", role: .cancel) {
                    model.dismissHomebrewFeedback()
                }
            } message: {
                Text(model.homebrewOperationError ?? "操作未完成")
            }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .overview:
            HomebrewOverviewPage(model: model)
        case .installed:
            HomebrewInstalledPage(model: model)
        case .upgrades:
            HomebrewUpgradesPage(model: model)
        case .discover:
            HomebrewDiscoverPage(model: model)
        case .doctor:
            HomebrewDoctorPage(model: model)
        case .configuration:
            HomebrewConfigurationPage(model: model)
        }
    }

    private var planBinding: Binding<HomebrewActionPlan?> {
        Binding(
            get: { model.homebrewPlan },
            set: { if $0 == nil { model.dismissHomebrewPlan() } }
        )
    }

    private var feedbackBinding: Binding<Bool> {
        Binding(
            get: { model.homebrewActionResult != nil },
            set: { if !$0 { model.dismissHomebrewFeedback() } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.homebrewOperationError != nil && model.homebrewActionResult == nil },
            set: { if !$0 { model.dismissHomebrewFeedback() } }
        )
    }
}
