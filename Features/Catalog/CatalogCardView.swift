import SwiftUI

struct CatalogCardGrid: View {
    let states: [CatalogCardState]
    var minimumCardWidth: CGFloat = 260
    var updateTargets: [CatalogCardState] = []
    var isActionEnabled = true
    var isUninstallEnabled: Bool? = nil
    var isItemActionEnabled: (CatalogCardState) -> Bool = { _ in true }
    let action: (CatalogCardState, CatalogCardAction) -> Void
    @State private var columnCount = 1

    private let columnSpacing: CGFloat = 24

    var body: some View {
        let targets = Dictionary(updateTargets.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let indices = Dictionary(states.enumerated().map { ($0.element.identity, $0.offset) }, uniquingKeysWith: { first, _ in first })
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumCardWidth), spacing: columnSpacing, alignment: .top)], alignment: .leading, spacing: 0) {
            ForEach(states) { state in
                let target = targets[state.identity]
                let index = indices[state.identity] ?? states.count
                let showsBottomDivider = index + columnCount < states.count
                let itemEnabled = isItemActionEnabled(state)
                CatalogCardView(state: state, updateTarget: target,
                                isActionEnabled: isActionEnabled && itemEnabled,
                                isUninstallEnabled: (isUninstallEnabled ?? isActionEnabled) && itemEnabled,
                                showsBottomDivider: showsBottomDivider) { selectedAction in
                    if selectedAction == .update, state.primaryAction == .uninstall {
                        guard let target else { preconditionFailure("An enabled library update requires its canonical target") }
                        action(target, selectedAction)
                    } else { action(state, selectedAction) }
                }
            }
        }
        .onGeometryChange(for: Int.self) { proxy in
            max(1, Int((proxy.size.width + columnSpacing) / (minimumCardWidth + columnSpacing)))
        } action: { count in
            columnCount = count
        }
    }
}

struct CatalogCardView: View {
    let state: CatalogCardState
    var updateTarget: CatalogCardState? = nil
    var isActionEnabled = true
    var isUninstallEnabled = true
    var showsBottomDivider = true
    let action: (CatalogCardAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                CatalogIconView(state: state)
                VStack(alignment: .leading, spacing: 3) {
                    name
                    if let description = nonEmptyDescription {
                        CatalogCardDescription(description: description)
                    }
                    metadataRow
                }
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)

                trailingControl
                    .fixedSize()
            }
            .padding(.vertical, 12)

            Rectangle()
                .fill(.separator.opacity(showsBottomDivider ? 0.45 : 0))
                .frame(height: 0.5)
                .padding(.leading, 70)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .controlSize(.regular)
    }

    private var nonEmptyDescription: String? {
        let trimmed = state.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var metadataRow: some View {
        HStack(alignment: .center, spacing: 5) {
            Text(state.identity.providerScope.tagTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityLabel(Text(state.identity.providerScope.cardTitle))
            if state.currentVersion != nil || state.availableVersion != nil {
                Circle()
                    .fill(.tertiary)
                    .frame(width: 2.5, height: 2.5)
                    .accessibilityHidden(true)
                versionSummary
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var trailingControl: some View {
        if state.progress != .idle {
            let label: LocalizedStringResource = if state.progress == .queued {
                LocalizedStringResource("Queued")
            } else if state.progress == .verifying {
                ActivityTaskStage.reconciling.title
            } else {
                ActivityTaskStage.executing.title
            }
            CatalogCircularProgressView(tint: state.primaryAction == .update ? .green : .accentColor)
                .accessibilityLabel(Text(label))
        } else {
            controls
        }
    }

    private var name: some View {
        LinkedTitle(
            state.displayName,
            destination: state.websiteURL,
            linkLabel: state.websiteURL != nil ? LocalizedStringResource("Website for \(state.displayName)") : nil
        )
        .font(.headline.weight(.semibold))
    }

    private var updateVersion: String? {
        state.versionStatus == .behind && state.currentVersion != nil ? state.availableVersion : nil
    }

    @ViewBuilder private var versionSummary: some View {
        if let version = state.currentVersion ?? state.availableVersion {
            let prefix = Text("V").font(.caption2)
            // Hair spaces keep the smaller prefix close to each version number.
            let title: Text = if let update = updateVersion {
                Text("\(prefix) \(version) → \(prefix) \(update)")
            } else {
                Text("\(prefix) \(version)")
            }
            HStack(spacing: 4) {
                title
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if updateVersion != nil {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(state.versionStatus.cardTitle))
        }
    }

    @ViewBuilder private var controls: some View {
        if state.primaryAction == .uninstall {
            HStack(spacing: 6) {
                if updateTarget != nil {
                    Button { action(.update) } label: {
                        Text("Update")
                    }
                    .buttonStyle(CatalogCardPillButtonStyle(tint: .green))
                    .disabled(!isActionEnabled || state.progress != .idle)
                    .accessibilityLabel(Text("Update \(state.displayName)"))
                }

                Button(role: .destructive) { action(.uninstall) } label: {
                    Text("Uninstall")
                }
                .buttonStyle(CatalogCardPillButtonStyle(tint: .red))
                .disabled(!isUninstallEnabled || state.progress != .idle)
                .accessibilityLabel(Text("Uninstall \(state.displayName)"))
            }
            .fixedSize()
        } else if let action = state.primaryAction {
            let actionTitle = String(localized: action.cardTitle)
            Button { self.action(action) } label: {
                Text(action.cardTitle)
            }
            .buttonStyle(CatalogCardPillButtonStyle(tint: action == .update ? .green : .blue))
            .disabled(!isActionEnabled || state.progress != .idle)
            .accessibilityLabel(Text("\(actionTitle) \(state.displayName)"))
        }
    }
}

/// Compact App Store-style indeterminate circular spinner shown in place of card buttons while queued or running.
private struct CatalogCircularProgressView: View {
    var tint: Color = .accentColor
    @State private var isSpinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isSpinning)
        }
        .frame(width: 22, height: 22)
        .padding(.horizontal, 6)
        .onAppear { isSpinning = true }
    }
}

struct CatalogCardDescription: View {
    let description: String?

    var body: some View {
        let text = (description ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(text.isEmpty)
    }
}

struct CatalogCardPillButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, tint: tint)
    }

    private struct PillButtonBody: View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        let configuration: Configuration
        let tint: Color

        var body: some View {
            let isActive = isEnabled && (isHovered || configuration.isPressed)
            let neutralBase = colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.06)

            configuration.label
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? .white : tint)
                .padding(.horizontal, 14)
                .frame(minWidth: 56)
                .frame(height: 24)
                .background(isActive ? tint : neutralBase, in: Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.14), value: isHovered)
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
