import Foundation

/// The key Claude Code listens to for hold-to-talk, as the bytes a terminal sends for it.
/// Read from the user's `~/.claude/keybindings.json` on every press, so Claude Whisper follows
/// whatever voice key this Claude Code install uses; without a custom binding it is Space,
/// Claude Code's default.
enum VoiceKey {
    static let action = "voice:pushToTalk"

    static func bytes() -> String {
        guard let key = configuredKey() else { return " " }
        if let encoded = encode(key) { return encoded }
        Log.write("voice key \"\(key)\" can't be typed into a terminal; using Space")
        return " "
    }

    // MARK: Faster start

    /// Claude Code starts listening on the first press of a modifier combo, but waits for several
    /// repeats of a bare key like Space to tell a hold from typing a space. Binding Option+K
    /// saves about 150-200 ms per dictation.
    static let fastKey = "meta+k"

    static var isFastStart: Bool { configuredKey() == fastKey }

    /// Adds or removes the Option+K push-to-talk binding in `~/.claude/keybindings.json`, leaving
    /// every other binding alone. Without it Claude Code falls back to Space.
    static func setFastStart(_ on: Bool) {
        var root = (try? Data(contentsOf: keybindingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        root["$schema"] = root["$schema"] ?? "https://www.schemastore.org/claude-code-keybindings.json"
        root["$docs"] = root["$docs"] ?? "https://code.claude.com/docs/en/keybindings"
        var blocks = root["bindings"] as? [[String: Any]] ?? []
        for i in blocks.indices where blocks[i]["context"] as? String == "Chat" {
            var bindings = blocks[i]["bindings"] as? [String: Any] ?? [:]
            bindings[fastKey] = nil
            blocks[i]["bindings"] = bindings
        }
        blocks.removeAll { $0["context"] as? String == "Chat" && ($0["bindings"] as? [String: Any])?.isEmpty == true }
        if on {
            if let i = blocks.firstIndex(where: { $0["context"] as? String == "Chat" }) {
                var bindings = blocks[i]["bindings"] as? [String: Any] ?? [:]
                bindings[fastKey] = action
                blocks[i]["bindings"] = bindings
            } else {
                blocks.append(["context": "Chat", "bindings": [fastKey: action]])
            }
        }
        root["bindings"] = blocks
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: keybindingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: keybindingsURL, options: .atomic)
            Log.write("faster start \(on ? "on" : "off"): \(keybindingsURL.path)")
        } catch {
            Log.write("could not update \(keybindingsURL.path): \(error)")
        }
    }

    // MARK: Reading the binding

    private static let keybindingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/keybindings.json")

    /// The last Chat binding for push-to-talk wins, the same rule Claude Code uses.
    private static func configuredKey() -> String? {
        guard let data = try? Data(contentsOf: keybindingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["bindings"] as? [[String: Any]] else { return nil }
        var found: String?
        for block in blocks where block["context"] as? String == "Chat" {
            guard let bindings = block["bindings"] as? [String: Any] else { continue }
            for (key, value) in bindings where value as? String == action { found = key }
        }
        return found
    }

    /// `space`, `k`, `meta+k`/`alt+k`/`opt+k` (Esc prefix), `ctrl+k` (control character),
    /// `shift+k`. Keys a terminal sends as longer escape sequences are not supported.
    private static func encode(_ binding: String) -> String? {
        var parts = binding.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.popLast() else { return nil }
        var char: String
        switch key {
        case "space": char = " "
        case let k where k.count == 1: char = k
        default: return nil
        }
        var prefix = ""
        for modifier in parts {
            switch modifier {
            case "meta", "alt", "opt", "option": prefix = "\u{1b}"
            case "shift": char = char.uppercased()
            case "ctrl", "control":
                guard let scalar = char.unicodeScalars.first, scalar.isASCII else { return nil }
                char = String(UnicodeScalar(UInt8(scalar.value & 0x1f)))
            default: return nil
            }
        }
        return prefix + char
    }
}
