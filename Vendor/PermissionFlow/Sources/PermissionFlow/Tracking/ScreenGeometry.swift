#if os(macOS)
import Foundation

/// Shared screen selection for CG/AX conversion and AppKit panel placement.
enum ScreenGeometry {
    struct Screen {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    static func visibleFrame(for rect: CGRect, screens: [Screen], fallback: CGRect?) -> CGRect? {
        bestMatch(for: rect, frames: screens.map(\.frame)).map { screens[$0].visibleFrame } ?? fallback
    }

    static func bestMatch(for rect: CGRect, frames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let intersection = frame.intersection(rect)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if let current = best, area <= current.area { continue }
            best = (index, area)
        }
        return best?.index
    }

    static func appKitFrame(fromGlobalTopLeft rect: CGRect, screens: [(frame: CGRect, cgBounds: CGRect)]) -> CGRect {
        guard let index = bestMatch(for: rect, frames: screens.map(\.cgBounds)) else { return rect }
        let screen = screens[index]
        return CGRect(
            x: screen.frame.minX + rect.minX - screen.cgBounds.minX,
            // Preserve the upstream visual attachment compensation.
            y: screen.frame.maxY - (rect.minY - screen.cgBounds.minY) - rect.height - 3,
            width: rect.width,
            height: rect.height
        )
    }

    static func panelFrame(for settingsFrame: CGRect, visibleFrame: CGRect, sidebarWidth: CGFloat,
                           inset: CGFloat, measuredHeight: (CGFloat) -> CGFloat) -> CGRect {
        let width = min(max(240, settingsFrame.width - sidebarWidth), visibleFrame.width - inset * 2)
        let height = measuredHeight(width)
        return clamped(CGRect(x: settingsFrame.minX + sidebarWidth, y: settingsFrame.minY - height,
                              width: width, height: height), to: visibleFrame, inset: inset)
    }

    static func clamped(_ rect: CGRect, to visibleFrame: CGRect, inset: CGFloat) -> CGRect {
        let minimumX = visibleFrame.minX + inset
        let minimumY = visibleFrame.minY + inset
        let maximumX = max(minimumX, visibleFrame.maxX - rect.width - inset)
        let maximumY = max(minimumY, visibleFrame.maxY - rect.height - inset)
        return CGRect(
            x: min(max(rect.minX, minimumX), maximumX),
            y: min(max(rect.minY, minimumY), maximumY),
            width: rect.width,
            height: rect.height
        )
    }
}
#endif
