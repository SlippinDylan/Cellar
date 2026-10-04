import Foundation

struct NodeEnvironmentResolver: Sendable {
    private let homeDirectory: URL

    init(homeDirectory: URL = .homeDirectory) {
        self.homeDirectory = homeDirectory
    }

    func environment(preferredNodeVersion: String? = nil) -> [String: String] {
        let nvmDirectory = homeDirectory.appending(path: ".nvm", directoryHint: .isDirectory)
        var searchPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        if let nodeBin = resolvedNodeBin(preferredVersion: preferredNodeVersion, in: nvmDirectory) {
            searchPaths.insert(nodeBin.path, at: 0)
        }

        return controlledEnvironment(searchPaths: searchPaths)
    }

    func environment(nodeExecutable: URL, npmExecutable: URL) -> [String: String] {
        var paths = [nodeExecutable.deletingLastPathComponent().path]
        let npmDirectory = npmExecutable.deletingLastPathComponent().path
        if npmDirectory != paths[0] { paths.append(npmDirectory) }
        paths.append(contentsOf: ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        return controlledEnvironment(searchPaths: paths)
    }

    private func controlledEnvironment(searchPaths: [String]) -> [String: String] {
        let nvmDirectory = homeDirectory.appending(path: ".nvm", directoryHint: .isDirectory)
        let userName = NSUserName()
        var values = [
            "HOME": homeDirectory.path,
            "PATH": searchPaths.joined(separator: ":"),
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "NVM_DIR": nvmDirectory.path,
            "NODE_MANAGER_ALLOW_JSON_EXECUTE": "0"
        ]
        if !userName.isEmpty {
            values["USER"] = userName
            values["LOGNAME"] = userName
        }
        return values
    }

    func installations(preferredNodeVersion: String? = nil) -> [NodeInstallation] {
        let nvmDirectory = homeDirectory.appending(path: ".nvm", directoryHint: .isDirectory)
        let defaultDirectory = resolvedDefaultNodeBin(in: nvmDirectory)?.deletingLastPathComponent()
        return installedNodes(in: nvmDirectory).map { item in
            NodeInstallation(
                version: item.name,
                directory: item.url.path,
                isActive: item.name == preferredNodeVersion
                    || (preferredNodeVersion == nil && item.url == defaultDirectory),
                isDefault: item.url == defaultDirectory
            )
        }
    }

    func resolvedDefaultNodeBin(in nvmDirectory: URL) -> URL? {
        let installed = installedNodes(in: nvmDirectory)

        guard !installed.isEmpty else { return nil }
        let aliasRoot = nvmDirectory.appending(path: "alias", directoryHint: .isDirectory)
        guard let alias = resolveAlias("default", aliasRoot: aliasRoot) else { return nil }
        let match = installed.first { candidate in
            candidate.version.matches(alias)
        }
        return match?.url.appending(path: "bin", directoryHint: .isDirectory)
    }

    private func resolvedNodeBin(preferredVersion: String?, in nvmDirectory: URL) -> URL? {
        if let preferredVersion,
           let match = installedNodes(in: nvmDirectory).first(where: { $0.name == preferredVersion }) {
            return match.url.appending(path: "bin", directoryHint: .isDirectory)
        }
        return resolvedDefaultNodeBin(in: nvmDirectory)
    }

    private func installedNodes(in nvmDirectory: URL) -> [(name: String, version: SemanticVersion, url: URL)] {
        let versionsDirectory = nvmDirectory.appending(path: "versions/node", directoryHint: .isDirectory)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return versions.compactMap { url in
            guard let version = SemanticVersion(url.lastPathComponent),
                  FileManager.default.isExecutableFile(atPath: url.appending(path: "bin/node").path)
            else { return nil }
            return (url.lastPathComponent, version, url)
        }.sorted { $0.version > $1.version }
    }

    private func resolveAlias(_ name: String, aliasRoot: URL, visited: Set<String> = []) -> String? {
        guard !visited.contains(name) else { return nil }
        let aliasURL = aliasRoot.appending(path: name)
        guard aliasURL.standardizedFileURL.path.hasPrefix(aliasRoot.standardizedFileURL.path + "/"),
              let snapshot = try? NodeConfigurationFile.read(at: aliasURL, maximumBytes: 4096),
              let rawValue = String(data: snapshot.contents, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first
        else { return name == "default" ? nil : name }

        let value = String(rawValue)
        if SemanticVersion.isVersionPrefix(value) || value == "node" || value == "stable" {
            return value
        }
        var nextVisited = visited
        nextVisited.insert(name)
        return resolveAlias(value, aliasRoot: aliasRoot, visited: nextVisited)
    }
}

struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let pieces = value.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
        guard pieces.count == 3,
              let major = Int(pieces[0]),
              let minor = Int(pieces[1]),
              let patch = Int(pieces[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    static func isVersionPrefix(_ value: String) -> Bool {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let pieces = normalized.split(separator: ".")
        return (1...3).contains(pieces.count) && pieces.allSatisfy { Int($0) != nil }
    }

    func matches(_ alias: String) -> Bool {
        if alias == "node" || alias == "stable" { return true }
        let normalized = alias.hasPrefix("v") ? String(alias.dropFirst()) : alias
        let wanted = normalized.split(separator: ".").compactMap { Int($0) }
        let actual = [major, minor, patch]
        return !wanted.isEmpty && zip(wanted, actual).allSatisfy(==)
    }
}
