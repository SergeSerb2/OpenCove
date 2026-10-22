import Darwin
import Foundation

/// One process per private data directory. The lock inode stays in place on exit.
final class InstanceLock {
    private var descriptor: Int32 = -1

    init(directory: URL) throws {
        let pinned = try CovePaths.pinDataDirectory(directory)
        let opened = Darwin.open(pinned.appendingPathComponent("instance.lock").path,
                                 O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard opened >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            Darwin.close(opened)
            throw CocoaError(.fileWriteNoPermission)
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(opened)
            throw CocoaError(.fileLocking)
        }
        descriptor = opened
    }

    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor) } }
}
