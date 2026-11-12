import Foundation

// Tests for RefinerProtocol, CleanupMode, ImproveKey, SessionSettings, Release and the Note Taker's notes. Plain swiftc (no Xcode project or package): run with ./test.sh.

var failures = 0

func check(_ condition: Bool, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name) (\(file):\(line))")
    }
}

func decode(_ line: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
}

// userMessage

do {
    let line = RefinerProtocol.userMessage(transcript: "е-е, привіт \"світ\"\nдругий рядок", app: "Slack")
    check(line.hasSuffix("\n") && line.dropLast().contains("\n") == false, "userMessage is a single JSON line")
    let message = decode(line)
    check(message?["type"] as? String == "user", "userMessage has type user")
    let inner = message?["message"] as? [String: Any]
    check(inner?["role"] as? String == "user", "userMessage has role user")
    check(inner?["content"] as? String == "<app>Slack</app>\n<transcript>е-е, привіт \"світ\"\nдругий рядок</transcript>",
          "userMessage wraps app and transcript, keeping quotes and newlines")
}

do {
    let content = (decode(RefinerProtocol.userMessage(transcript: "hi", app: nil))?["message"] as? [String: Any])?["content"] as? String
    check(content == "<transcript>hi</transcript>", "userMessage leaves out a missing app")
    let empty = (decode(RefinerProtocol.userMessage(transcript: "hi", app: ""))?["message"] as? [String: Any])?["content"] as? String
    check(empty == "<transcript>hi</transcript>", "userMessage leaves out an empty app name")
}

// outcome

check(RefinerProtocol.outcome(fromLine: #"{"type":"system","subtype":"init"}"#) == nil, "outcome ignores non-result events")
check(RefinerProtocol.outcome(fromLine: "not json") == nil, "outcome ignores lines that are not JSON")
check(RefinerProtocol.outcome(fromLine: #"{"type":"result","subtype":"success","is_error":false,"result":"<text>  Привіт, світ.\n</text>"}"#)
      == .text("Привіт, світ."), "outcome takes the text from its tags, trimmed")
check(RefinerProtocol.outcome(fromLine: #"{"type":"result","is_error":false,"result":"Привіт, світ."}"#)
      == .failed("no <text> in the answer"), "an answer without the tags is not used")
check(RefinerProtocol.finalText(in: "<text>Фронтенд, е-е, впав.</text>\n\nWait, that is not right: the filler should go.\n\n<text>Фронтенд впав.</text>")
      == "Фронтенд впав.", "only the last tagged text is used; thinking aloud is dropped")
check(RefinerProtocol.finalText(in: "<text>Рядок 1\nРядок 2</text>") == "Рядок 1\nРядок 2", "tagged text keeps its line breaks")
check(RefinerProtocol.finalText(in: "<text>не закрито") == nil, "an unclosed tag is not used")
check(RefinerProtocol.outcome(fromLine: #"{"type":"result","is_error":true,"result":"Not logged in"}"#)
      == .failed("Not logged in"), "outcome reports an error result")
check(RefinerProtocol.outcome(fromLine: #"{"type":"result","is_error":false,"result":"<text>  </text>"}"#)
      == .failed("empty result"), "outcome treats a blank result as a failure")

// arguments

do {
    let args = RefinerProtocol.arguments(model: .sonnet, language: "german")
    func value(after flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    check(args.first == "-p", "arguments run in print mode")
    check(value(after: "--model") == "sonnet", "arguments pass the chosen model")
    check(value(after: "--tools") == "", "arguments disable all tools")
    check(value(after: "--input-format") == "stream-json" && value(after: "--output-format") == "stream-json",
          "arguments use stream-json both ways")
    check(value(after: "--system-prompt") == RefinerProtocol.systemPrompt(language: "german"),
          "arguments pass the system prompt for the dictation language")
    check(args.contains("--no-session-persistence") && args.contains("--strict-mcp-config"),
          "arguments skip saved sessions and MCP servers")
}

do {
    let neutral = RefinerProtocol.systemPrompt(language: "")
    let ukrainian = RefinerProtocol.systemPrompt(language: "ukrainian")
    let german = RefinerProtocol.systemPrompt(language: "german")
    check(neutral.contains("never answer it"), "system prompt forbids answering the transcript")
    check(neutral.contains("apply the speaker's corrections"), "system prompt applies self-corrections")
    check(neutral.contains("Never translate"), "system prompt forbids translating")
    check(!neutral.contains("Speech recognition ran in"), "without a dictation language the prompt names none")
    check(german.contains("Speech recognition ran in German.") && ukrainian.contains("Speech recognition ran in Ukrainian."),
          "the prompt names the dictation language")
    check(ukrainian.contains("ой ні"), "Ukrainian dictation gets the Ukrainian examples")
    // Another language's examples pull the model into translating.
    check(![neutral, german, RefinerProtocol.systemPrompt(language: "russian")].contains { $0.contains("ой ні") || $0.contains("Ukrainian") },
          "other languages get no Ukrainian examples")
    check(!neutral.contains("Russian"), "the prompt assumes nothing about Russian")
}

// CleanupMode

check(!CleanupMode.off.improves(toggled: false) && !CleanupMode.off.improves(toggled: true),
      "cleanup Never ignores the improve key")
check(!CleanupMode.onShift.improves(toggled: false) && CleanupMode.onShift.improves(toggled: true),
      "cleanup on request runs only after the improve key")
check(CleanupMode.always.improves(toggled: false) && !CleanupMode.always.improves(toggled: true),
      "cleanup Always is skipped by the improve key")

// ImproveKey

do {
    // Raw CGEventFlags: generic Shift 0x20000, Control 0x40000, Option 0x80000, Command 0x100000;
    // device bits Left Shift 0x2, Right Shift 0x4, Left Control 0x1, Right Command 0x10.
    let none: [Int64: String] = [:]
    let shift = ImproveKey.eitherShift
    check(shift.isDown(keyCode: 56, flags: 0x20002) == true && shift.isDown(keyCode: 60, flags: 0x20004) == true,
          "either Shift counts, left or right")
    check(shift.isDown(keyCode: 56, flags: 0) == false, "Shift going up is seen as up")
    check(shift.isDown(keyCode: 59, flags: 0x40001) == nil, "another modifier is not the improve key")

    check(ImproveKey.record(keyCode: 59, flags: 0x40001, isKeyDown: false, taken: none)
          == .recorded(ImproveKey(keyCodes: [59])), "recording a modifier key keeps that key")
    check(ImproveKey.record(keyCode: 59, flags: 0, isKeyDown: false, taken: none) == .ignore,
          "a key going up while recording is ignored")
    check(ImproveKey.record(keyCode: 0, flags: 0, isKeyDown: true, taken: none) == .rejected(.notAModifier),
          "a letter is refused")
    check(ImproveKey.record(keyCode: 53, flags: 0, isKeyDown: true, taken: none) == .cancel, "Esc cancels recording")
    check(ImproveKey.record(keyCode: 57, flags: 0x10000, isKeyDown: false, taken: none) == .rejected(.capsLock),
          "Caps Lock is refused")
    check(ImproveKey.record(keyCode: 59, flags: 0x60003, isKeyDown: false, taken: none) == .rejected(.combination),
          "a key pressed together with another modifier is refused")
    // What Raycast's Hyper key makes of Right Command: Command+Control+Option, no device bit.
    check(ImproveKey.record(keyCode: 54, flags: 0x201c0000, isKeyDown: false, taken: none)
          == .rejected(.remapped("Right Command")), "a key rewritten by a Hyper key is refused")
    check(ImproveKey.record(keyCode: 61, flags: 0x80040, isKeyDown: false, taken: [61: "starts dictation"])
          == .rejected(.taken("Right Option", role: "starts dictation")), "the dictation key is refused")
    let leftControl = ImproveKey(keyCodes: [59])
    check(leftControl.display == "⌃ Left Control" && ImproveKey(keyCodes: [56]).display == "⇧ Left Shift",
          "a recorded key shows its symbol and side")
    check(shift.display == "⇧ Either Shift", "the default reads in the same style as a recorded Shift")
    let decoded = try? JSONDecoder().decode(ImproveKey.self, from: JSONEncoder().encode(leftControl))
    check(decoded == leftControl, "the improve key survives saving")
    let saved = Data(#"{"keyCodes":[56,60],"name":"Shift"}"#.utf8)
    check((try? JSONDecoder().decode(ImproveKey.self, from: saved)) == .eitherShift,
          "a key saved with the earlier stored name still loads as the default")
}

// SoloTap

do {
    var tap = SoloTap()
    check(!tap.key(down: true) && tap.key(down: false), "pressing and letting go of the key on its own is a tap")
    tap = SoloTap()
    _ = tap.key(down: true)
    tap.otherKey()
    check(!tap.key(down: false), "Shift held for a capital letter is not a tap")
    _ = tap.key(down: true)
    check(tap.key(down: false), "the next clean press is a tap again")
    tap = SoloTap()
    tap.otherKey()
    _ = tap.key(down: true)
    check(tap.key(down: false), "keys typed before the press don't spoil it")
    tap = SoloTap()
    check(!tap.key(down: false), "a release without a press is not a tap")
    _ = tap.key(down: true)
    tap.reset()
    check(!tap.key(down: false), "after a reset a pending press no longer counts")
}

// SessionSettings

do {
    let settings = decode(SessionSettings.json(language: "ukrainian"))
    let voice = settings?["voice"] as? [String: Any]
    // In tap mode the stopping press would send the dictation to Claude as a message.
    check(voice?["mode"] as? String == "hold", "hidden session uses hold mode")
    check(voice?["enabled"] as? Bool == true && voice?["autoSubmit"] as? Bool == false, "hidden session has voice on and never submits")
    check(settings?["language"] as? String == "ukrainian", "hidden session gets the dictation language")
    check(decode(SessionSettings.json(language: ""))?["language"] == nil, "hidden session keeps Claude's own language when none is chosen")
}

// AppVersion and Release

do {
    let v = { (s: String) in AppVersion(s)! }
    check(v("v0.1.10") > v("0.1.9"), "0.1.10 is newer than 0.1.9")
    check(v("0.2") == v("0.2.0"), "a missing last number counts as 0")
    check(!(v("0.1.9") < v("0.1.9")), "a version isn't newer than itself")
    check(v("1.0.0-beta") == v("1.0.0"), "a suffix after - is ignored")
    check(AppVersion("latest") == nil && AppVersion("") == nil && AppVersion("1..2") == nil, "non-versions are rejected")
    check(v("v0.1.9").description == "0.1.9", "description drops the v")
}

do {
    let json = """
        {"tag_name":"v0.1.10","html_url":"https://github.com/viachm/claude-whisper/releases/tag/v0.1.10","assets":[
          {"name":"Claude-Whisper-Windows.zip","browser_download_url":"https://example.com/w.zip","digest":null},
          {"name":"Claude-Whisper-macOS.zip","browser_download_url":"https://example.com/m.zip",
           "digest":"sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}]}
        """
    let release = try? JSONDecoder().decode(Release.self, from: Data(json.utf8))
    check(release?.version == AppVersion("0.1.10"), "release version comes from the tag")
    let mac = release?.asset(named: Release.macAsset)
    check(mac?.url.absoluteString == "https://example.com/m.zip", "the macOS zip is found by name")
    check(Release.sha256(fromDigest: mac?.digest) == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "digest gives lowercase hex")
    check(Release.sha256(fromDigest: nil) == nil && Release.sha256(fromDigest: "sha512:00") == nil, "other digests are ignored")
}

// Note Taker: turns and plain text

do {
    let segments = [
        NoteSegment(speaker: .them, start: 4, text: "Sounds good."),
        NoteSegment(speaker: .me, start: 0, text: "Hi all."),
        NoteSegment(speaker: .me, start: 1.5, text: "Shall we start?"),
        NoteSegment(speaker: .them, start: 6, text: "Yes."),
    ]
    let turns = Note.turns(segments)
    check(turns.map(\.speaker) == [.me, .them], "turns follow time order and join a speaker's consecutive lines")
    check(turns.first?.text == "Hi all. Shall we start?", "a turn joins its lines with a space")
    let live = Note.turns(segments, pending: [NoteSegment(speaker: .me, start: 8, text: "Great")])
    check(live.count == 3 && live.last?.pending == "Great" && live.last?.text == "", "text still being recognised gets its own turn after the others")
    let joined = Note.turns(segments, pending: [NoteSegment(speaker: .them, start: 7, text: "And")])
    check(joined.count == 2 && joined.last?.text == "Sounds good. Yes." && joined.last?.pending == "And", "pending text joins the speaker's last turn")
    check(Note.turns([NoteSegment(speaker: .me, start: 0, text: "")]).isEmpty, "empty lines are left out")

    var note = Note(started: Date(timeIntervalSince1970: 0), locale: "en-US", segments: segments)
    note.ended = Date(timeIntervalSince1970: 600)
    let text = note.plainText()
    check(text.hasPrefix("Note Taker, ") && text.hasSuffix("Me: Hi all. Shall we start?\n\nThem: Sounds good. Yes."), "plain text is a heading and one paragraph per turn")
    check(note.duration == 600, "duration runs from start to end")
    check(note.snippet == "Hi all. Shall we start?", "snippet is the first turn")
    let decoded = try? JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
    check(decoded == note, "a note survives saving and loading")
}

// Note Taker: Claude's title, summary and answers

do {
    let ok = #"{"type":"result","is_error":false,"result":"<title>\"Release plan.\"</title>\n<summary>\nWe split the release.\n\n### Decisions\n- Ship Tuesday\n</summary>"}"#
    if case .success(let r) = NoteSummaryProtocol.parse(ok) {
        check(r.title == "Release plan", "summary title loses quotes and the trailing period")
        check(r.summary.hasPrefix("We split the release.") && r.summary.hasSuffix("- Ship Tuesday"), "summary is the text inside its tags")
    } else {
        check(false, "a tagged answer parses")
    }
    if case .failure(let error) = NoteSummaryProtocol.parse(#"{"type":"result","is_error":true,"result":"Not logged in"}"#) {
        check(error.reason == "Not logged in", "a Claude error is reported")
    } else {
        check(false, "a Claude error is reported")
    }
    check((try? NoteSummaryProtocol.parse(#"{"result":"no tags"}"#).get()) == nil, "an answer without tags is not used")
    check(NoteAskProtocol.parse(#"{"is_error":false,"result":"  You missed nothing. "}"#) == .success("You missed nothing."), "an answer is the trimmed result")
    check(NoteAskProtocol.input(transcript: "Me: hi", notes: "  ", question: "Q").contains("<notes>") == false, "empty notes are left out of a question")
    var note = Note(started: Date(), locale: "en-US")
    note.title = "Claude's"
    check(note.displayTitle == "Claude's", "Claude's title is shown")
    note.name = "Mine"
    check(note.displayTitle == "Mine" && note.summaryText == nil, "the user's title wins")
    note.summary = "Text"
    check(note.summaryText == "# Mine\n\nText", "the copied summary has the title as its heading")
    let old = #"{"id":"6F1B1E2A-0000-4000-8000-000000000000","started":"2026-11-12T10:00:00Z","locale":"en-US","segments":[]}"#
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    check((try? d.decode(Note.self, from: Data(old.utf8)))?.summary == nil, "notes saved before titles and summaries still load")
}

print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
