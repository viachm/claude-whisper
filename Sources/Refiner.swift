import Foundation

/// Cleans up a transcript with Claude through the user's Claude Code login. Starting `claude -p`
/// takes longer than the model call itself, so the next process is started ahead of time and
/// waits for its message. Each process handles one dictation, so nothing carries over between them.
final class Refiner {
    private final class Worker {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        var buffer = Data()
        var finished = false
    }

    private static let timeout: TimeInterval = 10

    private var spare: Worker?
    private var spareModel: RefineModel?
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Starts a waiting process for `model` unless one is already there.
    func prepare(model: RefineModel) {
        if let spare, spare.process.isRunning, spareModel == model { return }
        reset()
        spare = spawn(model: model)
        spareModel = spare == nil ? nil : model
    }

    func reset() {
        if let spare, spare.process.isRunning { spare.process.terminate() }
        spare = nil
        spareModel = nil
    }

    /// Calls back on the main queue with the cleaned text, or nil when Claude failed or took too
    /// long; the caller then uses the transcript as it was. `keepWarm` starts the next process
    /// right away, for when every dictation is cleaned up.
    func refine(_ transcript: String, app: String?, model: RefineModel, keepWarm: Bool,
                completion: @escaping (String?) -> Void) {
        prepare(model: model)
        guard let worker = spare else { return completion(nil) }
        spare = nil
        spareModel = nil
        let started = Date()

        func finish(_ result: String?, _ note: String) {
            guard !worker.finished else { return }
            worker.finished = true
            worker.output.fileHandleForReading.readabilityHandler = nil
            try? worker.input.fileHandleForWriting.close()
            if worker.process.isRunning { worker.process.terminate() }
            Log.write("refine: \(note) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            completion(result)
        }

        worker.output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // At end of file the handler keeps firing with no data; once is enough.
            if chunk.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                guard !chunk.isEmpty else { return finish(nil, "claude exited without a result") }
                worker.buffer.append(chunk)
                while let newline = worker.buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: worker.buffer[..<newline], as: UTF8.self)
                    worker.buffer.removeSubrange(...newline)
                    switch RefinerProtocol.outcome(fromLine: line) {
                    case .text(let text): return finish(text, "\(transcript.count) → \(text.count) characters")
                    case .failed(let reason): return finish(nil, "failed: \(reason)")
                    case nil: continue
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { finish(nil, "timed out") }

        let message = RefinerProtocol.userMessage(transcript: transcript, app: app)
        do {
            try worker.input.fileHandleForWriting.write(contentsOf: Data(message.utf8))
        } catch {
            finish(nil, "could not write to claude: \(error)")
        }
        if keepWarm { DispatchQueue.main.async { [weak self] in self?.prepare(model: model) } }
    }

    private func spawn(model: RefineModel) -> Worker? {
        let worker = Worker()
        worker.process.executableURL = URL(fileURLWithPath: Preferences.shared.resolvedClaudePath)
        worker.process.arguments = RefinerProtocol.arguments(model: model)
        worker.process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        worker.process.environment = env
        worker.process.standardInput = worker.input
        worker.process.standardOutput = worker.output
        worker.process.standardError = FileHandle.nullDevice
        do {
            try worker.process.run()
            return worker
        } catch {
            Log.write("refine: could not start claude: \(error)")
            return nil
        }
    }
}
