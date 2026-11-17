import AVFoundation
import FluidAudio

/// Note Taker's speech model: NVIDIA's Parakeet TDT 0.6B v3 as post-trained into "Parakeet Ultra"
/// (CC-BY-4.0), run on the Neural Engine by FluidAudio. 25 European languages, Ukrainian among
/// them. Downloaded once, when asked, from Hugging Face into
/// ~/Library/Application Support/FluidAudio/Models; transcribing never leaves the Mac.
@MainActor
final class SpeechModel: ObservableObject {
    static let shared = SpeechModel()
    static let size = "610 MB"

    enum State: Equatable {
        case missing, downloading(Double), ready, failed(String)
    }

    @Published private(set) var state: State
    private var manager: AsrManager?

    /// Parakeet needs Apple silicon; Intel Macs keep Apple's recogniser.
    nonisolated static var isAvailable: Bool { SystemInfo.isAppleSilicon }

    private static var directory: URL { AsrModels.defaultCacheDirectory(for: .ultra) }

    private init() {
        state = AsrModels.modelsExist(at: Self.directory, version: .ultra) ? .ready : .missing
    }

    var isReady: Bool { state == .ready }

    /// Downloads the model (and prepares it for the Neural Engine); `done` runs once it is ready.
    func download(then done: (() -> Void)? = nil) {
        if case .downloading = state { return }
        state = .downloading(0)
        Log.write("note taker: downloading the speech model")
        let started = Date()
        Task {
            do {
                try await AsrModels.download(version: .ultra) { progress in
                    Task { @MainActor in
                        guard case .downloading = SpeechModel.shared.state else { return }
                        SpeechModel.shared.state = .downloading(progress.fractionCompleted)
                    }
                }
                state = .ready
                Log.write("note taker: speech model ready in \(Int(Date().timeIntervalSince(started))) s")
                done?()
            } catch {
                Log.write("note taker: speech model download failed: \(error)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// The model, loaded once for both sides of the call.
    func loaded() async throws -> AsrManager {
        if let manager { return manager }
        let models = try await AsrModels.load(from: Self.directory, version: .ultra)
        let manager = AsrManager(models: models)
        self.manager = manager
        return manager
    }
}

/// Live transcription of one audio source with Parakeet. Parakeet hears up to 15 seconds at a
/// time, so the audio is cut into utterances at pauses; each becomes a final line, and while one
/// is being spoken it is transcribed again every second or so as a guess.
final class ParakeetStream: NoteTranscriber, @unchecked Sendable {
    typealias Handler = (String, Double, Double, Bool) -> Void

    private let worker: ParakeetWorker
    private let converter = BufferConverter(to: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                              sampleRate: Double(UtteranceSegmenter.rate),
                                                              channels: 1, interleaved: false)!)
    private let lock = NSLock()
    private var incoming: [Float] = []
    private var total = 0
    private var loop: Task<Void, Never>?

    init(manager: AsrManager, language: String?, onResult: @escaping Handler) {
        worker = ParakeetWorker(manager: manager, language: language, onResult: onResult)
    }

    var seconds: Double { lock.withLock { Double(total) / Double(UtteranceSegmenter.rate) } }

    func start() async throws {
        loop = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self else { return }
                await self.worker.process(self.take())
            }
        }
    }

    /// From the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let out = converter.convert(buffer), let data = out.floatChannelData else { return }
        let count = Int(out.frameLength)
        lock.withLock {
            incoming.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
            total += count
        }
    }

    /// The language to keep to from now on (nil: let Parakeet guess).
    func setLanguage(_ code: String?) {
        Task { await worker.setLanguage(code) }
    }

    func finalizeSoFar() async {
        await worker.process(take())
        await worker.flush()
    }

    func finish(limit: Double = 3) async {
        loop?.cancel()
        let gate = OnceGate()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task {
                await self.finalizeSoFar()
                gate.run { done.resume() }
            }
            Task {
                try? await Task.sleep(for: .seconds(limit))
                gate.run {
                    Log.write("note taker: transcription did not finish within \(Int(limit)) s (parakeet)")
                    done.resume()
                }
            }
        }
    }

    private func take() -> [Float] {
        lock.withLock {
            defer { incoming = [] }
            return incoming
        }
    }
}

/// Cuts and transcribes one source's audio, one step at a time.
private actor ParakeetWorker {
    private var segmenter = UtteranceSegmenter()
    private let manager: AsrManager
    private var language: Language?
    private let onResult: ParakeetStream.Handler
    /// Where the last guess for the utterance in progress ended.
    private var guessedTo = 0
    private var failed = false

    init(manager: AsrManager, language: String?, onResult: @escaping ParakeetStream.Handler) {
        self.manager = manager
        self.language = language.flatMap(Language.init(rawValue:))
        self.onResult = onResult
    }

    func setLanguage(_ code: String?) { language = code.flatMap(Language.init(rawValue:)) }

    func process(_ samples: [Float]) async {
        for utterance in segmenter.append(samples) { await transcribe(utterance, final: true) }
        let rate = UtteranceSegmenter.rate
        if let current = segmenter.current, current.samples.count >= rate,
           current.end - guessedTo >= rate * 6 / 5 {
            guessedTo = current.end
            await transcribe(current, final: false)
        }
    }

    func flush() async {
        if let utterance = segmenter.flush() { await transcribe(utterance, final: true) }
    }

    private func transcribe(_ utterance: UtteranceSegmenter.Utterance, final: Bool) async {
        let rate = UtteranceSegmenter.rate
        var samples = utterance.samples
        if samples.count < rate { samples += [Float](repeating: 0, count: rate - samples.count) }
        do {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples, decoderState: &state, language: language)
            onResult(result.text, Double(utterance.start) / Double(rate), Double(utterance.end) / Double(rate), final)
        } catch {
            if !failed { Log.write("note taker: transcription failed: \(error)") }
            failed = true
        }
    }
}
