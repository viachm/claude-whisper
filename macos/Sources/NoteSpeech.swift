import Foundation

/// The language Note Taker transcribes a call in. "auto" and the 25 languages of the Parakeet
/// model (two-letter codes such as "uk") use Parakeet; anything else is an Apple locale such as
/// "ja-JP" for Apple's recogniser. Notes saved before Parakeet hold Apple locales ("en-US").
enum NoteLanguage {
    static let key = "noteTakerLanguage"
    static let automatic = "auto"
    /// What Parakeet v3 and Ultra were trained on.
    static let parakeet = ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
                           "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"]

    /// The language chosen in Settings; automatic unless changed.
    static var current: String { UserDefaults.standard.string(forKey: key) ?? automatic }

    static func usesParakeet(_ code: String) -> Bool { code == automatic || parakeet.contains(code) }

    /// The language Parakeet is told to keep to, so it writes the right alphabet; nil lets it guess.
    static func hint(_ code: String) -> String? { code == automatic ? nil : code }

    static func title(_ code: String) -> String {
        code == automatic ? "Automatic" : Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// Parakeet's languages by name, for a menu.
    static var parakeetByName: [String] { parakeet.sorted { title($0) < title($1) } }

    /// Apple's locales whose language Parakeet doesn't have.
    static func appleOnly(_ locales: [String]) -> [String] {
        locales.filter { !parakeet.contains(Locale(identifier: $0).language.languageCode?.identifier ?? $0) }
            .sorted { title($0) < title($1) }
    }
}

/// Splits a stream of 16 kHz mono audio into utterances at pauses, for a model that transcribes
/// up to 15 seconds at a time. Quiet stretches between utterances are dropped. Indexes count
/// samples from the start of the stream.
struct UtteranceSegmenter {
    static let rate = 16_000
    static let frame = 512
    /// Quiet that ends an utterance of at least `enough` seconds. A shorter one runs on until a
    /// `longPause`: Parakeet writes better with a few sentences of context than with a phrase.
    var pause = 0.6
    var enough = 6.0
    var longPause = 1.5
    /// The longest utterance; a longer one is cut at its quietest moment near the end.
    var longest = 14.5
    /// Audio kept before the first loud frame and after the last, so words aren't clipped.
    var margin = 0.25
    /// Less speech than this is a click or a cough, not an utterance.
    var shortest = 0.3

    struct Utterance: Equatable {
        let start: Int
        let samples: [Float]
        var end: Int { start + samples.count }
    }

    private var buffer: [Float] = []
    /// Index of buffer[0].
    private var offset = 0
    /// Samples up to here have been looked at, a frame at a time.
    private var analyzed = 0
    /// Where the utterance in progress starts (a margin before its first loud frame).
    private var speechStart: Int?
    /// The first and last loud frames of the utterance in progress.
    private var firstLoud = 0
    private var speechEnd = 0
    /// Loudness of each frame since speechStart, to find a quiet place to cut a long utterance.
    private var levels: [Float] = []
    /// Loudness of the last three seconds' frames.
    private var recent: [Float] = []

    /// Adds audio; returns the utterances it completed.
    mutating func append(_ samples: [Float]) -> [Utterance] {
        buffer += samples
        var done: [Utterance] = []
        let frame = Self.frame
        while analyzed + frame <= offset + buffer.count {
            let from = analyzed - offset
            var sum: Float = 0
            for i in from..<(from + frame) { sum += buffer[i] * buffer[i] }
            let level = (sum / Float(frame)).squareRoot()
            analyzed += frame
            look(level, frameEnd: analyzed, into: &done)
        }
        if speechStart == nil { forget(before: analyzed - seconds(margin)) }
        return done
    }

    /// The utterance still being spoken, for a preview.
    var current: Utterance? {
        guard let start = speechStart else { return nil }
        return slice(start, offset + buffer.count)
    }

    /// Ends the utterance in progress, if it holds enough speech.
    mutating func flush() -> Utterance? {
        defer {
            speechStart = nil
            levels = []
            forget(before: offset + buffer.count)
            analyzed = max(analyzed, offset)
        }
        guard let start = speechStart, speechEnd - firstLoud >= seconds(shortest) else { return nil }
        return slice(start, min(offset + buffer.count, speechEnd + seconds(margin)))
    }

    private mutating func look(_ level: Float, frameEnd: Int, into done: inout [Utterance]) {
        // The background noise is the quietest frame of the last three seconds: speech always has
        // gaps between words, a hiss or a hum doesn't.
        recent.append(level)
        if recent.count > seconds(3) / Self.frame { recent.removeFirst() }
        let loud = level > max(0.002, (recent.min() ?? 0) * 3)
        if loud {
            if speechStart == nil {
                speechStart = max(offset, frameEnd - Self.frame - seconds(margin))
                firstLoud = frameEnd - Self.frame
                levels = []
            }
            speechEnd = frameEnd
        }
        guard let start = speechStart else { return }
        levels.append(level)
        let quiet = frameEnd - speechEnd
        if quiet >= seconds(longPause) || (quiet >= seconds(pause) && speechEnd - start >= seconds(enough)) {
            if speechEnd - firstLoud >= seconds(shortest) {
                done.append(slice(start, min(frameEnd, speechEnd + seconds(margin))))
            }
            speechStart = nil
            levels = []
            forget(before: frameEnd - seconds(margin))
        } else if frameEnd - start >= seconds(longest) {
            // Cut at the quietest frame of the last three seconds.
            let window = min(levels.count, seconds(3) / Self.frame)
            let tail = levels.suffix(window)
            let quietest = tail.indices.min { tail[$0] < tail[$1] } ?? levels.count - 1
            let cut = frameEnd - (levels.count - 1 - quietest) * Self.frame
            done.append(slice(start, cut))
            speechStart = cut
            firstLoud = cut
            levels = Array(levels.suffix(from: quietest + 1))
            forget(before: cut)
        }
    }

    private func slice(_ from: Int, _ to: Int) -> Utterance {
        let a = max(0, from - offset), b = max(a, min(buffer.count, to - offset))
        return Utterance(start: offset + a, samples: Array(buffer[a..<b]))
    }

    private mutating func forget(before index: Int) {
        let drop = min(buffer.count, max(0, index - offset))
        guard drop > 0 else { return }
        buffer.removeFirst(drop)
        offset += drop
    }

    private func seconds(_ s: Double) -> Int { Int(s * Double(Self.rate)) }
}
