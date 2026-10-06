import SwiftUI

struct CatalogCardGrid: View {
    let states: [CatalogCardState]
    var minimumCardWidth: CGFloat = 260
    var updateTargets: [CatalogCardState] = []
    var isActionEnabled = true
    let action: (CatalogCardState, CatalogCardAction) -> Void

    var body: some View {
        let targets = Dictionary(uniqueKeysWithValues: updateTargets.map { ($0.identity, $0) })
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumCardWidth), spacing: AppLayout.cardSpacing, alignment: .top)], alignment: .leading, spacing: AppLayout.cardSpacing) {
            ForEach(states) { state in
                let target = targets[state.identity]
                CatalogCardView(state: state, updateTarget: target, isActionEnabled: isActionEnabled) { selectedAction in
                    if selectedAction == .update, state.primaryAction == .uninstall {
                        guard let target else { preconditionFailure("An enabled library update requires its canonical target") }
                        action(target, selectedAction)
                    } else { action(state, selectedAction) }
                }
            }
        }
    }
}

struct CatalogCardView: View {
    let state: CatalogCardState
    var updateTarget: CatalogCardState? = nil
    var isActionEnabled = true
    let action: (CatalogCardAction) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                header
                    .frame(height: 32, alignment: .leading)
                Text(state.description ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32, alignment: .topLeading)
                    .accessibilityHidden(state.description == nil)
                metadata
                    .frame(height: 20, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .accessibilityElement(children: .contain)
        .controlSize(.regular)
    }

    private var header: some View {
        HStack(spacing: 6) {
            name
            Spacer(minLength: 0)
            controls
                .controlSize(.large)
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(state.identity.providerScope.tagTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .fixedSize()
                .accessibilityLabel(Text(state.identity.providerScope.cardTitle))
            if let website = state.websiteURL {
                WebsiteLink(destination: website, title: LocalizedStringResource("Website for \(state.displayName)"))
                    .font(.title3.weight(.semibold))
            }
            versionSummary
            Spacer(minLength: 0)
            taskStatus
                .fixedSize()
        }
    }

    private var name: some View {
        Text(state.displayName)
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
    }

    private var updateVersion: String? {
        state.versionStatus == .behind && state.currentVersion != nil ? state.availableVersion : nil
    }

    @ViewBuilder private var versionSummary: some View {
        if let version = state.currentVersion ?? state.availableVersion {
            let display = updateVersion.map { "\(version) → \($0)" } ?? version
            HStack(spacing: 4) {
                Text("Version \(display)")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

    private var taskStatus: some View {
        HStack(spacing: 8) {
            if state.progress == .queued {
                Label("Queued", systemImage: "clock")
                    .font(.caption)
                    .fixedSize()
            } else if state.progress == .running || state.progress == .verifying {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(state.progress == .verifying ? ActivityTaskStage.reconciling.title : ActivityTaskStage.executing.title)
                }
                .font(.caption)
                .fixedSize()
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if state.primaryAction == .uninstall {
            HStack(spacing: 0) {
                if updateTarget != nil {
                    Button { action(.update) } label: {
                        Label("Update", systemImage: "arrowshape.up.circle").labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    }
                    .disabled(!isActionEnabled || state.progress != .idle)
                    .accessibilityLabel(Text("Update \(state.displayName)"))
                    .help("Update")
                }

                Button(role: .destructive) { action(.uninstall) } label: {
                    Label("Uninstall", systemImage: "trash").labelStyle(.iconOnly)
                        .foregroundStyle(.red)
                }
                .disabled(!isActionEnabled || state.progress != .idle)
                .accessibilityLabel(Text("Uninstall \(state.displayName)"))
                .help("Uninstall")
            }
            .buttonStyle(CatalogCardActionButtonStyle())
            .padding(2)
            .glassEffect(.regular, in: Capsule())
            .fixedSize()
        } else if let action = state.primaryAction {
            let actionTitle = String(localized: action.cardTitle)
            Button { self.action(action) } label: {
                Label(action.cardTitle, systemImage: action == .install ? "arrowshape.down.circle" : "arrowshape.up.circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(action == .update ? Color.green : Color.primary)
            }
            .buttonStyle(CatalogCardActionButtonStyle())
            .padding(2)
            .glassEffect(.regular, in: Capsule())
            .disabled(!isActionEnabled || state.progress != .idle)
            .accessibilityLabel(Text("\(actionTitle) \(state.displayName)"))
            .help(Text(action.cardTitle))
        }
    }
}

private struct CatalogCardActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .frame(width: 28, height: 28)
            .background(.quaternary.opacity(isEnabled && (isHovered || configuration.isPressed) ? 0.7 : 0), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
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
