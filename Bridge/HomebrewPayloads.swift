import Foundation

struct BrewInfoEnvelope: Decodable {
    let formulae: [BrewFormulaPayload]
    let casks: [BrewCaskPayload]
}

struct BrewOutdatedEnvelope: Decodable {
    let formulae: [BrewOutdatedPayload]
    let casks: [BrewOutdatedPayload]

    var models: [HomebrewOutdatedPackage] {
        let formulas = formulae.compactMap { $0.model(kind: .formula) }
        let caskModels = casks.compactMap { $0.model(kind: .cask) }
        return (formulas + caskModels).sorted {
            if $0.identity.kind != $1.identity.kind {
                return $0.identity.kind.sortOrder < $1.identity.kind.sortOrder
            }
            return $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending
        }
    }
}

struct BrewOutdatedPayload: Decodable {
    let name: String?
    let fullName: String?
    let token: String?
    let installedVersions: [String]
    let currentVersion: String?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case token
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }

    func model(kind: HomebrewPackageKind) -> HomebrewOutdatedPackage? {
        guard let identifier = fullName ?? name ?? token else { return nil }
        return HomebrewOutdatedPackage(
            identity: HomebrewPackageIdentity(name: identifier, kind: kind),
            installedVersions: installedVersions,
            currentVersion: currentVersion
        )
    }
}

struct BrewFormulaPayload: Decodable {
    struct Versions: Decodable {
        let stable: String?
        let head: String?
    }

    struct Installed: Decodable {
        let version: String
    }

    let name: String
    let fullName: String
    let tap: String?
    let description: String?
    let homepage: String?
    let versions: Versions
    let installed: [Installed]
    let dependencies: [String]
    let pinned: Bool
    let deprecated: Bool
    let disabled: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case tap
        case description = "desc"
        case homepage
        case versions
        case installed
        case dependencies
        case pinned
        case deprecated
        case disabled
    }

    var model: HomebrewPackage {
        HomebrewPackage(
            identity: HomebrewPackageIdentity(name: fullName, kind: .formula),
            displayName: name,
            description: description,
            homepage: homepage,
            installedVersions: installed.map(\.version),
            currentVersion: versions.stable ?? versions.head,
            tap: tap,
            dependencies: dependencies,
            pinned: pinned,
            deprecated: deprecated,
            disabled: disabled,
            artifacts: []
        )
    }
}

struct BrewCaskPayload: Decodable {
    let token: String
    let fullToken: String
    let tap: String?
    let names: FlexibleStringList
    let description: String?
    let homepage: String?
    let version: String?
    let installed: FlexibleStringList?
    let outdated: Bool
    let artifacts: [DynamicObject]
    private let oldTokens: [String]?

    enum CodingKeys: String, CodingKey {
        case token
        case fullToken = "full_token"
        case tap
        case names = "name"
        case description = "desc"
        case homepage
        case version
        case installed
        case outdated
        case artifacts
        case oldTokens = "old_tokens"
    }

    var model: HomebrewPackage {
        let resolvedTap = tap ?? Self.tapName(from: fullToken, token: token)
        return HomebrewPackage(
            identity: HomebrewPackageIdentity(name: fullToken, kind: .cask),
            displayName: names.values.first ?? token,
            description: description,
            homepage: homepage,
            installedVersions: installed?.values ?? [],
            currentVersion: version,
            tap: resolvedTap,
            dependencies: [],
            pinned: false,
            deprecated: false,
            disabled: false,
            artifacts: artifacts.flatMap(\.artifacts),
            oldTokens: oldTokens ?? []
        )
    }

    private static func tapName(from fullToken: String, token: String) -> String? {
        guard fullToken != token else { return nil }
        let components = fullToken.split(separator: "/")
        guard components.count >= 3 else { return nil }
        return components.prefix(2).joined(separator: "/")
    }
}

struct BrewTapPayload: Decodable {
    let name: String
    let path: String
    let remote: String?
    let official: Bool
    let trusted: Bool
    let formulaNames: [String]
    let caskTokens: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case remote
        case official
        case trusted
        case formulaNames = "formula_names"
        case caskTokens = "cask_tokens"
    }

    var model: HomebrewTap {
        HomebrewTap(
            name: name,
            remote: remote,
            path: path,
            official: official,
            trusted: trusted,
            formulaNames: formulaNames,
            caskTokens: caskTokens
        )
    }
}

struct FlexibleStringList: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            values = []
        } else if let list = try? container.decode([String].self) {
            values = list
        } else {
            values = [try container.decode(String.self)]
        }
    }
}

struct DynamicObject: Decodable {
    let values: [String: DynamicValue]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        values = try container.allKeys.reduce(into: [:]) { result, key in
            result[key.stringValue] = try container.decode(DynamicValue.self, forKey: key)
        }
    }

    var artifacts: [HomebrewCaskArtifact] {
        values.flatMap { key, value -> [HomebrewCaskArtifact] in
            if key == "target", values["app"] != nil { return [] }
            if key == "app" {
                let unresolved = HomebrewCaskArtifact(kind: key, values: value.strings, category: .installed)
                guard case .array(let arguments) = value, (1...2).contains(arguments.count),
                      case .string(let source)? = arguments.first else { return [unresolved] }
                let target: String?
                if let rawTarget = values["target"] {
                    guard case .string(let resolved) = rawTarget else { return [unresolved] }
                    target = resolved
                } else if arguments.count == 2 {
                    guard case .object(let options) = arguments[1], options.keys.allSatisfy({ $0 == "target" }) else { return [unresolved] }
                    if let rawTarget = options["target"] {
                        guard case .string(let specified) = rawTarget else { return [unresolved] }
                        target = specified
                    } else { target = nil }
                } else { target = nil }
                return [HomebrewCaskArtifact(kind: key, values: value.strings, category: .installed,
                    application: .init(source: source, target: target))]
            }
            if key == "uninstall", case .array(let entries) = value {
                let deletes = entries.flatMap { entry -> [String] in
                    guard case .object(let object) = entry else { return [] }
                    return object["delete"]?.strings ?? []
                }
                return [HomebrewCaskArtifact(kind: key, values: value.strings, category: .installed,
                    uninstallDeletePaths: deletes)]
            }
            if key == "zap", case .array(let entries) = value {
                return entries.flatMap { entry -> [HomebrewCaskArtifact] in
                    guard case .object(let object) = entry else { return [] }
                    return object.map { zapKey, zapValue in
                        HomebrewCaskArtifact(kind: zapKey, values: zapValue.strings, category: .zap)
                    }
                }
            }
            return [HomebrewCaskArtifact(kind: key, values: value.strings, category: .installed)]
        }
    }
}

indirect enum DynamicValue: Decodable {
    case string(String)
    case array([DynamicValue])
    case object([String: DynamicValue])
    case scalar(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DynamicValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DynamicValue].self) {
            self = .object(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .scalar(String(value))
        } else if let value = try? container.decode(Double.self) {
            self = .scalar(String(value))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var strings: [String] {
        switch self {
        case .string(let value), .scalar(let value):
            [value]
        case .array(let values):
            values.flatMap(\.strings)
        case .object(let values):
            values.keys.sorted().flatMap { values[$0]?.strings ?? [] }
        case .null:
            []
        }
    }
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
