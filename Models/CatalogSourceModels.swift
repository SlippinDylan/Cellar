import Foundation

enum CatalogWebsites {
    static let homebrew = url(host: "brew.sh", path: "/")
    static let node = url(host: "nodejs.org", path: "/en")
    static let npm = url(host: "www.npmjs.com", path: "/")
    static let npmRegistry = url(host: "registry.npmjs.org", path: "/")
    static let nvm = url(host: "github.com", path: "/nvm-sh/nvm#installing-and-updating")
    static let commandLineTools = url(host: "developer.apple.com", path: "/documentation/xcode/installing-the-command-line-tools")

    static func url(host: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        let parts = path.split(separator: "#", maxSplits: 1)
        components.path = String(parts[0])
        if parts.count == 2 { components.fragment = String(parts[1]) }
        guard let url = components.url else { preconditionFailure("Invalid built-in website URL") }
        return url
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              url.user == nil, url.password == nil,
              url.port.map({ (1...65_535).contains($0) }) != false
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }

    static func safeWebsite(_ url: URL?) -> URL? {
        guard let url, origin(url) != nil else { return nil }
        return url
    }
}

struct NPMCatalogResult: Equatable, Sendable {
    let identity: NPMPackageIdentity
    let version: String
    let description: String?
    let websiteURL: URL?
    let registryURL: URL
}

struct NodeOnlineVersions: Equatable, Sendable {
    let node: OnlineVersionState
    let npm: OnlineVersionState
    let nvm: OnlineVersionState
}

enum HomebrewSetupFailure: Error, Equatable, Sendable {
    case releaseMetadata
    case digestMissing
    case digestInvalid
    case digestMismatch
    case download
    case packageSignature
    case gatekeeper
    case systemOpen
    case temporaryFile
    case installationInProgress
}

struct HomebrewSetupError: Error, Sendable {
    let failure: HomebrewSetupFailure
    let officialURL = CatalogWebsites.homebrew
}

struct HomebrewInstallerMetadata: Equatable, Sendable {
    static let maximumDownloadBytes = 256 * 1_024 * 1_024
    let version: String
    let downloadURL: URL
    let sha256: String
    let size: Int

    init(version: String, downloadURL: URL, sha256: String, size: Int) throws {
        guard SemanticVersionStatus(current: version, available: version) != .unknown,
              downloadURL == CatalogWebsites.url(host: "github.com", path: "/Homebrew/brew/releases/download/\(version)/Homebrew.pkg"),
              (1...Self.maximumDownloadBytes).contains(size)
        else { throw HomebrewSetupFailure.releaseMetadata }
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw HomebrewSetupFailure.digestInvalid }
        self.version = version
        self.downloadURL = downloadURL
        self.sha256 = sha256.lowercased()
        self.size = size
    }
}

enum CommandLineToolsState: Equatable, Sendable {
    case installed(developerDirectory: String)
    case notInstalled
}
