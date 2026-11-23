import AppKit
import AVFoundation
import SwiftUI

/// Note Taker: transcribes a call as a dialog, your microphone as "Me" and everything the Mac
/// plays as "Them", on-device with the Parakeet model or, for other languages, Apple's speech
/// recogniser (not Claude: Claude Code's voice mode only listens while a key is held, and only to
/// the microphone). Claude, through the
/// user's Claude Code login, titles and summarizes a note when it stops and answers questions
/// about it. Each recording is saved as it goes; the window shows the live one or a saved one.
@available(macOS 26.0, *)
@MainActor
final class NoteTaker: ObservableObject {
    @Published private(set) var note: Note?
    @Published private(set) var pending: [Speaker: NoteSegment] = [:]
    /// The latest words still being recognised; `pending` shows them at most once a second, since
    /// every change redraws the whole transcript.
    private var heard: [Speaker: NoteSegment] = [:]
    private var showHeard: Task<Void, Never>?
    @Published private(set) var isRecording = false
    /// Recording, but with the microphone and the call audio off until `resume()`.
    @Published private(set) var isPaused = false
    /// The call seems to be over (see CallEndDetector): the menu bar app asks whether to stop.
    @Published private(set) var callSeemsOver = false
    private var callEnd = CallEndDetector(now: Date())
    private var callEndWatch: Task<Void, Never>?
    /// Why the call seems over, for the notification.
    private(set) var callEndReason = ""
    /// The other apps last seen recording from the microphone (logged when it changes).
    private var micApps: Set<String> = []
    private var pausedAt: Date?
    /// A problem or a slow step to show in the window, such as a model download.
    @Published private(set) var status: String?
    /// Notes Claude is titling and summarizing right now.
    @Published private(set) var summarizing: Set<UUID> = []
    /// Notes whose transcript Claude is cleaning up right now.
    @Published private(set) var improving: Set<UUID> = []
    /// Notes whose voices couldn't be told apart (no model download, say): cleaned up without them.
    private var voicesFailed: Set<UUID> = []

    static let improveKey = "noteTakerImprove"
    /// Whether Claude cleans up the transcript after a call; on unless turned off in Settings.
    static var improvesTranscript: Bool { UserDefaults.standard.object(forKey: improveKey) as? Bool ?? true }

    var isImproving: Bool { note.map { improving.contains($0.id) } ?? false }
    @Published private(set) var asking = false
    /// The question Claude is answering right now, shown at once.
    @Published private(set) var askingQuestion: String?

    let store: NoteStore
    private let workspace: URL
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var writers: [AudioTrackWriter] = []

    static let keepAudioKey = "noteTakerKeepAudio"
    /// Whether notes keep their audio, so it can be listened to; on unless turned off in Settings.
    static var keepsAudio: Bool { UserDefaults.standard.object(forKey: keepAudioKey) as? Bool ?? true }
    private var streams: [Speaker: any NoteTranscriber] = [:]
    /// A note waiting for the speech model to download before it records.
    @Published private(set) var awaitingModel: Note?
    /// Per source, from which transcriber time (seconds of audio it was given) which offset
    /// applies: the transcriber's times count audio only, so the offset is the time from the
    /// note's start to the first buffer, and grows by each pause.
    private var offsets: [Speaker: [(from: Double, offset: Double)]] = [:]
    /// Settles the language of a note recorded in Automatic from its first lines.
    private var detector: LanguageDetector?
    private var run = 0

    /// Apple's recogniser's language, chosen in Settings on Macs without Parakeet (Intel).
    static let localeKey = "noteTakerLocale"
    /// The language a new note is transcribed in (see NoteLanguage).
    static var language: String {
        SpeechModel.isAvailable ? NoteLanguage.current : UserDefaults.standard.string(forKey: localeKey) ?? "en-US"
    }

    private static func needsParakeet(_ language: String) -> Bool {
        SpeechModel.isAvailable && NoteLanguage.usesParakeet(language)
    }

    init(store: NoteStore, workspace: URL) {
        self.store = store
        self.workspace = workspace
    }

    var turns: [NoteTurn] { Note.turns(note?.segments ?? [], pending: Array(pending.values)) }

    /// Turns and pauses, with the current pause (if any) at the end.
    var items: [NoteItem] {
        var pauses = note?.pauses ?? []
        if let pausedAt, let started = note?.started { pauses.append(NotePause(start: pausedAt.timeIntervalSince(started))) }
        return Note.items(note?.segments ?? [], pending: Array(pending.values), pauses: pauses)
    }

    /// Time recorded by `date`, pauses left out, for the live timer.
    func recorded(at date: Date) -> TimeInterval {
        guard let note else { return 0 }
        let paused = (note.pauses ?? []).reduce(0) { $0 + ($1.duration ?? 0) }
        let current = pausedAt.map { date.timeIntervalSince($0) } ?? 0
        return date.timeIntervalSince(note.started) - paused - current
    }

    var transcriptText: String { note?.plainText(pending: Array(pending.values)) ?? "" }

    var isSummarizing: Bool { note.map { summarizing.contains($0.id) } ?? false }

    // MARK: Recording

    /// Starts a new note.
    func start() {
        guard !isRecording else { return }
        record(Note(started: Date(), locale: Self.language))
    }

    /// Records more into the note shown (a new one if there is none); the time since it stopped
    /// shows as a pause, and stopping again rewrites the summary.
    func continueNote() {
        guard !isRecording else { return }
        guard var note, let ended = note.ended else { return start() }
        note.pauses = (note.pauses ?? []) + [NotePause(start: ended.timeIntervalSince(note.started),
                                                       duration: Date().timeIntervalSince(ended))]
        note.ended = nil
        note.locale = Self.continuing(note)
        record(note)
    }

    /// The language more recording of a note is transcribed in: a note recorded with Apple's
    /// recogniser in a language Parakeet has (all notes before Parakeet) moves to the language
    /// chosen now, so it doesn't go back to the recogniser that didn't know that language.
    private static func continuing(_ note: Note) -> String {
        guard SpeechModel.isAvailable, !NoteLanguage.usesParakeet(note.locale),
              NoteLanguage.appleOnly([note.locale]).isEmpty else { return note.locale }
        return language
    }

    /// Whether Start (or Continue) has to download the speech model first.
    var needsModel: Bool {
        guard SpeechModel.isAvailable, !SpeechModel.shared.isReady else { return false }
        let language = note.map { $0.ended == nil ? $0.locale : Self.continuing($0) } ?? Self.language
        return NoteLanguage.usesParakeet(language)
    }

    private func record(_ note: Note) {
        // The first time, the speech model has to be downloaded: the window asks.
        if Self.needsParakeet(note.locale), !SpeechModel.shared.isReady {
            awaitingModel = note
            return
        }
        awaitingModel = nil
        run += 1
        let run = run
        let locale = note.locale
        self.note = note
        clearPending()
        offsets = [:]
        detector = locale == NoteLanguage.automatic && Self.needsParakeet(locale) ? LanguageDetector() : nil
        status = nil
        isRecording = true
        isPaused = false
        pausedAt = nil
        Log.write("note taker: \(note.segments.isEmpty ? "started" : "continued") (\(locale))")
        watchCallEnd()
        Task {
            do {
                try await begin(run: run, language: locale)
            } catch {
                Log.write("note taker: could not start: \(error)")
                status = "Could not start: \(error.localizedDescription)"
                stop()
            }
        }
    }

    /// Downloads the speech model, then records the note that was waiting for it.
    func downloadModel() {
        SpeechModel.shared.download { [weak self] in
            guard let self, let note = awaitingModel else { return }
            record(note)
        }
    }

    /// "Not Now" on the download prompt.
    func cancelAwaitingModel() { awaitingModel = nil }

    private func begin(run: Int, language: String) async throws {
        for speaker in [Speaker.me, .them] {
            let handler: (String, Double, Double, Bool) -> Void = { [weak self] text, start, end, final in
                Task { @MainActor in self?.received(speaker, run: run, text: text, start: start, end: end, final: final) }
            }
            let stream: any NoteTranscriber
            if Self.needsParakeet(language) {
                let manager = try await SpeechModel.shared.loaded()
                stream = ParakeetStream(manager: manager, language: NoteLanguage.hint(language), onResult: handler)
            } else {
                let apple = SpeechStream(locale: Locale(identifier: language), onResult: handler)
                try await apple.prepare { status = "Downloading the speech model for \(language)…" }
                stream = apple
            }
            try await stream.start()
            streams[speaker] = stream
        }
        guard self.run == run, isRecording, !isPaused else { return }
        status = nil
        try startCapture()
    }

    /// Starts the microphone and the call audio, feeding the transcribers.
    private func startCapture() throws {
        guard let note else { return }
        let started = note.started
        func mark(_ speaker: Speaker) {
            let streamTime = streams[speaker]?.seconds ?? 0
            offsets[speaker, default: []].append((streamTime, Date().timeIntervalSince(started) - streamTime))
        }
        let index = note.recordings?.count ?? 0
        func writer(_ speaker: Speaker) -> AudioTrackWriter? {
            guard Self.keepsAudio else { return nil }
            let url = store.audioFile(note.id, index: index, speaker: speaker)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                return try AudioTrackWriter(url: url)
            } catch {
                Log.write("note taker: can't save audio: \(error)")
                return nil
            }
        }
        let recordingStart = Date().timeIntervalSince(started)
        var saved: [Speaker] = []

        let mic = MicCapture()
        let micStream = streams[.me]
        let micWriter = writer(.me)
        try mic.start { buffer in
            micStream?.append(buffer)
            micWriter?.append(buffer)
        }
        self.mic = mic
        mark(.me)
        if let micWriter { writers.append(micWriter); saved.append(.me) }

        let system = SystemAudioCapture()
        let systemStream = streams[.them]
        let systemWriter = writer(.them)
        do {
            try system.start { buffer in
                systemStream?.append(buffer)
                systemWriter?.append(buffer)
            }
            self.system = system
            mark(.them)
            system.onRestart = { mark(.them) }
            if let systemWriter { writers.append(systemWriter); saved.append(.them) }
        } catch {
            systemWriter?.close()
            try? FileManager.default.removeItem(at: store.audioFile(note.id, index: index, speaker: .them))
            Log.write("note taker: no system audio: \(error)")
            status = "Can't hear the call audio (\(error.localizedDescription)); only your microphone is transcribed."
        }
        if !saved.isEmpty {
            self.note?.recordings = (note.recordings ?? []) + [NoteRecording(index: index, start: recordingStart, speakers: saved)]
        }
    }

    private func stopCapture() {
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        for writer in writers { writer.close() }
        writers = []
    }

    /// Turns the microphone and the call audio off; what was heard so far becomes final.
    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pausedAt = Date()
        stopCapture()
        Log.write("note taker: paused")
        let streams = Array(self.streams.values)
        Task { for stream in streams { await stream.finalizeSoFar() } }
    }

    func resume() {
        guard isRecording, isPaused else { return }
        closePause()
        isPaused = false
        callEnd.resumed(now: Date())
        Log.write("note taker: resumed")
        do {
            try startCapture()
        } catch {
            Log.write("note taker: could not resume: \(error)")
            status = "Could not resume: \(error.localizedDescription)"
            stop()
        }
    }

    /// Records the pause in the note.
    private func closePause() {
        guard let pausedAt, let started = note?.started else { return }
        note?.pauses = (note?.pauses ?? []) + [NotePause(start: pausedAt.timeIntervalSince(started),
                                                          duration: Date().timeIntervalSince(pausedAt))]
        self.pausedAt = nil
        save()
    }

    private func received(_ speaker: Speaker, run: Int, text: String, start: Double, end: Double, final: Bool) {
        guard run == self.run, note != nil else { return }
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A lone "." or "9" from a cough or a click is not a line.
        if text.unicodeScalars.filter(CharacterSet.letters.contains).count < 2 { text = "" }
        let offset = offsets[speaker]?.last { $0.from <= start + 0.05 }?.offset ?? offsets[speaker]?.first?.offset ?? 0
        // Speech, not a lone "Uh" or "Mm" the recogniser makes of noise in the call audio.
        if text.unicodeScalars.filter(CharacterSet.letters.contains).count >= 6 {
            callEnd.heard(at: Date())
            // The others talk again: the call was not over after all. Not your own voice, which goes
            // on in the room after a call, and not once the call app has let go of the microphone.
            if callSeemsOver, speaker == .them, final, callEndReason != CallEndDetector.micReleased { keepRecording() }
        }
        let segment = NoteSegment(speaker: speaker, start: start + offset,
                                  end: end.isFinite && end >= start ? end + offset : nil, text: text)
        if final {
            heard[speaker] = nil
            pending[speaker] = nil
            guard !text.isEmpty else { return }
            note?.segments.append(segment)
            save()
            if let code = detector?.add(text) {
                detector = nil
                Log.write("note taker: the call is in \(code)")
                switchLanguage(code)
            }
        } else {
            heard[speaker] = segment
            guard showHeard == nil else { return }
            showHeard = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.showHeard = nil
                self.pending = self.heard
            }
        }
    }

    /// Every 5 seconds while recording, whether the call seems over.
    private func watchCallEnd() {
        callEnd = CallEndDetector(now: Date())
        callSeemsOver = false
        micApps = []
        // Asked on the first recording, so the question doesn't come up as a call ends.
        CallEndNotice.requestPermission()
        callEndWatch?.cancel()
        callEndWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isRecording, !Task.isCancelled else { return }
                guard !self.isPaused else { continue }
                let apps = Microphone.otherAppsRecording()
                if let apps, apps != self.micApps {
                    Log.write("note taker: recording from the microphone: \(apps.isEmpty ? "no other app" : apps.sorted().joined(separator: ", "))")
                    self.micApps = apps
                }
                if let reason = self.callEnd.check(callAppRecording: apps.map { !$0.isEmpty }, now: Date()) {
                    Log.write("note taker: the call seems over (\(reason))")
                    self.callEndReason = reason
                    self.callSeemsOver = true
                }
            }
        }
    }

    private func endCallWatch() {
        callEndWatch?.cancel()
        callEndWatch = nil
        callSeemsOver = false
    }

    /// "Keep Recording" on the call-over prompt.
    func keepRecording() {
        callSeemsOver = false
        callEnd.keep(now: Date())
    }

    private func clearPending() {
        showHeard?.cancel()
        showHeard = nil
        heard = [:]
        pending = [:]
    }

    /// Stops listening; the last words still being recognised are added when they are final,
    /// then Claude titles and summarizes the note.
    func stop() {
        guard isRecording else { return }
        Log.write("note taker: stopping")
        endCallWatch()
        closePause()
        isRecording = false
        isPaused = false
        stopCapture()
        let streams = self.streams
        self.streams = [:]
        let run = run
        Task {
            await Self.finish(streams.values)
            // Let the final results queued on the main actor land first.
            try? await Task.sleep(for: .milliseconds(200))
            guard run == self.run, note != nil else { return }
            keepPending()
            self.note?.ended = Date()
            save()
            guard let note else { return }
            Log.write("note taker: stopped, \(note.segments.count) lines")
            if !note.segments.isEmpty {
                if Self.improvesTranscript { improve(thenSummarize: true) } else { summarize() }
            }
        }
    }

    /// Quitting while recording: what was heard so far becomes final and is saved; Claude's
    /// clean-up and summary wait until the note is next opened. `done` runs on the main actor.
    func stopForQuit(_ done: @escaping () -> Void) {
        guard isRecording else { return done() }
        Log.write("note taker: stopping for quit")
        endCallWatch()
        closePause()
        isRecording = false
        isPaused = false
        stopCapture()
        let streams = self.streams
        self.streams = [:]
        let run = run
        Task {
            await Self.finish(streams.values)
            try? await Task.sleep(for: .milliseconds(200))
            if run == self.run, note != nil {
                keepPending()
                note?.ended = Date()
                if note?.segments.isEmpty == false { note?.summaryPending = true }
                save()
                Log.write("note taker: stopped for quit, \(note?.segments.count ?? 0) lines")
            }
            done()
        }
    }

    /// Finishes every stream at once; each gives up after a few seconds (see SpeechStream.finish).
    private static func finish(_ streams: some Collection<any NoteTranscriber>) async {
        await withTaskGroup(of: Void.self) { group in
            for stream in streams { group.addTask { await stream.finish(limit: 3) } }
        }
    }

    /// Switches the language: for new notes, and for the one recording if Parakeet hears it.
    func setLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: NoteLanguage.key)
        // Chosen by hand: Automatic guesses again, a language is kept.
        detector = code == NoteLanguage.automatic ? LanguageDetector() : nil
        switchLanguage(code)
        Log.write("note taker: language \(code)")
    }

    /// Keeps the note recording to a language from now on (Settings stay as they are).
    private func switchLanguage(_ code: String) {
        guard isRecording, let note, Self.needsParakeet(note.locale), Self.needsParakeet(code) else { return }
        self.note?.locale = code
        for stream in streams.values { (stream as? ParakeetStream)?.setLanguage(NoteLanguage.hint(code)) }
        save()
    }

    /// Whether the language of the note recording can be switched (between Parakeet's languages).
    var canSwitchLanguage: Bool { isRecording && note.map { Self.needsParakeet($0.locale) } == true }

    /// Words still shown as a guess when the transcriber stopped answering are kept as they are.
    private func keepPending() {
        let guesses = heard.values.filter { !$0.text.isEmpty }
        if !guesses.isEmpty { note?.segments += guesses }
        clearPending()
    }

    /// Shows a saved note (stopping a recording first).
    func open(_ saved: Note) {
        stop()
        // Opening another note drops a download prompt left from an earlier Start.
        awaitingModel = nil
        run += 1
        pausedAt = nil
        note = saved
        clearPending()
        status = nil
        if saved.summaryPending == true {
            note?.summaryPending = nil
            save()
            if !saved.segments.isEmpty {
                if Self.improvesTranscript { improve(thenSummarize: true) } else { summarize() }
            }
        }
    }

    // MARK: Editing

    func rename(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note != nil, (name.isEmpty ? nil : name) != note?.name else { return }
        // Clearing the field goes back to Claude's title.
        note?.name = name.isEmpty || name == note?.title ? nil : name
        save()
    }

    func deleteNote() {
        guard let id = note?.id else { return }
        stop()
        run += 1
        store.delete(id)
        note = nil
        clearPending()
    }

    // MARK: Claude

    /// Asks Claude to clean up the transcript of the note shown and tell the other people apart,
    /// then (after a call) to summarize the cleaned-up version.
    /// After a call, only the records not yet improved go to Claude (with the improved ones
    /// before them for context); `again` improves the whole transcript anew.
    /// `given`: the note to improve when it may no longer be the one shown.
    func improve(_ given: Note? = nil, thenSummarize: Bool = false, again: Bool = false) {
        guard let note = given ?? note, !note.segments.isEmpty, !improving.contains(note.id) else { return }
        let id = note.id
        // First tell the voices in the call audio apart, so Claude labels people by voice.
        if !voicesFailed.contains(id), VoiceSeparation.needed(for: note, store: store) {
            improving.insert(id)
            let store = store
            let started = Date()
            Task {
                let result = await Task.detached { try await VoiceSeparation.voices(of: note, store: store) }.result
                improving.remove(id)
                switch result {
                case .success(let voices):
                    Log.write("note taker: told \(Set(voices.map(\.voice)).count) voices apart in \(Int(Date().timeIntervalSince(started))) s")
                    update(id) {
                        $0.voices = voices
                        $0.voicedRecordings = $0.recordings?.count
                    }
                case .failure(let error):
                    Log.write("note taker: could not tell the voices apart: \(error.localizedDescription)")
                    voicesFailed.insert(id)
                }
                let latest = self.note?.id == id ? self.note : store.notes.first { $0.id == id }
                if let latest { improve(latest, thenSummarize: thenSummarize, again: again) }
            }
            return
        }
        let records = again ? note.records : note.unimproved
        guard !records.isEmpty else {
            if thenSummarize { summarize() }
            return
        }
        let earlier = again ? [] : note.lines(before: records[0].id)
        improving.insert(id)
        let started = Date()
        NoteClaude.run(arguments: NoteImproveProtocol.arguments(model: .current),
                       input: NoteImproveProtocol.input(records, earlier: earlier, parts: note.voiceParts),
                       directory: workspace, timeout: 600) { [weak self] output in
            guard let self else { return }
            improving.remove(id)
            switch output.map(NoteImproveProtocol.parse) ?? .failure(SummaryError(reason: "Claude didn't answer")) {
            case .success(let parsed):
                let improved = NoteImproveProtocol.improved(parsed, records: records)
                Log.write("note taker: improved \(improved.count) of \(records.count) records in \(Int(Date().timeIntervalSince(started))) s")
                update(id) { note in
                    var all = again ? [:] : note.improved ?? [:]
                    var lengths = again ? [:] : note.improvedLengths ?? [:]
                    for record in records where improved[record.id.uuidString] != nil {
                        all[record.id.uuidString] = improved[record.id.uuidString]
                        lengths[record.id.uuidString] = record.text.count
                    }
                    note.improved = all
                    note.improvedLengths = lengths
                }
            case .failure(let error):
                Log.write("note taker: improving failed: \(error.reason)")
                if self.note?.id == id { status = "Couldn't improve the transcript: \(error.reason)" }
            }
            if thenSummarize, self.note?.id == id { summarize() }
        }
    }

    /// Asks Claude for a title and a summary of the note shown.
    func summarize() {
        guard let note, !note.segments.isEmpty, !summarizing.contains(note.id) else { return }
        let id = note.id
        summarizing.insert(id)
        let started = Date()
        NoteClaude.run(arguments: NoteSummaryProtocol.arguments(model: .current),
                       input: NoteSummaryProtocol.input(transcript: note.transcript, language: note.locale), directory: workspace) { [weak self] output in
            guard let self else { return }
            summarizing.remove(id)
            switch output.map(NoteSummaryProtocol.parse) ?? .failure(SummaryError(reason: "Claude didn't answer")) {
            case .success(let result):
                Log.write("note taker: summary in \(Int(Date().timeIntervalSince(started))) s")
                update(id) {
                    $0.title = result.title
                    $0.summary = result.summary
                }
            case .failure(let error):
                Log.write("note taker: summary failed: \(error.reason)")
                if self.note?.id == id { status = "Couldn't write the summary: \(error.reason)" }
            }
        }
    }

    /// Asks Claude a question about the note shown, such as "What did I miss?".
    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note, !question.isEmpty, !asking else { return }
        let id = note.id
        // Lines still being recognised count too: "what did I miss" is about right now.
        let transcript = isRecording
            ? Note.turns(note.segments, pending: Array(pending.values))
                .map { "\($0.speaker.label): \([$0.text, $0.pending].filter { !$0.isEmpty }.joined(separator: " "))" }
                .joined(separator: "\n")
            : note.transcript
        asking = true
        askingQuestion = question
        NoteClaude.run(arguments: NoteAskProtocol.arguments(model: .current),
                       input: NoteAskProtocol.input(transcript: transcript, question: question),
                       directory: workspace, timeout: 90) { [weak self] output in
            guard let self else { return }
            asking = false
            askingQuestion = nil
            let answer: String
            switch output.map(NoteAskProtocol.parse) ?? .failure(SummaryError(reason: "Claude didn't answer")) {
            case .success(let text): answer = text
            case .failure(let error):
                Log.write("note taker: question failed: \(error.reason)")
                answer = "Couldn't get an answer: \(error.reason)"
            }
            update(id) { $0.answers = ($0.answers ?? []) + [NoteAnswer(question: question, answer: answer)] }
        }
    }

    /// Changes a note whether or not it is still the one shown.
    private func update(_ id: UUID, _ change: (inout Note) -> Void) {
        if note?.id == id {
            change(&note!)
            save()
        } else if var saved = store.notes.first(where: { $0.id == id }) {
            change(&saved)
            try? store.save(saved)
        }
    }

    private func save() {
        guard let note, !note.segments.isEmpty || note.name != nil else { return }
        do {
            try store.save(note)
        } catch {
            Log.write("note taker: could not save: \(error)")
            status = "Could not save the note: \(error.localizedDescription)"
        }
    }
}

/// The Note Taker window: a third of the screen on its right edge, top to bottom, an ordinary
/// window that goes behind others when you click them. Closing it only hides it: a recording goes
/// on, with a red dot on the menu bar icon.
@available(macOS 26.0, *)
@MainActor
final class NoteTakerWindow: NSObject, NSWindowDelegate {
    let taker: NoteTaker
    /// Owned here, not by the view, so closing the panel can stop it.
    let player = NotePlayer()
    private var panel: NSPanel?

    init(taker: NoteTaker) {
        self.taker = taker
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !(panel.contentView is NSHostingView<NoteTakerView>) { attachView(to: panel) }
        if !panel.isVisible, let screen = NSScreen.main {
            let area = screen.visibleFrame
            // 40% of the screen at first; a width the user dragged to is kept.
            let saved = UserDefaults.standard.double(forKey: "noteTakerWidth")
            let width = min(area.width, max(420, saved > 0 ? saved : (area.width * 0.4).rounded()))
            panel.setFrame(NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height), display: true)
        }
        // While the window is open the app is in the Dock and in Command-Tab, like any app with a
        // window; closing it puts the app back in the menu bar only.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 800),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Note Taker"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 420)
        panel.delegate = self
        return panel
    }

    private func attachView(to panel: NSPanel) {
        panel.contentView = NSHostingView(rootView: NoteTakerView(taker: taker, player: player, close: { [weak panel] in panel?.close() }))
        HandCursor.install(on: panel)
    }

    func windowWillClose(_ notification: Notification) {
        // The recording goes on (Open Note Taker in the menu brings it back); a call playing stops.
        player.pause()
        NSApp.setActivationPolicy(.accessory)
        // A closed window's view went on redrawing every new line and its animations (a quarter
        // of a core during a call); it is made again when the window opens.
        panel?.contentView = NSView()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let width = panel?.frame.width { UserDefaults.standard.set(width, forKey: "noteTakerWidth") }
    }
}

// MARK: Views

@available(macOS 26.0, *)
private enum NoteTab: String, CaseIterable {
    case transcript = "Transcript", summary = "Summary"
}

@available(macOS 26.0, *)
struct NoteTakerView: View {
    @ObservedObject var taker: NoteTaker
    @ObservedObject var player: NotePlayer
    /// Watched so Start replaces Download Model once the model is ready.
    @ObservedObject private var speechModel = SpeechModel.shared
    let close: () -> Void
    @State private var showOriginal = false
    @State private var tab = NoteTab.transcript
    @State private var titleDraft = ""
    @State private var question = ""
    @State private var searching = false
    @State private var search = ""
    /// The transcript is scrolled to its end: only then does a new line scroll it, so reading
    /// earlier lines during a call is not pulled back down.
    @State private var atEnd = true
    @State private var showAnswers = false
    @State private var copied = false
    @State private var confirmDelete = false
    @AppStorage("noteTakerHintDismissed") private var hintDismissed = false
    @AppStorage(NoteModel.key) private var model = NoteModel.sonnet
    @State private var titleEditing = false
    /// Where each cleaned-up line starts, worked out once per note and transcript.
    @State private var startsCache = StartsCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            heading
            tabs
            Divider()
            Group {
                switch tab {
                case .transcript: transcriptTab
                case .summary: summaryTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if showAnswers, !(taker.note?.answers ?? []).isEmpty || taker.askingQuestion != nil {
                AnswersCard(answers: taker.note?.answers ?? [], pending: taker.askingQuestion) { showAnswers = false }
            }
            bottomBar
        }
        .font(.system(size: 14))
        .frame(minWidth: 360, minHeight: 420)
        .overlay {
            if taker.awaitingModel != nil {
                ModelDownloadCard(download: taker.downloadModel, cancel: taker.cancelAwaitingModel)
            }
        }
        .onAppear {
            loadDrafts()
            loadAudio()
        }
        .onChange(of: taker.note?.id) {
            loadDrafts()
            loadAudio()
        }
        .onChange(of: taker.isRecording) { loadAudio() }
        .onChange(of: taker.note?.displayTitle) { if !titleEditing { titleDraft = taker.note?.displayTitle ?? "" } }
        .onChange(of: titleEditing) { if !titleEditing { taker.rename(titleDraft) } }
        .onChange(of: taker.asking) { if taker.asking { showAnswers = true } }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete) {
            Button("Delete Note", role: .destructive) {
                taker.deleteNote()
                close()
            }
        }
    }

    /// The player follows the note shown, and has nothing while it records.
    private func loadAudio() {
        if taker.isRecording { player.unload() } else { player.load(taker.note, store: taker.store) }
    }

    private func loadDrafts() {
        titleDraft = taker.note?.displayTitle ?? ""
        search = ""
        searching = false
        showAnswers = false
    }

    // MARK: Top

    /// Room for the traffic lights, with the note's menu on the right.
    private var topBar: some View {
        HStack {
            Spacer()
            Menu {
                Button("Copy Transcript") { copyToClipboard(taker.transcriptText) }
                    .disabled(taker.turns.isEmpty)
                Button("Copy Summary") { taker.note?.summaryText.map(copyToClipboard) }
                    .disabled(taker.note?.summary == nil)
                Button(taker.note?.summary == nil ? "Write Summary" : "Rewrite Summary") { taker.summarize() }
                    .disabled(taker.isRecording || taker.isSummarizing || taker.note?.segments.isEmpty != false)
                Divider()
                Button(taker.note?.improved == nil ? "Improve Transcript" : "Improve Transcript Again") { taker.improve(again: true) }
                    .disabled(taker.isRecording || taker.isImproving || taker.note?.segments.isEmpty != false)
                Toggle("Show Original Transcript", isOn: $showOriginal)
                    .disabled(taker.note?.improved == nil)
                Divider()
                Button("New Note") { taker.start() }
                    .disabled(taker.isRecording)
                Button("Show Notes Folder") { NSWorkspace.shared.open(taker.store.directory) }
                Divider()
                Button("Delete Note…", role: .destructive) { confirmDelete = true }
                    .disabled(taker.note == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 22)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private static let titleFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 24)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 24) } ?? base
    }()

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            TitleField(text: $titleDraft, id: taker.note?.id, placeholder: "New note", font: Self.titleFont, editing: $titleEditing)
            HStack(spacing: 6) {
                if let note = taker.note {
                    Chip(text: Self.day(note.started), icon: nil)
                    if let duration = note.duration { Chip(text: Self.elapsed(duration), icon: "clock") }
                    if taker.canSwitchLanguage {
                        Menu {
                            ForEach([NoteLanguage.automatic] + NoteLanguage.parakeetByName, id: \.self) { code in
                                Button(NoteLanguage.title(code)) { taker.setLanguage(code) }
                            }
                        } label: {
                            Chip(text: NoteLanguage.title(note.locale), icon: "globe")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("The language of the call")
                    } else {
                        Chip(text: NoteLanguage.title(note.locale), icon: "globe")
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var tabs: some View {
        HStack(spacing: 22) {
            ForEach(NoteTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 5) {
                            switch item {
                            case .transcript:
                                if taker.isRecording && !taker.isPaused {
                                    // AppKit's own spinner: it turns on its own layer, without
                                    // redrawing the transcript the way an animated symbol did.
                                    ProgressView().controlSize(.mini).help("Listening")
                                } else {
                                    Image(systemName: "waveform").foregroundStyle(Color.secondary)
                                }
                            case .summary:
                                Image(systemName: "sparkle")
                                    .symbolEffect(.pulse, isActive: taker.isSummarizing)
                            }
                            Text(item.rawValue)
                                .fontWeight(tab == item ? .semibold : .regular)
                                .foregroundStyle(tab == item ? .primary : .secondary)
                        }
                        Rectangle()
                            .fill(tab == item ? Color.primary : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: Tabs

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcriptToolbar
                .padding(.horizontal, 20)
                .padding(.top, 14)
            if let status = taker.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }
            if taker.isImproving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Claude is cleaning up the transcript and telling speakers apart…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            transcript
        }
    }

    private var transcriptToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if !taker.isRecording && player.hasAudio {
                    PlayerControls(player: player)
                } else {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                }
                if taker.isRecording, let started = taker.note?.started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.elapsed(taker.recorded(at: context.date)))
                    }
                    if taker.isPaused { Text("Paused").foregroundStyle(.orange) }
                } else if !player.hasAudio {
                    Text(Self.elapsed(taker.note?.duration ?? 0))
                }
                if searching {
                    TextField("Search", text: $search)
                        .textFieldStyle(.plain)
                } else {
                    Spacer()
                }
                Button { searching.toggle(); if !searching { search = "" } } label: {
                    Image(systemName: searching ? "xmark.circle.fill" : "magnifyingglass")
                }
                .help(searching ? "Stop searching" : "Search the transcript")
                Button {
                    copyToClipboard(taker.transcriptText)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(taker.turns.isEmpty)
                .help("Copy the whole transcript")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if !hintDismissed {
                Divider()
                HStack(alignment: .top) {
                    Text("When you stop, Claude gives the note a title and writes a summary. Your microphone is “Me”, the call audio is “Them”; use headphones so your microphone doesn't hear them too.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { hintDismissed = true } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var visibleItems: [NoteItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return taker.items }
        return taker.items.filter {
            guard case .turn(let turn) = $0 else { return false }
            let improved = (taker.note?.improved?[turn.id.uuidString] ?? []).map(\.text).joined(separator: " ")
            return (turn.text + " " + turn.pending + " " + improved).localizedCaseInsensitiveContains(query)
        }
    }

    /// A record's lines as shown: Claude's cleaned-up utterances (each with where it starts), or
    /// the record as recognised.
    private func lines(of turn: NoteTurn) -> [(speaker: String, start: Double, text: String)] {
        guard !showOriginal, let note = taker.note, let utterances = note.improved?[turn.id.uuidString] else {
            return [(turn.speaker.label, turn.start, turn.text)]
        }
        let key = "\(note.id) \(note.segments.count) \(note.improved?.count ?? 0)"
        if startsCache.key != key {
            startsCache.key = key
            startsCache.starts = [:]
        }
        let starts = startsCache.starts[turn.id] ?? note.starts(of: turn, utterances)
        startsCache.starts[turn.id] = starts
        return zip(utterances, starts).map { ($0.speaker, $1, $0.text) }
    }

    /// The line the audio is playing now ("<record id>#<index>"), whose play button turns into pause.
    private var playingLine: String? {
        guard player.isPlaying, let note = taker.note else { return nil }
        var playing: String?
        for item in taker.items {
            guard case .turn(let turn) = item else { continue }
            for (index, line) in lines(of: turn).enumerated() where note.audioTime(line.start) <= player.current + 0.05 {
                playing = "\(turn.id)#\(index)"
            }
        }
        return playing
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not a LazyVStack: when Claude's cleanup changes the lines' heights, a lazy stack
                // scrolled to the bottom stops drawing the lines above (the top went blank).
                VStack(alignment: .leading, spacing: 14) {
                    if taker.turns.isEmpty && !taker.isPaused {
                        Text(taker.isRecording ? "Listening…" : "Nothing was said.")
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else if !search.isEmpty && visibleItems.isEmpty {
                        Text("No matches").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
                    }
                    // Found once per redraw: asked per line, it rebuilt every record for every line
                    // four times a second while playing (100% CPU on a long note).
                    let playing = playingLine
                    ForEach(visibleItems) { item in
                        switch item {
                        case .turn(let turn):
                            let playable = player.hasAudio && !taker.isRecording
                            let lines = lines(of: turn)
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                TurnView(speaker: line.speaker, start: line.start, text: line.text,
                                         pending: index == 0 && lines.count == 1 ? turn.pending : "",
                                         play: playable ? { player.play(fromNoteTime: line.start) } : nil,
                                         playing: playing == "\(turn.id)#\(index)",
                                         pause: { player.pause() })
                            }
                        case .pause(let pause): PauseView(pause: pause)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { _, isAtEnd in
                atEnd = isAtEnd
            }
            .onChange(of: taker.items) {
                guard search.isEmpty, atEnd else { return }
                // No animation: its frames redraw the whole transcript on every new line.
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }

    @ViewBuilder private var summaryTab: some View {
        if taker.isSummarizing || (taker.isImproving && taker.note?.summary == nil) {
            VStack(spacing: 12) {
                ProgressView()
                Text(taker.isImproving ? "Claude is cleaning up the transcript; the summary comes next…" : "Claude is writing the summary…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 50)
        } else if let summary = taker.note?.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MarkdownView(text: summary)
                        .font(.system(size: Self.textSize))
                    HStack {
                        Button { taker.note?.summaryText.map(copyToClipboard) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button { taker.summarize() } label: {
                            Label("Rewrite", systemImage: "arrow.clockwise")
                        }
                        .disabled(taker.isRecording)
                    }
                    .controlSize(.small)
                    .padding(.top, 6)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 12) {
                Text(taker.isRecording ? "Claude writes the summary when you stop." : "No summary yet.")
                    .foregroundStyle(.secondary)
                if !taker.isRecording, taker.note?.segments.isEmpty == false {
                    Button("Write Summary") { taker.summarize() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 50)
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if taker.isRecording {
                Text("Always get consent before transcribing others.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if taker.isRecording {
                    Button {
                        if taker.isPaused { taker.resume() } else { taker.pause() }
                    } label: {
                        Image(systemName: taker.isPaused ? "play.fill" : "pause.fill")
                            .font(.body.weight(.medium))
                            .frame(width: 40, height: 40)
                            .background(Circle().strokeBorder(Color.primary.opacity(0.15)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(taker.isPaused ? "Resume recording" : "Pause: the microphone and the call audio are off until you resume")
                }
                Button {
                    if taker.isRecording { taker.stop() } else { taker.continueNote() }
                } label: {
                    HStack(spacing: 8) {
                        if taker.isRecording {
                            RoundedRectangle(cornerRadius: 2).fill(Color.red).frame(width: 12, height: 12)
                            Text("Stop")
                        } else if taker.needsModel {
                            // Nothing records until the speech model is downloaded.
                            Image(systemName: "arrow.down.circle")
                            Text("Download Model")
                        } else {
                            Circle().fill(Color.red).frame(width: 11, height: 11)
                            Text(taker.note == nil ? "Start" : "Continue")
                        }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                askField
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var askField: some View {
        HStack(spacing: 8) {
            TextField("Ask Claude…", text: $question)
                .textFieldStyle(.plain)
                .onSubmit {
                    taker.ask(question)
                    question = ""
                }
            Menu {
                Picker("Claude model", selection: $model) {
                    ForEach(NoteModel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.name).font(.system(size: 12))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("The Claude model that answers and writes the summary")
            if taker.asking {
                ProgressView().controlSize(.small)
            } else if question.isEmpty {
                if let answers = taker.note?.answers, !answers.isEmpty, !showAnswers {
                    Button { showAnswers = true } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Show answers")
                }
                Button(NoteAskProtocol.whatDidIMiss) { taker.ask(NoteAskProtocol.whatDidIMiss) }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .disabled(taker.turns.isEmpty)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(Capsule().strokeBorder(Color.primary.opacity(0.15)))
    }

    // MARK: Formatting

    /// The size of transcript, summary and answer text: a little larger than the system's 13 pt.
    static let textSize: CGFloat = 15

    static func speedLabel(_ speed: Float) -> String {
        let number: String = speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", Double(speed))
        return number + "×"
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "'Today', HH:mm" : "d MMM yyyy, HH:mm"
        return f.string(from: date)
    }
}

@available(macOS 26.0, *)
/// Asks to download the speech model the first time Note Taker records, over the whole window.
@available(macOS 26.0, *)
private struct ModelDownloadCard: View {
    @ObservedObject private var model = SpeechModel.shared
    let download: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .contentShape(Rectangle())
            VStack(spacing: 14) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Download the Speech Model")
                    .font(.system(size: 20, weight: .semibold))
                Text("""
                    Note Taker transcribes calls on this Mac with Parakeet, a free speech model for 25 European \
                    languages. It is downloaded once (\(SpeechModel.size)); the call's audio never leaves the Mac.
                    """)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch model.state {
                case .downloading(let fraction):
                    VStack(spacing: 6) {
                        ProgressView(value: min(max(fraction, 0), 1))
                        Text(fraction < 0.99 ? "Downloading… \(Int(fraction * 100))%" : "Preparing the model…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                    Button("Hide", action: cancel)
                case .failed(let reason):
                    Text("The download failed: \(reason)")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    buttons(title: "Try Again")
                default:
                    buttons(title: "Download Model")
                }
            }
            .padding(28)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            .padding(24)
        }
    }

    private func buttons(title: String) -> some View {
        HStack(spacing: 10) {
            Button("Not Now", action: cancel)
                .controlSize(.large)
            Button(title, action: download)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }
}

private struct Chip: View {
    let text: String
    let icon: String?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// Line starts for the transcript, kept between redraws (the player redraws it four times a
/// second). A class, so filling it while drawing changes no view state.
private final class StartsCache {
    var key = ""
    var starts: [UUID: [Double]] = [:]
}

@available(macOS 26.0, *)
private struct TurnView: View {
    /// "Me", "Them", a name or "Speaker 1".
    let speaker: String
    /// Seconds from the note's start.
    let start: Double?
    let text: String
    let pending: String
    /// Plays the audio from this record, when the note has audio.
    var play: (() -> Void)?
    /// The audio is playing this line: its button pauses.
    var playing = false
    var pause: (() -> Void)?

    /// Me in the accent colour; everyone else gets a colour of their own, the same each time.
    static func color(_ speaker: String) -> Color {
        if speaker == "Me" { return .accentColor }
        if speaker == "Them" { return .orange }
        let palette: [Color] = [.orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint]
        let hash = speaker.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(speaker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.color(speaker))
                if let start, let play {
                    Button(action: playing ? (pause ?? play) : play) {
                        Label(NoteTakerView.elapsed(start), systemImage: playing ? "pause.fill" : "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(playing ? Color.accentColor : .secondary)
                    .help(playing ? "Pause" : "Listen from here")
                } else if let start {
                    Text(NoteTakerView.elapsed(start))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            (Text(text) + Text(text.isEmpty || pending.isEmpty ? "" : " ")
                + Text(pending).foregroundColor(.secondary))
                .font(.system(size: NoteTakerView.textSize))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Play/pause, a scrubber, the time and the speed, for a note with saved audio.
@available(macOS 26.0, *)
private struct PlayerControls: View {
    @ObservedObject var player: NotePlayer

    private var position: Binding<Double> {
        Binding(get: { player.current }, set: { player.seek(audio: $0) })
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .foregroundStyle(.primary)
            .help(player.isPlaying ? "Pause" : "Play the call")
            Slider(value: position, in: 0...max(player.duration, 1))
                .controlSize(.small)
            Text(NoteTakerView.elapsed(player.current) + " / " + NoteTakerView.elapsed(player.duration))
                .fixedSize()
            Menu {
                Picker("Speed", selection: $player.speed) {
                    ForEach(NotePlayer.speeds, id: \.self) { speed in
                        Text(NoteTakerView.speedLabel(speed)).tag(speed)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(NoteTakerView.speedLabel(player.speed))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")
        }
    }
}

/// Where the recording was paused, between two turns.
@available(macOS 26.0, *)
private struct PauseView: View {
    let pause: NotePause

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            Label(pause.duration.map { "Paused \(NoteTakerView.elapsed($0))" } ?? "Paused", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
    }
}

/// A question you asked, as a chat bubble on the right, so it reads apart from Claude's answer.
@available(macOS 26.0, *)
private struct QuestionBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.16)))
        }
    }
}

/// Questions asked about the call and Claude's answers, above the ask field.
@available(macOS 26.0, *)
private struct AnswersCard: View {
    let answers: [NoteAnswer]
    /// A question still waiting for its answer.
    let pending: String?
    let close: () -> Void
    /// The answers' natural height: the card is as tall as they are, up to `maxHeight`, then scrolls.
    @State private var contentHeight: CGFloat = 0
    private let maxHeight: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ask Claude").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(answers) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                QuestionBubble(text: item.question)
                                MarkdownView(text: item.answer).font(.system(size: NoteTakerView.textSize))
                                Button { copyToClipboard(item.answer) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let pending {
                            QuestionBubble(text: pending)
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Claude is reading the call…").foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { contentHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { contentHeight = geometry.size.height }
                    })
                }
                .frame(height: min(max(contentHeight, 40), maxHeight))
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: answers.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: pending) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// The Markdown Claude writes for summaries and answers: "###" headings, "-" bullets and inline
/// bold, italics and code. SwiftUI's Text renders only the inline part by itself.
@available(macOS 26.0, *)
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    Text(Self.inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                        .font(.system(size: NoteTakerView.textSize + 1, weight: .semibold))
                        .padding(.top, 8)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(String(line.dropFirst(2))))
                    }
                } else if !line.isEmpty {
                    Text(Self.inline(line))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }
}

/// Plays a note's saved audio: every recording's microphone and call tracks laid out on one
/// timeline that leaves the pauses out.
@available(macOS 26.0, *)
@MainActor
final class NotePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    /// Seconds into the audio.
    @Published var current: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var loadedID: UUID?
    /// Playback speed, kept between notes.
    @Published var speed: Float = UserDefaults.standard.object(forKey: "noteTakerSpeed") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "noteTakerSpeed")
            player?.defaultRate = speed
            if isPlaying { player?.rate = speed }
        }
    }
    static let speeds: [Float] = [1, 1.25, 1.5, 2]
    private var player: AVPlayer?
    private var observer: Any?
    private var loading: Task<Void, Never>?
    private var note: Note?

    var hasAudio: Bool { duration > 0 }

    func load(_ note: Note?, store: NoteStore) {
        guard note?.id != loadedID || note?.recordings != self.note?.recordings else { return }
        unload()
        self.note = note
        loadedID = note?.id
        guard let note, let recordings = note.recordings, !recordings.isEmpty else { return }
        loading = Task {
            let composition = AVMutableComposition()
            var tracks: [(track: AVMutableCompositionTrack, url: URL, mine: Bool)] = []
            for recording in recordings {
                let at = CMTime(seconds: note.audioTime(recording.start), preferredTimescale: 600)
                for speaker in recording.speakers {
                    let url = store.audioFile(note.id, index: recording.index, speaker: speaker)
                    let asset = AVURLAsset(url: url)
                    guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                          let length = try? await asset.load(.duration), length.seconds > 0,
                          let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { continue }
                    try? track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: at)
                    tracks.append((track, url, speaker == .me))
                }
            }
            guard !Task.isCancelled, loadedID == note.id else { return }
            let item = AVPlayerItem(asset: composition)
            // Keeps voices natural (no chipmunk pitch) when sped up.
            item.audioTimePitchAlgorithm = .timeDomain
            let player = AVPlayer(playerItem: item)
            player.defaultRate = speed
            self.player = player
            duration = composition.duration.seconds.isFinite ? composition.duration.seconds : 0
            balance(item, tracks: tracks)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.current = time.seconds
                    if self.isPlaying, time.seconds >= self.duration - 0.05 { self.pause() }
                }
            }
        }
    }

    /// Speech levels of the audio files played, measured once per file.
    private static var levels: [URL: Float?] = [:]

    /// Plays the microphone and the call about equally loud: the quieter one is raised to the
    /// other, the microphone a little below the call.
    /// Measuring a long call's files takes a moment, so it plays as recorded until then.
    private func balance(_ item: AVPlayerItem, tracks: [(track: AVMutableCompositionTrack, url: URL, mine: Bool)]) {
        let urls = tracks.map(\.url)
        let known = Self.levels
        Task {
            let levels = await Task.detached(priority: .utility) {
                urls.map { url in known[url] ?? AudioGain.speechLevel(of: url) }
            }.value
            for (url, level) in zip(urls, levels) { Self.levels[url] = level }
            let gains = SpeechLevel.gains(levels, mine: tracks.map(\.mine))
            guard gains.contains(where: { $0 != 1 }) else { return }
            let mix = AVMutableAudioMix()
            mix.inputParameters = zip(tracks, gains).compactMap { entry, gain in
                guard gain != 1, let tap = AudioGain.tap(gain: gain) else { return nil }
                let parameters = AVMutableAudioMixInputParameters(track: entry.track)
                parameters.audioTapProcessor = tap
                return parameters
            }
            item.audioMix = mix
            Log.write("note taker: playback gains \(gains.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        }
    }

    func unload() {
        loading?.cancel()
        pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        note = nil
        loadedID = nil
        current = 0
        duration = 0
    }

    func toggle() {
        if isPlaying { return pause() }
        if current >= duration - 0.1 { seek(audio: 0) }
        player?.play()
        isPlaying = player != nil
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Jumps to a seconds-into-the-audio position.
    func seek(audio seconds: Double) {
        current = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Plays from a moment of the note, such as where a record starts.
    func play(fromNoteTime time: Double) {
        guard let note else { return }
        seek(audio: max(0, note.audioTime(time) - 0.3))
        player?.play()
        isPlaying = player != nil
    }
}
