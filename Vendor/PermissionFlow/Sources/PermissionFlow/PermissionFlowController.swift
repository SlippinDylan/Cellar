#if os(macOS)
import AppKit
import Combine
import SystemSettingsKit
import SwiftUI

@available(macOS 13.0, *)
@MainActor
public final class PermissionFlowController: ObservableObject {
    /// The package exposes a single active floating panel at a time so opening
    /// a second permission flow closes the previous panel automatically.
    private static var activeController: PermissionFlowController?
    private let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    /// Apps currently represented in the floating panel.
    @Published public private(set) var droppedApps: [URL]

    /// The permission pane currently being guided.
    @Published public private(set) var currentPane: PermissionFlowPane?

    /// Drives the visibility of the "reopen settings" action.
    @Published var isSettingsFrontmost = false

    /// Drives the header icon animation while the app card is being dragged.
    @Published var isDraggingApp = false

    /// True while System Settings has been asked to open but its window is
    /// not on screen yet. The floating panel shows a loading state instead of
    /// the drag guide.
    @Published var isAwaitingSettingsWindow = false

    /// Drives the locale environment used by the floating SwiftUI panel.
    @Published public private(set) var localeIdentifier: String?

    public var onDrop: ((URL) -> Void)?

    private let configuration: PermissionFlowConfiguration
    private let tracker = SettingsWindowTracker()

    private var panel: FloatingDropPanel?
    private var pendingLaunchSourceFrame: CGRect?
    private var previousFrontmostApplication: ForegroundApplication?
    private let environment: Environment
    private let presentation: Presentation
    private var cancellables = Set<AnyCancellable>()

    public convenience init(configuration: PermissionFlowConfiguration = .init()) {
        self.init(configuration: configuration, environment: .live, presentation: .live)
    }

    init(configuration: PermissionFlowConfiguration = .init(), environment: Environment, presentation: Presentation) {
        self.environment = environment
        self.presentation = presentation
        self.configuration = configuration
        self.droppedApps = configuration.requiredAppURLs.uniqueAppURLs()
        self.localeIdentifier = configuration.localeIdentifier

        updateFrontmostAppState()
        bindTrackerCallbacks()
        observeFrontmostApplication()
    }

    /// Opens the requested privacy pane and starts the floating guidance flow.
    ///
    /// - Parameters:
    ///   - pane: The permission pane to open inside System Settings.
    ///   - suggestedAppURLs: Optional `.app` bundle URLs that should appear in
    ///     the floating panel as drag candidates. This parameter defaults to an
    ///     empty array, which means no explicit app list is injected here.
    ///     When this value is empty and no previously registered app is
    ///     available, the floating panel falls back to `Bundle.main.bundleURL`
    ///     if the current host bundle is itself an `.app`.
    ///   - sourceFrameInScreen: Optional source rect in screen coordinates used
    ///     as the launch point for the fly-to-settings animation. If omitted,
    ///     the panel still appears, but it skips the source-origin animation.
    @discardableResult
    public func authorize(
        pane: PermissionFlowPane,
        suggestedAppURLs: [URL] = [],
        sourceFrameInScreen: CGRect? = nil
    ) -> Bool {
        closeOtherActivePanelIfNeeded()
        closePanel()
        rememberPreviousFrontmostApplication()
        guard environment.openSettings(pane.settingsURL) else {
            previousFrontmostApplication = nil
            return false
        }

        currentPane = pane
        pendingLaunchSourceFrame = sourceFrameInScreen
        mergeDroppedApps(with: suggestedAppURLs)
        guard pane.supportsFloatingAuthorizationPanel else { return true }

        Self.activeController = self
        presentation.show(self)
        return true
    }

    /// Shows the floating guide.
    ///
    /// When System Settings is already on screen, the panel flies to that
    /// window. When it is still launching, the panel appears at the click
    /// anchor with a loading state instead of waiting invisibly.
    public func showPanel() {
        if panel == nil {
            panel = FloatingDropPanel(controller: self)
        }

        guard let panel else { return }

        if let settingsFrame = tracker.currentFrame {
            presentPanel(panel, for: settingsFrame)
            return
        }

        isAwaitingSettingsWindow = true
        panel.rebuildContent()
        panel.showWaiting(anchoredAt: pendingLaunchSourceFrame)
    }

    public func closePanel(returnToPreviousApp: Bool = false) {
        presentation.close(self)
        currentPane = nil
        isAwaitingSettingsWindow = false
        isDraggingApp = false
        pendingLaunchSourceFrame = nil

        if Self.activeController === self {
            Self.activeController = nil
        }

        if returnToPreviousApp, let previousFrontmostApplication {
            environment.activateApplication(previousFrontmostApplication)
        }
        previousFrontmostApplication = nil
    }

    public func resetDroppedApps() {
        droppedApps = configuration.requiredAppURLs.uniqueAppURLs()
    }

    /// Updates the locale injected into the floating panel.
    public func setLocaleIdentifier(_ localeIdentifier: String?) {
        guard self.localeIdentifier != localeIdentifier else { return }
        self.localeIdentifier = localeIdentifier
        panel?.updateLocaleIdentifier(localeIdentifier)
    }

    /// Registers a unique `.app` bundle URL and notifies the host if needed.
    public func registerDroppedApp(_ url: URL) {
        guard url.pathExtension.lowercased() == "app" else { return }
        let normalizedURL = url.standardizedFileURL
        guard droppedApps.contains(normalizedURL) == false else { return }
        droppedApps.append(normalizedURL)
        onDrop?(normalizedURL)
    }

    /// The panel always renders a single primary app card. If the host has not
    /// supplied one yet, the host application's bundle becomes the fallback.
    var preferredAppURL: URL? {
        if let first = droppedApps.first {
            return first
        }
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        return bundleURL.pathExtension.lowercased() == "app" ? bundleURL : nil
    }

    /// The panel becomes mouse-transparent while dragging so System Settings
    /// underneath can receive the drop.
    func setPanelDragging(_ isDragging: Bool) {
        isDraggingApp = isDragging
        panel?.setDraggingPassthrough(isDragging)
    }

    /// Keeps System Settings visually present whenever the floating panel is
    /// clicked or momentarily considered for focus.
    func keepSettingsVisible() {
        SystemSettings.activate()
        panel?.orderFrontRegardless()
    }

    func reopenCurrentSettingsPane() {
        guard let currentPane else { return }
        SystemSettings.open(url: currentPane.settingsURL)
        panel?.orderFrontRegardless()
    }

    /// Merges unique app bundle URLs into the current panel list.
    func mergeDroppedApps(with urls: [URL]) {
        for url in urls.uniqueAppURLs() {
            registerDroppedApp(url)
        }
    }

    private func bindTrackerCallbacks() {
        tracker.onFrameChange = { [weak self] frame in
            guard let self else { return }
            self.presentPanel(self.panel, for: frame)
        }
        tracker.onTrackingEnded = { [weak self] in
            self?.closePanel()
        }
    }

    private func observeFrontmostApplication() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFrontmostAppState()
            }
            .store(in: &cancellables)
    }

    private func closeOtherActivePanelIfNeeded() {
        if let activeController = Self.activeController, activeController !== self {
            activeController.closePanel()
        }
    }

    private func rememberPreviousFrontmostApplication() {
        let application = environment.frontmostApplication()
        guard application?.bundleIdentifier != systemSettingsBundleIdentifier else { return }
        previousFrontmostApplication = application
    }

    private func presentPanel(_ panel: FloatingDropPanel?, for settingsFrame: CGRect) {
        guard let panel else { return }

        if isAwaitingSettingsWindow {
            isAwaitingSettingsWindow = false
            panel.rebuildContent()
        }

        if let sourceFrame = pendingLaunchSourceFrame {
            panel.present(from: sourceFrame, to: settingsFrame)
            pendingLaunchSourceFrame = nil
        } else {
            panel.snap(to: settingsFrame)
        }
    }

    struct ForegroundApplication: Equatable, Sendable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
    }

    @MainActor
    struct Environment {
        var openSettings: (URL) -> Bool
        var frontmostApplication: () -> ForegroundApplication?
        var activateApplication: (ForegroundApplication) -> Void

        static var live: Self {
            .init(openSettings: { SystemSettings.open(url: $0) }, frontmostApplication: {
                NSWorkspace.shared.frontmostApplication.map {
                    ForegroundApplication(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
                }
            }, activateApplication: { previous in
                if let app = NSRunningApplication(processIdentifier: previous.processIdentifier) {
                    app.activate(options: [.activateIgnoringOtherApps])
                } else if let identifier = previous.bundleIdentifier {
                    NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?
                        .activate(options: [.activateIgnoringOtherApps])
                }
            })
        }
    }

    @MainActor
    struct Presentation {
        var show: (PermissionFlowController) -> Void
        var close: (PermissionFlowController) -> Void

        static var live: Self {
            .init(show: { controller in
                // Start tracking before showing the unchanged upstream panel.
                controller.tracker.startTracking(promptIfNeeded: controller.configuration.promptForAccessibilityTrust)
                controller.showPanel()
            }, close: { controller in
                controller.tracker.stopTracking()
                controller.panel?.close()
                controller.panel = nil
            })
        }
    }

    private func updateFrontmostAppState() {
        isSettingsFrontmost =
            environment.frontmostApplication()?.bundleIdentifier == systemSettingsBundleIdentifier
    }
}

@available(macOS 13.0, *)
private extension Array where Element == URL {
    /// Normalizes and de-duplicates `.app` bundle URLs.
    func uniqueAppURLs() -> [URL] {
        var seen = Set<String>()
        return compactMap { url in
            let normalized = url.standardizedFileURL
            guard normalized.pathExtension.lowercased() == "app" else { return nil }
            return seen.insert(normalized.path).inserted ? normalized : nil
        }
    }

    /// Uses normalized file paths for containment because equivalent file URLs
    /// can differ in their string representation.
    func contains(_ url: URL) -> Bool {
        contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path })
    }
}
#endif
