import Foundation

/// The key that switches Claude's cleanup for one dictation. It is pressed in the middle of a
/// dictation, so it has to be a modifier key on its own: anything else would type into the app.
/// Kept free of AppKit (flags are raw CGEventFlags values) so it can be tested alone.
struct ImproveKey: Codable, Equatable {
    var keyCodes: [Int64]

    static let eitherShift = ImproveKey(keyCodes: [56, 60])

    struct Modifier {
        let name: String
        let symbol: String
        /// The generic flag (NX_*MASK), set while either key of the kind is down.
        let flag: UInt64
        /// The device-specific bit (NX_DEVICE*KEYMASK) that tells left from right.
        let deviceMask: UInt64
    }

    private static let shift: UInt64 = 0x20000, control: UInt64 = 0x40000, option: UInt64 = 0x80000
    private static let command: UInt64 = 0x100000, fn: UInt64 = 0x800000
    private static let genericFlags = shift | control | option | command

    static let modifiers: [Int64: Modifier] = [
        56: Modifier(name: "Left Shift", symbol: "⇧", flag: shift, deviceMask: 0x2),
        60: Modifier(name: "Right Shift", symbol: "⇧", flag: shift, deviceMask: 0x4),
        59: Modifier(name: "Left Control", symbol: "⌃", flag: control, deviceMask: 0x1),
        62: Modifier(name: "Right Control", symbol: "⌃", flag: control, deviceMask: 0x2000),
        58: Modifier(name: "Left Option", symbol: "⌥", flag: option, deviceMask: 0x20),
        61: Modifier(name: "Right Option", symbol: "⌥", flag: option, deviceMask: 0x40),
        55: Modifier(name: "Left Command", symbol: "⌘", flag: command, deviceMask: 0x8),
        54: Modifier(name: "Right Command", symbol: "⌘", flag: command, deviceMask: 0x10),
        63: Modifier(name: "Fn", symbol: "fn", flag: fn, deviceMask: fn),
    ]

    private static let capsLockKeyCode: Int64 = 57
    private static let escapeKeyCode: Int64 = 53

    /// Worked out from the key codes rather than stored, so a saved key always reads the same as
    /// a freshly recorded one.
    var name: String {
        if Set(keyCodes) == Set(Self.eitherShift.keyCodes) { return "Either Shift" }
        return keyCodes.compactMap { Self.modifiers[$0]?.name }.joined(separator: " or ")
    }

    var display: String {
        let symbol = keyCodes.first.flatMap { Self.modifiers[$0]?.symbol } ?? ""
        return symbol.isEmpty ? name : "\(symbol) \(name)"
    }

    /// For a modifier-change event: nil when it is not this key, else whether it went down.
    func isDown(keyCode: Int64, flags: UInt64) -> Bool? {
        guard keyCodes.contains(keyCode), let modifier = Self.modifiers[keyCode] else { return nil }
        return flags & modifier.deviceMask != 0
    }

    enum Problem: Equatable {
        case notAModifier
        case capsLock
        case combination
        /// Another app rewrites the key on its way in (a Hyper key), so it can't be recognised.
        case remapped(String)
        /// Already the dictation or lock key; the string says which.
        case taken(String, role: String)

        var message: String {
            switch self {
            case .notAModifier:
                return "Use a modifier key on its own (Shift, Control, Option, Command or Fn); other keys would type into your app."
            case .capsLock:
                return "Caps Lock switches on and off, so it can't be used."
            case .combination:
                return "Press one key on its own."
            case .remapped(let name):
                return "Another app (e.g. a Hyper key in Raycast or Karabiner) changes \(name), so it can't be told apart."
            case .taken(let name, let role):
                return "\(name) already \(role)."
            }
        }
    }

    enum Recording: Equatable {
        /// Not a key press that decides anything (a key going up, say); keep listening.
        case ignore
        case cancel
        case recorded(ImproveKey)
        case rejected(Problem)
    }

    /// What a key event means while the improve key is being recorded. `taken` maps the key codes
    /// already in use to what they do ("starts dictation").
    static func record(keyCode: Int64, flags: UInt64, isKeyDown: Bool, taken: [Int64: String]) -> Recording {
        if isKeyDown {
            let modifiersHeld = flags & (genericFlags | fn) != 0
            if keyCode == escapeKeyCode && !modifiersHeld { return .cancel }
            return .rejected(.notAModifier)
        }
        if keyCode == capsLockKeyCode { return .rejected(.capsLock) }
        guard let modifier = modifiers[keyCode], flags & modifier.flag != 0 else { return .ignore }
        if flags & modifier.deviceMask == 0 { return .rejected(.remapped(modifier.name)) }
        if flags & genericFlags & ~modifier.flag != 0 { return .rejected(.combination) }
        if let role = taken[keyCode] { return .rejected(.taken(modifier.name, role: role)) }
        return .recorded(ImproveKey(keyCodes: [keyCode]))
    }
}

/// A modifier key pressed and let go on its own. Shift held for a capital letter, or any modifier
/// held for a shortcut, is not a tap: during a locked dictation the user may be typing elsewhere.
struct SoloTap {
    private var down = false
    private var withOtherKey = false

    /// The key went down or up; true when it went up without another key in between.
    mutating func key(down isDown: Bool) -> Bool {
        defer { down = isDown }
        if isDown {
            if !down { withOtherKey = false }
            return false
        }
        return down && !withOtherKey
    }

    /// Another key (or modifier) went down; a tap in progress no longer counts.
    mutating func otherKey() {
        if down { withOtherKey = true }
    }

    mutating func reset() {
        down = false
        withOtherKey = false
    }
}
