import AppKit
import Carbon.HIToolbox

/// The key that starts dictation. The modifier keys count when pressed on their own, so they keep
/// working as modifiers; a recorded shortcut is registered as a global hot key.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightCommand, rightOption, leftOption, rightControl, fn, shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Right Option"
        case .leftOption: return "Left Option"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        case .fn: return "Fn (Globe)"
        case .shortcut: return "Shortcut…"
        }
    }

    /// The symbol printed on the key, shown next to the name in Settings; Fn uses the SF Symbol
    /// "globe" instead, since the emoji is in colour.
    var symbol: String {
        switch self {
        case .rightCommand: return "⌘"
        case .rightOption, .leftOption: return "⌥"
        case .rightControl: return "⌃"
        case .fn: return ""
        case .shortcut: return "⌨︎"
        }
    }
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    /// Hold to talk, release to type. The lock key (Right Option while holding) keeps it
    /// listening after the key is let go.
    case hold
    /// Tap to start, tap again to type.
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: return "Hold to talk"
        case .toggle: return "Tap to start, tap to stop"
        }
    }
}

/// The start and stop cues; each is synthesised by tools/make-sounds.py.
enum SoundSet: String, CaseIterable, Identifiable {
    case chime, soft, click, bubble, glass

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum OutputAction: String, CaseIterable, Identifiable {
    case paste, pasteAndReturn, copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return "Paste at the cursor"
        case .pasteAndReturn: return "Paste and press Return"
        case .copy: return "Copy to the clipboard only"
        }
    }
}

/// A key plus the modifiers held with it, as recorded in Settings. The name is taken when the
/// key is recorded, so it shows the character of the keyboard layout in use at that time.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var keyName: String

    static let escape = KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: 0, keyName: "Esc")
    static let controlOptionSpace = KeyCombo(
        keyCode: UInt16(kVK_Space),
        modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
        keyName: "Space")

    init(keyCode: UInt16, modifiers: UInt, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    init(event: NSEvent, keepModifiers: Bool) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        keyCode = event.keyCode
        modifiers = keepModifiers ? flags.rawValue : 0
        keyName = Self.specialNames[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Key \(event.keyCode)"
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        let flags = modifierFlags
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + keyName
    }

    var isFunctionKey: Bool { Self.functionKeys.contains(Int(keyCode)) }

    var carbonModifiers: UInt32 {
        let flags = modifierFlags
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
        kVK_ForwardDelete: "⌦", kVK_Escape: "Esc", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_ANSI_KeypadEnter: "Enter",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// Everything the user can change in Settings, kept in UserDefaults (`io.github.viachm.ClaudeWhisper`).
/// Each property writes itself back on change; the app watches the ones that need re-arming
/// the hotkey or restarting the Claude session.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// Dictation languages Claude Code's voice mode accepts; anything else falls back to English.
    static let languages = [
        "english", "ukrainian", "spanish", "french", "german", "portuguese", "italian", "dutch",
        "polish", "czech", "russian", "greek", "turkish", "danish", "swedish", "norwegian",
        "japanese", "korean", "hindi", "indonesian",
    ]

    /// The first Claude Code install found in the usual places (native installer, Homebrew,
    /// npm, the old local install), used while no path is set.
    static var defaultClaudePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    private let defaults = UserDefaults.standard

    @Published var trigger: TriggerKey { didSet { defaults.set(trigger.rawValue, forKey: "trigger") } }
    @Published var shortcut: KeyCombo { didSet { store(shortcut, "shortcut") } }
    @Published var mode: HotkeyMode { didSet { defaults.set(mode.rawValue, forKey: "hotkeyMode") } }
    @Published var cancelKey: KeyCombo { didSet { store(cancelKey, "cancelKey") } }

    @Published var output: OutputAction { didSet { defaults.set(output.rawValue, forKey: "output") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    @Published var soundSet: SoundSet { didSet { defaults.set(soundSet.rawValue, forKey: "soundSet") } }
    /// The slider position, 0…1; Sound curves it into the playback volume.
    @Published var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "soundVolume") } }
    @Published var showOverlay: Bool { didSet { defaults.set(showOverlay, forKey: "showOverlay") } }

    /// Press Return after pasting a held dictation into Claude: the desktop app, a terminal tab
    /// running Claude Code, or one of `autoSendApps`.
    @Published var autoSend: Bool { didSet { defaults.set(autoSend, forKey: "autoSend") } }
    /// Also send a locked (or tap-mode) dictation, which is otherwise only inserted.
    @Published var sendAfterLock: Bool { didSet { defaults.set(sendAfterLock, forKey: "sendAfterLock") } }
    /// Bundle ids where a sent dictation always gets Return.
    @Published var autoSendApps: [String] { didSet { defaults.set(autoSendApps, forKey: "autoSendApps") } }

    /// Empty means the first install found (`defaultClaudePath`). Same key as the old
    /// `defaults write … claudePath`.
    @Published var claudePath: String { didSet { storeString(claudePath, "claudePath") } }
    /// Claude Code's `language` setting for this session only; empty leaves Claude's own setting.
    @Published var language: String { didSet { storeString(language, "language") } }
    @Published var extraArguments: String { didSet { storeString(extraArguments, "extraArguments") } }

    /// True while a shortcut field is recording, so the live hotkey does not fire meanwhile.
    @Published var isRecordingShortcut = false

    private init() {
        trigger = TriggerKey(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .rightCommand
        mode = HotkeyMode(rawValue: defaults.string(forKey: "hotkeyMode") ?? "") ?? .hold
        output = OutputAction(rawValue: defaults.string(forKey: "output") ?? "") ?? .paste
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        soundSet = SoundSet(rawValue: defaults.string(forKey: "soundSet") ?? "") ?? .click
        soundVolume = defaults.object(forKey: "soundVolume") as? Double ?? 0.6
        showOverlay = defaults.object(forKey: "showOverlay") as? Bool ?? true
        autoSend = defaults.object(forKey: "autoSend") as? Bool ?? true
        sendAfterLock = defaults.object(forKey: "sendAfterLock") as? Bool ?? false
        autoSendApps = defaults.stringArray(forKey: "autoSendApps") ?? []
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        language = defaults.string(forKey: "language") ?? ""
        extraArguments = defaults.string(forKey: "extraArguments") ?? ""
        shortcut = Self.load(KeyCombo.self, "shortcut", from: defaults) ?? .controlOptionSpace
        cancelKey = Self.load(KeyCombo.self, "cancelKey", from: defaults) ?? .escape
    }

    var resolvedClaudePath: String {
        let path = claudePath.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? Self.defaultClaudePath : (path as NSString).expandingTildeInPath
    }

    /// The extra arguments split like a shell would: on spaces, with quotes grouping words.
    var extraArgumentList: [String] {
        var args: [String] = [], current = "", quote: Character?, inWord = false
        for c in extraArguments {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                inWord = true
            } else if c.isWhitespace {
                if inWord { args.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(c)
                inWord = true
            }
        }
        if inWord { args.append(current) }
        return args
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func storeString(_ value: String, _ key: String) {
        if value.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
