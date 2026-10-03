import AppKit
import CryptoKit
import Foundation

actor HomebrewSetupService {
    private let temporaryRoot: URL
    private let metadata: @Sendable () async throws -> HomebrewInstallerMetadata
    private let download: @Sendable (HomebrewInstallerMetadata, URL) async throws -> Void
    private let digest: @Sendable (URL) async throws -> String
    private let packageSignature: @Sendable (URL) async throws -> Void
    private let gatekeeper: @Sendable (URL) async throws -> Void
    private let opener: @Sendable (URL) async throws -> Void
    private var installationInProgress = false
    private var handedOffDirectory: URL?

    init(
        temporaryRoot: URL,
        metadata: @escaping @Sendable () async throws -> HomebrewInstallerMetadata,
        download: @escaping @Sendable (HomebrewInstallerMetadata, URL) async throws -> Void,
        digest: @escaping @Sendable (URL) async throws -> String,
        packageSignature: @escaping @Sendable (URL) async throws -> Void,
        gatekeeper: @escaping @Sendable (URL) async throws -> Void,
        opener: @escaping @Sendable (URL) async throws -> Void
    ) {
        self.temporaryRoot = temporaryRoot
        self.metadata = metadata
        self.download = download
        self.digest = digest
        self.packageSignature = packageSignature
        self.gatekeeper = gatekeeper
        self.opener = opener
    }

    init(runner: ProcessRunner, http: CatalogHTTPClient = CatalogHTTPClient(), transport: any CatalogHTTPTransport = URLSessionCatalogTransport(), temporaryRoot: URL = FileManager.default.temporaryDirectory.appending(path: "Cellar-Installers")) {
        let client = HomebrewReleaseClient(http: http)
        let trust = HomebrewInstallerTrustClient(runner: runner)
        self.init(
            temporaryRoot: temporaryRoot,
            metadata: { try await client.installerMetadata() },
            download: { metadata, destination in
                try await transport.download(CatalogHTTPRequest(url: metadata.downloadURL, allowedOrigins: ["https://github.com", "https://release-assets.githubusercontent.com"], headers: ["User-Agent": "Cellar"], maximumBytes: metadata.size, timeout: 120), to: destination)
            },
            digest: { try await Self.sha256(of: $0) },
            packageSignature: { try await trust.validatePackageSignature($0) },
            gatekeeper: { try await trust.assessGatekeeper($0) },
            opener: { url in
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: URL(filePath: "/System/Library/CoreServices/Installer.app"), configuration: NSWorkspace.OpenConfiguration())
            }
        )
    }

    func openInstaller() async throws -> URL {
        guard !installationInProgress, handedOffDirectory == nil else { throw HomebrewSetupError(failure: .installationInProgress) }
        installationInProgress = true
        defer { installationInProgress = false }
        var directory: URL?
        var stage = HomebrewSetupFailure.releaseMetadata
        do {
            try Task.checkCancellation()
            let metadata = try await metadata()
            try Task.checkCancellation()
            stage = .temporaryFile
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let ownedDirectory = temporaryRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = ownedDirectory
            let package = ownedDirectory.appending(path: "Homebrew.pkg")
            stage = .download
            try await download(metadata, package)
            try Task.checkCancellation()
            let values = try package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false, values.fileSize == metadata.size else { throw HomebrewSetupFailure.download }
            stage = .digestMismatch
            guard try await digest(package).lowercased() == metadata.sha256 else { throw HomebrewSetupFailure.digestMismatch }
            try Task.checkCancellation()
            stage = .packageSignature
            try await packageSignature(package)
            try Task.checkCancellation()
            stage = .gatekeeper
            try await gatekeeper(package)
            try Task.checkCancellation()
            stage = .systemOpen
            try await opener(package)
            // Installer reads asynchronously. Retain the file until its caller reports completion.
            handedOffDirectory = ownedDirectory
            return package
        } catch {
            if let directory {
                do { try FileManager.default.removeItem(at: directory) }
                catch { throw HomebrewSetupError(failure: .temporaryFile) }
            }
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw HomebrewSetupError(failure: (error as? HomebrewSetupFailure) ?? stage)
        }
    }

    func finishInstallerHandoff() throws {
        guard let directory = handedOffDirectory else { return }
        try FileManager.default.removeItem(at: directory)
        handedOffDirectory = nil
    }

    static func sha256(of url: URL) async throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
