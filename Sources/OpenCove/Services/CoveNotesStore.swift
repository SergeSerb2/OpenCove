import Darwin
import Foundation

/// A small scratchpad saved as plain text in the private data directory.
/// Saves happen shortly after typing stops, and again when the app stops.
@MainActor
final class CoveNotesStore: ObservableObject {
    static let characterLimit = 32_768
    private static let fileName = "notes.txt"

    @Published private(set) var text: String
    @Published private(set) var lastError: String?
    @Published private(set) var hasUnsavedChanges = false
    private var saveTask: Task<Void, Never>?

    private static var url: URL { CovePaths.dataDirectory.appendingPathComponent(fileName) }

    init() {
        text = Self.load()
    }

    func update(_ value: String) {
        let bounded = value.count > Self.characterLimit ? String(value.prefix(Self.characterLimit)) : value
        guard bounded != text else { return }
        text = bounded
        hasUnsavedChanges = true
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges else { return }
        do {
            let url = Self.url
            // Never write through a link that something else placed at this path.
            if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
               type != .typeRegular {
                throw CocoaError(.fileWriteNoPermission)
            }
            try Data(text.utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            hasUnsavedChanges = false
            lastError = nil
        } catch {
            lastError = "Notes could not be saved: \(error.localizedDescription)"
        }
    }

    private static func load() -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return "" }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= Int64(characterLimit * 4),
              let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(characterLimit))
    }
}
