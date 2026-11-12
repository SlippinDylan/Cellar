import AppKit
import SwiftUI
import XCTest
@testable import Cellar

@MainActor
final class BatchPackageEditorTests: XCTestCase {
    func testEditingUndoAndRedoKeepPackageInputAndLineNumbersInSync() throws {
        var input = "git"
        let binding = Binding(get: { input }, set: { input = $0 })
        let host = NSHostingView(rootView: BatchPackageEditor(text: binding, isEditable: true)
            .frame(width: 500, height: 196))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 196),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(textView(in: host))
        window.makeFirstResponder(editor)
        let undo = try XCTUnwrap(editor.undoManager)
        undo.groupsByEvent = false
        let ruler = try XCTUnwrap(editor.enclosingScrollView?.verticalRulerView)
        let originalGutterWidth = ruler.ruleThickness
        let pasted = (1...12).map { "package-\($0)" }.joined(separator: "\n")

        undo.beginUndoGrouping()
        editor.insertText(pasted, replacementRange: NSRange(location: 0, length: 3))
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertEqual(input, pasted)
        XCTAssertGreaterThan(ruler.ruleThickness, originalGutterWidth)
        undo.undo()
        XCTAssertEqual(input, "git")
        XCTAssertEqual(editor.string, input)
        XCTAssertEqual(ruler.ruleThickness, originalGutterWidth)
        undo.redo()
        XCTAssertEqual(input, pasted)
        XCTAssertEqual(editor.string, input)
        XCTAssertGreaterThan(ruler.ruleThickness, originalGutterWidth)

        undo.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.delete(nil)
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertEqual(input, "")
        undo.undo()
        XCTAssertEqual(input, pasted)
        XCTAssertEqual(editor.string, input)
        undo.redo()
        XCTAssertEqual(input, "")
        XCTAssertEqual(editor.string, input)
        XCTAssertEqual(ruler.ruleThickness, originalGutterWidth)
    }

    func testLongInputCanScrollToFirstAndLastLines() throws {
        let text = (1...100).map { "package-\($0)" }.joined(separator: "\n")
        let host = NSHostingView(rootView: BatchPackageEditor(text: .constant(text), isEditable: true)
            .frame(width: 500, height: 196))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 196),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(textView(in: host))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        XCTAssertGreaterThan(scroll.contentView.documentRect.height, scroll.contentSize.height)
        for line in [0, 99] {
            let offset = PackageEditorLines.starts(in: text)[line]
            editor.scrollRangeToVisible(NSRange(location: offset, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: offset)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            XCTAssertTrue(editor.visibleRect.intersects(rect), "Line \(line + 1) must be reachable")
        }
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }
}
