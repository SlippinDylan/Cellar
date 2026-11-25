import Foundation

actor ManagerSnapshotInstaller {
    static let snapshotVersion = "586d960-app7"

    private let fileManager: FileManager
    private let bundle: Bundle
    private let applicationSupportDirectory: URL

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        applicationSupportDirectory: URL = .applicationSupportDirectory
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    func installIfNeeded() throws -> SnapshotStatus {
        let managersRoot = applicationSupportDirectory
            .appending(path: "Cellar", directoryHint: .isDirectory)
            .appending(path: "Managers", directoryHint: .isDirectory)
        let destination = managersRoot.appending(path: Self.snapshotVersion, directoryHint: .isDirectory)

        let installedStatus = status(at: destination)
        if installedStatus.nodeAvailable,
           installedStatus.homebrewAvailable,
           installedStatus.shellAvailable {
            return installedStatus
        }

        guard let resourcesURL = bundle.resourceURL else {
            throw BridgeError.invalidOutput("App bundle is missing the Resources directory")
        }

        let source = resourcesURL.appending(path: "Managers", directoryHint: .isDirectory)
        let sourceStatus = status(at: source)
        guard sourceStatus.nodeAvailable,
              sourceStatus.homebrewAvailable,
              sourceStatus.shellAvailable
        else {
            throw BridgeError.invalidOutput("Bundled Manager snapshot is incomplete")
        }

        try fileManager.createDirectory(at: managersRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let staging = managersRoot.appending(
            path: ".install-\(Self.snapshotVersion)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

        do {
            try fileManager.copyItem(at: source, to: staging)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            if !fileManager.fileExists(atPath: destination.path) {
                throw error
            }
        }

        let finalStatus = status(at: destination)
        guard finalStatus.nodeAvailable,
              finalStatus.homebrewAvailable,
              finalStatus.shellAvailable
        else {
            throw BridgeError.invalidOutput("Installed Manager runtime snapshot is incomplete")
        }
        return finalStatus
    }

    func status(at destination: URL? = nil) -> SnapshotStatus {
        let root = destination ?? applicationSupportDirectory
            .appending(path: "Cellar/Managers/\(Self.snapshotVersion)", directoryHint: .isDirectory)
        return SnapshotStatus(
            version: Self.snapshotVersion,
            location: root.path,
            nodeAvailable: fileManager.isExecutableFile(atPath: root.appending(path: "node-manager/main.sh").path)
                || fileManager.isReadableFile(atPath: root.appending(path: "node-manager/main.sh").path),
            homebrewAvailable: fileManager.isReadableFile(atPath: root.appending(path: "homebrew-manager/main.sh").path),
            shellAvailable: fileManager.isReadableFile(atPath: root.appending(path: "zsh-manager/omz-manager.sh").path)
                && fileManager.isExecutableFile(atPath: root.appending(path: "zsh-manager/app-json.sh").path)
        )
    }
}
