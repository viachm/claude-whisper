import AppKit
import SwiftUI

/// Note Taker: transcribes a call as a dialog, your microphone as "Me" and everything the Mac
/// plays as "Them", on-device with Apple's speech recogniser (not Claude: Claude Code's voice
/// mode only listens while a key is held, and only to the microphone). Each recording is saved
/// as it goes; the window shows the live one or a saved one.
@available(macOS 26.0, *)
@MainActor
final class NoteTaker: ObservableObject {
    @Published private(set) var note: Note?
    @Published private(set) var pending: [Speaker: NoteSegment] = [:]
    @Published private(set) var isRecording = false
    /// A problem or a slow step to show at the top of the window, such as a model download.
    @Published private(set) var status: String?
    @Published var locale: String {
        didSet { UserDefaults.standard.set(locale, forKey: "noteTakerLocale") }
    }
    @Published private(set) var locales: [String] = []

    let store: NoteStore
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var streams: [Speaker: SpeechStream] = [:]
    /// Seconds from the note's start to each source's first buffer, added to the
    /// transcriber's times, which count from there.
    private var offsets: [Speaker: Double] = [:]
    private var run = 0

    init(store: NoteStore) {
        self.store = store
        locale = UserDefaults.standard.string(forKey: "noteTakerLocale") ?? "en-US"
        Task { locales = await SpeechStream.supportedLocales() }
    }

    var turns: [NoteTurn] { Note.turns(note?.segments ?? [], pending: Array(pending.values)) }

    var text: String { note?.plainText(pending: Array(pending.values)) ?? "" }

    func start() {
        guard !isRecording else { return }
        run += 1
        let run = run
        let note = Note(started: Date(), locale: locale)
        self.note = note
        pending = [:]
        offsets = [:]
        status = nil
        isRecording = true
        Log.write("note taker: started (\(locale))")
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
            let stream = SpeechStream(locale: locale) { [weak self] text, start, final in
                Task { @MainActor in self?.received(speaker, run: run, text: text, start: start, final: final) }
            }
            try await stream.prepare { status = "Downloading the speech model for \(locale.identifier(.bcp47))…" }
            try await stream.start()
            streams[speaker] = stream
        }
        guard self.run == run, isRecording, let started = note?.started else { return }
        status = nil

        let mic = MicCapture()
        let micStream = streams[.me]
        try mic.start { micStream?.append($0) }
        self.mic = mic
        offsets[.me] = Date().timeIntervalSince(started)

        let system = SystemAudioCapture()
        let systemStream = streams[.them]
        do {
            try system.start { systemStream?.append($0) }
            self.system = system
            offsets[.them] = Date().timeIntervalSince(started)
        } catch {
            Log.write("note taker: no system audio: \(error)")
            status = "Can't hear the call audio (\(error.localizedDescription)); only your microphone is transcribed."
        }
    }

    private func received(_ speaker: Speaker, run: Int, text: String, start: Double, final: Bool) {
        guard run == self.run, note != nil else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = NoteSegment(speaker: speaker, start: start + (offsets[speaker] ?? 0), text: text)
        if final {
            pending[speaker] = nil
            guard !text.isEmpty else { return }
            note?.segments.append(segment)
            save()
        } else {
            pending[speaker] = segment
        }
    }

    /// Stops listening; the last words still being recognised are added when they are final.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        let streams = self.streams
        self.streams = [:]
        let run = run
        Task {
            for stream in streams.values { await stream.finish() }
            // Let the final results queued on the main actor land first.
            try? await Task.sleep(for: .milliseconds(200))
            guard run == self.run else { return }
            pending = [:]
            note?.ended = Date()
            save()
            Log.write("note taker: stopped, \(note?.segments.count ?? 0) lines")
        }
    }

    /// Shows a saved note (stopping a recording first).
    func open(_ saved: Note) {
        stop()
        run += 1
        note = saved
        pending = [:]
        status = nil
    }

    private func save() {
        guard let note, !note.segments.isEmpty else { return }
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
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 800),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
        panel.title = "Note Taker"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 300)
        panel.contentView = NSHostingView(rootView: NoteTakerView(taker: taker))
        panel.delegate = self
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        taker.stop()
    }
}

@available(macOS 26.0, *)
struct NoteTakerView: View {
    @ObservedObject var taker: NoteTaker
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let status = taker.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
            transcript
        }
        .frame(minWidth: 320, minHeight: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if taker.isRecording {
                Circle().fill(.red).frame(width: 9, height: 9)
                if let started = taker.note?.started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.elapsed(context.date.timeIntervalSince(started)))
                            .monospacedDigit()
                    }
                }
            } else if let note = taker.note {
                Text(Self.title(note)).foregroundStyle(.secondary)
            }
            Spacer()
            if !taker.isRecording {
                Picker("", selection: $taker.locale) {
                    ForEach(taker.locales.isEmpty ? [taker.locale] : taker.locales, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Language of the call")
            }
            Button {
                copyToClipboard(taker.text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(taker.turns.isEmpty)
            .help("Copy the whole conversation")
            if taker.isRecording {
                Button("Stop") { taker.stop() }
            } else {
                Button("New") { taker.start() }
                    .help("Start a new note")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if taker.turns.isEmpty {
                        Text(taker.isRecording
                             ? "Listening. Your microphone is “Me”, the call audio is “Them”."
                             : "Nothing was said.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(taker.turns) { turn in
                        TurnView(turn: turn)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .onChange(of: taker.turns) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func title(_ note: Note) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(note.started) ? "'Today' HH:mm" : "d MMM HH:mm"
        var text = f.string(from: note.started)
        if let duration = note.duration { text += " · \(elapsed(duration))" }
        return text
    }
}

@available(macOS 26.0, *)
private struct TurnView: View {
    let turn: NoteTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(turn.speaker.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(turn.speaker == .me ? Color.accentColor : Color.orange)
            (Text(turn.text) + Text(turn.text.isEmpty || turn.pending.isEmpty ? "" : " ")
                + Text(turn.pending).foregroundColor(.secondary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
