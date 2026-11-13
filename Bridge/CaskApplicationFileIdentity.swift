import Darwin
import Foundation

// Read-only application matching is separate from the stricter no-follow deletion boundary.
// A parent inode plus an exact name identifies the same location even after brew removes the bundle.
enum CaskApplicationFileIdentity {
    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
    }

    static func sameLocation(_ expected: URL, _ observed: URL) throws -> Bool {
        let expectedName = expected.lastPathComponent
        let observedName = observed.lastPathComponent
        guard expectedName.caseInsensitiveCompare(observedName) == .orderedSame else { return false }
        guard try directoryIdentity(expected.deletingLastPathComponent())
                == directoryIdentity(observed.deletingLastPathComponent()) else { return false }
        if expectedName == observedName { return true }
        // Case folding must not conflate separate names on a case-sensitive volume.
        return try directoryIdentity(expected) == directoryIdentity(observed)
    }

    private static func directoryIdentity(_ url: URL) throws -> DirectoryIdentity {
        try Task.checkCancellation()
        // Ancestor aliases may resolve for read-only matching; the final directory must itself be real.
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var value = stat()
        var volume = statfs()
        guard fstat(descriptor, &value) == 0, fstatfs(descriptor, &volume) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw POSIXError(.EXDEV) }
        return DirectoryIdentity(device: value.st_dev, inode: value.st_ino,
                                 birthSeconds: value.st_birthtimespec.tv_sec,
                                 birthNanoseconds: value.st_birthtimespec.tv_nsec)
    }
}
