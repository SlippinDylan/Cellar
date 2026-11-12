import AppKit
import SwiftUI

struct BatchPackageEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let editor = NSTextView(frame: .zero, textContainer: container)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 4, height: 8)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.string = text
        editor.isEditable = isEditable
        editor.setAccessibilityLabel(String(localized: "Packages to Install"))
        editor.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        let ruler = PackageLineNumberRuler(scrollView: scroll, editor: editor)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.ruler = ruler
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didScroll),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = isEditable
        if editor.string != text {
            editor.string = text
            context.coordinator.ruler?.updateLines()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        (scroll.documentView as? NSTextView)?.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var ruler: PackageLineNumberRuler?
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
            ruler?.updateLines()
        }
        func textViewDidChangeSelection(_ notification: Notification) { ruler?.needsDisplay = true }
        @objc func didScroll(_ notification: Notification) { ruler?.needsDisplay = true }
    }
}

// Offsets use UTF-16, matching AppKit selection and layout ranges.
enum PackageEditorLines {
    static func starts(in text: String) -> [Int] {
        let value = text as NSString
        var starts = [0]
        var index = 0
        while index < value.length {
            var end = 0
            var contentsEnd = 0
            value.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
            if contentsEnd < end { starts.append(end) }
            index = end
        }
        return starts
    }

    static func currentLine(starts: [Int], caret: Int) -> Int {
        starts.lastIndex(where: { $0 <= caret }) ?? 0
    }
}

final class PackageLineNumberRuler: NSRulerView {
    private unowned let editor: NSTextView
    private var starts = [0]
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    // Keep the gutter on the editor's shared surface instead of AppKit's ruler background.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let height = max(0, bounds.height - 16)
        NSRect(x: bounds.minX, y: bounds.minY + 8, width: 1, height: height).fill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY + 8, width: 1, height: height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        setAccessibilityElement(false)
        updateLines()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateLines() {
        starts = PackageEditorLines.starts(in: editor.string)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ruleThickness = max(24, (String(starts.count) as NSString).size(withAttributes: [.font: font]).width + 12)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
        layout.ensureLayout(for: container)
        let current = PackageEditorLines.currentLine(starts: starts, caret: editor.selectedRange().location)
        for (index, offset) in starts.enumerated() {
            let line: NSRect
            if offset == (editor.string as NSString).length {
                line = layout.extraLineFragmentRect
            } else {
                let glyph = layout.glyphIndexForCharacter(at: offset)
                line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let point = convert(NSPoint(x: 0, y: line.minY + editor.textContainerOrigin.y), from: editor)
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: index == current ? .semibold : .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: index == current ? NSColor.labelColor : NSColor.secondaryLabelColor]
            let number = String(index + 1) as NSString
            let size = number.size(withAttributes: attributes)
            let target = NSRect(x: (ruleThickness - size.width) / 2, y: point.y, width: size.width, height: size.height)
            if target.intersects(rect) { number.draw(in: target, withAttributes: attributes) }
        }
    }
}
