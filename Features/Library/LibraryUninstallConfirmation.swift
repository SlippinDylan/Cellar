import AppKit
import SwiftUI

struct LibraryUninstallConfirmation: View {
    @ObservedObject var uninstall: LibraryUninstallModel
    let maximumHeight: CGFloat
    @State private var presentationHeight: CGFloat?
    @State private var executionHeight: CGFloat?

    private var plan: BatchPlan? { uninstall.confirmation }
    private var removal: CaskRemovalPlan? { plan?.homebrewImpacts.first?.caskRemoval }
    private var displayName: String { removal?.displayName ?? uninstall.displayName ?? uninstall.presentedItem?.displayIdentifier ?? "" }

    private var scopeTitle: LocalizedStringResource? {
        uninstall.presentedItem?.scope.libraryTitle ?? plan?.intent.scope.libraryTitle
    }

    var body: some View {
        LibraryUninstallLayout(maximumHeight: maximumHeight, forcedHeight: executionHeight) {
            identity
            summary
            ScrollView {
                details.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 24)
            }
            .clipped()
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let removal, !removal.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(removal.warnings.enumerated()), id: \.offset) { _, warning in
                                Label {
                                    Text(warning.uninstallMessage)
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "exclamationmark.circle")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(alignment: .center, spacing: 12) {
                        Spacer(minLength: 0)
                        if uninstall.hasFinished {
                            Button("OK", action: uninstall.dismissConfirmation)
                                .fixedSize()
                                .buttonStyle(.glassProminent)
                                .tint(.blue)
                                .keyboardShortcut(.defaultAction)
                        } else if uninstall.isExecuting {
                            Button {} label: { Text("Uninstalling") }
                                .fixedSize()
                                .buttonStyle(.glassProminent)
                                .tint(.red)
                                .disabled(true)
                        } else {
                            Button("Cancel", role: .cancel, action: uninstall.dismissConfirmation)
                                .fixedSize()
                                .keyboardShortcut(.cancelAction)
                            Button("Uninstall", role: .destructive) {
                                if removal != nil, executionHeight == nil { executionHeight = presentationHeight }
                                Task { await uninstall.confirmUninstall() }
                            }
                            .fixedSize()
                            .buttonStyle(.glassProminent)
                            .tint(.red)
                            .disabled(uninstall.isPreparing || plan == nil || plan?.executableCount == 0 || uninstall.isExecuting)
                        }
                    }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        // Measure the intrinsic layout, before the host frame constrains it.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentationHeight = $0 }
        .constrainedSheetWidth(500)
        .frame(height: presentationHeight)
        .background(LibraryUninstallSheetSizing(height: presentationHeight))
        .presentationSizing(.fitted)
        .interactiveDismissDisabled(uninstall.isExecuting)
        .onChange(of: uninstall.isExecuting) { _, executing in
            if removal != nil, executing, executionHeight == nil { executionHeight = presentationHeight }
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon = uninstall.appIcon {
                Image(nsImage: icon).resizable().scaledToFit()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .frame(width: 56, height: 56)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Uninstall Software")
                    .font(.headline)
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .help(displayName)
                    .textSelection(.enabled)
                if let scopeTitle {
                    Text(scopeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            if removal != nil || (uninstall.isPreparing && uninstall.presentedItem?.scope == .homebrew(.cask)) {
                LibraryUninstallSizeSummary(
                    applicationSize: byteCount(removal?.applicationBytes),
                    estimatedRemoval: byteCount(removal?.removalBytes)
                )
                Divider()
            } else if plan != nil {
                Text("This item will be removed. This cannot be rolled back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var details: some View {
        if uninstall.isPreparing {
            ProgressView("Scanning Related Files…")
                .frame(maxWidth: .infinity, minHeight: 100)
        } else if let removal {
            VStack(alignment: .leading, spacing: 14) {
                ForEach([CaskRemovalCategory.application, .cache, .applicationData, .homebrewCache], id: \.self) { category in
                    let entries = removal.entries.filter { $0.category == category }
                    if !entries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(category.uninstallTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(entries) { entry in
                                    removalRow(entry)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                            }
                        }
                    }
                }
                if !uninstall.hasFinished {
                    Text("Application data will be permanently removed, except files marked as kept. This cannot be rolled back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if uninstall.hasFinished {
                    if let result = uninstall.result {
                        if result.refreshStatus == .failed {
                            Text("Uninstall finished, but the environment could not be refreshed. Use Refresh to check the current state.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(result.outcome.itemOutcomes, id: \.item) { outcome in
                            if let reason = outcome.reason { Text(reason.message).font(.callout).foregroundStyle(.secondary) }
                            let residuePaths = npmResiduePaths(for: outcome.item, in: result)
                            if !residuePaths.isEmpty {
                                Text("Remaining npm Files").font(.headline)
                                ForEach(residuePaths, id: \.self) {
                                    Text($0).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if let error = uninstall.error { Text(error.libraryMessage).font(.callout).foregroundStyle(.secondary) }
                    if let reason = uninstall.failureReason { Text(reason.message).font(.callout).foregroundStyle(.secondary) }
                }
            }
        } else if let plan {
            VStack(alignment: .leading, spacing: 12) {
                if let environment = plan.intent.scope.nodeEnvironment {
                    Text("Node Environment: \(environment.nodeVersion) · npm \(environment.npmVersion)")
                }
                if case .nodeRuntime = plan.intent.scope {
                    Text("Each selected Node installation and its global npm packages will be removed. Current and default Node versions are protected.")
                }
                ForEach(plan.intent.items, id: \.self) { item in
                    HStack(alignment: .center, spacing: 12) {
                        Text(item.displayIdentifier).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if uninstall.hasFinished {
                            if uninstall.error == nil && uninstall.result?.outcome.status == .succeeded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .accessibilityLabel("Removed")
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel(Text(uninstall.result?.outcome.status.libraryTitle ?? LocalizedStringResource("Operation Failed")))
                            }
                        }
                    }
                    if case .homebrew(let identity) = item, identity.kind == .formula,
                       let impact = plan.homebrewImpacts.first(where: { $0.targets == [identity] }), !impact.dependents.isEmpty {
                        Text("Installed Formula Dependents").font(.headline)
                        Text("These installed Formula packages use this software. Cask dependents are not listed. Homebrew checks the installed versions and may refuse removal.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(impact.dependents, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                    ForEach(artifacts(for: item, plan: plan), id: \.self) {
                        Text($0).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if uninstall.hasFinished {
                    if let result = uninstall.result {
                        if result.refreshStatus == .failed {
                            Text("Uninstall finished, but the environment could not be refreshed. Use Refresh to check the current state.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(result.outcome.itemOutcomes, id: \.item) { outcome in
                            if let reason = outcome.reason { Text(reason.message).font(.callout).foregroundStyle(.secondary) }
                            let residuePaths = npmResiduePaths(for: outcome.item, in: result)
                            if !residuePaths.isEmpty {
                                Text("Remaining npm Files").font(.headline)
                                ForEach(residuePaths, id: \.self) {
                                    Text($0).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if let error = uninstall.error { Text(error.libraryMessage).font(.callout).foregroundStyle(.secondary) }
                    if let reason = uninstall.failureReason { Text(reason.message).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func removalRow(_ entry: CaskRemovalEntry) -> some View {
        let status = uninstall.pathStatus(entry)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Button { uninstall.revealInFinder(entry) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.primaryDisplayName(for: entry))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(Self.abbreviatedParentDirectory(entry.path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(entry.path)
                .disabled(status == .removed)
                if let guidance = uninstall.guidance(for: entry) {
                    Text(guidance.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Group {
                if let failure = entry.sizeFailure {
                    Text(failure.title)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 160, alignment: .trailing)
                        .layoutPriority(1)
                        .help(Text(failure.explanation))
                } else {
                    byteCount(entry.estimatedBytes)
                        .fixedSize()
                }
            }
            .font(.callout).monospacedDigit()
            LibraryUninstallPathStatusIndicator(status: status)
        }
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
        }
    }

    static func primaryDisplayName(for entry: CaskRemovalEntry) -> String {
        let filename = URL(filePath: entry.path).lastPathComponent
        guard entry.category == .homebrewCache,
              let splitIndex = filename.index(filename.startIndex, offsetBy: 64, limitedBy: filename.endIndex),
              filename[splitIndex...].hasPrefix("--")
        else {
            return filename
        }
        let prefix = filename[..<splitIndex]
        let suffix = filename[splitIndex...].dropFirst(2)
        guard !suffix.isEmpty,
              prefix.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else {
            return filename
        }
        return String(suffix)
    }

    static func abbreviatedParentDirectory(_ path: String, homeDirectory: URL = .homeDirectory) -> String {
        let parent = URL(filePath: path).deletingLastPathComponent().path
        let home = homeDirectory.path
        if parent == home {
            return "~"
        }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        if parent.hasPrefix(homePrefix) {
            return "~/" + parent.dropFirst(homePrefix.count)
        }
        return parent
    }

    @ViewBuilder private func byteCount(_ bytes: Int64?) -> some View {
        if let bytes {
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        } else if uninstall.isPreparing {
            Text("Calculating…").foregroundStyle(.secondary)
        } else {
            Text("Size Unavailable").foregroundStyle(.secondary)
        }
    }

    private func artifacts(for item: BatchItem, plan: BatchPlan) -> [String] {
        guard case .homebrew(let identity) = item else { return [] }
        return plan.homebrewImpacts.first { $0.targets == [identity] }?.artifacts
            .filter { $0.category == .installed }.flatMap(\.values) ?? []
    }

    private func npmResiduePaths(for item: BatchItem, in result: BatchExecutionResult) -> [String] {
        guard let index = result.outcome.intent.items.firstIndex(of: item),
              case .npm(let providerResult) = result.providerResults[index],
              let residues = providerResult.residues else { return [] }
        return residues.directories + residues.bins
    }
}

struct LibraryUninstallPathStatusIndicator: View {
    let status: CaskRemovalPathStatus

    var body: some View {
        Group {
            switch status {
            case .pending, .retained, .unverified:
                Color.clear
            case .removing:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Uninstalling…")
            case .removed:
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    .accessibilityLabel("Removed")
            }
        }
        .frame(width: 24, height: 20)
    }
}

struct LibraryUninstallSizeSummary<Value: View>: View {
    let applicationSize: Value
    let estimatedRemoval: Value

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Application Size")
                applicationSize
            }
            GridRow {
                Text("Estimated Removal")
                estimatedRemoval
            }
        }
        .font(.callout)
    }
}

private struct LibraryUninstallSheetSizing: NSViewRepresentable {
    let height: CGFloat?

    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.height = height
        view.updateSheetSize()
    }

    final class SizingView: NSView {
        var height: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateSheetSize()
        }

        func updateSheetSize() {
            // SwiftUI can retain a fitted sheet's initial host size after its ideal content size changes.
            DispatchQueue.main.async { [weak self] in
                guard let self, let height = self.height, let window = self.window,
                      window.sheetParent != nil else { return }
                let size = NSSize(width: 500, height: height)
                let current = window.contentLayoutRect.size
                if abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 {
                    window.setContentSize(size)
                }
            }
        }
    }
}

private extension CaskRemovalSizeFailure {
    var title: LocalizedStringResource {
        switch self {
        case .permissionDenied: LocalizedStringResource("Permission Required to Read Size")
        case .limitReached: LocalizedStringResource("Size Scan Limit Reached")
        case .unsafePath: LocalizedStringResource("Size Scan Restricted")
        case .fileChanged: LocalizedStringResource("File Changed During Scan")
        case .notFound: LocalizedStringResource("File No Longer Exists")
        case .ioFailure: LocalizedStringResource("Unable to Read Size")
        }
    }

    var explanation: LocalizedStringResource {
        if self == .permissionDenied {
            return LocalizedStringResource("macOS or file permissions prevent reading this path. Check permissions and, if needed, Full Disk Access for Cellar in System Settings.")
        }
        return title
    }
}

private extension CaskRemovalCategory {
    var uninstallTitle: LocalizedStringResource {
        switch self {
        case .application: LocalizedStringResource("Application")
        case .cache: LocalizedStringResource("Caches")
        case .applicationData: LocalizedStringResource("Settings and Application Data")
        case .homebrewCache: LocalizedStringResource("Homebrew Download Cache")
        }
    }
}

private extension CaskRemovalWarning {
    var uninstallMessage: LocalizedStringResource {
        switch self {
        case .sharedData: LocalizedStringResource("Other installed applications may share this data. Shared files will be kept.")
        case .incompleteScan: LocalizedStringResource("Some locations could not be fully inspected. Additional files may remain.")
        case .uninstallerRequiresAuthorization: LocalizedStringResource("Homebrew’s uninstaller may require separate administrator authorization.")
        }
    }
}

// Only the list receives a constrained height; fixed content is measured before list placement.
struct LibraryUninstallLayout: Layout {
    let maximumHeight: CGFloat
    var forcedHeight: CGFloat? = nil
    private let width: CGFloat = 500
    private let padding: CGFloat = 24
    private let sectionSpacing: CGFloat = 14
    private let listSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let contentWidth = width - 2 * padding
        let identity = subviews[0].sizeThatFits(.init(width: contentWidth, height: nil))
        let summary = subviews[1].sizeThatFits(.init(width: contentWidth, height: nil))
        let list = subviews[2].sizeThatFits(.init(width: contentWidth + padding, height: nil))
        let footer = subviews[3].sizeThatFits(.init(width: width, height: nil))
        let summaryBlockHeight = summary.height > 0 ? sectionSpacing + summary.height + listSpacing : listSpacing
        let contentHeight = identity.height + summaryBlockHeight + list.height
        return CGSize(width: width, height: min(maximumHeight, forcedHeight ?? (contentHeight + 2 * padding + footer.height)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let contentWidth = bounds.width - 2 * padding
        let identitySize = subviews[0].sizeThatFits(.init(width: contentWidth, height: nil))
        let summarySize = subviews[1].sizeThatFits(.init(width: contentWidth, height: nil))
        let footerSize = subviews[3].sizeThatFits(.init(width: bounds.width, height: nil))
        let footerY = bounds.maxY - footerSize.height
        let hasSummary = summarySize.height > 0
        let summaryY = bounds.minY + padding + identitySize.height + (hasSummary ? sectionSpacing : 0)
        let listY = summaryY + summarySize.height + listSpacing
        let listHeight = max(0, footerY - padding - listY)
        subviews[0].place(at: .init(x: bounds.minX + padding, y: bounds.minY + padding), anchor: .topLeading,
                          proposal: .init(width: contentWidth, height: identitySize.height))
        subviews[1].place(at: .init(x: bounds.minX + padding, y: summaryY), anchor: .topLeading,
                          proposal: .init(width: contentWidth, height: summarySize.height))
        subviews[2].place(at: .init(x: bounds.minX + padding, y: listY), anchor: .topLeading,
                          proposal: .init(width: contentWidth + padding, height: listHeight))
        subviews[3].place(at: .init(x: bounds.minX, y: footerY), anchor: .topLeading,
                          proposal: .init(width: bounds.width, height: footerSize.height))
    }
}

// Measure the presenting window, never the sheet, so the cap cannot feed back into itself.
struct LibraryWindowHeightReader: NSViewRepresentable {
    let changed: (CGFloat?) -> Void

    func makeNSView(context: Context) -> WindowView { WindowView(changed: changed) }
    func updateNSView(_ nsView: WindowView, context: Context) { nsView.changed = changed }

    final class WindowView: NSView {
        var changed: (CGFloat?) -> Void

        init(changed: @escaping (CGFloat?) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                                                       name: NSWindow.didResizeNotification, object: window)
                publishHeight()
            } else {
                DispatchQueue.main.async { [weak self] in self?.changed(nil) }
            }
        }

        @objc private func windowResized(_ notification: Notification) { publishHeight() }

        private func publishHeight() {
            guard let window else { return }
            let height = window.contentLayoutRect.height
            let measuredHeight: CGFloat? = height > 0 ? height : nil
            DispatchQueue.main.async { [weak self] in self?.changed(measuredHeight) }
        }
    }
}
