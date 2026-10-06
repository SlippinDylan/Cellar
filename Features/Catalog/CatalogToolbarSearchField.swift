import AppKit
import SwiftUI

struct CatalogToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID?
    let prompt: LocalizedStringResource
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = String(localized: prompt)
        field.setAccessibilityLabel(String(localized: prompt))
        field.sendsSearchStringImmediately = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard let focusRequest, context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.fittingSize.width, height: nsView.fittingSize.height)
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: CatalogToolbarSearchField
        var lastFocusRequest: UUID?

        init(parent: CatalogToolbarSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), let submit = parent.onSubmit else { return false }
            parent.text = textView.string
            submit()
            return true
        }
    }
}
