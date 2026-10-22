// MIT. Independent, optional MediaRemote adapter for OpenCove.
// /usr/bin/swift requires installed Xcode or Command Line Tools.
// No Apple Events, app launch, identity changes, or permission requests.
@preconcurrency import Foundation
@preconcurrency import ObjectiveC
import Darwin

private let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)
@Sendable private func symbol<T>(_ name: String, _ type: T.Type) -> T? {
    guard let framework, let address = dlsym(framework, name) else { return nil }
    return unsafeBitCast(address, to: type)
}
@Sendable private func object(_ receiver: AnyObject, _ name: String) -> AnyObject? {
    let selector = NSSelectorFromString(name)
    guard let cls = object_getClass(receiver), let method = class_getInstanceMethod(cls, selector),
          method_getNumberOfArguments(method) == 2 else { return nil }
    let result = method_copyReturnType(method)
    defer { free(result) }
    guard isObjectEncoding(result) else { return nil }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    return unsafeBitCast(method_getImplementation(method), to: Getter.self)(receiver, selector)?.takeUnretainedValue()
}
@Sendable private func isObjectEncoding(_ encoding: UnsafePointer<CChar>) -> Bool {
    let value = String(cString: encoding)
    return value == "@" || (value.hasPrefix("@\"") && value.hasSuffix("\""))
}

private let arguments = Array(CommandLine.arguments.dropFirst())
private let action = arguments.first ?? "--read"
private let watching = action == "--watch"
private var previousFrame: Data?
private var lastEmission = -Double.greatestFiniteMagnitude
@Sendable private func emit(_ payload: [String: Any]) {
    // One bounded JSON line carries a binary plist, preserving real Date/Data/NSNumber.
    guard PropertyListSerialization.propertyList(payload, isValidFor: .binary),
          let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0),
          data.count <= 16 * 1024 * 1024 else { exit(1) }
    if watching, previousFrame == data, ProcessInfo.processInfo.systemUptime - lastEmission < 15 { return }
    previousFrame = data
    lastEmission = ProcessInfo.processInfo.systemUptime
    guard var line = try? JSONSerialization.data(withJSONObject: ["snapshot": data.base64EncodedString()]),
          line.count <= 23 * 1024 * 1024 else { exit(1) }
    line.append(10)
    FileHandle.standardOutput.write(line)
}
@Sendable private func fail(_ message: String) -> Never { emit(["error": message]); exit(1) }
private let allowed = ["--read", "--watch", "--toggle", "--next", "--previous", "--seek"]
guard allowed.contains(action), arguments.count <= 6 else { fail("Unsupported media adapter action.") }
private var expectedBundle: String?
private var expectedItem: String?
private var position: Double?
if action == "--seek" {
    guard arguments.count == 6, arguments[2] == "--source", arguments[4] == "--item",
          let value = Double(arguments[1]), value.isFinite, value >= 0,
          !arguments[3].isEmpty, itemID(arguments[5]) != nil else {
        fail("A finite seek time, source, and item identifier are required.")
    }
    position = value
    expectedBundle = arguments[3]
    expectedItem = arguments[5]
} else if action != "--read" && !watching {
    guard arguments.count == 3, arguments[1] == "--source" else { fail("A media source is required.") }
    expectedBundle = arguments[2]
} else if arguments.count > 1 { fail("The metadata reader takes no extra arguments.") }

@Sendable private func currentBundle() -> String? {
    guard let cls = NSClassFromString("MRNowPlayingRequest"),
          let path = object(cls, "localNowPlayingPlayerPath"), let client = object(path, "client") else { return nil }
    return object(client, "bundleIdentifier") as? String
}
@Sendable private func commands() -> [[String: Any]] {
    guard let cls = NSClassFromString("MRNowPlayingRequest"),
          let values = object(cls, "localSupportedCommands") as? [AnyObject] else { return [] }
    return values.compactMap { object($0, "dictionaryRepresentation") as? [String: Any] }
}
@Sendable private func enabled(_ name: String, in values: [[String: Any]]) -> Bool {
    values.contains { value in
        guard value["command"] as? String == name else { return false }
        return (value["enabled"] as? NSNumber)?.boolValue ?? ((value["enabled"] as? String)?.uppercased() == "YES")
    }
}
@Sendable private func itemID(_ value: Any?) -> String? {
    guard let value = value as? String, value.utf8.count <= 8_192,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
}
@Sendable private func itemID(in info: [String: Any]) -> String? {
    itemID(info["kMRMediaRemoteNowPlayingInfoContentItemIdentifier"])
}
/// Seek validation needs an immediate reader. A stale async callback or a title,
/// artist, duration, or source match cannot identify the current item safely.
@Sendable private func currentItemInfo(for bundle: String) -> [String: Any]? {
    guard currentBundle() == bundle, let cls = NSClassFromString("MRNowPlayingRequest"),
          let item = object(cls, "localNowPlayingItem"),
          let info = object(item, "nowPlayingInfo") as? [String: Any],
          itemID(in: info) != nil, currentBundle() == bundle else { return nil }
    return info
}
@Sendable private func complete(_ info: [String: Any]?, bundle: String?, error: String? = nil) {
    // Reject metadata if the active source changed while the read was in flight.
    guard currentBundle() == bundle else { emit(["error": "The active source changed during the metadata read."]); return }
    let supported = commands()
    if action == "--read" || watching {
        var payload: [String: Any] = ["version": 1, "commands": supported]
        if let bundle { payload["bundleID"] = bundle }
        if let bundle, let info, let identity = itemID(in: info),
           let current = currentItemInfo(for: bundle), itemID(in: current) == identity {
            payload["canValidateSeekItem"] = true
        } else { payload["canValidateSeekItem"] = false }
        if let info, !info.isEmpty { payload["info"] = info }
        else { payload["error"] = error ?? "MediaRemote returned no metadata for this process." }
        emit(payload)
        return
    }
    guard let bundle, bundle == expectedBundle, let info, !info.isEmpty else { fail("The selected media source is no longer active.") }
    if action == "--seek" {
        typealias Seek = @convention(c) (Double) -> Void
        guard enabled("SeekToPlaybackPosition", in: supported),
              let seek = symbol("MRMediaRemoteSetElapsedTime", Seek.self), let position else {
            fail("This source does not support seeking.")
        }
        guard let expectedItem, itemID(in: info) == expectedItem else {
            fail("The current item changed or cannot be identified.")
        }
        // Re-read inside this process after interpreter startup and capability
        // discovery, immediately before the write. Never seek from cached info.
        guard let current = currentItemInfo(for: bundle), itemID(in: current) == expectedItem,
              let duration = (current["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue,
              duration.isFinite, duration > 0, currentBundle() == bundle else {
            fail("The current item changed or cannot be identified.")
        }
        seek(min(position, duration))
        emit(["submitted": true]) // No acknowledgement API; caller refreshes actual state.
        return
    }
    let name: String, opcode: Int32
    switch action {
    case "--toggle": name = "TogglePlayPause"; opcode = 2
    case "--next": name = "NextTrack"; opcode = 4
    case "--previous": name = "PreviousTrack"; opcode = 5
    default: fail("Unsupported media command.")
    }
    typealias Send = @convention(c) (Int32, CFDictionary?) -> Bool
    guard enabled(name, in: supported), let send = symbol("MRMediaRemoteSendCommand", Send.self),
          currentBundle() == bundle else { fail("This source does not enable that media command.") }
    guard send(opcode, nil) else { fail("MediaRemote rejected the media command.") }
    emit(["submitted": true])
}

private var reading = false
private var requestID = UUID()
private var lastRead = -Double.greatestFiniteMagnitude
private var hasMetadata = false
private var artworkKey: String?
private var artworkData: Data?
private var artworkAttempt = -Double.greatestFiniteMagnitude
// The adapter's state and OS reply delivery are confined to the main queue.
// A bounded request lifetime avoids a request -> completion -> request cycle.
private var activeArtworkRequest: NSObject?
private func read() {
    guard !reading else { return }
    guard framework != nil, let cls = NSClassFromString("MRNowPlayingRequest") else { fail("MediaRemote is not available on this macOS version.") }
    reading = true
    lastRead = ProcessInfo.processInfo.systemUptime
    let token = UUID()
    requestID = token
    let bundle = currentBundle()
    var finishing = false
    func finish(_ info: [String: Any]?, _ error: String? = nil) {
        guard requestID == token, reading, !finishing else { return }
        finishing = true
        var delivered = false
        func deliver(_ value: [String: Any]?) {
            guard requestID == token, reading, !delivered else { return }
            delivered = true
            activeArtworkRequest = nil
            reading = false
            hasMetadata = value?.isEmpty == false
            complete(value, bundle: bundle, error: error)
            if !watching { exit(0) }
        }
        guard action == "--read" || watching, let bundle, let info,
              info["kMRMediaRemoteNowPlayingInfoArtworkData"] == nil,
              let item = itemID(in: info), currentBundle() == bundle else { deliver(info); return }
        let identifier = info["kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] as? String ?? ""
        let key = bundle + "\n" + item + "\n" + identifier
        if key == artworkKey, artworkData != nil || ProcessInfo.processInfo.systemUptime - artworkAttempt < 15 {
            var value = info
            value["kMRMediaRemoteNowPlayingInfoArtworkData"] = artworkData
            deliver(value)
            return
        }
        let selector = NSSelectorFromString("requestNowPlayingItemArtworkOnQueue:completion:")
        guard let type = cls as? NSObject.Type, let method = class_getInstanceMethod(cls, selector),
              method_getNumberOfArguments(method) == 4 else { deliver(info); return }
        let result = method_copyReturnType(method)
        let queue = method_copyArgumentType(method, 2), block = method_copyArgumentType(method, 3)
        defer { free(result); free(queue); free(block) }
        guard result.pointee == 118, let queue, isObjectEncoding(queue), let block,
              String(cString: block) == "@?" else { deliver(info); return }
        artworkKey = key
        artworkData = nil
        artworkAttempt = ProcessInfo.processInfo.systemUptime
        // The OS supplies MRArtwork and NSError. The request is read-only and
        // never changes the active player. Retain it through its callback.
        typealias Request = @convention(c) (AnyObject, Selector, DispatchQueue, @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) -> Void
        let request = type.init()
        activeArtworkRequest = request
        unsafeBitCast(method_getImplementation(method), to: Request.self)(request, selector, .main) { artwork, failure in
            DispatchQueue.main.async {
                withExtendedLifetime(activeArtworkRequest) {
                    guard requestID == token, reading, !delivered else { return }
                    var value = info
                    // A late image belongs only to this exact source, item,
                    // and artwork version. Never attach it to a newer track.
                    if failure == nil, let artwork, let data = object(artwork, "imageData") as? Data,
                       !data.isEmpty, data.count <= 12 * 1024 * 1024,
                       let current = currentItemInfo(for: bundle), itemID(in: current) == item,
                       (current["kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] as? String ?? "") == identifier {
                        artworkData = data
                        value["kMRMediaRemoteNowPlayingInfoArtworkData"] = data
                    }
                    deliver(value)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { deliver(info) }
    }
    if let item = object(cls, "localNowPlayingItem"), let info = object(item, "nowPlayingInfo") as? [String: Any], !info.isEmpty {
        finish(info)
        return
    }
    let selector = NSSelectorFromString("requestNowPlayingInfoOnQueue:completion:")
    if let type = cls as? NSObject.Type, let method = class_getInstanceMethod(cls, selector), method_getNumberOfArguments(method) == 4 {
        let result = method_copyReturnType(method)
        let queue = method_copyArgumentType(method, 2), block = method_copyArgumentType(method, 3)
        defer { free(result); free(queue); free(block) }
        guard result.pointee == 118, let queue, isObjectEncoding(queue),
              let block, String(cString: block) == "@?" else { finish(nil, "The metadata request ABI is unavailable."); return }
        typealias Request = @convention(c) (AnyObject, Selector, DispatchQueue, @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) -> Void
        let request = type.init()
        unsafeBitCast(method_getImplementation(method), to: Request.self)(request, selector, .main) { info, error in
            DispatchQueue.main.async {
                withExtendedLifetime(request) { finish(info as? [String: Any], (error as? NSError)?.localizedDescription) }
            }
        }
    } else {
        typealias Read = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
        guard let get = symbol("MRMediaRemoteGetNowPlayingInfo", Read.self) else { finish(nil); return }
        get(.main) { info in DispatchQueue.main.async { finish(info as? [String: Any]) } }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil, "MediaRemote metadata request timed out.") }
}

if watching {
    // Reuse one interpreter. Parent loss and a 10-minute lease bound its lifetime.
    let parent = getppid(), started = ProcessInfo.processInfo.systemUptime
    typealias Register = @convention(c) (DispatchQueue) -> Void
    if let register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", Register.self) { register(.main) }
    var observations: [NSObjectProtocol] = []
    for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification", "kMRMediaRemoteNowPlayingApplicationDidChangeNotification", "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"] {
        let actual: String
        if let framework, let address = dlsym(framework, name), let value = address.assumingMemoryBound(to: NSString?.self).pointee { actual = value as String }
        else { actual = name }
        observations.append(NotificationCenter.default.addObserver(forName: .init(actual), object: nil, queue: .main) { _ in
            if ProcessInfo.processInfo.systemUptime - lastRead >= 0.25 { read() }
        })
    }
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        guard getppid() == parent, ProcessInfo.processInfo.systemUptime - started < 600 else { exit(0) }
        if ProcessInfo.processInfo.systemUptime - lastRead >= (hasMetadata ? 4 : 15) { read() }
    }
    RunLoop.main.add(timer, forMode: .common)
    read()
    RunLoop.main.run()
} else {
    read()
    RunLoop.main.run()
}
