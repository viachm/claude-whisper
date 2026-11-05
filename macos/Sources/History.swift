import Foundation

struct Transcript: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
}

/// The last 30 dictations, newest first, in `~/Library/Application Support/Claude Whisper/history.json`.
/// Pasting into a window that had no text field loses the text, and the clipboard is put back
/// right after, so this is where it can still be found.
final class History: ObservableObject {
    static let limit = 30

    @Published private(set) var entries: [Transcript] = []
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude Whisper/history.json")

    init() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            entries = try Self.decoder.decode([Transcript].self, from: data)
        } catch {
            Log.write("could not read \(url.path): \(error)")
        }
    }

    func add(_ text: String) {
        entries = Array(([Transcript(date: Date(), text: text)] + entries).prefix(Self.limit))
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            Log.write("could not write \(url.path): \(error)")
        }
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
