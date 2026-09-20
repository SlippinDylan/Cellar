import Foundation

struct ShellEnvironmentResolver: Sendable {
    private let homeDirectory: URL
    private let temporaryDirectory: URL

    init(
        homeDirectory: URL = .homeDirectory,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
    }

    func environment() -> [String: String] {
        let userName = NSUserName()
        var environment = [
            "HOME": homeDirectory.path,
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporaryDirectory.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "SHELL_MANAGER_ALLOW_JSON_EXECUTE": "0"
        ]
        if !userName.isEmpty {
            environment["USER"] = userName
            environment["LOGNAME"] = userName
        }
        return environment
    }
}
