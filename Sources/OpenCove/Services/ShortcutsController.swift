import Foundation

/// Lists and runs the user's macOS Shortcuts through the system `shortcuts`
/// command. Listing needs no permission. A shortcut runs only from an explicit
/// tap on a pinned tile (or the development API), never automatically.
@MainActor
final class ShortcutsController: ObservableObject {
    struct Outcome: Equatable {
        let name: String
        let succeeded: Bool
        let date: Date
    }

    @Published private(set) var available: [String] = []
    @Published private(set) var isListing = false
    @Published private(set) var listError: String?
    @Published private(set) var running: Set<String> = []
    @Published private(set) var lastOutcome: Outcome?
    var onFinish: ((Outcome) -> Void)?

    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")
    private static let runLimit: TimeInterval = 120

    var isSupported: Bool { FileManager.default.isExecutableFile(atPath: Self.tool.path) }

    func refreshList() {
        guard !isListing else { return }
        guard isSupported else { listError = "Shortcuts is not available on this Mac."; return }
        isListing = true
        Task.detached(priority: .utility) {
            let result = Self.execute(["list"], timeout: 15)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isListing = false
                guard let result, result.status == 0, let text = String(data: result.output, encoding: .utf8) else {
                    self.listError = "Your shortcuts could not be listed."
                    return
                }
                self.listError = nil
                let names = text.split(whereSeparator: \.isNewline).map(String.init)
                    .filter { !$0.isEmpty && $0.count <= CovePreferences.shortcutNameLimit }
                self.available = Array(NSOrderedSet(array: names)) as? [String] ?? names
            }
        }
    }

    /// Runs a shortcut by name. Returns false if it is already running or the tool is missing.
    @discardableResult
    func run(_ name: String) -> Bool {
        guard isSupported, !name.isEmpty, !running.contains(name) else { return false }
        running.insert(name)
        Task.detached(priority: .userInitiated) {
            let result = Self.execute(["run", name], timeout: Self.runLimit)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.running.remove(name)
                let outcome = Outcome(name: name, succeeded: result?.status == 0, date: Date())
                self.lastOutcome = outcome
                self.onFinish?(outcome)
            }
        }
        return true
    }

    /// Runs the tool with no shell and no inherited standard input. Returns nil
    /// if it cannot start or exceeds the time limit (it is then terminated).
    nonisolated private static func execute(_ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Read while running so a large list cannot fill the pipe and block the tool.
        final class Box: @unchecked Sendable { var data = Data() }
        let output = Box()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "org.opencove.shortcuts.read").async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(262_144)
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 2)
        return (process.terminationStatus, output.data)
    }
}
