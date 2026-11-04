import Foundation

// Tests for RefinerProtocol, CleanupMode, ImproveKey and SessionSettings. Plain swiftc (no Xcode project or package): run with ./test.sh.

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
check(RefinerProtocol.outcome(fromLine: #"{"type":"result","subtype":"success","is_error":false,"result":"  Привіт, світ.\n"}"#)
      == .text("Привіт, світ."), "outcome trims the result text")
check(RefinerProtocol.outcome(fromLine: #"{"type":"result","is_error":true,"result":"Not logged in"}"#)
      == .failed("Not logged in"), "outcome reports an error result")
check(RefinerProtocol.outcome(fromLine: #"{"type":"result","is_error":false,"result":"   "}"#)
      == .failed("empty result"), "outcome treats a blank result as a failure")

// arguments

do {
    let args = RefinerProtocol.arguments(model: .sonnet)
    func value(after flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    check(args.first == "-p", "arguments run in print mode")
    check(value(after: "--model") == "sonnet", "arguments pass the chosen model")
    check(value(after: "--tools") == "", "arguments disable all tools")
    check(value(after: "--input-format") == "stream-json" && value(after: "--output-format") == "stream-json",
          "arguments use stream-json both ways")
    check(value(after: "--system-prompt") == RefinerProtocol.systemPrompt, "arguments pass the system prompt")
    check(args.contains("--no-session-persistence") && args.contains("--strict-mcp-config"),
          "arguments skip saved sessions and MCP servers")
}

check(RefinerProtocol.systemPrompt.contains("never answer it"), "system prompt forbids answering the transcript")
check(RefinerProtocol.systemPrompt.contains("apply the speaker's corrections"), "system prompt applies self-corrections")
check(RefinerProtocol.systemPrompt.contains("Ukrainian and English") && RefinerProtocol.systemPrompt.contains("never Russian"),
      "system prompt targets Ukrainian and English")

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

print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
