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

    var body: some View {
        LibraryUninstallLayout(maximumHeight: maximumHeight, forcedHeight: executionHeight) {
            identity
            VStack(alignment: .leading, spacing: 12) {
                Text("Uninstall Software").font(.title2.bold())
                summary
            }
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                details.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 24)
            }
            .clipped()
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    if removal != nil && uninstall.hasFinished {
                        Button("OK", action: uninstall.dismissConfirmation)
                            .keyboardShortcut(.defaultAction)
                    } else if removal != nil && uninstall.isExecuting {
                        Text("Uninstalling…").foregroundStyle(.secondary)
                    } else {
                        Button("Cancel", role: .cancel, action: uninstall.dismissConfirmation)
                            .keyboardShortcut(.cancelAction)
                            .disabled(uninstall.isExecuting)
                        Button("Uninstall", role: .destructive) {
                            if removal != nil { executionHeight = presentationHeight }
                            Task { await uninstall.confirmUninstall() }
                        }
                        .tint(.red)
                        .disabled(uninstall.isPreparing || plan == nil || plan?.executableCount == 0 || uninstall.isExecuting)
                    }
                }
                .frame(height: 40)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        // Measure the intrinsic layout, before the host frame constrains it.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentationHeight = $0 }
        .constrainedSheetWidth(700)
        .frame(height: presentationHeight)
        .background(LibraryUninstallSheetSizing(height: presentationHeight))
        .presentationSizing(.fitted)
        .interactiveDismissDisabled(uninstall.isExecuting)
        .onChange(of: uninstall.isExecuting) { _, executing in
            if executing && removal != nil && executionHeight == nil { executionHeight = presentationHeight }
        }
    }

    private var identity: some View {
        VStack(spacing: 12) {
            if let icon = uninstall.appIcon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 88, height: 88)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "shippingbox").font(.system(size: 64)).foregroundStyle(.secondary)
                    .frame(width: 88, height: 88).accessibilityHidden(true)
            }
            Text(displayName).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                .help(displayName).textSelection(.enabled)
        }
    }

    @ViewBuilder private var summary: some View {
        if removal != nil || (uninstall.isPreparing && uninstall.presentedItem?.scope == .homebrew(.cask)) {
            LibraryUninstallSizeSummary(
                applicationSize: byteCount(removal?.applicationBytes),
                estimatedRemoval: byteCount(removal?.removalBytes)
            )
            Divider()
        } else if let plan {
            Text(plan.intent.scope.libraryTitle).font(.headline)
            Text("This item will be removed. This cannot be rolled back.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var details: some View {
        if uninstall.isPreparing {
            ProgressView("Scanning Related Files…")
                .frame(maxWidth: .infinity, minHeight: 100)
        } else if let removal {
            VStack(alignment: .leading, spacing: 16) {
                ForEach([CaskRemovalCategory.application, .cache, .applicationData, .homebrewCache], id: \.self) { category in
                    let entries = removal.entries.filter { $0.category == category }
                    if !entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.uninstallTitle).font(.headline)
                            ForEach(entries) { entry in
                                removalRow(entry)
                            }
                        }
                    }
                }
                ForEach(Array(removal.warnings.enumerated()), id: \.offset) { _, warning in
                    Label { Text(warning.uninstallMessage) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !uninstall.hasFinished {
                    Text("Application data will be permanently removed, except files marked as kept. This cannot be rolled back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if uninstall.hasFinished {
                    if let result = uninstall.result {
                        Text(result.outcome.status.libraryTitle).font(.headline)
                        if result.refreshStatus == .failed {
                            Text("Uninstall finished, but the environment could not be refreshed. Use Refresh to check the current state.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(result.outcome.itemOutcomes, id: \.item) { outcome in
                            if let reason = outcome.reason { Text(reason.message).font(.callout).foregroundStyle(.secondary) }
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
                    Text(item.displayIdentifier).textSelection(.enabled)
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
            }
        }
    }

    private func removalRow(_ entry: CaskRemovalEntry) -> some View {
        let status = uninstall.pathStatus(entry)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Button { uninstall.revealInFinder(entry) } label: {
                    Text(entry.path).font(.callout)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
                .disabled(status == .removed)
                if let guidance = uninstall.guidance(for: entry) {
                    Text(guidance.message)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Group {
                if let failure = entry.sizeFailure {
                    Text(failure.title).foregroundStyle(.secondary).help(Text(failure.explanation))
                } else {
                    byteCount(entry.estimatedBytes)
                }
            }
            .font(.callout).monospacedDigit().fixedSize()
            LibraryUninstallPathStatusIndicator(status: status)
        }
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
        }
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
                let size = NSSize(width: 700, height: height)
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
    private let width: CGFloat = 700
    private let padding: CGFloat = 24
    private let identityWidth: CGFloat = 144
    private let columnSpacing: CGFloat = 24
    private let listSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let detailWidth = width - 2 * padding - identityWidth - columnSpacing
        let identity = subviews[0].sizeThatFits(.init(width: identityWidth, height: nil))
        let summary = subviews[1].sizeThatFits(.init(width: detailWidth, height: nil))
        let list = subviews[2].sizeThatFits(.init(width: detailWidth + padding, height: nil))
        let footer = subviews[3].sizeThatFits(.init(width: width, height: nil))
        let contentHeight = max(identity.height, summary.height + listSpacing + list.height)
        return CGSize(width: width, height: min(maximumHeight, forcedHeight ?? (contentHeight + 2 * padding + footer.height)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let detailX = bounds.minX + padding + identityWidth + columnSpacing
        let detailWidth = bounds.width - 2 * padding - identityWidth - columnSpacing
        let summarySize = subviews[1].sizeThatFits(.init(width: detailWidth, height: nil))
        let footerSize = subviews[3].sizeThatFits(.init(width: bounds.width, height: nil))
        let footerY = bounds.maxY - footerSize.height
        let listY = bounds.minY + padding + summarySize.height + listSpacing
        let listHeight = max(0, footerY - padding - listY)
        subviews[0].place(at: .init(x: bounds.minX + padding + identityWidth / 2,
                                     y: (bounds.minY + footerY) / 2), anchor: .center,
                          proposal: .init(width: identityWidth, height: nil))
        subviews[1].place(at: .init(x: detailX, y: bounds.minY + padding), anchor: .topLeading,
                          proposal: .init(width: detailWidth, height: summarySize.height))
        subviews[2].place(at: .init(x: detailX, y: listY), anchor: .topLeading,
                          proposal: .init(width: detailWidth + padding, height: listHeight))
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
