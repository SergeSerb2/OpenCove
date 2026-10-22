import Darwin
import Foundation

enum CovePaths {
    private static let directoryLock = NSLock()
    private static var pinnedDirectory: URL?

    static var isDevelopment: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true || ProcessInfo.processInfo.environment["OPENCOVE_DATA_DIR"] != nil
    }

    static var dataDirectoryConfigurationError: String? {
        guard let raw = ProcessInfo.processInfo.environment["OPENCOVE_DATA_DIR"] else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        return !raw.isEmpty && !raw.utf8.contains(0) && path.hasPrefix("/")
            ? nil : "OPENCOVE_DATA_DIR must be an absolute local directory path."
    }

    static var dataDirectory: URL {
        directoryLock.lock()
        let pinned = pinnedDirectory
        directoryLock.unlock()
        if let pinned { return pinned }
        if let path = ProcessInfo.processInfo.environment["OPENCOVE_DATA_DIR"], dataDirectoryConfigurationError == nil {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isDevelopment ? "OpenCove Development" : "OpenCove", isDirectory: true)
    }

    /// Resolve routing aliases once, before opening the instance lock or stores.
    /// All later callers share this target instead of resolving the environment
    /// path again after an intermediate symlink may have changed.
    static func pinDataDirectory(_ directory: URL) throws -> URL {
        directoryLock.lock()
        defer { directoryLock.unlock() }
        if let pinnedDirectory { return pinnedDirectory }
        try preparePrivateDirectory(directory)
        guard let physical = Darwin.realpath(directory.path, nil) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { Darwin.free(physical) }
        let pinned = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        try preparePrivateDirectory(pinned)
        pinnedDirectory = pinned
        return pinned
    }

    static func prepare() {
        // Startup's InstanceLock reports errors before constructing any stores.
        guard dataDirectoryConfigurationError == nil else { return }
        try? preparePrivateDirectory(dataDirectory)
    }

    /// Never follow a final-component symlink or change an existing directory's permissions.
    static func preparePrivateDirectory(_ directory: URL) throws {
        guard dataDirectoryConfigurationError == nil, directory.isFileURL, directory.path.hasPrefix("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // Inspect physical parents through directory handles. Foundation can
        // rewrite /private/tmp back to /tmp, whose lstat is a symlink on macOS.
        // The open directory, rather than a normalized display path, defines
        // the ancestry whose ownership and replacement permissions matter.
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var ancestor = Darwin.openat(descriptor, "..", flags)
        guard ancestor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(ancestor) }
        for _ in 0..<1_024 {
            var parent = stat()
            guard fstat(ancestor, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
                  parent.st_uid == geteuid() || parent.st_uid == 0,
                  parent.st_mode & 0o022 == 0 || parent.st_mode & S_ISVTX != 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let next = Darwin.openat(ancestor, "..", flags)
            guard next >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            var nextInfo = stat()
            guard fstat(next, &nextInfo) == 0 else {
                Darwin.close(next)
                throw CocoaError(.fileWriteNoPermission)
            }
            if nextInfo.st_dev == parent.st_dev && nextInfo.st_ino == parent.st_ino {
                Darwin.close(next)
                return
            }
            Darwin.close(ancestor)
            ancestor = next
        }
        throw CocoaError(.fileWriteNoPermission)
    }

    static func writePrivateControlDescriptor(_ data: Data, to url: URL) throws {
        try preparePrivateDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".control-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func readPrivateControlDescriptor(_ url: URL) -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 4_096 else { return nil }
        guard let data = try? file.read(upToCount: 4_097), data.count == info.st_size else { return nil }
        return data
    }
}
