#if os(macOS)
import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

@available(macOS 13.0, *)
@MainActor
final class SettingsWindowTracker {
    /// Polling remains enabled even when AX is available because System Settings
    /// can appear before accessibility observers are fully attached.
    private let pollInterval: TimeInterval = 1.0 / 30.0

    private var trackingState = SettingsWindowTrackingState()
    private(set) var isTracking = false
    private let frameProbe: (() -> CGRect?)?
    private let now: () -> ContinuousClock.Instant

    var onFrameChange: ((CGRect) -> Void)?
    var onTrackingEnded: (() -> Void)?
    private(set) var currentFrame: CGRect?

    private let bundleIdentifier = "com.apple.systempreferences"
    private var appObserver: AXObserver?
    private var windowObserver: AXObserver?
    private var observedWindow: AXUIElement?
    private var pollTimer: Timer?

    init(frameProbe: (() -> CGRect?)? = nil, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.frameProbe = frameProbe
        self.now = now
    }

    /// Starts locating the System Settings window and emitting frame updates.
    /// It can optionally prompt for Accessibility access so AX-based tracking
    /// becomes available after the initial window-server fallback.
    func startTracking(promptIfNeeded: Bool) {
        if promptIfNeeded {
            requestAccessibilityTrust()
        }

        stopTracking()
        trackingState.start(at: now())
        isTracking = true

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleWindow()
            }
        }
        pollTimer?.tolerance = pollInterval * 0.25
        sampleWindow()
    }

    /// Tears down polling and all AX observers so a future tracking session
    /// begins from a clean state.
    func stopTracking() {
        isTracking = false
        pollTimer?.invalidate()
        pollTimer = nil

        if let observer = appObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        if let observer = windowObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        appObserver = nil
        windowObserver = nil
        observedWindow = nil
        currentFrame = nil
        trackingState.reset()
    }

    /// Triggers the macOS Accessibility permission prompt when requested by
    /// the host app. Window-server tracking works without this, but AX access
    /// gives more direct move/resize notifications and window attributes.
    private func requestAccessibilityTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Central tracking loop entry point.
    /// It resolves the running System Settings app, emits a best-effort frame
    /// from the window server immediately, and if AX is available, attaches
    /// observers to the active window for continued updates.
    func sampleWindow() {
        guard isTracking else { return }
        let app: NSRunningApplication?
        let frame: CGRect?
        if let frameProbe {
            app = nil
            frame = frameProbe()
        } else {
            app = runningSettingsApplication()
            frame = app.flatMap { windowServerFrame(for: $0.processIdentifier) }
        }
        guard let frame else {
            finishTrackingIfWindowDisappeared()
            return
        }
        _ = trackingState.observe(isVisible: true, at: now())
        if currentFrame != frame {
            currentFrame = frame
            onFrameChange?(frame)
        }
        guard let app, AXIsProcessTrusted() else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if appObserver == nil {
            appObserver = makeObserver(for: app.processIdentifier)
            if let appObserver {
                addNotification(kAXMainWindowChangedNotification as CFString, element: appElement, observer: appObserver)
                addNotification(kAXFocusedWindowChangedNotification as CFString, element: appElement, observer: appObserver)
                CFRunLoopAddSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(appObserver),
                    .commonModes
                )
            }
        }

        guard let window = mainWindow(for: appElement) else { return }
        guard isSameElement(window, observedWindow) == false else {
            updateCurrentFrame()
            return
        }

        observedWindow = window
        updateWindowObserver(for: app.processIdentifier, window: window)
        updateCurrentFrame()
    }

    /// Rebinds the AX observer to the currently tracked System Settings
    /// window so move and resize notifications keep the floating panel in sync.
    private func updateWindowObserver(for pid: pid_t, window: AXUIElement) {
        if let windowObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(windowObserver),
                .commonModes
            )
        }

        windowObserver = makeObserver(for: pid)
        if let windowObserver {
            addNotification(kAXMovedNotification as CFString, element: window, observer: windowObserver)
            addNotification(kAXResizedNotification as CFString, element: window, observer: windowObserver)
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(windowObserver),
                .commonModes
            )
        }
    }

    /// Reads the active AX window's position and size attributes, converts
    /// them into AppKit screen coordinates, and publishes the new frame.
    private func updateCurrentFrame() {
        guard let window = observedWindow else { return }
        guard
            let position = pointValue(for: kAXPositionAttribute, element: window),
            let size = sizeValue(for: kAXSizeAttribute, element: window)
        else { return }

        let frame = appKitFrame(fromGlobalTopLeftFrame: CGRect(origin: position, size: size))
        guard currentFrame != frame else { return }
        currentFrame = frame
        onFrameChange?(frame)
    }

    /// Chooses the best AX window to track for System Settings.
    /// Main window is preferred, then focused window, then the first window
    /// in the app's AX window list as a last fallback.
    private func mainWindow(for appElement: AXUIElement) -> AXUIElement? {
        if let window = elementValue(for: kAXMainWindowAttribute, element: appElement) {
            return window
        }
        if let window = elementValue(for: kAXFocusedWindowAttribute, element: appElement) {
            return window
        }
        return arrayValue(for: kAXWindowsAttribute, element: appElement)?.first
    }

    /// Creates an AX observer for the System Settings process.
    /// All notifications funnel back into sampleWindow() so state refresh is
    /// handled in one place on the main thread.
    private func makeObserver(for pid: pid_t) -> AXObserver? {
        var observer: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<SettingsWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                tracker.sampleWindow()
            }
        }, &observer)
        guard result == .success else { return nil }
        return observer
    }

    /// Registers a specific AX notification on an AX element using this
    /// tracker instance as the observer callback context.
    private func addNotification(_ name: CFString, element: AXUIElement, observer: AXObserver) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, element, name, refcon)
    }

    /// Reads an AX attribute expected to contain a single AXUIElement value.
    /// Used for attributes like main window and focused window.
    /// Validates CF type before conversion so unexpected payloads degrade to nil.
    private func elementValue(for key: String, element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Safe after CFGetTypeID check: value is known to be an AXUIElement.
        return (value as! AXUIElement)
    }

    /// Reads an AX attribute expected to contain an array of AXUIElement values.
    /// Used as a fallback when main/focused window attributes are unavailable.
    /// Validates CFArray and each element's type; skips non-element entries.
    private func arrayValue(for key: String, element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }

        let nsArray = value as! NSArray
        var elements: [AXUIElement] = []
        elements.reserveCapacity(nsArray.count)

        for case let item as CFTypeRef in nsArray {
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { continue }
            // Safe after CFGetTypeID check: item is known to be an AXUIElement.
            elements.append(item as! AXUIElement)
        }

        return elements.isEmpty ? nil : elements
    }

    /// Reads an AX CGPoint attribute such as kAXPositionAttribute.
    /// Validates CF type and AXValue subtype before conversion to avoid crashes
    /// when System Settings returns an unexpected attribute payload.
    private func pointValue(for key: String, element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        let pointValue = value as! AXValue
        guard AXValueGetType(pointValue) == .cgPoint else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(pointValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// Reads an AX CGSize attribute such as kAXSizeAttribute.
    /// Validates CF type and AXValue subtype before conversion to avoid crashes
    /// when System Settings returns an unexpected attribute payload.
    private func sizeValue(for key: String, element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        let sizeValue = value as! AXValue
        guard AXValueGetType(sizeValue) == .cgSize else { return nil }

        var size = CGSize.zero
        guard AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Compares AX elements by Core Foundation equality to avoid rebuilding
    /// observers when the tracked window object has not actually changed.
    private func isSameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    /// Chooses the most relevant running System Settings process to track.
    /// This prefers a UI-capable instance over prohibited activation-policy
    /// helpers when multiple matching processes exist.
    private func runningSettingsApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .max(by: { ($0.activationPolicy == .prohibited ? 0 : 1) < ($1.activationPolicy == .prohibited ? 0 : 1) })
    }

    /// Scans on-screen window-server entries for the System Settings process
    /// and returns the largest visible layer-0 window as the tracked frame.
    private func windowServerFrame(for pid: pid_t) -> CGRect? {
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        // Choose the largest visible layer-0 window for the System Settings
        // process, which maps well to the main document-sized window.
        //
        // Important: kCGWindowBounds is the window server's bounds for the
        // composited window surface. In practice this can still feel "larger"
        // than the visually useful content area because macOS windows may have
        // outer decoration/framing/shadow that is not where we want to attach
        // the floating helper panel.
        //
        // If the panel appears slightly too far away from the bottom edge of
        // System Settings, the gap usually does NOT come from the coordinate
        // flip in appKitScreenFrame(fromWindowServerBounds:). It usually means
        // the source bounds themselves are visually taller than the edge you
        // want to align against.
        //
        // That is why a manual vertical compensation such as +28 can appear to
        // "fix" the issue: it is effectively trimming some bottom framing from
        // the tracked window frame before the panel snaps underneath it.
        let bestMatch = windows
            .filter { window in
                guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
                guard ownerPID == pid else { return false }
                let layer = window[kCGWindowLayer as String] as? Int ?? 0
                let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
                return layer == 0 && alpha > 0
            }
            .compactMap { window -> CGRect? in
                guard let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
                guard let cgBounds = CGRect(dictionaryRepresentation: bounds) else { return nil }
                let frame = appKitFrame(fromGlobalTopLeftFrame: cgBounds)
                guard frame.width > 320, frame.height > 240 else { return nil }
                return frame
            }
            .max(by: { $0.width * $0.height < $1.width * $1.height })

        return bestMatch
    }

    /// Converts a global top-left-origin rectangle from CG/AX space into
    /// AppKit screen coordinates using the screen with the greatest overlap.
    /// The `- 3` vertical offset is the upstream visual compensation used
    /// by this package so the floating helper panel sits closer to the visible
    /// bottom edge of the System Settings window.
    private func appKitFrame(fromGlobalTopLeftFrame frame: CGRect) -> CGRect {
        let screens = NSScreen.screens.compactMap { screen -> (frame: CGRect, cgBounds: CGRect)? in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return (frame: screen.frame, cgBounds: CGDisplayBounds(displayID))
        }

        return ScreenGeometry.appKitFrame(fromGlobalTopLeft: frame, screens: screens)
    }

    /// A hidden/minimized/closed window is no longer a useful authorization target.
    private func finishTrackingIfWindowDisappeared() {
        guard trackingState.observe(isVisible: false, at: now()) else { return }
        stopTracking()
        onTrackingEnded?()
    }

}
#endif
