import AppKit
import Combine
import PermissionFlow

@MainActor
final class FullDiskAccessGuide: ObservableObject {
    let controller: PermissionFlowController
    private let checkAccess: @Sendable () async -> ProtectedFileAccessResult
    private var observers: Set<AnyCancellable> = []
    private var monitorTask: Task<Void, Never>?

    init(
        controller: PermissionFlowController = PermissionFlow.makeController(configuration: .init(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false
        )),
        checkAccess: @escaping @Sendable () async -> ProtectedFileAccessResult = ProtectedFileAccessVerification.liveCheck
    ) {
        self.controller = controller
        self.checkAccess = checkAccess
    }

    @discardableResult
    func open(locale: Locale, onGranted: (@MainActor () -> Void)? = nil) -> Bool {
        close()
        controller.setLocaleIdentifier(locale.identifier)
        let opened = controller.authorize(pane: .fullDiskAccess)
        guard opened else { return false }
        startMonitoring(onGranted: onGranted)
        return true
    }

    func close() {
        observers.removeAll()
        monitorTask?.cancel()
        monitorTask = nil
        controller.closePanel()
    }

    private func startMonitoring(onGranted: (@MainActor () -> Void)?) {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.close() }
            .store(in: &observers)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                if app.bundleIdentifier == "com.apple.systempreferences" {
                    self?.close()
                }
            }
            .store(in: &observers)

        let checkAccess = self.checkAccess
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                if await checkAccess() == .verified {
                    guard !Task.isCancelled else { return }
                    self.close()
                    onGranted?()
                    return
                }
            }
        }
    }
}
