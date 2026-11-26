import AppKit
import SwiftUI

enum AppLayout {
    static let spacing: CGFloat = 16
    static let cardSpacing: CGFloat = 8
    static let minimumInfoRowHeight: CGFloat = 32
    static let minimumControlRowHeight: CGFloat = 40
    static let minimumDescribedRowHeight: CGFloat = 52
}

extension View {
    func constrainedSheetWidth(_ idealWidth: CGFloat, horizontalMargin: CGFloat = 56) -> some View {
        modifier(ConstrainedSheetWidthModifier(idealWidth: idealWidth, horizontalMargin: horizontalMargin))
    }
}

private struct ConstrainedSheetWidthModifier: ViewModifier {
    let idealWidth: CGFloat
    let horizontalMargin: CGFloat
    @State private var resolvedWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .frame(width: resolvedWidth ?? initialWidth)
            .background(SheetParentWidthReader { parentWidth in
                let clamped = min(idealWidth, max(320, parentWidth - horizontalMargin))
                if resolvedWidth != clamped {
                    resolvedWidth = clamped
                }
            })
    }

    private var initialWidth: CGFloat {
        let parentWidth = NSApp.keyWindow?.frame.width ?? idealWidth + horizontalMargin
        return min(idealWidth, max(320, parentWidth - horizontalMargin))
    }
}

private struct SheetParentWidthReader: NSViewRepresentable {
    let onWidth: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onWidth = onWidth
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onWidth = onWidth
    }

    @MainActor
    final class ObserverView: NSView {
        var onWidth: (@MainActor (CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWidth()
        }

        private func reportWidth() {
            guard let window else { return }
            let fallbackKeyWindow = NSApp.keyWindow === window ? nil : NSApp.keyWindow
            guard let parentWidth = (window.sheetParent ?? window.parent ?? fallbackKeyWindow)?.frame.width else { return }
            Task { @MainActor [weak self] in
                self?.onWidth?(parentWidth)
            }
        }
    }
}

struct DashboardSectionHeader<Trailing: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    let tint: Color
    @ViewBuilder let trailing: Trailing

    init(
        _ title: LocalizedStringResource,
        systemImage: String,
        tint: Color,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary.opacity(0.75))
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(.separator.opacity(0.35))
                .frame(height: 0.5)
                .padding(.leading, 4)
            trailing
        }
        .padding(.leading, 2)
    }
}

struct SettingsPage<Content: View>: View {
    var fillsViewport = false
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: fillsViewport ? max(0, geometry.size.height - AppLayout.spacing * 2) : nil,
                       alignment: .topLeading)
            }
            .contentMargins(AppLayout.spacing, for: .scrollContent)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: LocalizedStringResource
    var website: URL? = nil
    var websiteTitle: LocalizedStringResource = "Official Website"
    var detail: String? = nil
    var action: SettingsSectionAction? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LinkedTitle(title, destination: website, linkLabel: websiteTitle)
                    .font(.headline)
                if detail != nil || action != nil { Spacer(minLength: 12) }
                if let detail {
                    Text(verbatim: detail).font(.callout).foregroundStyle(.secondary)
                }
                if let action {
                    Button(action.title, action: action.perform)
                        .disabled(!action.isEnabled)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                }
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct SettingsSectionAction {
    let title: LocalizedStringResource
    let isEnabled: Bool
    let perform: () -> Void
}

struct SettingsTextField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(title, text: $text, prompt: Text(verbatim: prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
    }
}
