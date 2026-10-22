// SPDX-License-Identifier: MIT
import AudioToolbox
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// An opt-in, audio-only level history, not a frequency spectrum or a recording.
///
/// Packaging must supply NSScreenCaptureUsageDescription explaining that the
/// Screen & System Audio Recording permission is used only for transient audio
/// levels. NSAudioCaptureUsageDescription should explain the same audio use;
/// it is also required if this backend is ever replaced with Core Audio taps.
/// No NSMicrophoneUsageDescription or microphone capture is used here.
///
/// Wire requestAccessAndStart() only to an explicit user action. Restoring an
/// enabled preference must call start(), which never requests permission.
/// Apple ABI: ScreenCaptureKit/SCStream.h, CoreGraphics/CGWindow.h, and
/// CoreMedia/CMSampleBuffer.h in the public macOS SDK. References:
/// https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
/// https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()
@MainActor
final class AudioWaveformController: ObservableObject {
    @Published private(set) var levels = Array(repeating: 0.0, count: 8)
    @Published private(set) var available = false
    @Published private(set) var status = "Live waveform is off."
    @Published private(set) var lastError: String?

    private var session: WaveformCaptureSession?
    private var startTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastPermissionCheck = 0.0

    // On-demand development diagnostics only; no publication or polling.
    private(set) var startAttempts: UInt64 = 0
    var captureActive: Bool { session != nil }
    var captureStarting: Bool { startTask != nil }
    var meterActive: Bool { meterTask != nil }

    deinit {
        startTask?.cancel()
        meterTask?.cancel()
        let capture = session
        capture?.receiver.invalidate()
        let pendingStart = startTask
        let pendingCleanup = cleanupTask
        Task { @MainActor in
            await pendingCleanup?.value
            await pendingStart?.value
            await capture?.stop()
        }
    }

    /// Safe for startup and preference restoration: preflight does not prompt.
    func start() {
        startAttempts &+= 1
        guard session == nil, startTask == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            showAccessRequired()
            return
        }
        guard hasUsageDescription else { return }
        beginCapture()
    }

    /// The only path that can request new permission. Call from a user button.
    func requestAccessAndStart() {
        guard session == nil, startTask == nil else { return }
        guard hasUsageDescription else { return }
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                showAccessRequired()
                return
            }
        }
        // Recheck rather than assuming a grant is effective without relaunch.
        start()
    }

    func stop() {
        if startTask != nil || session != nil || meterTask != nil { generation = UUID() }
        meterTask?.cancel()
        meterTask = nil
        let pendingStart = startTask
        pendingStart?.cancel()
        startTask = nil
        let capture = session
        session = nil
        capture?.receiver.invalidate()
        // Do not race stopCapture against an in-flight startCapture. New starts
        // await this teardown before creating another stream.
        let previousCleanup = cleanupTask
        if pendingStart != nil || capture != nil {
            cleanupTask = Task {
                await previousCleanup?.value
                await pendingStart?.value
                await capture?.stop()
            }
        }
        clearLevels()
        if lastError != nil { lastError = nil }
        if status != "Live waveform is off." { status = "Live waveform is off." }
    }

    private var hasUsageDescription: Bool {
        let description = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String
        guard description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            clearLevels()
            status = "Live waveform needs the installed app's capture permission description."
            lastError = "Add NSScreenCaptureUsageDescription to the app's Info.plist, explaining audio-only levels with no saved audio."
            return false
        }
        return true
    }

    private func beginCapture() {
        generation = UUID()
        let id = generation
        let previousCleanup = cleanupTask
        lastError = nil
        status = "Starting system audio levels…"
        startTask = Task { [weak self] in
            await previousCleanup?.value
            guard let self, self.generation == id, !Task.isCancelled else { return }
            var capture: WaveformCaptureSession?
            do {
                // Never enumerate shareable content without a successful
                // preflight; enumeration itself can otherwise trigger consent.
                guard CGPreflightScreenCaptureAccess() else { throw WaveformFailure.accessRequired }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard self.generation == id else { return }
                guard CGPreflightScreenCaptureAccess() else { throw WaveformFailure.accessRequired }
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else { throw WaveformFailure.noDisplay }
                let created = try WaveformCaptureSession(display: display)
                capture = created
                self.session = created
                try await created.stream.startCapture()
                try Task.checkCancellation()
                guard self.generation == id else { await created.stop(); return }
                self.status = "Waiting for system audio."
                self.lastPermissionCheck = ProcessInfo.processInfo.systemUptime
                self.startTask = nil
                self.startMeter(receiver: created.receiver, generation: id)
            } catch {
                await capture?.stop()
                guard self.generation == id, !Task.isCancelled else { return }
                self.session = nil
                self.startTask = nil
                self.clearLevels()
                if !CGPreflightScreenCaptureAccess() {
                    self.showAccessRequired()
                } else {
                    self.status = "System audio levels could not start."
                    self.lastError = "\(error.localizedDescription) Check Screen & System Audio Recording access in System Settings; after granting access, relaunch OpenCove and try again."
                }
            }
        }
    }

    private func startMeter(receiver: WaveformAudioReceiver, generation id: UUID) {
        meterTask = Task { [weak self, weak receiver] in
            while !Task.isCancelled {
                // Poll a tiny mailbox. Native audio callbacks never enqueue
                // per-buffer main-actor tasks or pass PCM across this boundary.
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard self?.generation == id, let receiver else { return }
                self?.publish(receiver.snapshot())
            }
        }
    }

    private func publish(_ snapshot: WaveformAudioReceiver.Snapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPermissionCheck >= 1 {
            lastPermissionCheck = now
            guard CGPreflightScreenCaptureAccess() else {
                stop()
                showAccessRequired()
                return
            }
        }
        if let error = snapshot.error {
            stop()
            status = "System audio levels stopped."
            lastError = "\(error) Check capture access, then try enabling the live waveform again."
            return
        }
        guard let sampleTime = snapshot.sampleTime, now - sampleTime < 0.5 else {
            // Silence, sleep, a disconnected display, and protected content
            // must never leave a frozen waveform pretending to be live.
            clearLevels()
            let waiting = "Waiting for system audio. Some protected audio cannot be measured."
            if status != waiting { status = waiting }
            return
        }
        if levels != snapshot.levels { levels = snapshot.levels }
        if !available { available = true }
        let nextStatus = snapshot.levels.contains(where: { $0 > 0 })
            ? "Measuring system audio levels."
            : "System audio is quiet."
        if status != nextStatus { status = nextStatus }
    }

    private func clearLevels() {
        if levels.contains(where: { $0 != 0 }) { levels = Array(repeating: 0, count: 8) }
        if available { available = false }
    }

    private func showAccessRequired() {
        clearLevels()
        lastError = nil
        status = "Enable live waveform access to continue. In System Settings → Privacy & Security → Screen & System Audio Recording, allow OpenCove, then relaunch if needed."
    }
}

/// Only the main actor owns stream lifecycle. No IOProc, aggregate device,
/// microphone, screen output, SCRecordingOutput, or file writer is created.
@MainActor
private final class WaveformCaptureSession {
    let stream: SCStream
    let receiver: WaveformAudioReceiver
    private var stopped = false

    init(display: SCDisplay) throws {
        let output = WaveformAudioReceiver()
        receiver = output
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // SCStream still requires a display content filter for audio-only use.
        // No .screen output is registered, so this app receives no pixels.
        // Keep the unused video configuration small as a defensive measure.
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        receiver.invalidate()
        // Even failed starts must release their output registration. The stream
        // can already be stopped when its delegate reports an error.
        do { try await stream.stopCapture() } catch { /* Still detach the output. */ }
        do { try stream.removeStreamOutput(receiver, type: .audio) } catch { /* Stream may already be invalid. */ }
    }
}

/// Native callbacks run outside the main actor. All sample-processing state
/// belongs to `queue`; only `mailbox` crosses threads, under `lock`. Delegate
/// callbacks touch the mailbox only. The unchecked Sendable conformance encodes
/// this boundary; it does not make the audio buffers or SCStream actor-isolated.
private final class WaveformAudioReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Snapshot {
        var levels = Array(repeating: 0.0, count: 8)
        var sampleTime: TimeInterval?
        var error: String?
    }

    let queue = DispatchQueue(label: "OpenCove.audio-levels", qos: .userInitiated)
    private let lock = NSLock()
    private var mailbox = Snapshot()
    private var active = true
    // Two buffers cover both interleaved and planar stereo PCM. Allocate the
    // AudioBufferList once, not a new PCM array or audio buffer each callback.
    private let buffers = AudioBufferList.allocate(maximumBuffers: 2)
    private let bufferListSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.stride
    private var history = Array(repeating: 0.0, count: 8)
    private var nextBin = 0
    private var sumSquares = 0.0
    private var accumulatedFrames = 0
    private var previousSampleRate = 0.0
    private var previousBufferTime: TimeInterval?

    deinit { buffers.unsafeMutablePointer.deallocate() }

    func invalidate() {
        lock.lock()
        active = false
        mailbox = Snapshot()
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return mailbox
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.lock()
        let shouldProcess = active && mailbox.error == nil
        lock.unlock()
        guard shouldProcess else { return }

        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              description.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              description.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              description.mBitsPerChannel == 32,
              (1...2).contains(description.mChannelsPerFrame),
              description.mSampleRate.isFinite, (8_000...192_000).contains(description.mSampleRate) else {
            fail("ScreenCaptureKit returned an unsupported audio format.")
            return
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        guard frames <= 48_000 else {
            fail("ScreenCaptureKit returned an unexpectedly large audio buffer.")
            return
        }
        var retainedBlock: CMBlockBuffer?
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: buffers.unsafeMutablePointer, bufferListSize: bufferListSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlock
        )
        guard result == noErr else {
            fail("System audio samples could not be read (\(result)).")
            return
        }
        // CMSampleBuffer.h requires retaining this block while its PCM pointers
        // are in use. No sample buffer or PCM pointer survives this callback.
        withExtendedLifetime(retainedBlock) {
            consume(frames: frames, description: description)
        }
    }

    private func consume(frames: Int, description: AudioStreamBasicDescription) {
        guard (1...2).contains(buffers.count) else {
            fail("System audio returned an unsupported channel layout.")
            return
        }
        var channelCount = 0
        for buffer in buffers {
            guard (1...2).contains(buffer.mNumberChannels), buffer.mData != nil,
                  Int(buffer.mDataByteSize) >= frames * Int(buffer.mNumberChannels) * MemoryLayout<Float>.stride,
                  description.mBytesPerFrame == buffer.mNumberChannels * UInt32(MemoryLayout<Float>.stride) else {
                fail("System audio returned an invalid PCM buffer.")
                return
            }
            channelCount += Int(buffer.mNumberChannels)
        }
        guard channelCount == Int(description.mChannelsPerFrame) else {
            fail("System audio returned inconsistent channel counts.")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if previousSampleRate != description.mSampleRate || previousBufferTime.map({ now - $0 >= 0.5 }) == true {
            sumSquares = 0
            accumulatedFrames = 0
            for index in history.indices { history[index] = 0 }
            nextBin = 0
            previousSampleRate = description.mSampleRate
        }
        previousBufferTime = now
        let windowFrames = max(1, Int(description.mSampleRate / 20))
        for frame in 0..<frames {
            var frameSquares = 0.0
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                for channel in 0..<channels {
                    let value = Double(samples[frame * channels + channel])
                    // Invalid floating-point values cannot poison the meter.
                    let sample = value.isFinite ? min(1, max(-1, value)) : 0
                    frameSquares += sample * sample
                }
            }
            sumSquares += frameSquares / Double(channelCount)
            accumulatedFrames += 1
            if accumulatedFrames == windowFrames {
                let rms = sqrt(sumSquares / Double(accumulatedFrames))
                // Map a real -60...0 dBFS RMS range to 0...1. These are eight
                // consecutive 50 ms time bins, not invented frequency bands.
                let level = rms > 0 ? min(1, max(0, (20 * log10(rms) + 60) / 60)) : 0
                history[nextBin] = level
                nextBin = (nextBin + 1) % history.count
                lock.lock()
                if active {
                    for index in history.indices { mailbox.levels[index] = history[(nextBin + index) % history.count] }
                    mailbox.sampleTime = ProcessInfo.processInfo.systemUptime
                }
                lock.unlock()
                sumSquares = 0
                accumulatedFrames = 0
            }
        }
    }

    private func fail(_ message: String) {
        lock.lock()
        if active, mailbox.error == nil { mailbox.error = message }
        lock.unlock()
    }
}

private enum WaveformFailure: LocalizedError {
    case accessRequired
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .accessRequired: return "System audio capture access is not granted."
        case .noDisplay: return "No display is available for the audio-only stream. Connect a display and try again."
        }
    }
}
