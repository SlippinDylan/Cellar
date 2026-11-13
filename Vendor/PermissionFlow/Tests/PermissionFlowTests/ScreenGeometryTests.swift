import Foundation
import Testing
@testable import PermissionFlow

struct ScreenGeometryTests {
    @Test func narrowOverlapOnPrimaryDoesNotPullPanelOffSecondaryScreen() throws {
        let first = ScreenGeometry.Screen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))
        let second = ScreenGeometry.Screen(frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                          visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1055))
        let source = CGRect(x: 1880, y: 100, width: 700, height: 600)
        for screens in [[first, second], [second, first]] {
            let settings = ScreenGeometry.appKitFrame(fromGlobalTopLeft: source,
                screens: screens.map { (frame: $0.frame, cgBounds: $0.frame) })
            #expect(settings == CGRect(x: 1880, y: 377, width: 700, height: 600))
            let visible = try #require(ScreenGeometry.visibleFrame(for: settings, screens: screens, fallback: first.visibleFrame))
            let panel = ScreenGeometry.panelFrame(for: settings, visibleFrame: visible,
                sidebarWidth: 230, inset: 12, measuredHeight: { _ in 140 })
            #expect(panel == CGRect(x: 2110, y: 237, width: 470, height: 140))
            #expect(second.visibleFrame.contains(panel))
        }
    }

    @Test func spanningWindowsSelectLargestOverlapRegardlessOfScreenOrder() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let neighbors = [
            CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 900, width: 1920, height: 1080),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        ]
        let windows = [
            CGRect(x: 1400, y: 200, width: 700, height: 500),
            CGRect(x: -650, y: 200, width: 700, height: 500),
            CGRect(x: 300, y: 850, width: 700, height: 600),
            CGRect(x: 300, y: -550, width: 700, height: 600)
        ]
        for (neighbor, window) in zip(neighbors, windows) {
            let target = ScreenGeometry.Screen(frame: neighbor, visibleFrame: neighbor.insetBy(dx: 8, dy: 24))
            let primary = ScreenGeometry.Screen(frame: main, visibleFrame: main.insetBy(dx: 8, dy: 24))
            for screens in [[primary, target], [target, primary]] {
                #expect(ScreenGeometry.visibleFrame(for: window, screens: screens, fallback: main) == target.visibleFrame)
                let panel = ScreenGeometry.clamped(window, to: target.visibleFrame, inset: 12)
                #expect(target.visibleFrame.insetBy(dx: 12, dy: 12).contains(panel))
            }
        }
    }

    @Test func coordinateConversionMatchesPanelScreenForHorizontalAndVerticalLayouts() throws {
        let main = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    cgBounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let neighbors = [
            (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), cgBounds: CGRect(x: 1440, y: -180, width: 1920, height: 1080)),
            (frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), cgBounds: CGRect(x: -1920, y: -180, width: 1920, height: 1080)),
            (frame: CGRect(x: 0, y: 900, width: 1920, height: 1080), cgBounds: CGRect(x: 0, y: -1080, width: 1920, height: 1080)),
            (frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080), cgBounds: CGRect(x: 0, y: 900, width: 1920, height: 1080))
        ]
        for neighbor in neighbors {
            let source = CGRect(x: neighbor.cgBounds.minX + 300, y: neighbor.cgBounds.minY + 200, width: 700, height: 500)
            let expected = CGRect(x: neighbor.frame.minX + 300, y: neighbor.frame.maxY - 703, width: 700, height: 500)
            for screens in [[main, neighbor], [neighbor, main]] {
                let converted = ScreenGeometry.appKitFrame(fromGlobalTopLeft: source, screens: screens)
                #expect(converted == expected)
                let index = try #require(ScreenGeometry.bestMatch(for: converted, frames: screens.map(\.frame)))
                #expect(screens[index].frame == neighbor.frame)
            }
        }
    }

    @Test func singleScreenAndOffscreenFallbackPreserveExistingGeometry() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 50, width: 1440, height: 825)
        let source = CGRect(x: 200, y: 100, width: 800, height: 600)
        #expect(ScreenGeometry.appKitFrame(fromGlobalTopLeft: source, screens: [(screen, screen)])
            == CGRect(x: 200, y: 197, width: 800, height: 600))
        let offscreen = CGRect(x: 9000, y: 9000, width: 420, height: 150)
        let screens = [ScreenGeometry.Screen(frame: screen, visibleFrame: visible)]
        #expect(ScreenGeometry.visibleFrame(for: offscreen, screens: screens, fallback: visible) == visible)
        #expect(ScreenGeometry.visibleFrame(for: offscreen, screens: screens, fallback: nil) == nil)
        #expect(ScreenGeometry.appKitFrame(fromGlobalTopLeft: offscreen, screens: [(screen, screen)]) == offscreen)
        #expect(ScreenGeometry.clamped(offscreen, to: visible, inset: 12)
            == CGRect(x: 1008, y: 713, width: 420, height: 150))
        #expect(ScreenGeometry.bestMatch(for: source, frames: []) == nil)
    }
}
