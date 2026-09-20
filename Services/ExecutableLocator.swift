import Foundation

struct ExecutableLocator: Sendable {
    func locate(_ name: String, path: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(filePath: String(directory), directoryHint: .isDirectory)
                .appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
