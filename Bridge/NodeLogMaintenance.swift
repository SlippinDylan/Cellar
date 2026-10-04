import Foundation

struct NodeLogMaintenanceState: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let path: String
        let modified: Date
        let size: Int
        let inode: UInt64
    }
    let files: [File]
    // The cleanup operation creates its own newest log before retaining 100 files.
    var candidates: [String] { Array(files.dropFirst(99)).map(\.path) }

    static func read(managerDirectory: URL) throws -> Self {
        let directory = managerDirectory.appending(path: ".runtime/logs")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  directory.resolvingSymlinksInPath().path.hasPrefix(managerDirectory.resolvingSymlinksInPath().path + "/") else {
                throw BridgeError.managerFailure(code: "unsafe-log-directory", detail: nil)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .init(files: []) }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var files: [File] = []
        for file in entries where file.lastPathComponent.contains(".log.") {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            guard let modified = attributes[.modificationDate] as? Date, modified <= Date(),
                  let size = attributes[.size] as? Int, let inode = attributes[.systemFileNumber] as? UInt64 else {
                throw BridgeError.managerFailure(code: "log-state-unavailable", detail: nil)
            }
            files.append(.init(path: file.path, modified: modified, size: size, inode: inode))
        }
        files.sort { $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified }
        if files.count > 99, files[98].modified == files[99].modified {
            throw BridgeError.managerFailure(code: "log-order-ambiguous", detail: nil)
        }
        return .init(files: files)
    }
}
