import Foundation
import NaturalLanguage

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

/// Settles the language of a call recorded in Automatic. Parakeet guesses each utterance on its
/// own, so an English phrase in a Ukrainian call comes out in English; once the call's first
/// lines show its language, the note keeps to it.
struct LanguageDetector {
    /// Letters heard before deciding: a few sentences.
    var enough = 120
    /// How sure the guess has to be.
    var confidence = 0.7
    private var text = ""

    /// Adds a finished line; returns the call's language once it is clear.
    mutating func add(_ line: String) -> String? {
        text += " " + line
        guard text.unicodeScalars.filter(CharacterSet.letters.contains).count >= enough else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = NoteLanguage.parakeet.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
              probability >= confidence, NoteLanguage.parakeet.contains(language.rawValue) else { return nil }
        return language.rawValue
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

/// How loud speech is in a recording, to play the microphone and the call equally loud: a
/// microphone is often ten times quieter than the call.
enum SpeechLevel {
    /// The median loudness of the stretches (e.g. half seconds, as RMS) that stand out from the
    /// recording's background noise; nil when none do.
    static func of(_ levels: [Float]) -> Float? {
        guard !levels.isEmpty else { return nil }
        let floor = levels.sorted()[levels.count / 5]
        let speech = levels.filter { $0 > max(floor * 4, 0.003) }.sorted()
        return speech.isEmpty ? nil : speech[speech.count / 2]
    }

    /// How loud the user's own microphone plays next to the call: a little quieter, since your
    /// own voice sounds louder to you than the same level of someone else's.
    static let ownShare: Float = 0.9

    /// The gain for each recording that brings its speech to the loudest one's (the microphone's,
    /// `mine`, to `ownShare` of it), raising at most 12× (a track with no speech plays as it is).
    static func gains(_ levels: [Float?], mine: [Bool] = []) -> [Float] {
        let loudest = levels.compactMap { $0 }.max() ?? 0
        return levels.enumerated().map { index, level in
            guard let level, level > 0 else { return 1 }
            let target = loudest * (index < mine.count && mine[index] ? ownShare : 1)
            return min(12, target / level)
        }
    }
}

/// Tells when the call being recorded seems to be over: someone spoke and then nobody has for
/// three minutes, or the call app (Zoom, Teams, a browser with Meet) took the microphone and let it go.
/// It asks once; after the question is closed (or people talk again) only a new sign asks again.
struct CallEndDetector {
    static let silence: TimeInterval = 180
    /// How long the call app must have let go of the microphone (not a brief device switch).
    static let release: TimeInterval = 10
    static let micReleased = "the call app let go of the microphone"

    private var lastSpeech: Date
    private var spoke = false
    private var callAppSeen = false
    private var micFreeSince: Date?
    private(set) var asked = false

    init(now: Date) { lastSpeech = now }

    mutating func heard(at now: Date) {
        lastSpeech = now
        spoke = true
    }

    /// `callAppRecording`: whether another app records from the microphone (nil when unknown).
    /// Returns why the call seems over, the first time it does.
    mutating func check(callAppRecording: Bool?, now: Date) -> String? {
        if let recording = callAppRecording {
            if recording {
                callAppSeen = true
                micFreeSince = nil
            } else if callAppSeen, micFreeSince == nil {
                micFreeSince = now
            }
        }
        guard !asked else { return nil }
        if spoke, now.timeIntervalSince(lastSpeech) >= Self.silence {
            asked = true
            return "nobody has spoken for 3 minutes"
        }
        if let free = micFreeSince, now.timeIntervalSince(free) >= Self.release {
            asked = true
            return Self.micReleased
        }
        return nil
    }

    /// The notification closed, or people talking again: asks again only once someone speaks and then
    /// falls silent, or the call app takes the microphone and lets it go again.
    mutating func keep(now: Date) {
        asked = false
        spoke = false
        callAppSeen = false
        micFreeSince = nil
        lastSpeech = now
    }

    /// After a pause, the silence counts from the resume.
    mutating func resumed(now: Date) {
        lastSpeech = now
        micFreeSince = nil
    }
}

/// Tells when a call seems to have started while Note Taker isn't recording: a call app (or a
/// browser, for Meet) has kept the microphone for 10 seconds. It asks once each time an app takes
/// the microphone, and not about a call that was being recorded.
struct CallStartDetector {
    /// The setting (on unless turned off).
    static let key = "noteTakerSuggestStart"
    static let hold: TimeInterval = 10
    /// Bundle id prefixes of the apps calls happen in, with the names shown in the notification.
    static let callApps: [(prefix: String, name: String)] = [
        ("com.microsoft.teams", "Teams"), ("us.zoom", "Zoom"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"), ("com.cisco.webex", "Webex"), ("com.webex", "Webex"),
        ("com.hnc.Discord", "Discord"), ("net.whatsapp.WhatsApp", "WhatsApp"), ("ru.keepcoder.Telegram", "Telegram"),
        ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("company.thebrowser", "Arc"),
        ("com.microsoft.edgemac", "Edge"), ("org.mozilla.firefox", "Firefox"), ("com.brave.Browser", "Brave"),
    ]

    private var since: [String: Date] = [:]
    private var asked: Set<String> = []

    static func name(of bundle: String) -> String? {
        callApps.first { bundle.hasPrefix($0.prefix) }?.name
    }

    /// `apps`: the other apps recording from the microphone. Returns the call app to suggest
    /// recording in, the first time it has held the microphone long enough.
    mutating func check(apps: Set<String>, recording: Bool, now: Date) -> String? {
        let calls = apps.filter { Self.name(of: $0) != nil }
        since = since.filter { calls.contains($0.key) }
        asked.formIntersection(calls)
        for app in calls where since[app] == nil { since[app] = now }
        // Stopping a recording mid-call doesn't bring the question up.
        if recording { asked.formUnion(calls) }
        guard let app = calls.sorted().first(where: { app in
            !asked.contains(app) && now.timeIntervalSince(since[app] ?? now) >= Self.hold
        }) else { return nil }
        asked.insert(app)
        return app
    }

    /// Whether an app it asked about still holds the microphone.
    var askedAppHolds: Bool { !asked.isEmpty }
}
