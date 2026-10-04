import Foundation

struct NPMRegistryClient: Sendable {
    let registryURL: URL
    private let http: CatalogHTTPClient

    init(registryURL: URL, http: CatalogHTTPClient = CatalogHTTPClient()) throws {
        guard CatalogWebsites.origin(registryURL) != nil, registryURL.query == nil, registryURL.fragment == nil else { throw CatalogSourceError.invalidURL }
        self.registryURL = registryURL.path.isEmpty ? registryURL.appending(path: "/") : registryURL
        self.http = http
    }

    func search(_ query: String, environment: NodeEnvironmentContext, limit: Int = 50) async throws -> [NPMCatalogResult] {
        try Task.checkCancellation()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        guard term.utf8.count <= 512, (1...100).contains(limit) else { throw CatalogSourceError.invalidQuery }
        var components = URLComponents(url: registryURL.appending(path: "-/v1/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "text", value: term), URLQueryItem(name: "size", value: String(limit)), URLQueryItem(name: "from", value: "0")]
        guard let url = components?.url else { throw CatalogSourceError.invalidURL }
        let response = try JSONDecoder().decode(NPMRegistrySearchResponse.self, from: await http.data(from: url))
        guard response.total >= 0 else { throw CatalogSourceError.invalidResponse }
        var names = Set<String>()
        return try response.objects.prefix(limit).compactMap { result in
            let package = result.package
            guard Self.validPackageName(package.name), !package.version.isEmpty, package.version.utf8.count <= 128 else { throw CatalogSourceError.invalidResponse }
            guard names.insert(package.name).inserted else { return nil }
            return NPMCatalogResult(identity: NPMPackageIdentity(name: package.name, environment: environment), version: package.version, description: package.description.map { String($0.prefix(1_000)) }, websiteURL: CatalogWebsites.safeWebsite(package.links?.homepage ?? package.links?.npm), registryURL: registryURL)
        }
    }

    static func validPackageName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 1_024 else { return false }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        // Registry search includes legacy names, which may contain uppercase letters.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func validPart(_ part: Substring) -> Bool {
            !part.isEmpty && part != "." && part != ".." && part.unicodeScalars.allSatisfy(allowed.contains)
        }
        if name.hasPrefix("@") { return parts.count == 2 && validPart(parts[0].dropFirst()) && validPart(parts[1]) }
        return parts.count == 1 && validPart(parts[0])
    }

    static func packageScope(_ specOrQuery: String) throws -> String? {
        let value = specOrQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("@") else { return nil }
        let scope = String(value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard scope.range(of: #"^@[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil else { throw CatalogSourceError.invalidQuery }
        return scope
    }
}

struct GitHubReleaseMetadata: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?
        let size: Int
        enum CodingKeys: String, CodingKey { case name, digest, size; case browserDownloadURL = "browser_download_url" }
    }
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey { case draft, prerelease, assets; case tagName = "tag_name"; case htmlURL = "html_url" }
}

struct HomebrewReleaseClient: Sendable {
    private let http: CatalogHTTPClient
    init(http: CatalogHTTPClient = CatalogHTTPClient()) { self.http = http }

    func latestVersion() async throws -> String { try await release().tagName }

    func installerMetadata() async throws -> HomebrewInstallerMetadata {
        let release = try await release()
        let assets = release.assets.filter { $0.name == "Homebrew.pkg" }
        guard assets.count == 1, let asset = assets.first else { throw HomebrewSetupFailure.releaseMetadata }
        guard let digest = asset.digest else { throw HomebrewSetupFailure.digestMissing }
        guard digest.hasPrefix("sha256:") else { throw HomebrewSetupFailure.digestInvalid }
        return try HomebrewInstallerMetadata(version: release.tagName, downloadURL: asset.browserDownloadURL, sha256: String(digest.dropFirst(7)), size: asset.size)
    }

    private func release() async throws -> GitHubReleaseMetadata {
        try await latestGitHubRelease(owner: "Homebrew", repository: "brew", http: http)
    }
}

private func latestGitHubRelease(owner: String, repository: String, http: CatalogHTTPClient) async throws -> GitHubReleaseMetadata {
    let url = CatalogWebsites.url(host: "api.github.com", path: "/repos/\(owner)/\(repository)/releases/latest")
    let release = try JSONDecoder().decode(GitHubReleaseMetadata.self, from: await http.data(from: url))
    let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
    guard !release.draft, !release.prerelease,
          SemanticVersionStatus(current: version, available: version) != .unknown,
          release.htmlURL == CatalogWebsites.url(host: "github.com", path: "/\(owner)/\(repository)/releases/tag/\(release.tagName)")
    else { throw CatalogSourceError.invalidResponse }
    return release
}

struct NodeVersionMetadataClient: Sendable {
    private let http: CatalogHTTPClient
    init(http: CatalogHTTPClient = CatalogHTTPClient()) { self.http = http }

    func load() async throws -> NodeOnlineVersions {
        async let node = state { try await latestNodeVersion() }
        async let npm = state { try await latestNPMVersion() }
        async let nvm = state { try await latestNVMVersion() }
        let result = try await NodeOnlineVersions(node: node, npm: npm, nvm: nvm)
        try Task.checkCancellation()
        return result
    }

    func latestNodeVersion() async throws -> String {
        struct Release: Decodable { let version: String; let files: [String] }
        let url = CatalogWebsites.url(host: "nodejs.org", path: "/dist/index.json")
        let releases = try JSONDecoder().decode([Release].self, from: await http.data(from: url))
        let versions = releases.filter { $0.files.contains("osx-arm64-tar") }.map { $0.version.hasPrefix("v") ? String($0.version.dropFirst()) : $0.version }
        guard let newest = versions.filter({ !$0.contains("-") && SemanticVersionStatus(current: $0, available: $0) != .unknown }).max(by: { SemanticVersionStatus(current: $0, available: $1) == .behind }) else { throw CatalogSourceError.invalidResponse }
        return newest
    }

    func latestNPMVersion() async throws -> String {
        struct Package: Decodable { let version: String }
        let package = try JSONDecoder().decode(Package.self, from: await http.data(from: CatalogWebsites.npmRegistry.appending(path: "npm/latest")))
        guard SemanticVersionStatus(current: package.version, available: package.version) != .unknown else { throw CatalogSourceError.invalidResponse }
        return package.version
    }

    func latestNVMVersion() async throws -> String {
        let tag = try await latestGitHubRelease(owner: "nvm-sh", repository: "nvm", http: http).tagName
        return String(tag.dropFirst(tag.hasPrefix("v") ? 1 : 0))
    }

    private func state(_ operation: @Sendable () async throws -> String) async throws -> OnlineVersionState {
        do { return .available(version: try await operation()) }
        catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            try Task.checkCancellation()
            return .unavailable(reason: String(describing: error))
        }
    }
}
