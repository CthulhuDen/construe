import AVFoundation
import CoreAudio
import OSLog
import Synchronization

/// Captures all sound the Mac plays, except Construe's own, into an in-memory `AudioRingBuffer`.
///
/// Uses a Core Audio process tap rather than ScreenCaptureKit: a tap records audio only, so macOS
/// doesn't treat it as screen recording (which would black out Live Captions).
///
/// Audio flows in two stages so the HAL's real-time IO thread never waits on us:
/// 1. The IO proc runs on that thread and only copies each cycle's samples into a lock-free `SampleFIFO`.
/// 2. A `Drain` on `processingQueue` empties the FIFO every 50 ms, resamples to 16 kHz and appends
///    to the `AudioRingBuffer`.
///
/// Setup and teardown run on `controlQueue`, so this type isn't main-actor isolated; the ring
/// buffer and the time of the last sound are guarded by a mutex, which the IO thread never touches.
nonisolated final class SystemAudioCapture {
    private struct State {
        var buffer: AudioRingBuffer
        var lastSound: ContinuousClock.Instant
    }

    /// The live Core Audio objects and the stages fed by them, created and destroyed together.
    private struct Pipeline {
        let tap: AudioHardwareTap
        let device: AudioHardwareAggregateDevice
        let procID: AudioDeviceIOProcID
        let fifo: SampleFIFO
        let drain: Drain
        /// Rebuilds the pipeline when the device's sample rate changes, since the format depends on it.
        let rateListener: AudioObjectPropertyListenerBlock
    }

    /// Room in the FIFO, in seconds of device audio: how far the drain may fall behind before samples drop.
    private static let fifoSeconds = 1.0
    /// Frames per IO cycle requested on our private device: about 43 ms of audio (2048 frames at
    /// 48 kHz, 4096 at 96 kHz, vs. the usual 512), so a short stall elsewhere in the process fits
    /// within one cycle instead of skipping it. Latency doesn't matter for catching phrases.
    private static func ioBufferFrames(sampleRate: Double) -> UInt32 {
        sampleRate < 50_000 ? 2048 : 4096
    }

    /// With no audio callback for this long, capture is rebuilt (e.g. after sleep or an IO overload).
    private static let stallTimeout = Duration.seconds(3)
    /// How long device events must stop before capture is rebuilt. Unplugging a device fires several
    /// in a row (sample rate, then default device); building after the first one would target a
    /// device that is disappearing, and a failed build ends listening.
    private static let rebuildDelay = DispatchTimeInterval.milliseconds(300)

    private let state: Mutex<State>
    private let controlQueue = DispatchQueue(label: "Construe.SystemAudioCapture.control")
    private let processingQueue = DispatchQueue(label: "Construe.SystemAudioCapture.processing", qos: .utility)
    private let bufferSeconds: Int
    private let onStop: @MainActor (Error) -> Void

    // Used only on `controlQueue`.
    private var pipeline: Pipeline?
    private var watchdog: DispatchSourceTimer?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var lastRebuild: ContinuousClock.Instant?
    private var pendingRebuild: DispatchWorkItem?
    private var pendingReasons: [String] = []

    /// `onStop` is called on the main actor when capture stops on its own, e.g. when it can't recover from a stall.
    init(bufferSeconds: Int, onStop: @escaping @MainActor (Error) -> Void) {
        let capacity = Int(AudioRingBuffer.sampleRate) * bufferSeconds
        state = Mutex(State(buffer: AudioRingBuffer(capacity: capacity), lastSound: .now))
        self.bufferSeconds = bufferSeconds
        self.onStop = onStop
    }

    func start() async throws {
        try await onControlQueue {
            try self.build()
            self.startMonitoring()
        }
        Logger.audio.info("System audio capture started, buffer \(self.bufferSeconds, privacy: .public) s")
    }

    func stop() async {
        try? await onControlQueue {
            self.stopMonitoring()
            self.tearDown()
        }
        state.withLock { $0.buffer = AudioRingBuffer(capacity: 0) }
        Logger.audio.info("System audio capture stopped")
    }

    /// The buffered sound, oldest first, while capture keeps running.
    func snapshot() -> (samples: [Float], hasSound: Bool) {
        state.withLock { ($0.buffer.snapshot(), $0.buffer.hasSound) }
    }

    /// Time since the last frame that wasn't silent (or since the start, if there was none).
    var timeSinceSound: Duration {
        state.withLock { ContinuousClock.now - $0.lastSound }
    }

    // MARK: Pipeline

    /// Creates a mono tap of all processes but Construe, wraps it in a private aggregate device
    /// around the current output device, and starts reading from it.
    private func build() throws {
        let system = AudioHardwareSystem.shared
        let ownProcess = try system.process(for: getpid()).map { [$0.id] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: ownProcess)
        description.name = "Construe listening"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard let tap = try system.makeProcessTap(description: description) else {
            throw ListeningError.audioDevice(kAudioHardwareUnspecifiedError)
        }

        do {
            guard let output = try system.defaultOutputDevice else {
                throw ListeningError.audioDevice(kAudioHardwareBadDeviceError)
            }
            let outputUID = try output.uid
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Construe listening",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: try tap.uid, kAudioSubTapDriftCompensationKey: true],
                ],
                kAudioAggregateDeviceTapAutoStartKey: true,
            ]
            guard let device = try system.makeAggregateDevice(description: composition) else {
                throw ListeningError.audioDevice(kAudioHardwareUnspecifiedError)
            }

            do {
                // The tap and the aggregate's streams report the tap's own rate (48 kHz), but audio arrives
                // at the aggregate device's rate, which follows the output device (96 kHz on some USB
                // headsets). Reading it at the reported rate plays it back at half speed.
                let sampleRate = try device.nominalSampleRate
                let tapRate = try tap.format.mSampleRate
                Logger.audio.debug("""
                    Capture rate: \(sampleRate, privacy: .public) Hz (tap reports \(tapRate, privacy: .public) Hz), \
                    output device \(outputUID, privacy: .public)
                    """)

                setIOBufferSize(on: device, sampleRate: sampleRate)
                let fifo = SampleFIFO(capacity: Int(sampleRate * Self.fifoSeconds))
                guard let drain = Drain(fifo: fifo, sampleRate: sampleRate, queue: processingQueue, append: { [weak self] in
                    self?.append($0)
                }) else { throw ListeningError.audioConversionFailed }
                let procID = try makeIOProc(on: device, fifo: fifo)
                do {
                    try device.start(IOProcID: procID)
                } catch {
                    AudioDeviceDestroyIOProcID(device.id, procID)
                    drain.cancel()
                    throw error
                }
                let rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.scheduleRebuild(reason: "sample rate changed")
                }
                var address = Self.nominalSampleRateAddress
                AudioObjectAddPropertyListenerBlock(device.id, &address, controlQueue, rateListener)
                pipeline = Pipeline(
                    tap: tap, device: device, procID: procID, fifo: fifo, drain: drain, rateListener: rateListener)
            } catch {
                try? system.destroyAggregateDevice(device)
                throw error
            }
        } catch {
            try? system.destroyProcessTap(tap)
            throw Self.listeningError(error)
        }
    }

    /// Creates the IO proc on the HAL's real-time IO thread (no dispatch queue). It must never block:
    /// no allocation, locks, logging or Objective-C, and no reference counting, so it captures the
    /// FIFO unretained. That's safe because `tearDown()` destroys the proc before releasing the FIFO.
    private func makeIOProc(on device: AudioHardwareAggregateDevice, fifo: SampleFIFO) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { [unowned(unsafe) fifo] _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // The tap's stream comes after any input streams of the output device (e.g. a headset mic).
            // Reported formats have proven unreliable, so the channel count comes from the buffer itself.
            guard let tapBuffer = buffers.last, let data = tapBuffer.mData, tapBuffer.mNumberChannels > 0 else {
                fifo.markAlive()
                return
            }
            let channels = Int(tapBuffer.mNumberChannels)
            let frames = Int(tapBuffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            fifo.write(interleaved: data.assumingMemoryBound(to: Float.self), frames: frames, channels: channels)
        }
        guard status == noErr, let procID else { throw ListeningError.audioDevice(status) }
        return procID
    }

    /// Asks for `ioBufferFrames(sampleRate:)` per cycle, within the device's allowed range. Only our
    /// private aggregate device is affected, not playback. Failure just leaves the default size.
    private func setIOBufferSize(on device: AudioHardwareAggregateDevice, sampleRate: Double) {
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var frames = Self.ioBufferFrames(sampleRate: sampleRate)
        if AudioObjectGetPropertyData(device.id, &rangeAddress, 0, nil, &rangeSize, &range) == noErr {
            frames = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            device.id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        var actual: UInt32 = 0
        var actualSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device.id, &address, 0, nil, &actualSize, &actual)
        if status == noErr {
            Logger.audio.debug("IO buffer: \(actual, privacy: .public) frames")
        } else {
            Logger.audio.notice("Couldn't set the IO buffer size (error \(status, privacy: .public)), using \(actual, privacy: .public) frames")
        }
    }

    private func append(_ samples: UnsafeBufferPointer<Float>) {
        state.withLock { state in
            if state.buffer.append(samples) {
                state.lastSound = .now
            }
        }
    }

    /// Stops reading and destroys the IO proc, aggregate device and tap, in that order. The IO proc
    /// is gone before the pipeline (and with it the FIFO the proc writes to) is released.
    private func tearDown() {
        guard let pipeline else { return }
        self.pipeline = nil
        var address = Self.nominalSampleRateAddress
        AudioObjectRemovePropertyListenerBlock(pipeline.device.id, &address, controlQueue, pipeline.rateListener)
        try? pipeline.device.stop(IOProcID: pipeline.procID)
        AudioDeviceDestroyIOProcID(pipeline.device.id, pipeline.procID)
        pipeline.drain.cancel()
        try? AudioHardwareSystem.shared.destroyAggregateDevice(pipeline.device)
        try? AudioHardwareSystem.shared.destroyProcessTap(pipeline.tap)
    }

    /// Stops the pipeline now and recreates it once events have settled for `rebuildDelay`; each
    /// new event restarts the wait. The ring buffer is kept throughout.
    private func scheduleRebuild(reason: String) {
        pendingReasons.append(reason)
        // Stop reading right away, so no audio is read at a rate that may no longer be right.
        tearDown()
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        controlQueue.asyncAfter(deadline: .now() + Self.rebuildDelay, execute: work)
    }

    /// Recreates the pipeline on the current output device. Stops capture if that fails.
    private func rebuild() {
        let reasons = pendingReasons.joined(separator: ", ")
        pendingReasons = []
        pendingRebuild = nil
        Logger.audio.notice("Rebuilding system audio capture: \(reasons, privacy: .public)")
        lastRebuild = .now
        do {
            try build()
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        Logger.audio.error("System audio capture stopped: \(error.localizedDescription, privacy: .public)")
        stopMonitoring()
        tearDown()
        Task { @MainActor [onStop] in onStop(error) }
    }

    // MARK: Monitoring

    /// Watches for a new default output device and for stalled audio callbacks.
    private func startMonitoring() {
        var address = Self.defaultOutputDeviceAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild(reason: "default output device changed")
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener) == noErr {
            outputDeviceListener = listener
        }

        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        timer.resume()
        watchdog = timer
    }

    private func stopMonitoring() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        pendingReasons = []
        watchdog?.cancel()
        watchdog = nil
        if let listener = outputDeviceListener {
            var address = Self.defaultOutputDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
            outputDeviceListener = nil
        }
    }

    private func checkForStall() {
        // No pipeline also means a rebuild is pending, which is intentional.
        guard let pipeline else { return }
        let sinceCallback = pipeline.fifo.timeSinceLastWrite
        guard sinceCallback >= Self.stallTimeout else { return }
        // A rebuild that didn't bring callbacks back won't be retried endlessly.
        if let lastRebuild, ContinuousClock.now - lastRebuild < Self.stallTimeout * 3 {
            fail(ListeningError.audioStalled)
        } else {
            scheduleRebuild(reason: "no audio for \(sinceCallback)")
        }
    }

    private static var nominalSampleRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: Drain

    /// Empties the FIFO on a background queue: resamples to 16 kHz mono and hands the result to
    /// `append`. Also measures the delivered rate once, so a wrong sample rate shows in the log.
    private final class Drain {
        private static let interval = DispatchTimeInterval.milliseconds(50)

        private let fifo: SampleFIFO
        private let sampleRate: Double
        private let scratch: AVAudioPCMBuffer
        private let converter: PCMConverter
        private let append: (UnsafeBufferPointer<Float>) -> Void
        private let timer: DispatchSourceTimer
        // Used only on the drain's queue.
        private var measureStart: ContinuousClock.Instant?
        private var measuredFrames = 0
        private var measured = false
        private var loggedChannels = false

        init?(
            fifo: SampleFIFO, sampleRate: Double, queue: DispatchQueue,
            append: @escaping (UnsafeBufferPointer<Float>) -> Void
        ) {
            guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
                  let target = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32, sampleRate: AudioRingBuffer.sampleRate, channels: 1,
                      interleaved: false),
                  let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fifo.capacity)),
                  let converter = PCMConverter(from: format, to: target)
            else { return nil }
            self.fifo = fifo
            self.sampleRate = sampleRate
            self.scratch = scratch
            self.converter = converter
            self.append = append
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
            timer.setEventHandler { [weak self] in self?.run() }
            timer.resume()
        }

        func cancel() {
            timer.cancel()
        }

        private func run() {
            guard let channel = scratch.floatChannelData?[0] else { return }
            let count = fifo.read(into: channel, maxCount: Int(scratch.frameCapacity))
            let dropped = fifo.takeDroppedCount()
            if dropped > 0 {
                Logger.audio.error("Dropped \(dropped, privacy: .public) samples: processing fell behind")
            }
            if !loggedChannels, fifo.channels > 0 {
                loggedChannels = true
                Logger.audio.debug("Tap delivers \(self.fifo.channels, privacy: .public) channels")
            }
            measure(count)
            guard count > 0 else { return }

            scratch.frameLength = AVAudioFrameCount(count)
            do {
                let output = try converter.convert(scratch)
                if let samples = output.floatChannelData?[0] {
                    append(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
                }
            } catch {
                Logger.audio.error("Converting audio failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        private func measure(_ count: Int) {
            guard !measured else { return }
            guard let measureStart else {
                measureStart = .now
                return
            }
            measuredFrames += count
            let elapsed = ContinuousClock.now - measureStart
            guard elapsed >= .seconds(5) else { return }
            measured = true
            let rate = Double(measuredFrames) / (elapsed / .seconds(1))
            if abs(rate - sampleRate) / sampleRate > 0.05 {
                Logger.audio.error("""
                    Measured capture rate \(Int(rate), privacy: .public) frames/s doesn't match \
                    \(Int(self.sampleRate), privacy: .public) Hz; caught audio will play at the wrong speed
                    """)
            } else {
                Logger.audio.info("Measured capture rate: \(Int(rate), privacy: .public) frames/s")
            }
        }
    }

    // MARK: Helpers

    private func onControlQueue(_ body: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private static func listeningError(_ error: Error) -> Error {
        if let error = error as? AudioHardwareError {
            return ListeningError.audioDevice(error.error)
        }
        return error
    }
}
