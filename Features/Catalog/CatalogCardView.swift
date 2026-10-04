import SwiftUI

struct CatalogCardGrid: View {
    let states: [CatalogCardState]
    var isActionEnabled = true
    let action: (CatalogCardState, CatalogCardAction) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .top)], alignment: .leading, spacing: 16) {
            ForEach(states) { state in
                CatalogCardView(state: state, isActionEnabled: isActionEnabled) { action(state, $0) }
            }
        }
    }
}

struct CatalogCardView: View {
    let state: CatalogCardState
    var isActionEnabled = true
    var showsPrimaryAction = true
    let action: (CatalogCardAction) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(state.displayName, systemImage: state.identity.providerScope.cardSymbol)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(state.identity.providerScope.cardTitle)
                    .foregroundStyle(.secondary)
                if let description = state.description {
                    Text(description)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .accessibilityLabel(Text(description))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let version = state.currentVersion { Text("Installed: \(version)") }
                    if let version = state.availableVersion { Text("Available: \(version)") }
                    CatalogVersionStatusView(status: state.versionStatus)
                }
                if let environment = state.nodeEnvironment {
                    Text("Node Environment: \(environment.nodeVersion) · npm \(environment.npmVersion)")
                        .foregroundStyle(.secondary)
                }
                if state.progress == .queued {
                    Label("Queued", systemImage: "clock")
                } else if state.progress == .running || state.progress == .verifying {
                    HStack {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(state.progress == .verifying ? ActivityTaskStage.reconciling.title : ActivityTaskStage.executing.title)
                    }
                    .accessibilityElement(children: .combine)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { controls }
                    VStack(alignment: .leading, spacing: 12) { controls }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .accessibilityElement(children: .contain)
        .controlSize(.regular)
    }

    @ViewBuilder private var controls: some View {
        if let action = state.primaryAction, showsPrimaryAction {
            let actionTitle = String(localized: action.cardTitle)
            Button(role: action == .uninstall ? .destructive : nil) { self.action(action) } label: { Text(action.cardTitle) }
                .buttonStyle(.bordered)
                .disabled(!isActionEnabled || state.progress != .idle)
                .accessibilityLabel(Text("\(actionTitle) \(state.displayName)"))
        }
        if let website = state.websiteURL {
            Link(destination: website) { Label("Website", systemImage: "arrow.up.right").frame(minHeight: 28) }
                .accessibilityLabel(Text("Website for \(state.displayName)"))
                .accessibilityHint("Opens in the default browser")
        }
    }
}

struct CatalogVersionStatusView: View {
    let status: SemanticVersionStatus

    var body: some View {
        Label { Text(status.cardTitle) } icon: {
            Image(systemName: status.cardSymbol).foregroundStyle(status.cardColor)
        }
    }
}

extension CatalogProviderScope {
    var cardTitle: LocalizedStringResource {
        switch self {
        case .homebrewFormula: LocalizedStringResource("Homebrew · Formula")
        case .homebrewCask: LocalizedStringResource("Homebrew · Cask")
        case .npm: LocalizedStringResource("npm")
        }
    }

    var cardSymbol: String {
        switch self {
        case .homebrewFormula: "shippingbox"
        case .homebrewCask: "app"
        case .npm: "shippingbox.fill"
        }
    }
}

extension SemanticVersionStatus {
    var cardTitle: LocalizedStringResource {
        switch self {
        case .behind: LocalizedStringResource("Update Available")
        case .current: LocalizedStringResource("Up to Date")
        case .ahead: LocalizedStringResource("Ahead of Available Version")
        case .unknown: LocalizedStringResource("Version Status Unknown")
        }
    }

    var cardSymbol: String {
        switch self {
        case .behind: "arrow.up.circle"
        case .current: "checkmark.circle"
        case .ahead: "arrow.up.forward.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var cardColor: Color {
        switch self {
        case .behind: .orange
        case .current: .green
        case .ahead: .blue
        case .unknown: .secondary
        }
    }
}

extension CatalogCardAction {
    var cardTitle: LocalizedStringResource {
        switch self {
        case .install: LocalizedStringResource("Install")
        case .update: LocalizedStringResource("Update")
        case .uninstall: LocalizedStringResource("Uninstall…")
        }
    }
}
