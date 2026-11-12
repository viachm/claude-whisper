import AppKit
import AVFoundation
import SwiftUI

/// Note Taker: transcribes a call as a dialog, your microphone as "Me" and everything the Mac
/// plays as "Them", on-device with Apple's speech recogniser (not Claude: Claude Code's voice
/// mode only listens while a key is held, and only to the microphone). Claude, through the
/// user's Claude Code login, titles and summarizes a note when it stops and answers questions
/// about it. Each recording is saved as it goes; the window shows the live one or a saved one.
@available(macOS 26.0, *)
@MainActor
final class NoteTaker: ObservableObject {
    @Published private(set) var note: Note?
    @Published private(set) var pending: [Speaker: NoteSegment] = [:]
    @Published private(set) var isRecording = false
    /// Recording, but with the microphone and the call audio off until `resume()`.
    @Published private(set) var isPaused = false
    private var pausedAt: Date?
    /// A problem or a slow step to show in the window, such as a model download.
    @Published private(set) var status: String?
    /// Notes Claude is titling and summarizing right now.
    @Published private(set) var summarizing: Set<UUID> = []
    @Published private(set) var asking = false

    let store: NoteStore
    private let workspace: URL
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var writers: [AudioTrackWriter] = []

    static let keepAudioKey = "noteTakerKeepAudio"
    /// Whether notes keep their audio, so it can be listened to; on unless turned off in Settings.
    static var keepsAudio: Bool { UserDefaults.standard.object(forKey: keepAudioKey) as? Bool ?? true }
    private var streams: [Speaker: SpeechStream] = [:]
    /// Per source, from which transcriber time (seconds of audio it was given) which offset
    /// applies: the transcriber's times count audio only, so the offset is the time from the
    /// note's start to the first buffer, and grows by each pause.
    private var offsets: [Speaker: [(from: Double, offset: Double)]] = [:]
    private var run = 0

    static let localeKey = "noteTakerLocale"
    static var locale: String { UserDefaults.standard.string(forKey: localeKey) ?? "en-US" }

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
        record(Note(started: Date(), locale: Self.locale))
    }

    /// Records more into the note shown (a new one if there is none); the time since it stopped
    /// shows as a pause, and stopping again rewrites the summary.
    func continueNote() {
        guard !isRecording else { return }
        guard var note, let ended = note.ended else { return start() }
        note.pauses = (note.pauses ?? []) + [NotePause(start: ended.timeIntervalSince(note.started),
                                                       duration: Date().timeIntervalSince(ended))]
        note.ended = nil
        record(note)
    }

    private func record(_ note: Note) {
        run += 1
        let run = run
        let locale = note.locale
        self.note = note
        pending = [:]
        offsets = [:]
        status = nil
        isRecording = true
        isPaused = false
        pausedAt = nil
        Log.write("note taker: \(note.segments.isEmpty ? "started" : "continued") (\(locale))")
        Task {
            do {
                try await begin(run: run, locale: Locale(identifier: locale))
            } catch {
                Log.write("note taker: could not start: \(error)")
                status = "Could not start: \(error.localizedDescription)"
                stop()
            }
        }
    }

    private func begin(run: Int, locale: Locale) async throws {
        for speaker in [Speaker.me, .them] {
            let stream = SpeechStream(locale: locale) { [weak self] text, start, end, final in
                Task { @MainActor in self?.received(speaker, run: run, text: text, start: start, end: end, final: final) }
            }
            try await stream.prepare { status = "Downloading the speech model for \(locale.identifier(.bcp47))…" }
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
        // A lone "." or "," from a cough or a click is not a line.
        if text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).isEmpty { text = "" }
        let offset = offsets[speaker]?.last { $0.from <= start + 0.05 }?.offset ?? offsets[speaker]?.first?.offset ?? 0
        let segment = NoteSegment(speaker: speaker, start: start + offset,
                                  end: end.isFinite && end >= start ? end + offset : nil, text: text)
        if final {
            pending[speaker] = nil
            guard !text.isEmpty else { return }
            note?.segments.append(segment)
            save()
        } else {
            pending[speaker] = segment
        }
    }

    /// Stops listening; the last words still being recognised are added when they are final,
    /// then Claude titles and summarizes the note.
    func stop() {
        guard isRecording else { return }
        closePause()
        isRecording = false
        isPaused = false
        stopCapture()
        let streams = self.streams
        self.streams = [:]
        let run = run
        Task {
            for stream in streams.values { await stream.finish() }
            // Let the final results queued on the main actor land first.
            try? await Task.sleep(for: .milliseconds(200))
            guard run == self.run, let note else { return }
            pending = [:]
            self.note?.ended = Date()
            save()
            Log.write("note taker: stopped, \(note.segments.count) lines")
            if !note.segments.isEmpty { summarize() }
        }
    }

    /// Shows a saved note (stopping a recording first).
    func open(_ saved: Note) {
        stop()
        run += 1
        pausedAt = nil
        note = saved
        pending = [:]
        status = nil
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
        pending = [:]
    }

    // MARK: Claude

    /// Asks Claude for a title and a summary of the note shown.
    func summarize() {
        guard let note, !note.segments.isEmpty, !summarizing.contains(note.id) else { return }
        let id = note.id
        summarizing.insert(id)
        let started = Date()
        NoteClaude.run(arguments: NoteSummaryProtocol.arguments(model: .current),
                       input: NoteSummaryProtocol.input(transcript: note.transcript), directory: workspace) { [weak self] output in
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
        let transcript = Note.turns(note.segments, pending: Array(pending.values))
            .map { "\($0.speaker.label): \([$0.text, $0.pending].filter { !$0.isEmpty }.joined(separator: " "))" }
            .joined(separator: "\n")
        asking = true
        NoteClaude.run(arguments: NoteAskProtocol.arguments(model: .current),
                       input: NoteAskProtocol.input(transcript: transcript, question: question),
                       directory: workspace, timeout: 90) { [weak self] output in
            guard let self else { return }
            asking = false
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

/// The Note Taker window: a third of the screen on its right edge, top to bottom, above other
/// windows so it stays visible next to the call. Closing it stops the recording.
@available(macOS 26.0, *)
@MainActor
final class NoteTakerWindow: NSObject, NSWindowDelegate {
    let taker: NoteTaker
    private var panel: NSPanel?

    init(taker: NoteTaker) {
        self.taker = taker
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible, let screen = NSScreen.main {
            let area = screen.visibleFrame
            let width = (area.width / 3).rounded()
            panel.setFrame(NSRect(x: area.maxX - width, y: area.minY, width: width, height: area.height), display: true)
        }
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
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 420)
        panel.contentView = NSHostingView(rootView: NoteTakerView(taker: taker, close: { [weak panel] in panel?.close() }))
        panel.delegate = self
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        taker.stop()
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
    let close: () -> Void
    @StateObject private var player = NotePlayer()
    @State private var tab = NoteTab.transcript
    @State private var titleDraft = ""
    @State private var question = ""
    @State private var searching = false
    @State private var search = ""
    @State private var showAnswers = false
    @State private var copied = false
    @State private var confirmDelete = false
    @AppStorage("noteTakerHintDismissed") private var hintDismissed = false
    @AppStorage(NoteModel.key) private var model = NoteModel.sonnet
    @FocusState private var titleFocused: Bool

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
            if showAnswers, let answers = taker.note?.answers, !answers.isEmpty || taker.asking {
                AnswersCard(answers: answers, asking: taker.asking) { showAnswers = false }
            }
            bottomBar
        }
        .font(.system(size: 14))
        .frame(minWidth: 360, minHeight: 420)
        .onAppear {
            loadDrafts()
            loadAudio()
        }
        .onChange(of: taker.note?.id) {
            loadDrafts()
            loadAudio()
        }
        .onChange(of: taker.isRecording) { loadAudio() }
        .onChange(of: taker.note?.displayTitle) { if !titleFocused { titleDraft = taker.note?.displayTitle ?? "" } }
        .onChange(of: titleFocused) { if !titleFocused { taker.rename(titleDraft) } }
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

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("New note", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .regular, design: .serif))
                .focused($titleFocused)
                .onSubmit { titleFocused = false }
            HStack(spacing: 6) {
                if let note = taker.note {
                    Chip(text: Self.day(note.started), icon: nil)
                    if let duration = note.duration { Chip(text: Self.elapsed(duration), icon: "clock") }
                    Chip(text: Locale.current.localizedString(forIdentifier: note.locale) ?? note.locale, icon: "globe")
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
                                Image(systemName: "waveform")
                                    .foregroundStyle(taker.isRecording && !taker.isPaused ? Color.green : Color.secondary)
                                    .symbolEffect(.variableColor.iterative, isActive: taker.isRecording && !taker.isPaused)
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
            }
            transcript
        }
    }

    private var transcriptToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if !taker.isRecording && player.hasAudio {
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 16)
                    }
                    .foregroundStyle(.primary)
                    .help(player.isPlaying ? "Pause" : "Play the call")
                    Slider(value: Binding(get: { player.current }, set: { player.seek(audio: $0) }), in: 0...max(player.duration, 1))
                        .controlSize(.small)
                    Text("\(Self.elapsed(player.current)) / \(Self.elapsed(player.duration))")
                        .fixedSize()
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
            return (turn.text + " " + turn.pending).localizedCaseInsensitiveContains(query)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if taker.turns.isEmpty && !taker.isPaused {
                        Text(taker.isRecording ? "Listening…" : "Nothing was said.")
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else if !search.isEmpty && visibleItems.isEmpty {
                        Text("No matches").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 30)
                    }
                    ForEach(visibleItems) { item in
                        switch item {
                        case .turn(let turn):
                            TurnView(turn: turn, play: player.hasAudio && !taker.isRecording
                                     ? { player.play(fromNoteTime: turn.start) } : nil)
                        case .pause(let pause): PauseView(pause: pause)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .onChange(of: taker.items) {
                guard search.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var summaryTab: some View {
        if taker.isSummarizing {
            VStack(spacing: 12) {
                ProgressView()
                Text("Claude is writing the summary…").foregroundStyle(.secondary)
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
            TextField("Ask anything about this call", text: $question)
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

@available(macOS 26.0, *)
private struct TurnView: View {
    let turn: NoteTurn
    /// Plays the audio from this record, when the note has audio.
    var play: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(turn.speaker.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(turn.speaker == .me ? Color.accentColor : Color.orange)
                if let play {
                    Button(action: play) {
                        Label(NoteTakerView.elapsed(turn.start), systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Listen from here")
                } else {
                    Text(NoteTakerView.elapsed(turn.start))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            (Text(turn.text) + Text(turn.text.isEmpty || turn.pending.isEmpty ? "" : " ")
                + Text(turn.pending).foregroundColor(.secondary))
                .font(.system(size: NoteTakerView.textSize))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// Questions asked about the call and Claude's answers, above the ask field.
@available(macOS 26.0, *)
private struct AnswersCard: View {
    let answers: [NoteAnswer]
    let asking: Bool
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
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.question).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                MarkdownView(text: item.answer).font(.system(size: NoteTakerView.textSize))
                                Button { copyToClipboard(item.answer) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if asking {
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
                .onChange(of: asking) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
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
            for recording in recordings {
                let at = CMTime(seconds: note.audioTime(recording.start), preferredTimescale: 600)
                for speaker in recording.speakers {
                    let asset = AVURLAsset(url: store.audioFile(note.id, index: recording.index, speaker: speaker))
                    guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                          let length = try? await asset.load(.duration), length.seconds > 0,
                          let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { continue }
                    try? track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: at)
                }
            }
            guard !Task.isCancelled, loadedID == note.id else { return }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
            self.player = player
            duration = composition.duration.seconds.isFinite ? composition.duration.seconds : 0
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.current = time.seconds
                    if self.isPlaying, time.seconds >= self.duration - 0.05 { self.pause() }
                }
            }
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
