import Foundation

enum CatalogIcon: Hashable, Sendable {
    case placeholder
    case remote(URL)
    case localApp(candidates: [String], fallback: URL?)

    static func homebrew(_ package: HomebrewPackage, homeDirectory: URL = .homeDirectory) -> Self {
        guard package.identity.kind == .cask else { return .placeholder }
        let remoteURL = remoteIconURL(for: package)
        if package.isInstalled {
            let candidates = localApplicationCandidates(for: package, homeDirectory: homeDirectory)
            if !candidates.isEmpty {
                return .localApp(candidates: candidates, fallback: remoteURL)
            }
        }
        return remoteURL.map(Self.remote) ?? .placeholder
    }

    private static func remoteIconURL(for package: HomebrewPackage) -> URL? {
        guard package.tap == "homebrew/cask" else { return nil }
        let name = package.identity.name
        let token = name.hasPrefix("homebrew/cask/") ? String(name.dropFirst("homebrew/cask/".count)) : name
        // Never strip an arbitrary tap prefix or infer identity from a display name.
        guard !token.isEmpty, token != ".", token != "..",
              token.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46, 64, 95].contains($0) })
        else { return nil }
        return URL(string: "https://cdn.jsdelivr.net/gh/alielsokary/CaskFlow@icons/\(token).png")
    }

    private static func localApplicationCandidates(for package: HomebrewPackage, homeDirectory: URL) -> [String] {
        let systemApps = "/Applications"
        let userApps = homeDirectory.appending(path: "Applications").standardizedFileURL.path(percentEncoded: false)
        var paths: [String] = []
        var seen = Set<String>()

        func appendIfAllowed(_ rawPath: String) {
            guard !rawPath.contains("\0") else { return }
            let url = URL(filePath: rawPath).standardizedFileURL
            let name = url.lastPathComponent
            guard !url.pathComponents.contains(".."),
                  name.hasSuffix(".app"),
                  name.count > 4,
                  !name.hasPrefix(".")
            else { return }
            var path = url.path(percentEncoded: false)
            if path.hasSuffix("/") { path.removeLast() }
            let isInAllowedRoot = path.hasPrefix("\(systemApps)/") || path.hasPrefix("\(userApps)/")
            guard isInAllowedRoot, seen.insert(path).inserted else { return }
            paths.append(path)
        }

        for artifact in package.artifacts {
            guard let app = artifact.application else { continue }
            let raw = (app.target ?? app.source).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.contains("\0") else { continue }
            if raw.hasPrefix("/") {
                appendIfAllowed(raw)
            } else if raw.hasPrefix("~/") {
                let expanded = homeDirectory.appending(path: String(raw.dropFirst(2))).path(percentEncoded: false)
                appendIfAllowed(expanded)
            } else {
                let bundleName = URL(filePath: raw).lastPathComponent
                guard bundleName.hasSuffix(".app"), !bundleName.contains("/") else { continue }
                appendIfAllowed("\(systemApps)/\(bundleName)")
                appendIfAllowed("\(userApps)/\(bundleName)")
            }
        }
        return paths
    }
}
