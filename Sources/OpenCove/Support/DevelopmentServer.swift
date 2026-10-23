import AppKit
import Combine
import CoreFoundation
import Network
import SwiftUI

/// Opt-in, loopback-only controls. Never started by a normal app launch.
@MainActor
final class DevelopmentServer {
    private let store: CoveStore
    private weak var updater: CoveUpdater?
    private weak var notch: NotchPanelController?
    private let port: UInt16
    private let token = UUID().uuidString + UUID().uuidString
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "org.opencove.development-http")
    private static let headerLimit = 16_384
    private static let bodyLimit = 65_536
    private var connections: [ObjectIdentifier: Client] = [:]
    private var rendererBusy = false
    private var timerPublications: UInt64 = 0
    private var timerObservation: AnyCancellable?
    private let startedAt = ISO8601DateFormatter().string(from: Date())
    private let bundlePath = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
    private let sourceTree = Bundle.main.object(forInfoDictionaryKey: "OpenCoveSourceTreeSHA256") as? String ?? ""

    private final class Client {
        var buffer = Data()
        var request: RequestHead?
        var bodyOffset = 0
        var responding = false
        var timeout: Task<Void, Never>?
        var renderTask: Task<Void, Never>?
    }

    private struct RequestHead {
        let method: String
        let target: String
        let headers: [String: String]
        let contentLength: Int
    }

    private let descriptorURL = CovePaths.dataDirectory.appendingPathComponent("control.json")

    init(store: CoveStore, port: UInt16, updater: CoveUpdater? = nil, notch: NotchPanelController? = nil) {
        self.store = store
        self.updater = updater
        self.notch = notch
        self.port = port
        // Only explicitly enabled development controls observe this count.
        timerObservation = store.activities.$timer.dropFirst().sink { [weak self] _ in
            self?.timerPublications &+= 1
        }
    }

    func start() throws {
        guard listener == nil else { throw ControlError.invalid("Controls are already running.") }
        let arguments = ProcessInfo.processInfo.arguments
        guard port > 0, let index = arguments.firstIndex(of: "--control-port"),
              arguments.indices.contains(index + 1), UInt16(arguments[index + 1]) == port else {
            throw ControlError.invalid("Controls require an explicit --control-port from 1 to 65535.")
        }
        try CovePaths.preparePrivateDirectory(CovePaths.dataDirectory)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let server = try NWListener(using: parameters)
        server.newConnectionHandler = { [weak self, weak server] connection in
            Task { @MainActor in
                guard let self, let server, self.listener === server, self.connections.count < 32 else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        server.stateUpdateHandler = { [weak self, weak server] state in
            Task { @MainActor in
                guard let self, let server, self.listener === server else { return }
                switch state {
                case .ready:
                    do { try self.publishDescriptor() }
                    catch {
                        self.reportFailure(error)
                    }
                case .failed(let error):
                    self.reportFailure(error)
                default: break
                }
            }
        }
        listener = server
        server.start(queue: queue)
    }

    private func publishDescriptor() throws {
        let descriptor: [String: Any] = ["port": port, "token": token, "pid": ProcessInfo.processInfo.processIdentifier]
        let data = try JSONSerialization.data(withJSONObject: descriptor, options: .prettyPrinted)
        try CovePaths.writePrivateControlDescriptor(data, to: descriptorURL)
    }

    func reportFailure(_ error: Error) {
        // NWError's NSError bridge can lose its POSIX detail. Report the typed
        // network reason, never the descriptor, token or authenticated URL.
        let detail = (error as? NWError).map { String(describing: $0) } ?? error.localizedDescription
        let message = "Development controls are unavailable: \(detail)\nCheck --control-port and the private data directory, then restart OpenCove."
        store.lastError = message
        fputs("OpenCove: \(message)\n", stderr)
        stop()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { close(id) }
        if let data = CovePaths.readPrivateControlDescriptor(descriptorURL),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           value["token"] as? String == token {
            try? FileManager.default.removeItem(at: descriptorURL)
        }
    }

    private var liveConnections: [ObjectIdentifier: NWConnection] = [:]

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let client = Client()
        connections[id] = client
        liveConnections[id] = connection
        // One absolute deadline covers reads AND response writes. Slow drips cannot extend it.
        client.timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.close(id)
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.close(id) } }
            if case .cancelled = state { Task { @MainActor in self?.close(id) } }
        }
        connection.start(queue: queue)
        read(connection)
    }

    private func close(_ id: ObjectIdentifier) {
        let client = connections.removeValue(forKey: id)
        client?.timeout?.cancel()
        client?.renderTask?.cancel()
        liveConnections.removeValue(forKey: id)?.cancel()
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let client = self.connections[ObjectIdentifier(connection)], !client.responding else { return }
                if let data { client.buffer.append(data) }
                if client.request == nil {
                    guard let separator = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
                        if client.buffer.count > Self.headerLimit { self.fail(connection, 431, "Request headers are too large.") }
                        else if complete || error != nil { self.fail(connection, 400, "Incomplete request headers.") }
                        else { self.read(connection) }
                        return
                    }
                    guard separator.upperBound <= Self.headerLimit else { self.fail(connection, 431, "Request headers are too large."); return }
                    do {
                        let head = try self.parseHead(Data(client.buffer[..<separator.lowerBound]))
                        client.request = head
                        client.bodyOffset = separator.upperBound
                        if let failure = self.accessFailure(head) { self.fail(connection, failure.0, failure.1); return }
                    } catch let failure as HTTPFailure { self.fail(connection, failure.status, failure.message); return }
                    catch { self.fail(connection, 400, "Invalid request headers."); return }
                }
                guard let head = client.request else { return }
                let bodyCount = client.buffer.count - client.bodyOffset
                guard bodyCount <= head.contentLength else { self.fail(connection, 400, "Extra request bytes and pipelining are not supported."); return }
                if bodyCount < head.contentLength {
                    if complete || error != nil { self.fail(connection, 400, "Incomplete request body.") }
                    else { self.read(connection) }
                    return
                }
                self.route(connection, head: head, body: Data(client.buffer[client.bodyOffset...]))
            }
        }
    }

    private struct HTTPFailure: Error { let status: Int; let message: String }

    private func parseHead(_ data: Data) throws -> RequestHead {
        func reject(_ status: Int = 400, _ message: String = "Invalid HTTP request.") throws -> Never {
            throw HTTPFailure(status: status, message: message)
        }
        guard data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }),
              let text = String(data: data, encoding: .ascii) else { try reject() }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, !first.contains(where: { $0.isEmpty }) else { try reject() }
        let method = String(first[0]), target = String(first[1])
        guard first[2] == "HTTP/1.1" else { try reject(505, "Only HTTP/1.1 is supported.") }
        let tokenBytes = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        guard method.utf8.allSatisfy({ tokenBytes.contains($0) }), target.hasPrefix("/"), !target.hasPrefix("//"),
              !target.contains("#"), !target.contains("\\"), target.utf8.allSatisfy({ (33...126).contains($0) }) else { try reject() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { try reject() }
            let name = String(line[..<colon]).lowercased()
            let raw = line[line.index(after: colon)...]
            guard name.utf8.allSatisfy({ tokenBytes.contains($0) }),
                  raw.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }), headers[name] == nil else { try reject() }
            headers[name] = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        guard headers["transfer-encoding"] == nil else { try reject(400, "Transfer-Encoding is not supported.") }
        guard headers["expect"] == nil else { try reject(417, "Expect is not supported.") }
        guard headers["content-encoding"] == nil else { try reject(415, "Content-Encoding is not supported.") }
        if method == "POST", headers["content-length"] == nil { try reject(411, "Content-Length is required.") }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(rawLength) else { try reject(400, "Invalid Content-Length.") }
        guard length <= Self.bodyLimit else { try reject(413, "Request body is too large.") }
        guard method == "POST" || length == 0 else { try reject(400, "This method does not accept a body.") }
        return RequestHead(method: method, target: target, headers: headers, contentLength: length)
    }

    private func accessFailure(_ head: RequestHead) -> (Int, String)? {
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard allowedHosts.contains(head.headers["host"] ?? "") else { return (403, "Loopback host required.") }
        if let origin = head.headers["origin"], !allowedHosts.contains(where: { origin == "http://\($0)" }) { return (403, "Origin denied.") }
        if head.headers["sec-fetch-site"] == "cross-site" { return (403, "Cross-site requests are denied.") }
        if head.method == "GET", head.target == "/" { return nil }
        guard head.headers["x-opencove-token"] == token else { return (401, "Development token required. Reopen the URL from opencovectl url after restarting the app.") }
        return nil
    }

    private func route(_ connection: NWConnection, head: RequestHead, body: Data) {
        let method = head.method, target = head.target
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let allowedMethod: String
        switch path {
        case "/", "/state", "/render": allowedMethod = "GET"
        case "/command": allowedMethod = "POST"
        default: fail(connection, 404, "Unknown development endpoint."); return
        }
        guard method == allowedMethod else {
            respond(connection, status: 405, json: ["error": "Method not allowed."], extraHeaders: "Allow: \(allowedMethod)\r\n"); return
        }
        if path != "/render", target != path { fail(connection, 400, "This endpoint does not accept a query."); return }
        switch path {
        case "/": respond(connection, status: 200, contentType: "text/html; charset=utf-8", data: Data(DevelopmentPage.html.utf8))
        case "/state":
            do { respond(connection, status: 200, json: try snapshot()) }
            catch { fail(connection, 500, "App state could not be encoded.") }
        case "/render":
            let query = URLComponents(string: target)?.queryItems ?? []
            guard query.count <= 1, query.allSatisfy({ $0.name == "surface" && $0.value != nil }) else { fail(connection, 400, "Use one render surface."); return }
            connections[ObjectIdentifier(connection)]?.renderTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do { self.respond(connection, status: 200, contentType: "image/png", data: try await self.render(surface: query.first?.value ?? "notch")) }
                catch is CancellationError { }
                catch let failure as ControlError { self.fail(connection, failure.status, failure.localizedDescription) }
                catch { self.fail(connection, 500, "Native rendering failed.") }
            }
        default:
            guard head.headers["content-type"]?.lowercased().split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
                fail(connection, 415, "Content-Type must be application/json."); return
            }
            do {
                let value: Any
                do { value = try JSONSerialization.jsonObject(with: body) }
                catch { throw ControlError.invalid("The command body must be a JSON object.") }
                guard let object = value as? [String: Any], let action = object["action"] as? String,
                      !action.isEmpty, action.utf8.count <= 128 else { throw ControlError.invalid("A command action is required.") }
                if action == "input.middleClick" {
                    guard Set(object.keys).isSubset(of: ["action", "region"]),
                          let region = object["region"] as? String,
                          ["gestureStrip", "body"].contains(region) else {
                        throw ControlError.invalid("Choose gestureStrip or body; arbitrary input targets are not accepted.")
                    }
                    guard let notch else { throw ControlError.rejected("The native panel controller is unavailable.") }
                    let receipt: [String: Any]
                    do { receipt = try notch.acceptMiddleClick(region: region) }
                    catch let error as NotchPanelController.InputAcceptanceError {
                        throw ControlError.rejected(error.localizedDescription)
                    }
                    var state = try snapshot()
                    state["commandStatus"] = "observed"
                    state["nativeInput"] = receipt
                    respond(connection, status: 200, json: state)
                    return
                }
                if action == "system.refreshAudio" {
                    let caller = object["caller"] as? String ?? "developmentAPI"
                    guard object["caller"] == nil || object["caller"] is String,
                          ["developmentAPI", "nativePicker"].contains(caller) else {
                        throw ControlError.invalid("Use developmentAPI or nativePicker for the audio refresh caller.")
                    }
                    connections[ObjectIdentifier(connection)]?.renderTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        do {
                            self.respond(connection, status: 200, json: try await self.acceptAudioRefresh(mountPicker: caller == "nativePicker"))
                        } catch is CancellationError { }
                        catch let failure as ControlError { self.fail(connection, failure.status, failure.localizedDescription) }
                        catch { self.fail(connection, 500, "Audio refresh acceptance could not return evidence.") }
                    }
                    return
                }
                try dispatch(action, object)
                var state = try snapshot()
                state["commandStatus"] = "submitted"
                respond(connection, status: 200, json: state)
            } catch let failure as ControlError { fail(connection, failure.status, failure.localizedDescription) }
            catch is DecodingError { fail(connection, 400, "Preference values have invalid types.") }
            catch { fail(connection, 500, "The command could not return a valid app state. It may have been applied; inspect the app before retrying.") }
        }
    }

    private func fail(_ connection: NWConnection, _ status: Int, _ message: String) {
        respond(connection, status: status, json: ["error": message])
    }

    private func acceptAudioRefresh(mountPicker: Bool) async throws -> [String: Any] {
        // Mount the actual Activities settings through the unordered renderer.
        // Its onAppear alone uses the default nativePicker caller; the API path
        // names itself explicitly and invokes the same refreshAudio entry.
        guard let evidence = try await store.system.withAudioRefreshAcceptance({
            if mountPicker { _ = try await self.render(surface: "settings-activities") }
            else { self.store.system.refreshAudio(caller: .developmentAPI) }
        }) else {
            throw ControlError.rejected("Audio acceptance requires running system monitoring, no other acceptance, and an unchanged monitoring generation.")
        }
        guard !evidence.isEmpty else {
            throw ControlError.rejected("No synchronous audio refresh was observed. The native picker may not have appeared.")
        }
        // This reports observations, including real read errors and empty output
        // lists. It does not infer acceptance from an HTTP 200 or cached state.
        var result = try snapshot()
        result["commandStatus"] = "observed"
        result["audioRefreshAcceptance"] = try encoded(evidence)
        return result
    }

    private func dispatch(_ action: String, _ values: [String: Any]) throws {
        func number(_ name: String) throws -> Double {
            guard let n = values[name] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw ControlError.invalid("\(name) must be a finite number.") }
            return n.doubleValue
        }
        func requireCapability(_ available: Bool, _ message: String) throws {
            guard available else { throw ControlError.rejected(message) }
        }
        func activity(_ operation: () -> Void) throws {
            switch store.activities.performSynchronousOperation(operation) {
            case .submitted: return
            case .failed(let message): throw ControlError.failed(message)
            }
        }
        func system(_ operation: () -> SystemController.OperationResult) throws {
            switch operation() {
            case .submitted: return
            case .rejected(let message): throw ControlError.rejected(message)
            case .failed(let message):
                throw ControlError.failed("The system write failed: \(message) It may have partially applied; read state before retrying.")
            }
        }
        switch action {
        case "updates.check":
            guard let updater, updater.canCheckForUpdates else {
                throw ControlError.rejected("The updater is unavailable or already checking. Read fresh state.")
            }
            updater.checkForUpdates()
        case "updates.preferences":
            guard let updater, updater.controller != nil else {
                throw ControlError.rejected("The updater is off in this launch.")
            }
            guard let changes = values["values"] as? [String: Any], !changes.isEmpty,
                  Set(changes.keys).isSubset(of: ["automaticChecks", "automaticDownloads"]) else {
                throw ControlError.invalid("Use automaticChecks or automaticDownloads boolean values.")
            }
            for value in changes.values {
                guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw ControlError.invalid("Update preferences must be booleans.")
                }
            }
            if changes["automaticDownloads"] as? Bool == true, !updater.allowsAutomaticUpdates {
                throw ControlError.rejected("This update configuration does not support automatic installation.")
            }
            if let value = changes["automaticChecks"] as? Bool { updater.setAutomaticChecks(value) }
            if let value = changes["automaticDownloads"] as? Bool { updater.setAutomaticDownloads(value) }
        case "expand": store.expand()
        case "compact.open": store.openCompactActivity()
        case "compact.dismiss", "compact.restore":
            guard let target = values["target"] as? String, target.utf8.count <= 64, UUID(uuidString: target) != nil else {
                throw ControlError.invalid("Echo the current compact activity target from state.")
            }
            let submitted = action == "compact.dismiss" ? store.dismissCompactActivity(target: target)
                : store.restoreCompactActivity(target: target)
            guard submitted else { throw ControlError.rejected("This activity is no longer available for that action. Read fresh state.") }
        case "collapse": store.collapse()
        case "hud.preview":
            guard let name = values["kind"] as? String, let kind = HUDKind(rawValue: name) else {
                throw ControlError.invalid("Choose a known overlay category.")
            }
            if let message = store.previewHUD(kind) { throw ControlError.rejected(message) }
        case "toggle": store.toggleExpanded()
        case "selectTab":
            guard let name = values["tab"] as? String, let tab = CoveTab(rawValue: name) else { throw ControlError.invalid("Unknown tab.") }
            guard store.selectTab(tab, expand: true) else { throw ControlError.rejected("This section is disabled. Enable it in Settings first.") }
        case "preferences":
            guard let changes = values["values"] as? [String: Any] else { throw ControlError.invalid("Preference values are required.") }
            guard var object = try encoded(store.preferences) as? [String: Any] else { throw ControlError.failed("Settings could not be encoded.") }
            for (key, value) in changes {
                guard let expected = object[key] else { throw ControlError.invalid("Unknown preference field.") }
                if let expected = expected as? NSNumber {
                    guard let actual = value as? NSNumber,
                          (CFGetTypeID(expected) == CFBooleanGetTypeID()) == (CFGetTypeID(actual) == CFBooleanGetTypeID()),
                          actual.doubleValue.isFinite else { throw ControlError.invalid("Invalid type for preference \(key).") }
                } else {
                    guard let text = value as? String, text.utf8.count <= 256 else { throw ControlError.invalid("Invalid text for preference \(key).") }
                }
                object[key] = value
            }
            let candidate = try JSONDecoder().decode(CovePreferences.self, from: JSONSerialization.data(withJSONObject: object))
            var normalized = candidate
            normalized.normalize()
            guard candidate == normalized else { throw ControlError.invalid("A preference is outside its supported range or choices.") }
            store.preferences = candidate
            guard store.savePreferences() else { throw ControlError.failed(store.lastError ?? "Settings could not be saved.") }
        case "display.select":
            guard let choice = values["choice"] as? String, choice.utf8.count <= 64 else {
                throw ControlError.invalid("Provide a display choice.")
            }
            guard ["all", "builtIn", "main"].contains(choice) || UUID(uuidString: choice) != nil else {
                throw ControlError.invalid("Choose a display mode or an available display.")
            }
            switch store.chooseDisplay(choice) {
            case .success: break
            case .failure(let error):
                switch error {
                case .invalidChoice: throw ControlError.invalid(error.localizedDescription)
                case .unavailable: throw ControlError.rejected(error.localizedDescription)
                case .saveFailed: throw ControlError.failed(error.localizedDescription)
                }
            }
        case "preferences.reset":
            guard store.resetPreferences() else { throw ControlError.failed(store.lastError ?? "Settings could not be saved.") }
        case "onboarding.complete":
            store.preferences.completedOnboarding = true
            guard store.savePreferences() else { throw ControlError.failed(store.lastError ?? "Setup could not be saved.") }
        case "settings": store.openSettings()
        case "media.refresh": store.media.refreshFromUser()
        case "media.playPause":
            try requireCapability(store.media.state.supportsPlayPause, "Play/pause is unavailable for this source.")
            store.media.playPause()
        case "media.next":
            try requireCapability(store.media.state.supportsNext, "Next track is unavailable for this source.")
            store.media.next()
        case "media.previous":
            try requireCapability(store.media.state.supportsPrevious, "Previous track is unavailable for this source.")
            store.media.previous()
        case "media.shuffle":
            try requireCapability(store.media.state.supportsShuffle, "Shuffle is unavailable for this source.")
            store.media.toggleShuffle()
        case "media.repeat":
            try requireCapability(store.media.state.supportsRepeat, "Repeat is unavailable for this source.")
            store.media.cycleRepeat()
        case "media.favorite":
            try requireCapability(store.media.state.supportsFavorite, "Favorites are unavailable for this source.")
            store.media.toggleFavorite()
        case "media.copyLink":
            try requireCapability(store.media.state.supportsCopyLink, "This source did not provide a copyable media link.")
            store.media.copyLink()
        case "media.speed":
            let speed = try number("speed")
            try requireCapability(store.media.state.supportsPlaybackSpeed, "Playback speed is unavailable for this source.")
            guard let source = values["source"] as? String, let item = values["item"] as? String,
                  !source.isEmpty, source.utf8.count <= 1_024, !item.isEmpty, item.utf8.count <= 8_192 else {
                throw ControlError.invalid("Provide the source and item identifiers from the current media state.")
            }
            guard source == store.media.state.sourceBundleIdentifier,
                  item == store.media.state.contentItemIdentifier else {
                throw ControlError.rejected("The media source or item changed. Read fresh state before choosing a speed.")
            }
            guard speed > 0, speed <= 16,
                  store.media.state.supportedPlaybackSpeeds.contains(where: { abs($0 - speed) < 0.000001 }) else {
                throw ControlError.invalid("Choose a playback speed advertised by the current source.")
            }
            guard store.media.setPlaybackSpeed(speed, source: source, itemID: item) else {
                throw ControlError.rejected(store.media.lastError ?? "Playback speed could not be submitted.")
            }
        case "media.seek":
            let seconds = try number("seconds")
            guard store.media.state.available, store.media.state.supportsSeek else { throw ControlError.rejected("No seekable media source is available.") }
            let target: String?
            if let supplied = values["target"] {
                guard let value = supplied as? String, !value.isEmpty, value.utf8.count <= 128 else {
                    throw ControlError.invalid("Use the seek target from the current media state.")
                }
                guard value == store.media.state.seekTarget else {
                    throw ControlError.rejected("The media item changed. Read fresh state before seeking.")
                }
                target = value
            } else { target = nil }
            guard seconds >= 0, seconds <= store.media.state.duration else { throw ControlError.invalid("Seek time is outside the current track.") }
            guard store.media.seek(to: seconds, target: target) else {
                throw ControlError.rejected(store.media.lastError ?? "The seek could not be submitted.")
            }
        case "system.refresh": store.system.refresh()
        case "system.volume":
            let value = try number("value")
            guard (0...1).contains(value) else { throw ControlError.invalid("Volume must be between zero and one.") }
            try requireCapability(store.system.state.canSetVolume, "The current output has no writable volume control.")
            try system { store.system.setVolumeWithResult(value) }
        case "system.mute":
            try requireCapability(store.system.state.canSetMute, "The current output has no writable mute control.")
            try system { store.system.toggleMuteWithResult() }
        case "system.adjustVolume":
            let delta = try number("delta"), id = try number("id")
            guard abs(delta) <= 0.25, id >= 0, id <= Double(UInt32.max), id.rounded() == id,
                  let uid = values["uid"] as? String else { throw ControlError.invalid("A small relative volume change and expected output identity are required.") }
            try system { store.system.adjustVolume(delta, expectedDeviceID: UInt32(id), expectedUID: uid) }
        case "system.output":
            let id = try number("id")
            guard id >= 0, id <= Double(UInt32.max), id.rounded() == id else { throw ControlError.invalid("Invalid output device.") }
            try requireCapability(store.system.state.outputDevices.contains(where: { $0.id == UInt32(id) }), "That output device is unavailable.")
            try requireCapability(store.system.state.canSelectOutputDevice || store.system.state.outputDeviceID == UInt32(id), "The default output cannot be changed.")
            try system { store.system.selectOutputDeviceWithResult(UInt32(id)) }
        case "system.brightness":
            let value = try number("value")
            guard (0...1).contains(value) else { throw ControlError.invalid("Brightness must be between zero and one.") }
            try requireCapability(store.system.state.canSetBrightness, "No active display has a writable brightness control.")
            try system { store.system.setBrightnessWithResult(value) }
        case "calendar.refresh": store.activities.refreshCalendar()
        case "calendar.request": store.activities.requestCalendarAccess()
        case "calendar.selectDate":
            guard let raw = values["date"] as? String, let date = ISO8601DateFormatter().date(from: raw) else { throw ControlError.invalid("Use an ISO 8601 date.") }
            store.activities.loadSelectedDate(date)
        case "calendar.exclude":
            guard let id = values["id"] as? String, !id.isEmpty, id.utf8.count <= 1_024,
                  let excluded = values["excluded"] as? NSNumber, CFGetTypeID(excluded) == CFBooleanGetTypeID() else {
                throw ControlError.invalid("Calendar id and a Boolean exclusion state are required.")
            }
            try activity { store.activities.setCalendarExcluded(id, excluded: excluded.boolValue) }
        case "weather.location":
            let latitude = try number("latitude"), longitude = try number("longitude")
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw ControlError.invalid("Invalid weather coordinates.") }
            store.weather.setLocation(latitude: latitude, longitude: longitude, name: values["name"] as? String ?? "")
        case "weather.refresh":
            guard store.preferences.enableWeather else { throw ControlError.rejected("Weather is disabled. Enable it in preferences before refreshing.") }
            store.weather.refresh()
        case "weather.clear":
            guard store.weather.clearLocation() else {
                throw ControlError.failed(store.weather.lastError ?? "The weather location could not be removed.")
            }
        case "files.add":
            guard let paths = values["paths"] as? [String], !paths.isEmpty, paths.count <= 100 else { throw ControlError.invalid("Provide 1 to 100 absolute file paths.") }
            let urls = try paths.map { path -> URL in
                guard !path.utf8.contains(0), path.utf8.count <= 4_096 else { throw ControlError.invalid("A file path is invalid or too long.") }
                let expanded = (path as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/") else { throw ControlError.invalid("Use absolute file paths, optionally starting with ~.") }
                let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
                guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
                      attributes.isRegularFile == true, attributes.isReadable != false,
                      FileManager.default.isReadableFile(atPath: url.path) else { throw ControlError.invalid("Choose existing, readable regular files.") }
                return url
            }
            try activity { store.activities.addFiles(urls) }
        case "files.remove":
            guard let rawID = values["id"] as? String, let id = UUID(uuidString: rawID) else { throw ControlError.invalid("File id is required.") }
            guard store.activities.files.contains(where: { $0.id == id }) else { throw ControlError.missing("That tray file no longer exists.") }
            try activity { store.activities.removeFile(id) }
        case "files.clear": try activity { store.activities.clearFiles() }
        case "timer.start":
            let seconds = try number("seconds")
            guard seconds >= 1 && seconds <= 86_400 else { throw ControlError.invalid("Timer duration must be 1 to 86400 seconds.") }
            try activity { store.activities.startTimer(seconds: seconds) }
        case "timer.pause": try activity { store.activities.pauseTimer() }
        case "timer.resume":
            try requireCapability(store.activities.timer.remaining > 0, "There is no paused timer to resume.")
            try activity { store.activities.resumeTimer() }
        case "timer.cancel": try activity { store.activities.cancelTimer() }
        case "notification.post":
            guard let title = values["title"] as? String, title.count <= 200, let body = values["body"] as? String, body.count <= 2_000 else { throw ControlError.invalid("A short title and body are required.") }
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.isEmpty else { throw ControlError.invalid("Enter a notification title or message.") }
            try activity { store.activities.postNotification(title: title, body: body) }
        default: throw ControlError.invalid("Unknown command action.")
        }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: .fragmentsAllowed)
    }

    private func snapshot() throws -> [String: Any] {
        let windows = NSApp.windows.filter { $0.isVisible && ($0.title == "OpenCove" || $0.identifier != nil) }.map { window in
            var value: [String: Any] = ["title": window.title, "width": window.frame.width, "height": window.frame.height,
                                       "x": window.frame.origin.x, "y": window.frame.origin.y]
            if let hidden = NotchPanelController.contentIsHidden(in: window) { value["contentHidden"] = hidden }
            if let id = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                value["displayID"] = id.uint32Value
            }
            return value
        }
        var result: [String: Any] = ["app": "OpenCove", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unbundled", "expanded": store.isExpanded, "tab": store.selectedTab.rawValue, "settingsVisible": store.settingsVisible, "dataDirectory": CovePaths.dataDirectory.path, "nativeWindows": windows]
        result["preferences"] = try encoded(store.preferences)
        let sparkle = updater?.controller?.updater
        result["updates"] = ["available": sparkle != nil,
                             "canCheckForUpdates": sparkle?.canCheckForUpdates ?? false,
                             "automaticChecks": sparkle?.automaticallyChecksForUpdates ?? false,
                             "automaticDownloads": sparkle?.automaticallyDownloadsUpdates ?? false,
                             "allowsAutomaticUpdates": sparkle?.allowsAutomaticUpdates ?? false,
                             "status": updater?.status ?? "No updater is attached to these controls."]
        result["enabledTabs"] = store.enabledTabs.map(\.rawValue)
        result["visibleTab"] = store.visibleTab.map { $0.rawValue as Any } ?? NSNull()
        result["expandedDuo"] = store.showsExpandedDuo
        var media = store.media.state
        media.elapsed = store.media.playback.elapsed
        media.artworkData = nil
        result["media"] = try encoded(media)
        result["compactMediaVisible"] = store.compactMediaVisible
        result["compactActivity"] = store.compactActivity.rawValue
        result["compactActivities"] = store.availableCompactActivities.map(\.rawValue)
        result["dismissedCompactActivities"] = store.dismissedCompactActivities.map(\.rawValue)
        result["compactDismissTarget"] = store.compactDismissTarget.map { $0 as Any } ?? NSNull()
        result["compactRestoreTarget"] = store.compactRestoreTarget.map { $0 as Any } ?? NSNull()
        result["compactDismissActivity"] = store.compactDismissActivity.map { $0.rawValue as Any } ?? NSNull()
        result["compactRestoreActivity"] = store.compactRestoreActivity.map { $0.rawValue as Any } ?? NSNull()
        result["mediaPeekVisible"] = store.showsMediaPeek
        result["mediaPeekRemaining"] = store.mediaPeekRemaining.map { $0 as Any } ?? NSNull()
        result["hudRemaining"] = store.hudRemaining.map { $0 as Any } ?? NSNull()
        result["playbackClock"] = ["receivedSamples": store.media.playback.receivedSamples,
                                   "changeNotifications": store.media.playback.changeNotifications]
        result["artworkAvailable"] = store.media.state.artworkData != nil
        result["systemReduceMotion"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        result["mediaTextMotion"] = NSApp.windows.filter(\.isVisible).flatMap { window in
            window.contentView.map { CoveScrollingMediaTextView.motionSnapshots(in: $0) } ?? []
        }
        result["playbackIndicatorMotion"] = NSApp.windows.filter(\.isVisible).flatMap { window in
            window.contentView.map { CovePlaybackIndicatorView.motionSnapshots(in: $0) } ?? []
        }
        result["artworkTransitionMotion"] = NSApp.windows.filter(\.isVisible).flatMap { window in
            window.contentView.map { CoveArtworkTransitionView.motionSnapshots(in: $0) } ?? []
        }
        result["timerClock"] = ["publications": timerPublications]
        result["timerProgressMotion"] = NSApp.windows.filter(\.isVisible).flatMap { window in
            window.contentView.map { CoveTimerProgressView.motionSnapshots(in: $0) } ?? []
        }
        result["system"] = try encoded(store.system.state)
        result["events"] = try encoded(store.activities.events)
        result["calendarAuthorization"] = store.activities.calendarAuthorization
        result["selectedCalendarDate"] = ISO8601DateFormatter().string(from: store.activities.selectedCalendarDate)
        result["calendarActivity"] = store.activities.eventActivity.map { ["title": $0.event.title, "remainingSeconds": $0.remainingSeconds] }
        result["files"] = try encoded(store.activities.files.map { file in var file = file; file.bookmarkData = nil; return file })
        result["timer"] = try encoded(store.activities.timer.snapshot())
        result["notifications"] = try encoded(store.activities.notifications)
        result["weather"] = try encoded(store.weather.state)
        result["weatherPresentation"] = try encoded(WeatherWidgetData(state: store.weather.state,
            style: CoveWeatherStyle(rawValue: store.preferences.weatherStyle) ?? .conditions, at: Date()))
        result["weatherStatus"] = ["hasLocation": store.weather.hasLocation,
                                    "loading": store.weather.isLoading,
                                    "requestingLocation": store.weather.isRequestingLocation,
                                    "requestAttempts": store.weather.requestAttempts]
        result["notificationMirror"] = store.mirroringStatus
        result["loginItemStatus"] = store.loginItemStatus
        result["pid"] = ProcessInfo.processInfo.processIdentifier
        result["bundlePath"] = bundlePath
        result["bundleIdentifier"] = Bundle.main.bundleIdentifier ?? ""
        result["sourceTreeSHA256"] = sourceTree
        result["startedAt"] = startedAt
        result["controlProtocol"] = 1
        result["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""
        result["travel"] = try encoded(store.travel.state)
        result["waveform"] = ["available": store.waveform.available, "status": store.waveform.status,
                              "enabled": store.preferences.usesLiveWaveform,
                              "startAttempts": store.waveform.startAttempts,
                              "captureActive": store.waveform.captureActive,
                              "captureStarting": store.waveform.captureStarting,
                              "meterActive": store.waveform.meterActive]
        result["physicalNotch"] = ["width": store.physicalNotchWidth, "height": store.physicalNotchHeight]
        result["displaySelection"] = try encoded(store.displaySelection)
        if let hud = store.hud { result["hud"] = try encoded(hud) }
        else { result["hud"] = NSNull() }
        result["errors"] = [store.lastError, store.media.lastError, store.system.lastError, store.activities.lastError, store.weather.lastError].compactMap { $0 }
        result["notices"] = [store.activities.lastNotice].compactMap { $0 }
        return result
    }

    private func render(surface: String) async throws -> Data {
        guard !rendererBusy else { throw ControlError.rejected("A native capture is already in progress. Retry after it finishes.") }
        rendererBusy = true
        defer { rendererBusy = false }
        if surface == "live-notch-compositor" {
            // The explicit authenticated surface captures only the mounted app
            // panel. Selection does not retain its NSWindow across an await.
            do {
                guard let capture = try NSApp.windows.first(where: {
                    $0.isVisible && NotchPanelController.contentIsHidden(in: $0) == false
                }).map({ try OwnedWindowCapture(window: $0) }) else {
                    throw ControlError.rejected("No visible native notch content is available.")
                }
                let source = store.media.state.sourceBundleIdentifier
                let target = store.media.state.seekTarget
                let available = store.media.state.available
                return try await capture.png {
                    guard !self.store.system.state.isLocked,
                          self.store.media.state.sourceBundleIdentifier == source,
                          self.store.media.state.seekTarget == target,
                          self.store.media.state.available == available else {
                        throw ControlError.rejected("The session or media source changed during owned-window capture. Read fresh state and retry.")
                    }
                }
            } catch let failure as OwnedWindowCapture.Failure {
                throw ControlError.rejected(failure.localizedDescription)
            }
        }
        if surface == "live-notch" {
            guard let window = NSApp.windows.first(where: {
                $0.isVisible && NotchPanelController.contentIsHidden(in: $0) == false
            }), let view = window.contentView else {
                throw ControlError.rejected("No visible native notch content is available.")
            }
            // Draw this app's existing view, including its mounted timeline.
            // This neither orders a window nor reads WindowServer/desktop pixels.
            view.layoutSubtreeIfNeeded()
            return try png(from: view)
        }
        let content: AnyView
        let size: CGSize
        switch surface {
        case "notch":
            size = NotchView.desiredSize(store: store)
            content = AnyView(NotchView(store: store).environment(\.colorScheme, .dark))
        case "onboarding":
            size = CGSize(width: 700, height: 550)
            content = AnyView(OnboardingView(store: store))
        case "settings":
            size = CGSize(width: 760, height: 550)
            content = AnyView(SettingsView(store: store))
        case "settings-appearance":
            size = CGSize(width: 760, height: 550)
            content = AnyView(SettingsView(store: store, initialPage: .appearance))
        case "settings-media":
            size = CGSize(width: 760, height: 550)
            content = AnyView(SettingsView(store: store, initialPage: .media))
        case "settings-activities":
            size = CGSize(width: 760, height: 900)
            content = AnyView(SettingsView(store: store, initialPage: .activities))
        case "settings-updates":
            size = CGSize(width: 760, height: 760)
            content = AnyView(SettingsView(store: store, initialPage: .about, updater: updater))
        case "settings-weather":
            size = CGSize(width: 760, height: 550)
            content = AnyView(SettingsView(store: store, initialPage: .weather))
        case "lock":
            size = CGSize(width: 460, height: 250)
            content = AnyView(LockScreenView(store: store, weather: store.weather).environment(\.colorScheme, .dark))
        case "weather":
            size = CGSize(width: 560, height: 760)
            content = AnyView(ScrollView { WeatherView(controller: store.weather,
                style: CoveWeatherStyle(rawValue: store.preferences.weatherStyle) ?? .conditions,
                motion: store.preferences.reduceMotion ? nil : CoveMotion.animation(preferences: store.preferences, hud: false)).padding(20) }
                .environment(\.colorScheme, .dark))
        default: throw ControlError.invalid("Unknown render surface.")
        }
        // An unordered window supplies native AppKit rendering context. It never
        // becomes visible/key, reads the desktop, or receives user input.
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .transaction { transaction in
                transaction.disablesAnimations = true
                transaction.animation = nil
            })
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.setFrameSize(size)
        hosting.layoutSubtreeIfNeeded()
        // Native containers and vibrant text finish mounting on later run-loop
        // turns. Yield without ordering the window or blocking the main actor.
        try await Task.sleep(for: .milliseconds(80))
        try Task.checkCancellation()
        hosting.layoutSubtreeIfNeeded()
        hosting.needsDisplay = true
        window.displayIfNeeded()
        hosting.display()
        return try png(from: hosting)
    }

    private func png(from view: NSView) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ControlError.failed("Native rendering failed.")
        }
        bitmap.size = view.bounds.size
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            CoveTimerProgressView.withCurrentPresentation(in: view) {
                CoveArtworkTransitionView.withCurrentPresentation(in: view) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
            }
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ControlError.failed("Native rendering failed.") }
        return png
    }

    private func respond(_ connection: NWConnection, status: Int, json: [String: Any], extraHeaders: String = "") {
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            respond(connection, status: status, contentType: "application/json", data: data, extraHeaders: extraHeaders)
        } catch {
            respond(connection, status: 500, contentType: "application/json", data: Data(#"{"error":"App state could not be encoded."}"#.utf8))
        }
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String, data: Data, extraHeaders: String = "") {
        guard let client = connections[ObjectIdentifier(connection)], !client.responding else { return }
        client.responding = true
        client.buffer.removeAll(keepingCapacity: false)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 411: "Length Required", 413: "Payload Too Large", 415: "Unsupported Media Type", 417: "Expectation Failed", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 505: "HTTP Version Not Supported"][status] ?? "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n\(extraHeaders)\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(ObjectIdentifier(connection)) }
        })
    }

    private enum ControlError: LocalizedError {
        case invalid(String), rejected(String), failed(String), missing(String)
        var status: Int {
            switch self { case .invalid: return 400; case .rejected: return 409; case .failed: return 500; case .missing: return 404 }
        }
        var errorDescription: String? {
            switch self { case .invalid(let message), .rejected(let message), .failed(let message), .missing(let message): return message }
        }
    }
}
