import Foundation

/// Who said a line in a note: you (the microphone) or the other people on the call (whatever
/// the Mac plays).
enum Speaker: String, Codable {
    case me, them

    var label: String { self == .me ? "Me" : "Them" }
}

/// One finished stretch of speech, as the transcriber delivers it (roughly a sentence).
struct NoteSegment: Codable, Equatable, Identifiable {
    var id = UUID()
    var speaker: Speaker
    /// Seconds from the start of the note.
    var start: Double
    var text: String
}

/// What the note window shows: consecutive segments by the same speaker run together.
struct NoteTurn: Equatable, Identifiable {
    var id: UUID
    var speaker: Speaker
    var start: Double
    /// Finished text.
    var text: String
    /// Text still being recognised, shown after `text` until the transcriber settles on it.
    var pending: String
}

/// One Note Taker recording, saved as `notes/<id>.json` in Claude Whisper's Application Support folder.
struct Note: Codable, Equatable, Identifiable {
    var id = UUID()
    var started: Date
    var ended: Date?
    /// The transcription language, as a BCP 47 code such as "en-US".
    var locale: String
    var segments: [NoteSegment] = []

    /// The conversation as turns, in time order, with lines still being recognised merged in.
    static func turns(_ segments: [NoteSegment], pending: [NoteSegment] = []) -> [NoteTurn] {
        let all = (segments.map { ($0, false) } + pending.map { ($0, true) })
            .filter { !$0.0.text.isEmpty }
            // Stable for equal starts: finished text before pending text.
            .enumerated()
            .sorted { ($0.element.0.start, $0.offset) < ($1.element.0.start, $1.offset) }
            .map { $0.element }
        var turns: [NoteTurn] = []
        for (segment, isPending) in all {
            if let last = turns.last, last.speaker == segment.speaker {
                if isPending {
                    turns[turns.count - 1].pending = join(last.pending, segment.text)
                } else {
                    turns[turns.count - 1].text = join(last.text, segment.text)
                }
            } else {
                turns.append(NoteTurn(id: segment.id, speaker: segment.speaker, start: segment.start,
                                      text: isPending ? "" : segment.text, pending: isPending ? segment.text : ""))
            }
        }
        return turns
    }

    /// Plain text for the clipboard: a heading, then one paragraph per turn.
    func plainText(pending: [NoteSegment] = []) -> String {
        let day = DateFormatter()
        day.dateFormat = "d MMM yyyy, HH:mm"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        var heading = "Note Taker, \(day.string(from: started))"
        if let ended { heading += "–\(time.string(from: ended))" }
        let body = Self.turns(segments, pending: pending).map { turn in
            "\(turn.speaker.label): \(Self.join(turn.text, turn.pending))"
        }
        return ([heading] + body).joined(separator: "\n\n")
    }

    /// The first words said, for the menu.
    var snippet: String {
        let words = Self.turns(segments).first.map { $0.text } ?? ""
        let line = words.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return line.count > 50 ? line.prefix(50) + "…" : line
    }

    var duration: TimeInterval? { ended.map { $0.timeIntervalSince(started) } }

    private static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }
}

/// The saved notes, newest first, one JSON file each in
/// `~/Library/Application Support/Claude Whisper/notes`.
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    let directory: URL

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude Whisper/notes")) {
        self.directory = directory
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        notes = files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Note.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }

    /// Writes the note and puts it at its place in `notes`. Called after every finished line,
    /// so a crash or a forced quit loses at most the line being spoken.
    func save(_ note: Note) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(note).write(to: directory.appendingPathComponent("\(note.id.uuidString).json"), options: .atomic)
        notes.removeAll { $0.id == note.id }
        notes.append(note)
        notes.sort { $0.started > $1.started }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
