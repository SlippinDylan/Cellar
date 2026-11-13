import CryptoKit
import Foundation

// Installed snapshots are data, never Ruby to evaluate or a reason to query the current recipe.
struct CaskInstalledMetadata {
    let artifacts: [HomebrewCaskArtifact]
    let fingerprint: String
    let installedToken: String

    static func read(package: HomebrewPackage, caskroom: URL, budget: CaskRemovalScanBudget) throws -> Self {
        try budget.check()
        let currentToken = package.identity.name.split(separator: "/").last.map(String.init) ?? ""
        let tokens = Array(Set([currentToken] + package.oldTokens)).sorted()
        guard package.identity.kind == .cask, package.isInstalled, tokens.count <= 128,
              tokens.allSatisfy(validToken), CaskRemovalFileSystem.isNormalized(caskroom.path) else {
            throw HomebrewClientError.stateChanged
        }
        let installation = try locate(tokens: tokens, caskroom: caskroom, budget: budget)
        let token = installation.token
        let root = caskroom.appending(path: token + "/.metadata")
        let selected = installation.snapshot
        let source = try BoundFile.read(selected.url, limit: 1_048_576, budget: budget)
        let receipt = try BoundFile.read(root.appending(path: "INSTALL_RECEIPT.json"), limit: 1_048_576, budget: budget)
        let config = try BoundFile.read(root.appending(path: "config.json"), limit: 65_536, budget: budget)
        let decoder = JSONDecoder()
        let tab = try decoder.decode(Receipt.self, from: receipt.data)
        _ = try decoder.decode(DynamicObject.self, from: config.data)
        let json = selected.url.pathExtension == "json" ? try decoder.decode(InstalledJSON.self, from: source.data) : nil
        let compact = try isCompactJSON(source, decoder: decoder)
        // Old API versions are platform defaults; the resolved receipt must agree with the installed directory.
        let version = compact ? json?.version ?? selected.version : selected.version
        guard package.installedVersions.contains(selected.version),
              tab.source?.version == nil || tab.source?.version == version else { throw HomebrewClientError.stateChanged }
        if let recordedToken = json?.token, recordedToken != token { throw HomebrewClientError.stateChanged }
        let qualified = package.identity.name.split(separator: "/")
        let targetTap = package.tap ?? (qualified.count == 3 ? qualified.prefix(2).joined(separator: "/") : nil)
        for tap in [tab.source?.tap, json?.tap].compactMap({ $0 }) where tap != targetTap {
            throw HomebrewClientError.stateChanged
        }
        let storedArtifacts: [DynamicObject]
        if compact, let artifacts = json?.artifacts { storedArtifacts = artifacts }
        else if let artifacts = tab.uninstallArtifacts { storedArtifacts = artifacts }
        else { throw HomebrewClientError.stateChanged }
        guard storedArtifacts.allSatisfy({ !$0.values.isEmpty }) else { throw HomebrewClientError.stateChanged }
        let artifacts = storedArtifacts.flatMap(\.artifacts)
        // A partially read installation cannot authorize the data selected earlier in this read.
        let reselected = try locate(tokens: tokens, caskroom: caskroom, budget: budget)
        guard reselected.token == token, reselected.snapshot.url.path == selected.url.path else {
            throw HomebrewClientError.stateChanged
        }
        var digest = SHA256()
        for file in [source, receipt, config] {
            try budget.check()
            guard try CaskRemovalFileSystem.fingerprint(file.url.path) == file.identity else { throw HomebrewClientError.stateChanged }
            // Boundaries include lengths because paths and JSON can contain arbitrary separator characters.
            for data in [Data(file.url.path.utf8), Data(file.identity.utf8), file.data] {
                digest.update(data: Data("\(data.count):".utf8))
                digest.update(data: data)
            }
        }
        return Self(artifacts: artifacts, fingerprint: digest.finalize().map { String(format: "%02x", $0) }.joined(), installedToken: token)
    }

    private static func validToken(_ token: String) -> Bool {
        token != "." && token != ".." && token.range(of: #"^[A-Za-z0-9][A-Za-z0-9@+._-]*$"#, options: .regularExpression) != nil
    }

    private static func isCompactJSON(_ source: BoundFile, decoder: JSONDecoder) throws -> Bool {
        guard source.url.pathExtension == "json" else { return false }
        let object = try decoder.decode(DynamicObject.self, from: source.data)
        // Homebrew's compact installed schema has exactly these optional keys, including an intentional empty object.
        return !source.url.lastPathComponent.hasSuffix(".internal.json")
            && Set(object.values.keys).isSubset(of: ["artifacts", "url_specs", "version"])
    }

    private static func locate(tokens: [String], caskroom: URL, budget: CaskRemovalScanBudget) throws
        -> (token: String, snapshot: (url: URL, version: String)) {
        var installations: [(token: String, snapshot: (url: URL, version: String))] = []
        for token in tokens {
            try budget.check()
            let root = caskroom.appending(path: token + "/.metadata")
            guard CaskRemovalFileSystem.exists(root.path) else { continue }
            installations.append((token, try snapshot(root: root, token: token, budget: budget)))
        }
        guard installations.count == 1, let installation = installations.first else { throw HomebrewClientError.stateChanged }
        return installation
    }

    private struct Receipt: Decodable {
        struct Source: Decodable {
            let version: String?
            let tap: String?
        }
        let source: Source?
        let uninstallArtifacts: [DynamicObject]?
        enum CodingKeys: String, CodingKey { case source; case uninstallArtifacts = "uninstall_artifacts" }
    }

    private struct InstalledJSON: Decodable {
        let artifacts: [DynamicObject]?
        let version: String?
        let token: String?
        let tap: String?
    }

    private struct BoundFile {
        let url: URL
        let identity: String
        let data: Data

        static func read(_ url: URL, limit: Int, budget: CaskRemovalScanBudget) throws -> Self {
            try budget.check()
            let identity = try CaskRemovalFileSystem.fingerprint(url.path)
            let data = try CaskRemovalFileSystem.readRegularFile(url.path, limit: limit, shouldContinue: budget.check)
            guard try CaskRemovalFileSystem.fingerprint(url.path) == identity else { throw HomebrewClientError.stateChanged }
            return Self(url: url, identity: identity, data: data)
        }
    }

    private static func snapshot(root: URL, token: String, budget: CaskRemovalScanBudget) throws -> (url: URL, version: String) {
        var timestamps: [URL] = []
        try CaskRemovalFileSystem.walk(root.path, budget: budget) { node, depth in
            if depth == 0 { return true }
            let url = URL(filePath: node.path)
            if url.lastPathComponent.hasPrefix(".") { return false }
            if node.isSymbolicLink { throw HomebrewClientError.stateChanged }
            if depth == 2 {
                timestamps.append(url)
                return false
            }
            return node.isDirectory
        }
        guard let latest = timestamps.map(\.lastPathComponent).max() else { throw HomebrewClientError.stateChanged }
        let selected = timestamps.filter { $0.lastPathComponent == latest }
        guard selected.count == 1, let directory = selected.first else { throw HomebrewClientError.stateChanged }
        for suffix in ["json", "internal.json", "rb"] {
            try budget.check()
            let url = directory.appending(path: "Casks/\(token).\(suffix)")
            if CaskRemovalFileSystem.exists(url.path) {
                return (url, directory.deletingLastPathComponent().lastPathComponent)
            }
        }
        throw HomebrewClientError.stateChanged
    }
}
