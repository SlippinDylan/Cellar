import Foundation

enum CatalogIcon: Hashable, Sendable {
    case placeholder
    case remote(URL)

    static func homebrew(_ package: HomebrewPackage) -> Self {
        guard package.identity.kind == .cask, package.tap == "homebrew/cask" else { return .placeholder }
        let name = package.identity.name
        let token = name.hasPrefix("homebrew/cask/") ? String(name.dropFirst("homebrew/cask/".count)) : name
        // Never strip an arbitrary tap prefix or infer identity from a display name.
        guard !token.isEmpty, token != ".", token != "..",
              token.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46, 64, 95].contains($0) }),
              let url = URL(string: "https://cdn.jsdelivr.net/gh/alielsokary/CaskFlow@icons/\(token).png")
        else { return .placeholder }
        return .remote(url)
    }
}
