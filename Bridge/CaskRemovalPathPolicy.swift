import Darwin
import Foundation

// Exact metadata paths only. Neither glob expansion nor parent/vendor cleanup belongs here.
enum CaskRemovalPathPolicy {
    struct RelatedPath {
        let path: String
        let category: CaskRemovalCategory
        let isSharedContainer: Bool
    }

    struct OwnershipClaim {
        let components: [String]

        func protects(_ path: String) -> Bool {
            let candidate = path.split(separator: "/").map { String($0).lowercased().precomposedStringWithCanonicalMapping }
            for (pattern, component) in zip(components, candidate) {
                if pattern == "**" { return true }
                guard fnmatch(pattern, component, FNM_NOESCAPE) == 0 else { return false }
            }
            return true // An ancestor or descendant claim overlaps the candidate's subtree.
        }
    }

    static func ownershipClaim(_ value: String, home: URL) -> OwnershipClaim? {
        let path = value.hasPrefix("~/") ? home.path + "/" + String(value.dropFirst(2)) : value
        let library = home.appending(path: "Library").path.lowercased().precomposedStringWithCanonicalMapping
        let folded = path.lowercased().precomposedStringWithCanonicalMapping
        guard CaskRemovalFileSystem.isNormalized(path), folded == library || folded.hasPrefix(library + "/") else { return nil }
        let components = folded.split(separator: "/").map { value -> String in
            let component = String(value)
            // Ruby glob braces are not expanded: a static component prefix limits conservative protection.
            if let brace = component.firstIndex(where: { $0 == "{" || $0 == "}" }) { return String(component[..<brace]) + "*" }
            return component
        }
        return OwnershipClaim(components: components)
    }

    static func relatedPath(_ value: String, home: URL) -> RelatedPath? {
        guard !value.contains(where: { "*?[]{}".contains($0) }) else { return nil }
        let path = value.hasPrefix("~/") ? home.path + "/" + value.dropFirst(2) : value
        guard CaskRemovalFileSystem.isNormalized(path),
              path.hasPrefix(home.appending(path: "Library").path + "/") else { return nil }
        let relative = String(path.dropFirst(home.appending(path: "Library").path.count + 1))
        let components = relative.split(separator: "/")
        guard components.count >= 2, components.count <= 8 else { return nil }
        let root = String(components[0])
        let caches: Set<String> = ["Caches", "Logs", "HTTPStorages", "WebKit"]
        let data: Set<String> = ["Application Support", "Preferences", "Containers", "Application Scripts",
                                 "Saved Application State", "Cookies", "LaunchAgents", "Group Containers"]
        guard caches.contains(root) || data.contains(root),
              !(root == "Caches" && components[1].lowercased().precomposedStringWithCanonicalMapping == "homebrew") else { return nil }
        return RelatedPath(path: path, category: caches.contains(root) ? .cache : .applicationData,
                           isSharedContainer: root == "Group Containers")
    }

    static func overlaps(_ first: String, _ second: String) -> Bool {
        // Conservatively protect case variants even on a case-sensitive volume.
        let a = comparisonKey(first)
        let b = comparisonKey(second)
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    static func comparisonKey(_ path: String) -> String {
        path.lowercased().precomposedStringWithCanonicalMapping
    }
}
