import AppKit
import SwiftUI

private enum MaintenanceSheetTool: Identifiable, Equatable {
    case batchInstall
    case homebrewHealth
    case node(NodeMaintenanceAction)

    var id: String {
        switch self {
        case .batchInstall: "batch-install"
        case .homebrewHealth: "homebrew-health"
        case .node(let action): "node-\(action.rawValue)"
        }
    }
}

struct MaintenanceView: View {
    @ObservedObject var model: AppModel
    @StateObject private var batchInstallation: DiscoverInstallationModel
    @State private var activeTool: MaintenanceSheetTool?
    @State private var showsNodeDiagnostics = false
    var clipboard: ActivityClipboard = .live

    init(model: AppModel, clipboard: ActivityClipboard = .live) {
        self.model = model
        _batchInstallation = StateObject(wrappedValue: DiscoverInstallationModel(model: model))
        self.clipboard = clipboard
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppLayout.spacing) {
                    if let node = model.node, let error = node.maintenanceError {
                        HStack(spacing: 12) {
                            Label("Some maintenance information could not be read.", systemImage: "exclamationmark.triangle")
                            Spacer(minLength: 0)
                            Button("Session Diagnostics…") {
                                model.activityDiagnostics.record(
                                    operation: .maintenance,
                                    scope: node.summary.activityEnvironment.map(ActivityScope.npm),
                                    detail: error
                                )
                                showsNodeDiagnostics = true
                            }
                            .controlSize(.regular)
                        }
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250), spacing: AppLayout.cardSpacing, alignment: .top)],
                        alignment: .leading,
                        spacing: AppLayout.cardSpacing
                    ) {
                        batchInstallCard
                        homebrewHealthCard
                        ForEach(NodeMaintenanceAction.allCases) { action in
                            nodeMaintenanceCard(action)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(AppLayout.spacing, for: .scrollContent)

            EnvironmentFooterView {
                LabeledContent("Homebrew", value: homebrewFooterValue)
                if let node = model.node {
                    LabeledContent("Node", value: "\(node.summary.nodeVersion) · npm \(node.summary.npmVersion)")
                } else {
                    Text("Node Environment Unavailable")
                }
            }
            .padding(.horizontal, AppLayout.spacing)
            .padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .focusedSceneValue(\.batchInstallAction, openBatchInstall)
        .sheet(item: $activeTool) { tool in
            switch tool {
            case .batchInstall:
                DiscoverBatchInstallSheet(
                    installation: batchInstallation,
                    context: model.discoverContext,
                    initialScope: .homebrewFormula
                )
            case .homebrewHealth:
                HomebrewHealthSheet(model: model, clipboard: clipboard)
            case .node(let action):
                NodeMaintenanceSheet(model: model, action: action)
            }
        }
        .sheet(isPresented: $showsNodeDiagnostics) {
            ActivityDiagnosticsView(store: model.activityDiagnostics, initialSelection: nil, clipboard: clipboard)
        }
    }

    private func openBatchInstall() {
        batchInstallation.dismissPreview()
        batchInstallation.dismissResult()
        activeTool = .batchInstall
    }

    private var homebrewFooterValue: String {
        if let version = model.homebrew?.version {
            return HomeVersion.normalized(version)
        }
        if model.homebrew?.isInstalled == false {
            return String(localized: "Not Installed")
        }
        return "—"
    }

    private var batchInstallCard: some View {
        MaintenanceToolCard(
            title: LocalizedStringResource("Batch Install"),
            description: LocalizedStringResource("Enter one package per line. Blank lines and duplicate entries are removed. Maximum 100 items from one scope."),
            systemImage: "square.stack.3d.up.fill",
            tint: .blue
        ) {
            Button("Batch Install", action: openBatchInstall)
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(model.isBusy || (!model.discoverContext.homebrewAvailable && model.discoverContext.npm == nil))
        }
    }

    private var homebrewHealthCard: some View {
        MaintenanceToolCard(
            title: LocalizedStringResource("Homebrew Health"),
            description: LocalizedStringResource("Check Homebrew for configuration and installation issues."),
            systemImage: "stethoscope.circle.fill",
            tint: .orange
        ) {
            Button("Check Homebrew Health") { activeTool = .homebrewHealth }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(model.homebrew?.isInstalled != true || model.isBusy)
        }
    }

    private func nodeMaintenanceCard(_ action: NodeMaintenanceAction) -> some View {
        MaintenanceToolCard(
            title: action.title,
            description: action.detail,
            systemImage: action.symbolName,
            tint: action.tint
        ) {
            Button {
                activeTool = .node(action)
            } label: {
                Text(action == .verify ? LocalizedStringResource("Verify npm Cache") : LocalizedStringResource("Review…"))
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .disabled(model.isBusy || !model.nodeActionIsAvailable(action.request))
            .accessibilityLabel(Text(action.title))
            .accessibilityHint(Text(action.detail))
        }
    }
}

struct MaintenanceIconBadge: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct MaintenanceLoadingState: View {
    let title: LocalizedStringResource

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
    }
}

struct MaintenanceModalFrame<Subtitle: View, Content: View, Footer: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    let tint: Color
    var width: CGFloat = 460
    @ViewBuilder let subtitle: Subtitle
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                MaintenanceIconBadge(systemImage: systemImage, tint: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .font(.subheadline)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            content
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            HStack(spacing: 10) {
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .constrainedSheetWidth(width)
    }
}

struct MaintenanceDetailWell<Content: View>: View {
    var maxHeight: CGFloat = 260
    @ViewBuilder let content: Content
    @State private var measuredHeight: CGFloat?

    var body: some View {
        let boundedHeight = measuredHeight.map { min($0, maxHeight) }
        let overflows = measuredHeight.map { $0 > maxHeight } ?? false

        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    if measuredHeight != height {
                        measuredHeight = height
                    }
                }
        }
        .scrollDisabled(!overflows)
        .scrollIndicators(overflows ? .automatic : .hidden)
        .frame(height: boundedHeight)
        .frame(idealHeight: boundedHeight ?? maxHeight, maxHeight: maxHeight)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

private struct MaintenanceToolCard<Footer: View>: View {
    let title: LocalizedStringResource
    let description: LocalizedStringResource
    let systemImage: String
    let tint: Color
    @ViewBuilder let footer: Footer

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    MaintenanceIconBadge(systemImage: systemImage, tint: tint)

                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 2)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    footer
                }
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(6)
        }
        .accessibilityElement(children: .contain)
    }
}
