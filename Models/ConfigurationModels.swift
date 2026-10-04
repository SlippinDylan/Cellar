import Foundation

struct NPMRegistryLayers: Sendable {
    let effective: String
    let user: String
    let project: String
    let global: String
}

enum SourceConfiguration {
    static func registryURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let components = URLComponents(string: value), components.query == nil, components.fragment == nil,
              let url = components.url, CatalogWebsites.origin(url) != nil else { return nil }
        return url
    }
    static func validScope(_ scope: String) -> Bool {
        scope.range(of: #"^@[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}

enum TerminalPluginSource {
    static func repository(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value), components.scheme == "https", components.host == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == components.path else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { return nil }
        let owner = String(parts[1])
        var repo = String(parts[2])
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        func validName(_ name: String) -> Bool {
            name != "." && name != ".." && name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
        }
        guard validName(owner), validName(repo) else { return nil }
        return CatalogWebsites.url(host: "github.com", path: "/\(owner)/\(repo)")
    }
}

struct ShellConfigurationPlan: Identifiable, Sendable {
    let id: UUID
    let plans: [ShellActionPlan]
    let originalContents: Data
    let expectedContents: [Data]
    var canExecute: Bool { !plans.isEmpty && plans.allSatisfy(\.canExecute) }
}

enum TerminalConfigurationSelection {
    static func hasChanges(plugins: Set<String>, theme: String, snapshot: ShellStatus) -> Bool {
        plugins != Set(snapshot.activePlugins) || theme != snapshot.currentTheme
    }
}

struct ShellConfigurationResult: Sendable {
    let operations: [ShellOperationResult]
    let failure: String?
    var wasCancelled = false
    var stepOutcomes: [ShellStepOutcome] = []
    var status: ActivityStatus {
        if !stepOutcomes.isEmpty {
            if stepOutcomes.allSatisfy({ $0.status == .succeeded }), failure == nil { return .succeeded }
            if stepOutcomes.contains(where: { [.succeeded, .partiallySucceeded].contains($0.status) }) { return .partiallySucceeded }
            return wasCancelled || stepOutcomes.allSatisfy({ $0.status == .cancelled }) ? .cancelled : .failed
        }
        if failure == nil { return .succeeded }
        if !operations.isEmpty { return .partiallySucceeded }
        return wasCancelled ? .cancelled : .failed
    }
}

extension NodeActionPlan {
    var blockingMessage: LocalizedStringResource {
        switch payload.blockedReason {
        case "nvm-unavailable": LocalizedStringResource("nvm is unavailable. Follow the official installation guide and refresh.")
        case "node-version-not-installed": LocalizedStringResource("This Node version is no longer installed. Refresh the environment.")
        case "default-node-unresolved": LocalizedStringResource("The nvm default cannot be resolved. Select an installed version or set a default.")
        case "cannot-uninstall-current-node": LocalizedStringResource("The current Cellar Node version cannot be removed.")
        case "cannot-uninstall-default-node": LocalizedStringResource("The nvm default Node version cannot be removed.")
        case "node-package-inventory-unavailable": LocalizedStringResource("The global packages in this Node installation could not be read. Nothing was removed.")
        case "project-path-not-directory": LocalizedStringResource("The selected project is no longer a directory. Choose the project again.")
        case "project-nvmrc-not-regular-file": LocalizedStringResource("The project .nvmrc must be a regular file. Symbolic links are not changed.")
        default: LocalizedStringResource("This action is blocked by the current environment. Refresh and review the protected target or file type.")
        }
    }
}

extension ShellActionPlan {
    var blockingMessage: LocalizedStringResource {
        switch payload.blockedReason {
        case "zshrc-is-symlink", "zshrc-not-regular-file": LocalizedStringResource("The shell configuration must be a regular .zshrc file. Symbolic links are not changed.")
        case "already-installed": LocalizedStringResource("Oh My Zsh is already installed.")
        case "target-path-exists", "plugin-destination-exists": LocalizedStringResource("The installation destination is already occupied. Existing files will not be replaced.")
        case "oh-my-zsh-not-installed": LocalizedStringResource("Install Oh My Zsh before adding a plugin.")
        case "theme-not-installed": LocalizedStringResource("This theme is no longer installed. Choose a local theme again.")
        default: LocalizedStringResource("This action is blocked by the current environment. Refresh and review the protected target or file type.")
        }
    }
}
