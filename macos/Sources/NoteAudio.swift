import AVFoundation
import CoreAudio
import Speech

/// The microphone, as buffers on an audio thread.
final class MicCapture {
    private let engine = AVAudioEngine()
    private var frames = 0
    private var lastReport = Date()

    func start(_ handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.measure(buffer)
            handler(buffer)
        }
        engine.prepare()
        try engine.start()
        Log.write("note taker: microphone at \(Int(format.sampleRate)) Hz \(format.channelCount) ch")
    }

    /// Logs every 30 s that microphone audio arrives, next to the call audio's line.
    private func measure(_ buffer: AVAudioPCMBuffer) {
        frames += Int(buffer.frameLength)
        let seconds = Date().timeIntervalSince(lastReport)
        if seconds >= 30 {
            Log.write("note taker: microphone \(Int(Double(frames) / seconds)) frames/s")
            frames = 0
            lastReport = Date()
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

struct AudioError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) failed (\(status))" }
}

/// Everything the Mac plays (the other people on a call), through a Core Audio process tap. The
/// first start asks for the "System Audio Recording" permission; until it is given, the buffers
/// are silent. Claude Whisper's own sounds are left out.
///
/// The tap runs on an aggregate device clocked by the output device, so when the output device
/// changes, or changes its sample rate (Bluetooth headphones switching to their call mode when a
/// call starts), it is rebuilt; otherwise the call audio would stop arriving.
@available(macOS 14.2, *)
final class SystemAudioCapture {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Claude Whisper system audio", qos: .userInitiated)
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private var watchedOutput = AudioObjectID(kAudioObjectUnknown)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var restartWork: DispatchWorkItem?
    /// Called on the main queue after the tap was rebuilt for a new output device.
    var onRestart: (() -> Void)?
    /// For the log: buffers and the loudest sample since the last line.
    private var buffers = 0
    private var frames = 0
    private var peak: Float = 0
    private var lastReport = Date()

    func start(_ handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.handler = handler
        try startTap()
        watch()
    }

    private func startTap() throws {
        guard let handler else { return }
        let own = Self.processObject(pid: getpid()).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        description.uuid = UUID()
        description.name = "Claude Whisper Note Taker"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tap))

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.address(kAudioTapPropertyFormat)
        try check("reading the tap format", AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd))
        let tapRate = asbd.mSampleRate

        let output = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Claude Whisper Note Taker",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check("AudioHardwareCreateAggregateDevice", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
        // The aggregate runs at the output device's rate and hands the tap's audio over resampled
        // to it: 16 kHz for Bluetooth headphones in call mode, while the tap itself says 48 kHz.
        // Taking the tap's rate would play the call 3x fast to the transcriber.
        let deviceRate = Self.sampleRate(device)
        if deviceRate > 0 { asbd.mSampleRate = deviceRate }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw AudioError(step: "tap format", status: -1) }
        try check("AudioDeviceCreateIOProcIDWithBlock", AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            // Only valid during this call: the handler converts (copies) it before returning.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            self?.measure(buffer)
            handler(buffer)
        })
        try check("AudioDeviceStart", AudioDeviceStart(device, proc))
        Log.write("note taker: call audio from \(Self.deviceName(Self.defaultOutput())) at \(Int(Self.sampleRate(Self.defaultOutput()))) Hz, tap \(Int(tapRate)) Hz, read at \(Int(format.sampleRate)) Hz \(format.channelCount) ch")
    }

    /// Logs every 30 s whether call audio arrives and how loud it is: silence for a long time
    /// while someone talks points at the permission or the output device.
    private func measure(_ buffer: AVAudioPCMBuffer) {
        buffers += 1
        frames += Int(buffer.frameLength)
        if let data = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for i in stride(from: 0, to: Int(buffer.frameLength), by: 4) { peak = max(peak, abs(data[channel][i])) }
            }
        }
        if Date().timeIntervalSince(lastReport) >= 30 {
            let seconds = Date().timeIntervalSince(lastReport)
            Log.write("note taker: call audio \(buffers) buffers, \(Int(Double(frames) / seconds)) frames/s, peak \(String(format: "%.3f", peak))")
            buffers = 0
            frames = 0
            peak = 0
            lastReport = Date()
        }
    }

    /// Rebuilds the tap when the default output device, or its sample rate, changes.
    private func watch() {
        let output = Self.defaultOutput()
        watchedOutput = output
        listen(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDefaultOutputDevice))
        if output != kAudioObjectUnknown {
            listen(output, Self.address(kAudioDevicePropertyNominalSampleRate))
            listen(output, Self.address(kAudioDevicePropertyDeviceIsAlive))
        }
    }

    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputChanged() }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func unwatch() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = []
    }

    /// Coalesced: a device switch fires several of these at once.
    private func outputChanged() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restart() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func restart() {
        guard handler != nil else { return }
        Log.write("note taker: output device changed, restarting call audio")
        stopTap()
        unwatch()
        do {
            try startTap()
        } catch {
            Log.write("note taker: could not restart call audio: \(error)")
        }
        watch()
        onRestart?()
    }

    func stop() {
        restartWork?.cancel()
        handler = nil
        unwatch()
        stopTap()
    }

    private func stopTap() {
        if device != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(device, proc)
                AudioDeviceDestroyIOProcID(device, proc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw AudioError(step: step, status: status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Core Audio's object for a process, which exists once the process has used audio.
    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutput() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func sampleRate(_ device: AudioDeviceID) -> Double {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

    private static func deviceName(_ device: AudioDeviceID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "unknown device" }
        return name.takeRetainedValue() as String
    }

    private static func defaultOutputUID() throws -> String {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        let device = defaultOutput()
        if device == kAudioObjectUnknown { throw AudioError(step: "finding the output device", status: -1) }
        var status: OSStatus
        var size: UInt32
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw AudioError(step: "reading the output device", status: status) }
        return uid.takeRetainedValue() as String
    }
}

/// Converts (and so copies) audio buffers to one format, keeping resampler state between them so
/// a stream of buffers stays seamless. Used from one audio thread at a time.
final class BufferConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to output: AVAudioFormat) {
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.write("note taker: audio conversion failed: \(error)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }
}

/// Saves one audio source as a small AAC file (mono, 22 kHz, 32 kbit/s: about 14 MB an hour),
/// writing on a queue of its own so the audio thread never waits for the disk.
final class AudioTrackWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private let converter: BufferConverter
    private let queue = DispatchQueue(label: "Claude Whisper audio writer")

    init(url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        converter = BufferConverter(to: file.processingFormat)
    }

    /// From the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let out = converter.convert(buffer) else { return }
        queue.async { [weak self] in
            do {
                try self?.file?.write(from: out)
            } catch {
                Log.write("note taker: could not write audio: \(error)")
                self?.file = nil
            }
        }
    }

    /// Finishes the file once what is queued is written. Call after the audio has stopped.
    func close() {
        queue.sync { file = nil }
    }
}

/// Live, on-device transcription of one audio source. Buffers go in from an audio thread; text
/// comes out (on no particular thread) as guesses that are later replaced by a final result for
/// the same stretch of audio. Times are seconds of the audio given so far.
protocol NoteTranscriber: AnyObject, Sendable {
    /// Seconds of audio handed over so far: the time the next result will start at.
    var seconds: Double { get }
    func start() async throws
    func append(_ buffer: AVAudioPCMBuffer)
    /// Turns what has been heard so far into final results, for a pause.
    func finalizeSoFar() async
    /// Ends the input and waits for the last final results, for at most `limit` seconds.
    func finish(limit: Double) async
}

/// Transcription with Apple's SpeechTranscriber, for languages Parakeet doesn't have.
@available(macOS 26.0, *)
final class SpeechStream: NoteTranscriber, @unchecked Sendable {
    /// Text, start and end in seconds of audio given, and whether it is final.
    typealias Handler = (String, Double, Double, Bool) -> Void

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let onResult: Handler
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: BufferConverter?
    private var results: Task<Void, Never>?
    /// Seconds of audio handed to the transcriber so far: the time its next result will start at.
    private(set) var seconds: Double = 0

    init(locale: Locale, onResult: @escaping Handler) {
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        self.onResult = onResult
    }

    /// The languages that can be transcribed on this Mac, as BCP 47 codes.
    static func supportedLocales() async -> [String] {
        await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
    }

    /// Downloads the language's model if macOS doesn't have it yet; `downloading` is called first.
    func prepare(downloading: () -> Void) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            downloading()
            try await request.downloadAndInstall()
        }
    }

    func start() async throws {
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        results = Task { [transcriber, onResult] in
            do {
                for try await result in transcriber.results {
                    onResult(String(result.text.characters), result.range.start.seconds,
                             result.range.end.seconds, result.isFinal)
                }
            } catch {
                Log.write("note taker: transcription stopped: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// From the audio thread: converts the buffer to what the transcriber wants and queues it.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let format, let continuation else { return }
        if converter?.output != format { converter = BufferConverter(to: format) }
        guard let out = converter?.convert(buffer) else { return }
        seconds += Double(out.frameLength) / format.sampleRate
        continuation.yield(AnalyzerInput(buffer: out))
    }

    /// Turns what has been heard so far into final results, for a pause: with no more audio
    /// coming, the transcriber would otherwise keep the last words as a guess.
    func finalizeSoFar() async {
        do {
            try await analyzer.finalize(through: nil)
        } catch {
            Log.write("note taker: finalizing failed: \(error)")
        }
    }

    /// Ends the input and waits for the last final results, for at most `limit` seconds: on short
    /// notes the analyzer sometimes never finishes, which used to leave the note unsaved.
    func finish(limit: Double = 3) async {
        let gate = OnceGate()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task {
                await self.finishNow()
                gate.run { done.resume() }
            }
            Task {
                try? await Task.sleep(for: .seconds(limit))
                gate.run {
                    Log.write("note taker: transcription did not finish within \(Int(limit)) s (\(self.stage))")
                    self.results?.cancel()
                    done.resume()
                }
            }
        }
    }

    /// How far finish() got, for the log when it gives up.
    private var stage = "not finishing"

    private func finishNow() async {
        continuation?.finish()
        continuation = nil
        stage = "finalizing"
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.write("note taker: finishing transcription failed: \(error)")
        }
        stage = "waiting for the last results"
        await results?.value
        stage = "done"
    }
}

/// Runs the first of several racing callbacks and ignores the rest.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ action: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { action() }
    }
}
