import SwiftUI

struct CatalogCardGrid: View {
    let states: [CatalogCardState]
    var minimumCardWidth: CGFloat = 260
    var isActionEnabled = true
    let action: (CatalogCardState, CatalogCardAction) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumCardWidth), alignment: .top)], alignment: .leading, spacing: 16) {
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
                header
                if let description = state.description {
                    Text(description)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .accessibilityLabel(Text(description))
                }
                versionSummary
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
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .accessibilityElement(children: .contain)
        .controlSize(.regular)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(state.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)

            Text(state.identity.providerScope.tagTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .fixedSize()
                .layoutPriority(1)
                .accessibilityLabel(Text(state.identity.providerScope.cardTitle))

            if let website = state.websiteURL {
                WebsiteLink(destination: website, title: LocalizedStringResource("Website for \(state.displayName)"))
                .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var updateVersion: String? {
        state.versionStatus == .behind && state.currentVersion != nil ? state.availableVersion : nil
    }

    @ViewBuilder private var versionSummary: some View {
        if let version = state.currentVersion ?? state.availableVersion {
            let display = updateVersion.map { "\(version) → \($0)" } ?? version
            HStack(spacing: 6) {
                Text(display)
                    .textSelection(.enabled)
                if updateVersion != nil {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(state.versionStatus.cardTitle))
        }
    }

    @ViewBuilder private var controls: some View {
        if let action = state.primaryAction, showsPrimaryAction {
            let actionTitle = String(localized: action.cardTitle)
            Button(role: action == .uninstall ? .destructive : nil) { self.action(action) } label: { Text(action.cardTitle) }
                .buttonStyle(.glass)
                .disabled(!isActionEnabled || state.progress != .idle)
                .accessibilityLabel(Text("\(actionTitle) \(state.displayName)"))
        }
    }
}

extension CatalogProviderScope {
    var tagTitle: LocalizedStringResource {
        switch self {
        case .homebrewFormula: LocalizedStringResource("Formula")
        case .homebrewCask: LocalizedStringResource("Cask")
        case .npm: LocalizedStringResource("NPM")
        }
    }

    var cardTitle: LocalizedStringResource {
        switch self {
        case .homebrewFormula: LocalizedStringResource("Homebrew · Formula")
        case .homebrewCask: LocalizedStringResource("Homebrew · Cask")
        case .npm: LocalizedStringResource("npm")
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

}

extension CatalogCardAction {
    var cardTitle: LocalizedStringResource {
        switch self {
        case .install: LocalizedStringResource("Install")
        case .update: LocalizedStringResource("Update")
        case .uninstall: LocalizedStringResource("Uninstall")
        }
    }
}
